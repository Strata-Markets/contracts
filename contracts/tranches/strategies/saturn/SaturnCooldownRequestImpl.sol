// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IUnstakeHandler} from "../../interfaces/cooldown/IUnstakeHandler.sol";
import {IsUSDat, ISaturnWithdrawalQueueV2} from "./IsUSDat.sol";

/**
 * @title SaturnCooldownRequestImpl
 * @dev Implementation of the unstake process for sUSDat tokens via Saturn's WithdrawalQueueERC721.
 * This contract is designed to be used within the UnstakeCooldown contract.
 *
 * Flow:
 * 1. `request()` - calls `sUSDat.requestRedeem(shares, 0)` which:
 *    - Internally transfers sUSDat shares from this contract to the WithdrawalQueue
 *    - Mints an ERC721 NFT representing the withdrawal request to this contract
 *    - No approval needed: requestRedeem uses internal _transfer
 * 2. Saturn's off-chain processor processes the withdrawal request:
 *    - Settles the request at current NAV from the vault's USDat buffer
 *    - Marks the request as Processed in the WithdrawalQueue
 * 3. `finalize()` - calls `queue.claim(requestId)` on the WithdrawalQueueERC721:
 *    - Transfers USDat to this contract
 *    - Reverts if request is not yet processed (caught by UnstakeCooldown's try/catch)
 *    - This contract then transfers USDat to the receiver
 *
 * Note: Saturn's withdrawal queue has no fixed SLA. Processing typically takes ~7 days.
 *
 * V2 Changes:
 *   - finalize() now calls queue.claim(requestId) instead of sUSDat.claim()
 *     because V2 removed claim()/claimBatch() from the vault.
 *   - requestRedeem second param renamed from minUsdatReceived to minSharePrice
 *     (passing 0 means "no minimum" in both V1 and V2).
 */
contract SaturnCooldownRequestImpl is IUnstakeHandler, Initializable, IERC721Receiver {
    IsUSDat public immutable sUSDat;
    IERC20 public immutable USDat;

    address public handler;
    address public user;
    address public receiver;
    uint256 public requestedAt;
    uint256 public requestedAmount;
    uint256 public requestId;

    bool public pending;

    error HasActiveRequest();

    constructor(IsUSDat sUSDat_) {
        _disableInitializers();

        sUSDat = sUSDat_;
        USDat = IERC20(sUSDat_.asset());
    }

    function initialize(address handler_, address user_) public virtual initializer {
        user = user_;
        handler = handler_;
    }

    function request() external returns (uint256 unlockAt) {
        return request(user);
    }

    function request(address receiver_) public returns (uint256 unlockAt) {
        require(msg.sender == handler, "NotAuthorized");
        require(pending == false, "HasActiveRequest");

        uint256 shares = sUSDat.balanceOf(address(this));
        require(shares > 0, "NoSharesToRedeem");

        // Record the expected base asset value before the request
        // (shares will be transferred to the withdrawal queue)
        requestedAmount = sUSDat.previewRedeem(shares);

        // requestRedeem internally transfers shares from this contract to the WithdrawalQueue.
        // No approval needed — sUSDat uses internal _transfer.
        // minSharePrice = 0 (no minimum price protection at this stage)
        requestId = sUSDat.requestRedeem(shares, 0);

        requestedAt = block.timestamp;
        receiver = receiver_;
        pending = true;

        // Saturn typically processes requests within 7 days
        return block.timestamp + 7 days;
    }

    /**
     * @dev Completes the unstake request and transfers USDat to the receiver.
     * Calls queue.claim(requestId) on the WithdrawalQueueERC721 contract.
     * If the request has not yet been processed by Saturn, claim() reverts —
     * UnstakeCooldown catches this via try/catch and skips
     * the unready request without marking it as completed.
     * Can be called by the UnstakeHandler, which can be triggered permissionlessly.
     */
    function finalize() external returns (uint256 amount) {
        require(msg.sender == handler, "NotAuthorized");

        // V2: claim directly on the WithdrawalQueueERC721, not on the vault
        ISaturnWithdrawalQueueV2 queue = ISaturnWithdrawalQueueV2(sUSDat.getWithdrawalQueue());
        queue.claim(requestId);

        amount = USDat.balanceOf(address(this));
        if (amount > 0) {
            SafeERC20.safeTransfer(USDat, receiver, amount);
        }

        pending = false;
        requestedAmount = 0;
        return amount;
    }

    /**
     * @dev Sweeps any residual USDat balance to the receiver.
     * Permissionless — when pending is false, this proxy is no longer managed
     * by UnstakeCooldown, so anyone can trigger the late settlement.
     * Useful if assets arrive after finalization, or if a small remainder
     * is left behind due to rounding or partial fulfillment.
     */
    function finalizeLateSettlement() external returns (uint256 amount) {
        require(pending == false, "HasActiveRequest");

        amount = USDat.balanceOf(address(this));
        if (amount > 0) {
            SafeERC20.safeTransfer(USDat, receiver, amount);
        }
        return amount;
    }

    function getPendingAmount() external view returns (uint256 amount) {
        amount = requestedAmount;
        return amount;
    }

    /**
     * @notice Saturn withdrawals always go through the queue.
     * @dev Returns true so that the cooldown flow is always used.
     */
    function isCooldownActive() public pure returns (bool) {
        return true;
    }

    /**
     * @notice Saturn's redemption request is handled via an NFT. The WithdrawalQueue validates
     *         that the receiver can accept the NFT when the receiver's code.length > 0, which is
     *         the case for this contract.
     */
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}
