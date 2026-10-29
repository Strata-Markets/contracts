// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ISharesCooldown} from "../../interfaces/cooldown/ISharesCooldown.sol";
import {ICooldown} from "../../interfaces/cooldown/ICooldown.sol";
import {ITranche} from "../../interfaces/ITranche.sol";
import {IStrataCDO} from "../../interfaces/IStrataCDO.sol";
import {CooldownBase} from "./CooldownBase.sol";

/**
 * @title Strata Shares Cooldown Manager
 * @notice Manages cooldown periods for vault share redemptions with configurable lock times and fees.
 * @dev This contract acts as a silo that holds vault shares during the cooldown period before redemption.
 *      Key features:
 *      - Supports multiple concurrent redemption requests per user (up to 70 active requests)
 *      - Configurable cooldown periods based on vault coverage ratios
 *      - Optional early exit with proportional fees (fee = vaultEarlyExitFeePerDay * daysRemaining)
 *      - Users can cancel pending requests and recover their shares
 *      - Supports redemptions to external receivers (limited to 40 requests per receiver)
 *
 *      Workflow:
 *      1. Tranche Vault initiates redemption via requestRedeem() - shares are locked in this contract
 *      2. After cooldown period expires, user calls finalize() to redeem underlying assets
 *      3. Alternatively, user can call finalizeWithFee() for early exit with fee
 *      4. User can cancel() pending requests to recover locked shares
 */
contract SharesCooldown is ISharesCooldown, CooldownBase {

    modifier onlyUser (address user) {
        require(msg.sender == user, "OnlySharesOwner");
        _;
    }

    mapping(address vault => mapping(address account => TRequest[] requests)) public activeRequests;
    mapping(address vault => uint256 fee)               public vaultEarlyExitFeePerDay;
    mapping(address vault => TExitUpperBounds bounds)   public vaultExitBounds;

    mapping(address vault => mapping(address account => mapping(bytes12 key => TRequestMeta meta)))
        public requestMeta;

    // Counter to generate unique keys per user
    mapping(address vault => mapping(address account => uint96 metaKeyNonce))
        private _metaKeyNonce;


    /// @notice Initiates a share redemption request with optional cooldown period and fee.
    /// @dev Called by COOLDOWN_WORKER_ROLE (typically StrataCDO) when vault coverage requires lockup or fee.
    ///      Lockup and fee values are determined using calculateExitParams() based on vault coverage.
    ///      Request handling follows the same pattern as ERC20Cooldown and UnstakeCooldown transfer methods.
    /// @param vault The tranche vault holding the shares
    /// @param token The output asset to withdraw later
    /// @param initialFrom The account initiating the redemption
    /// @param to The recipient who will receive the redeemed assets (can differ from initialFrom)
    /// @param shares Amount of vault shares to redeem
    /// @param fee Fee in basis points (1e18 = 100%) to burn from shares before locking
    /// @param cooldownSeconds Lock duration in seconds; 0 for immediate redemption
    function requestRedeem(
        ITranche vault,
        address token,
        address initialFrom,
        address to,
        uint256 shares,
        uint256 fee,
        uint32 cooldownSeconds
    ) external onlyRole(COOLDOWN_WORKER_ROLE) {
        return requestRedeemInner(vault, token, initialFrom, to, shares, fee, cooldownSeconds, bytes(""));
    }

    function requestRedeem(
        ITranche vault,
        address token,
        address initialFrom,
        address to,
        uint256 shares,
        uint256 fee,
        uint32 cooldownSeconds,
        bytes memory strategyOptions
    ) external onlyRole(COOLDOWN_WORKER_ROLE) {
        return requestRedeemInner(vault, token, initialFrom, to, shares, fee, cooldownSeconds, strategyOptions);
    }

    function requestRedeemInner(
        ITranche vault,
        address token,
        address initialFrom,
        address to,
        uint256 shares,
        uint256 fee,
        uint32 cooldownSeconds,
        bytes memory strategyOptions
    ) internal {
        if (shares == 0) {
            return;
        }
        if (fee > 0) {
            (uint256 sharesUser, ) = accrueFee(vault, shares, fee);
            shares = sharesUser;
        }
        if (cooldownSeconds == 0) {
            redeem(vault, token, shares, to, strategyOptions);
            emit Finalized(IERC20(address(vault)), to, shares);
            return;
        }

        TRequest[] storage requests = activeRequests[address(vault)][to];

        uint256 requestsCount = requests.length;
        if (initialFrom != to && requestsCount >= PUBLIC_REQUEST_SLOTS_CAP) {
            revert ExternalReceiverRequestLimitReached(
                vault,
                initialFrom,
                to,
                shares
            );
        }

        uint64 unlockAt = uint64(block.timestamp + cooldownSeconds);
        bytes12 metaKey = bytes12(0);
        if (requestsCount < MAX_ACTIVE_REQUEST_SLOTS) {
            if (
                requestsCount > 0 &&
                requests[requestsCount - 1].unlockAt == unlockAt &&
                areBytesEqual(
                    strategyOptions,
                    requestMeta[address(vault)][to][requests[requestsCount - 1].metaKey].strategyOptions
                )
            ) {
                // is requested within current block
                TRequest storage last = requests[requestsCount - 1];
                last.token = token;
                last.shares += uint192(shares);
            } else {
                // Generate unique key if options provided
                if (strategyOptions.length > 0) {
                    uint96 nonce = ++_metaKeyNonce[address(vault)][to];
                    metaKey = bytes12(uint96(nonce));
                    requestMeta[address(vault)][to][metaKey] = TRequestMeta({
                        strategyOptions: strategyOptions
                    });
                }
                requests.push(TRequest({
                    unlockAt: unlockAt,
                    shares: uint192(shares),
                    token: token,
                    metaKey: metaKey
                }));
            }
        } else {
            TRequest storage last = requests[requestsCount - 1];
            // Check if strategy options are compatible
            bytes memory lastMeta = requestMeta[address(vault)][to][last.metaKey].strategyOptions;

            if (strategyOptions.length > 0 && !areBytesEqual(lastMeta, strategyOptions)) {
                // When merging into the latest request after MAX_ACTIVE_REQUEST_SLOTS is reached,
                // new requests with non-empty strategyOptions MUST match the existing request's options.
                // If options differ, the user must wait for other requests to be processed before
                // adding new requests with different strategy parameters.
                revert("StrategyOptionsMismatch");
            }
            // Override with the user's latest token intent.
            last.token = token;
            last.shares += uint192(shares);
            if (last.unlockAt < unlockAt) {
                last.unlockAt = unlockAt;
            }
        }

        emit RequestedCooldown(address(vault), token, initialFrom, to, shares, unlockAt);
    }


    /// @notice Permissionless finalization for the user:
    ///         finalizes all ready requests using the preconfigured token at redemption time.
    /// @dev Implements the ICooldown interface.
    function finalize(IERC20 vault, address user) external returns (uint256 claimed) {
        return finalize(ITranche(address(vault)), address(0), user, block.timestamp);
    }
    function finalize(IERC20 vault, address user, uint256 at) external returns (uint256 claimed) {
        return finalize(ITranche(address(vault)), address(0), user, at);
    }

    /// @notice Permissionless finalization for the user:
    ///         finalizes specific token requests or all requests using the preconfigured token output at redemption time.
    function finalize(ITranche vault, address token, address user) external returns (uint256 claimed) {
        return finalize(vault, token, user, block.timestamp);
    }
    function finalize(ITranche vault, address token, address user, uint256 at) public nonReentrant returns (uint256 claimed) {
        if (token == address(0)) {
            claimed = _finalizeAll(address(vault), user, address(0), at, bytes(""));
        } else {
            (claimed, ) = _processFinalization(address(vault), user, token, address(0), at, bytes(""));
        }
        if (claimed == 0) {
            revert NothingToFinalize();
        }
        emit Finalized(vault, user, claimed);
        return claimed;
    }


    /// @notice Finalizes all claimable requests by redeeming to the override token.
    /// @dev Only callable by the request owner to override the per-request token.
    /// @param vault The tranche vault address.
    /// @param token The output asset to redeem for all claimable requests.
    /// @param user The request owner (must be msg.sender).
    /// @return claimed The total shares redeemed.
    function finalizeWithTokenOverride(IERC20 vault, address token, address user) external onlyUser(user) nonReentrant returns (uint256 claimed) {
        claimed = _finalizeAll(address(vault), user, token, block.timestamp, bytes(""));
        emit Finalized(vault, user, claimed);
        return claimed;
    }

    /// @notice Finalizes all claimable requests with override token and/or strategy options.
    /// @dev Only callable by the request owner to override both token and/or strategy options for all requests.
    /// @param vault The tranche vault address.
    /// @param token The output asset to redeem for all claimable requests.
    /// @param user The request owner (must be msg.sender).
    /// @param strategyOptions Custom strategy options for redemption.
    /// @return claimed The total shares redeemed.
    function finalizeWithOverrides(IERC20 vault, address token, address user, bytes calldata strategyOptions) external onlyUser(user) nonReentrant returns (uint256 claimed) {
        claimed = _finalizeAll(address(vault), user, token, block.timestamp, strategyOptions);
        emit Finalized(vault, user, claimed);
        return claimed;
    }

    /// @notice Finalizes a single redemption request with optional overrides.
    /// @dev Only callable by the request owner to override token and/or strategy options for a specific request.
    /// @param vault The tranche vault address.
    /// @param idx The index of the request in the user's active requests array.
    /// @param token The output asset to redeem (use address(0) for request's original token).
    /// @param user The request owner (must be msg.sender).
    /// @param strategyOptions Custom strategy options for redemption (empty to use request's original options).
    /// @return claimed The shares redeemed.
    function finalizeRequest(IERC20 vault, uint256 idx, address token, address user, bytes calldata strategyOptions) external onlyUser(user) nonReentrant returns (uint256 claimed) {
        claimed = _finalizeRequest(address(vault), idx, user, token, strategyOptions);
        emit Finalized(vault, user, claimed);
        return claimed;
    }

    /// @notice Finalizes a redemption request before the unlock time by paying an early exit fee.
    /// @dev Allows users to bypass the cooldown period by paying a fee proportional to the remaining lock time.
    ///      The fee is calculated as: fee = vaultEarlyExitFeePerDay * daysLeft
    ///      The fee is burned from the shares, and the remaining shares are redeemed to the user.
    ///      Only the recipient (user) can finalize their own requests early.
    ///      Scenario: If Alice redeems shares to Bob with a 7-day lock, Bob can call this function
    ///      after 3 days to receive the shares immediately by paying a fee for the remaining 4 days.
    /// @param vault The vault/tranche token address
    /// @param token Optional output asset to redeem; use ZeroAddress for the preselected token.
    /// @param user The recipient address of the redemption request (must be msg.sender)
    /// @param i The index of the request in the user's active requests array
    /// @param guard Optional user-provided guard rails to enforce expected values
    /// @param strategyOptions Overriden options for redemption (optional)
    /// @return claimed The amount of shares claimed after deducting the early exit fee
    function finalizeWithFee(
        ITranche vault,
        address token,
        address user,
        uint256 i,
        TFinalizeWithFeeGuard calldata guard,
        bytes calldata strategyOptions
    ) external onlyUser(user) nonReentrant returns (uint256 claimed) {
        TRequest[] storage requests = activeRequests[address(vault)][user];
        uint256 len = requests.length;
        require(i < len, "OutOfRange");
        TRequest memory req = requests[i];
        require(req.unlockAt > block.timestamp, "RequestReady");
        require(guard.shares == 0 || guard.shares == req.shares, "UnexpectedShares");

        bytes memory options;
        if (strategyOptions.length > 0) {
            options = strategyOptions;
        } else {
            options = requestMeta[address(vault)][user][req.metaKey].strategyOptions;
        }

        if (req.metaKey != bytes12(0)) {
            delete requestMeta[address(vault)][user][req.metaKey];
        }
        if (i < len - 1) {
            requests[i] = requests[len - 1];
        }
        requests.pop();

        uint256 shares = req.shares;
        uint256 daysLeft = (req.unlockAt - block.timestamp) / (24 * 60 * 60) + 1; // includes current day in the count
        uint256 fee = vaultEarlyExitFeePerDay[address(vault)];

        require(guard.daysLeft == 0 || guard.daysLeft == daysLeft, "UnexpectedDays");

        (uint256 sharesUser, uint256 sharesFee) = accrueFee(vault, shares, fee * daysLeft);

        // Early exits still enforce the ratio limit; price post-fee shares as the silo redeems them.
        uint256 maxAssets = IStrataCDO(vault.getCDOAddress()).maxWithdraw(address(vault));
        require(vault.quoteRedeem(sharesUser, 0) <= maxAssets, "MaxRedemptionLimitReached");

        address tokenToRedeem = token != address(0) ? token : req.token;


        redeem(vault, tokenToRedeem, sharesUser, user, options);
        emit ExitFeeAccrued(address(this), user, sharesFee, sharesUser);

        claimed = sharesUser;
    }

    /// @notice Cancels an active redemption request and returns the shares to the user.
    /// @dev The shares are transferred back to the user who is the recipient of the redemption request.
    ///      Only the recipient (user) can cancel their own requests.
    ///      Scenario: If Alice redeems shares to Bob, the shares remain locked in this contract.
    ///      Only Bob can cancel the request and receive the shares back to his account.
    /// @param vault The vault/tranche token address
    /// @param user The recipient address of the redemption request (must be msg.sender)
    /// @param i The index of the request in the user's active requests array
    /// @param guard Optional user-provided guard rails to enforce expected values
    function cancel(IERC20 vault, address user, uint256 i, TCancelGuard calldata guard) external onlyUser(user) nonReentrant {

        TRequest[] storage requests = activeRequests[address(vault)][user];
        uint256 len = requests.length;
        require(i < len, "OutOfRange");
        TRequest memory req = requests[i];
        if (req.metaKey != bytes12(0)) {
            delete requestMeta[address(vault)][user][req.metaKey];
        }
        if (i < len - 1) {
            requests[i] = requests[len - 1];
        }
        requests.pop();
        require(guard.shares == 0 || guard.shares == req.shares, "UnexpectedShares");
        vault.transfer(user, req.shares);
        emit RequestCanceled(address(vault), user, req.shares);
    }

    function balanceOf(IERC20 vault, address user) external view returns (ICooldown.TBalanceState memory) {
        return balanceOf(vault, user, block.timestamp);
    }
    function balanceOf(IERC20 vault, address user, uint256 at) public view returns (ICooldown.TBalanceState memory) {
        TRequest[] storage requests = activeRequests[address(vault)][user];

        bool isCooldownActive = isCooldownActiveInner(address(vault));

        uint256 l = requests.length;
        uint256 pending;
        uint256 claimable;
        uint256 nextUnlockAt;
        uint256 nextUnlockAmount;

        for (uint256 i; i < l; i++) {
            TRequest memory req = requests[i];
            if (isCooldownActive && req.unlockAt > at) {
                pending += req.shares;
                if (nextUnlockAt == 0 || req.unlockAt < nextUnlockAt) {
                    nextUnlockAt = req.unlockAt;
                    nextUnlockAmount = req.shares;
                    continue;
                }
                if (req.unlockAt == nextUnlockAt) {
                    nextUnlockAmount += req.shares;
                }
                continue;
            }
            claimable += req.shares;
        }
        return
            TBalanceState({
                pending: pending,
                claimable: claimable,
                nextUnlockAt: nextUnlockAt,
                nextUnlockAmount: nextUnlockAmount,
                totalRequests: l
            });
    }

    /// @notice Configures exit parameters (cooldown periods and fees) for a specific vault based on coverage thresholds.
    /// @dev Only callable by TwoStepConfigManager to ensure governance-controlled configuration changes.
    ///      Defines three coverage ranges with corresponding exit parameters:
    ///      - Range 0: coverage <= p0 (most restrictive, typically longest lock/highest fee)
    ///      - Range 1: p0 < coverage <= p1 (moderate restrictions)
    ///      - Range 2: coverage > p1 (least restrictive, typically no lock/minimal fee)
    ///      The bounds.p0 and bounds.p1 values are in parts per million (ppm), where 1e6 = 100%.
    ///      Example: p0=5000 (0.5%), p1=23000 (2.3%) creates three ranges for different coverage levels.
    /// @param vault The tranche vault address to configure
    /// @param bounds The exit bounds configuration containing coverage thresholds (p0, p1) and corresponding exit parameters (r0, r1, r2)
    function setVaultExitBounds(address vault, TExitUpperBounds calldata bounds) external onlyTwoStepConfigManager {
        require(bounds.p0 <= bounds.p1, 'P1>P0');

        vaultExitBounds[vault] = bounds;
        emit VaultCooldownBoundsUpdated(vault, bounds);
    }

    /// @notice Sets the daily early exit fee rate for a vault, capped at 1% per day.
    function setVaultEarlyExitFee(address vault, uint256 fee) external onlyOwner {
        require(fee <= 0.01e18, "InvalidFee");
        vaultEarlyExitFeePerDay[vault] = fee;

        emit VaultEarlyExitFeeSet(vault, fee);
    }

    /// @notice Calculates exit parameters (cooldown period and fee) for a vault based on current coverage ratio.
    function calculateExitParams (address vault, uint32 coveragePpm) public view returns (TExitParams memory) {
        TExitUpperBounds memory bounds = vaultExitBounds[vault];
        if (coveragePpm <= bounds.p0) return bounds.r0;
        if (coveragePpm <= bounds.p1) return bounds.r1;
        return bounds.r2;
    }

    /// @dev Returns false if cooldown is disabled (p1=0 and r2.sharesLock=0), indicating immediate finalizations are allowed.
    function isCooldownActiveInner (address vault) internal view returns (bool) {
        return vaultExitBounds[vault].p1 > 0 || vaultExitBounds[vault].r2.sharesLock > 0;
    }

    /// @dev Accrues exit fees by burning a portion of shares;
    ///      called either before lockup (immediate fee) or during early exit (proportional to remaining lock time).
    function accrueFee (ITranche vault, uint256 shares, uint256 feeBps) internal returns (uint256 sharesUser, uint256 sharesFee) {
        sharesFee = Math.mulDiv(shares, feeBps, 1e18, Math.Rounding.Floor);
        sharesUser = shares > sharesFee ? shares - sharesFee : 0;

        require(sharesUser > 0 && sharesFee > 0, "EmptyFee");
        vault.burnSharesAsFee(sharesFee, address(this));
    }

    /// @dev Finalize all requests using their output assets; when `overrideToken` is set, redeem all requests
    ///      to that token (used only through onlyUser entrypoints).
    function _finalizeAll(address vault, address user, address overridenToken, uint256 at, bytes memory strategyOptions) internal returns (uint256 claimed) {
        if (overridenToken != address(0)) {
            (claimed, ) = _processFinalization(vault, user, address(0), overridenToken, at, strategyOptions);
            return claimed;
        }
        address finalizeToken = ITranche(vault).asset();
        while (true) {
            (uint256 singleClaimed, address nextToken) = _processFinalization(vault, user, finalizeToken, overridenToken, at, strategyOptions);
            claimed += singleClaimed;
            if (nextToken == address(0)) {
                break;
            }
            finalizeToken = nextToken;
        }
        return claimed;
    }

    /// @dev Finalizes a single request by index; when `overridenToken` is set, redeem to that token.
    function _finalizeRequest(address vault, uint256 idx, address user, address overridenToken, bytes memory strategyOptions) internal returns (uint256 claimed) {
        TRequest[] storage requests = activeRequests[vault][user];
        uint256 len = requests.length;
        require(idx < len, "OutOfRange");
        TRequest memory req = requests[idx];
        bool isCooldownActive = isCooldownActiveInner(vault);
        if (isCooldownActive && req.unlockAt > block.timestamp) {
            revert("RequestLocked");
        }

        bytes memory options = strategyOptions.length != 0
            ? strategyOptions
            : requestMeta[vault][user][req.metaKey].strategyOptions;

        address token = overridenToken != address(0)
            ? overridenToken
            : req.token;

        claimed = req.shares;

        if (req.metaKey != bytes12(0)) {
            delete requestMeta[vault][user][req.metaKey];
        }
        if (idx < len - 1) {
            requests[idx] = requests[len - 1];
        }
        requests.pop();

        redeem(ITranche(vault), token, claimed, user, options);
        return claimed;
    }


    /// @notice Finalizes claimable requests for a specific or all tokens.
    /// @dev Iterates the user's requests, sums claimable shares that match `token`, and redeems them.
    ///      If `token` is zero, `overrideToken` MUST be set and all claimable requests are redeemed
    ///      using the override token (used only through onlyUser entrypoints).
    /// @param vault Tranche vault address.
    /// @param user Owner of the requests being finalized.
    /// @param token Token filter; when zero, all claimable requests are aggregated.
    /// @param tokenToRedeem Override token to withdraw (optional).
    /// @param at Timestamp used to determine claimable requests.
    /// @param strategyOptions Overriden options for redemption (optional).
    /// @return claimed Total shares redeemed in this pass.
    /// @return nextToken Next token found among remaining requests (zero if none).
    function _processFinalization(
        address vault,
        address user,
        address token,
        address tokenToRedeem,
        uint256 at,
        bytes memory strategyOptions
    ) internal returns (uint256 claimed, address nextToken) {
        if (at > block.timestamp) {
            revert InvalidTime();
        }
        if (tokenToRedeem == address(0)) {
            tokenToRedeem = token;
        }
        if (tokenToRedeem == address(0)) {
            revert ZeroAddress();
        }

        TRequest[] storage requests = activeRequests[address(vault)][user];
        bool isCooldownActive = isCooldownActiveInner(vault);

        uint256 claimedUnbatched = 0;
        uint256 len = requests.length;

        for (uint256 i; i < len; ) {
            TRequest memory req = requests[i];
            if (isCooldownActive && req.unlockAt > at) {
                // still pending
                unchecked {
                    i++;
                }
                continue;
            }
            if (token != address(0) && token != req.token) {
                if (nextToken == address(0)) {
                    nextToken = req.token;
                }
                unchecked {
                    i++;
                }
                continue;
            }
            bytes memory options = requestMeta[address(vault)][user][req.metaKey].strategyOptions;
            bool redeemUnbatched = strategyOptions.length == 0 && options.length > 0;
            if (redeemUnbatched) {
                claimedUnbatched += req.shares;
            } else {
                // Batch shares for redemption with empty or overriden options
                claimed += req.shares;
            }

            if (req.metaKey != bytes12(0)) {
                delete requestMeta[vault][user][req.metaKey];
            }
            if (i < len - 1) {
                requests[i] = requests[len - 1];
            }
            requests.pop();
            unchecked {
                len--;
            }
            if (redeemUnbatched) {
                redeem(ITranche(vault), tokenToRedeem, req.shares, user, options);
            }
        }
        if (claimed > 0) {
            redeem(ITranche(vault), tokenToRedeem, claimed, user, strategyOptions);
        }

        return (claimed + claimedUnbatched, nextToken);
    }

    function redeem (ITranche vault, address token, uint256 shares, address receiver, bytes memory strategyOptions) internal {
        if (strategyOptions.length == 0) {
            ITranche(vault).redeem(token, shares, receiver, address(this));
            return;
        }
        ITranche(vault).redeem(token, shares, receiver, address(this), ITranche.TRedemptionParams({
            exitMode: IStrataCDO.TExitMode.Dynamic,
            exitFee: 0,
            cooldownSeconds: 0,
            strategyOptions: strategyOptions
        }));
    }

    function areBytesEqual (bytes memory a, bytes memory b) internal pure returns (bool) {
        // Quick length check first
        if (a.length != b.length) {
            return false;
        }
        if (a.length == 0) {
            // Both empty
            return true;
        }
        return keccak256(a) == keccak256(b);
    }
}
