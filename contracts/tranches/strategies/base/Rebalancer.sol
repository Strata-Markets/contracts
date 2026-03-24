// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlled} from "../../../governance/AccessControlled.sol";
import {IRebalancer, IRebalanceable} from "../../interfaces/IRebalancer.sol";
import {IUnstakeCooldown, ICooldown} from "../../interfaces/cooldown/ICooldown.sol";

// Handles the rebalance flow between strats in a MultiStrategy.
//
// initiateRebalance withdraws from the source strat. If assets arrive immediately
// (e.g. Midas instant redemption), the deposit to the destination strat completes in the
// same transaction. If the withdrawal is deferred (e.g. Ethena cooldown), a PendingRebalance
// is stored; the operator finalises the underlying cooldown externally, then calls
// completeRebalance once the depositToken balance has arrived.
//
// totalAssets reports the baseAssets value locked in pending rebalances so that
// MultiStrategy can include them in its own totalAssets.
contract Rebalancer is IRebalancer, AccessControlled {
    using SafeERC20 for IERC20;

    struct PendingRebalance {
        uint256 fromStratIdx;
        uint256 toStratIdx;
        address withdrawToken;
        address shareToken;     // underlying protocol share token registered in unstakeCooldown (e.g. mHYPER for Midas)
        address depositToken;
        uint256 baseAssets;
    }

    IRebalanceable public strategy;
    IUnstakeCooldown public unstakeCooldown;

    PendingRebalance[] public pendingRebalances;

    event RebalanceInitiated(uint256 indexed fromStratIdx, uint256 indexed toStratIdx, uint256 baseAssets);
    event RebalanceCompleted(uint256 indexed fromStratIdx, uint256 indexed toStratIdx, uint256 baseAssets);

    function initialize(address owner_, address acm_, IRebalanceable strategy_, IUnstakeCooldown unstakeCooldown_) external initializer {
        AccessControlled_init(owner_, acm_);
        strategy = strategy_;
        unstakeCooldown = unstakeCooldown_;
    }

    // Initiates a rebalance from one strat to another.
    // withdrawToken: token to pull from the source strat (must be supported by that strat).
    // depositToken:  token to deposit to the destination strat (may differ if a swap is
    //                needed; for same-base-asset strategies they are the same).
    // Detects deferral by checking whether depositToken arrived at this contract after the
    // withdrawal. If not (deferred cooldown), tracks as pending until completeRebalance.
    function initiateRebalance(
        uint256 fromStratIdx,
        uint256 toStratIdx,
        address withdrawToken,
        address depositToken,
        uint256 baseAssets
    ) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        uint256 balBefore = IERC20(depositToken).balanceOf(address(this));
        strategy.withdrawForRebalance(fromStratIdx, withdrawToken, baseAssets, address(this));
        uint256 received = IERC20(depositToken).balanceOf(address(this)) - balBefore;

        if (received > 0) {
            IERC20(depositToken).forceApprove(address(strategy), received);
            strategy.depositForRebalance(toStratIdx, depositToken, received, baseAssets);
            strategy.notifyRebalanceComplete(fromStratIdx, toStratIdx, baseAssets);

            emit RebalanceCompleted(fromStratIdx, toStratIdx, baseAssets);
        } else {
            address shareToken = strategy.getStratShareToken(fromStratIdx);
            pendingRebalances.push(PendingRebalance({
                fromStratIdx: fromStratIdx,
                toStratIdx: toStratIdx,
                withdrawToken: withdrawToken,
                shareToken: shareToken,
                depositToken: depositToken,
                baseAssets: baseAssets
            }));

            emit RebalanceInitiated(fromStratIdx, toStratIdx, baseAssets);
        }
    }

    // Completes a deferred rebalance: finalises the underlying cooldown so the deposit token
    // arrives at this contract, then deposits it into the destination strat.
    function completeRebalance(uint256 idx) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        require(idx < pendingRebalances.length, "InvalidIndex");
        PendingRebalance memory pending = pendingRebalances[idx];

        unstakeCooldown.finalize(IERC20(pending.shareToken), address(this));

        uint256 available = IERC20(pending.depositToken).balanceOf(address(this));
        require(available > 0, "AssetsNotAvailable");

        IERC20(pending.depositToken).forceApprove(address(strategy), available);
        strategy.depositForRebalance(pending.toStratIdx, pending.depositToken, available, pending.baseAssets);
        strategy.notifyRebalanceComplete(pending.fromStratIdx, pending.toStratIdx, pending.baseAssets);

        uint256 last = pendingRebalances.length - 1;
        if (idx < last) {
            pendingRebalances[idx] = pendingRebalances[last];
        }
        pendingRebalances.pop();

        emit RebalanceCompleted(pending.fromStratIdx, pending.toStratIdx, pending.baseAssets);
    }

    /// @notice Returns the base asset value of all in-flight deferred rebalances.
    /// @dev Queries unstakeCooldown.balanceOf for each unique withdrawToken across pending rebalances.
    ///      Both pending and claimable amounts are included — claimable means the cooldown has elapsed
    ///      but completeRebalance has not yet been called.
    ///      Values are in base asset units because MidasCooldownRequestImpl.getPendingAmount()
    ///      stores the expected base asset amount computed at request time, not the raw token amount.
    function totalAssets() external view returns (uint256 total) {
        uint256 n = pendingRebalances.length;
        if (n == 0) return 0;
        address[] memory seen = new address[](n);
        uint256 seenCount;
        for (uint256 i; i < n; i++) {
            address tok = pendingRebalances[i].withdrawToken;
            bool found;
            for (uint256 j; j < seenCount; j++) {
                if (seen[j] == tok) { found = true; break; }
            }
            if (!found) {
                seen[seenCount++] = tok;
                ICooldown.TBalanceState memory state = unstakeCooldown.balanceOf(IERC20(tok), address(this));
                total += state.pending + state.claimable;
            }
        }
    }

    function pendingCount() external view returns (uint256) {
        return pendingRebalances.length;
    }
}
