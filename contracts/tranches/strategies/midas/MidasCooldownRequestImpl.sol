// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUnstakeHandler} from "../../interfaces/cooldown/IUnstakeHandler.sol";
import {IMToken} from "./interfaces/IMToken.sol";
import {IRedemptionVault, Request } from "./interfaces/IRedemptionVault.sol";
import {RequestStatus} from "./interfaces/IManageableVault.sol";

/**
 * @title MidasCooldownRequestImpl
 * @dev Implementation of the unstake process for Midas tokens with cooldown period.
 * This contract is designed to be used within the UnstakeCooldown contract.
 * It handles the cooldown request, finalization, and asset transfer for unstaking Midas tokens.
 *
 * Flow:
 * 1. `request()` - calls `redeemRequest` on the Midas RedemptionVault.
 *    Midas creates a Request struct and holds the mTokens in the vault.
 * 2. Midas admin approves the request off-chain, which transfers the base asset (e.g. USDC)
 *    from the `requestRedeemer` to this proxy contract.
 * 3. `finalize()` - transfers the received base asset to the receiver.
 *
 * Note: For instant redemption (bypassing cooldown), users should redeem Tranche tokens
 * to mToken first, then manually call Midas `redeemInstant` to get the base asset immediately,
 * paying the Midas instant redemption fee.
 */
contract MidasCooldownRequestImpl is IUnstakeHandler, Initializable {
    IMToken public immutable mToken;
    IERC20 public immutable baseAsset;
    IRedemptionVault public immutable redemptionVault;

    address public handler;
    address public user;
    address public receiver;
    uint256 public requestedAt;
    uint256 public requestedAmount;
    uint256 public requestId;

    bool public pending;

    error HasActiveRequest();

    constructor(
        IERC20 baseAsset_,
        IMToken mToken_,
        IRedemptionVault redemptionVault_
    ) {
        _disableInitializers();

        baseAsset = baseAsset_;
        mToken = mToken_;
        redemptionVault = redemptionVault_;
    }

    function initialize(
        address handler_,
        address user_
    ) public virtual initializer {
        user = user_;
        handler = handler_;
    }

    function request() external returns (uint256 unlockAt) {
        return request(user);
    }
    function request(address receiver_) public returns (uint256 unlockAt) {
        require(msg.sender == handler, "NotAuthorized");
        require(pending == false, "HasActiveRequest");

        uint256 shares = mToken.balanceOf(address(this));
        require(shares > 0, "NoMTokenToRedeem");

        SafeERC20.forceApprove(
            IERC20(address(mToken)),
            address(redemptionVault),
            shares
        );

        // Use the "redeemRequest" path. For instant redemption, users may redeem mTokens directly
        // by paying the Midas instant fee.
        requestId = redemptionVault.redeemRequest(
            address(baseAsset),
            shares
        );

        // Query the Midas request to get the expected base asset amount
        Request memory req = redemptionVault.redeemRequests(requestId);
        // amountMToken * mTokenRate / tokenOutRate gives base18 result
        // Convert from base18 to actual tokenOut decimals (e.g. USDC = 6)
        uint256 expectedBase18 = (req.amountMToken * req.mTokenRate) / req.tokenOutRate;
        uint8 tokenOutDec = IERC20Metadata(address(baseAsset)).decimals();
        uint256 expectedBaseAssets = expectedBase18 / (10 ** (18 - tokenOutDec));

        requestedAt = block.timestamp;
        receiver = receiver_;
        pending = true;
        requestedAmount = expectedBaseAssets;

        // Midas typically processes requests within 1-3 days
        return block.timestamp + 3 days;

    }

    /**
     * @dev Completes the unstake request and transfers assets to the receiver.
     * After Midas admin approves the request, the base asset is transferred
     * from the requestRedeemer to this proxy. This function transfers those assets
     * to the final receiver.
     * Reverts if Midas request is still pending (not yet approved or canceled) —
     * this allows UnstakeCooldown to skip unready requests via try/catch
     * without marking them as completed.
     * Can be called by the UnstakeHandler, which can be triggered permissionlessly.
     */
    function finalize() external returns (uint256 amount) {
        require(msg.sender == handler, "NotAuthorized");

        Request memory req = redemptionVault.redeemRequests(requestId);
        require (req.status != RequestStatus.Pending, "RequestPending");
        amount = baseAsset.balanceOf(address(this));
        if (amount > 0) {
            SafeERC20.safeTransfer(baseAsset, receiver, amount);
        }

        if (req.status == RequestStatus.Canceled) {
            // If the request was canceled, return any mToken balance to the receiver (just in case)
            uint256 shares = mToken.balanceOf(address(this));
            if (shares > 0) {
                SafeERC20.safeTransfer(mToken, receiver, shares);
            }
        }

        pending = false;
        requestedAmount = 0;
        requestId = 0;
        return amount;
    }

    /**
     * @dev Sweeps any residual base asset balance to the receiver.
     * Permissionless — when pending is false, this proxy is no longer managed
     * by UnstakeCooldown, so anyone can trigger the late settlement.
     * Useful if assets arrive after finalization, or if a small remainder
     * is left behind due to rounding or partial fulfillment.
     */
    function finalizeLateSettlement() external returns (uint256 amount) {
        require(pending == false, "HasActiveRequest");

        amount = baseAsset.balanceOf(address(this));
        if (amount > 0) {
            SafeERC20.safeTransfer(baseAsset, receiver, amount);
        }
        return amount;
    }

    function getPendingAmount() external view returns (uint256 amount) {
        amount = requestedAmount;
        return amount;
    }

    /**
     * @notice Midas redemptions go through the cooldown flow.
     * @dev Returns true so that the cooldown flow is always used.
     */
    function isCooldownActive() public pure returns (bool) {
        return true;
    }
}
