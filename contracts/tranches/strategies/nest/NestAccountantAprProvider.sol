// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IStrategyAprPairProvider} from "../../interfaces/IAprPairFeed.sol";
import {INestAccountant, IAprSnapshotProvider} from "./interfaces/INestContracts.sol";
import {MathLib} from "../../utils/MathLib.sol";
/// @title NestAccountantAprProvider
/// @notice Base APR provider for Nest BoringVault strategies (nALPHA, nOPAL, etc.)
/// @dev APR is computed from the rate of change of the Nest Accountant exchange rate
///      across a 10-entry ring buffer of *meaningful* snapshots. Each snapshot stores the
///      accountant exchange rate and its update timestamp in a single storage slot.
///
///      The Nest accountant updates rates in batches: the rate stays flat for hours, then
///      jumps 200-400% when yield is harvested. A single-update APR is therefore extremely
///      noisy. By measuring the rate delta across 10 meaningful entries (5~10 days), the batch
///      harvesting noise is naturally smoothed out.
///
///      An update is considered *negligible* and skipped when the instantaneous APR between
///      consecutive entries is below MIN_MEANINGFUL_APR (0.5%) AND the time elapsed is less
///      than MIN_UPDATE_PERIOD (2 days). This filters duplicate submissions, gas-bumped
///      re-submits, and zero-change periods without discarding genuine yield signals.
///
///      Implements IStrategyAprPairProvider so it can be used directly as the APR feed
///      provider for the AprPairFeed contract. targetApr is always 0 (no benchmark).
///
///      Implements IAprSnapshotProvider so strategies can call updateSnapshot() on
///      deposit/withdraw to keep the APR feed up-to-date without a keeper.

contract NestAccountantAprProvider is IStrategyAprPairProvider, IAprSnapshotProvider {
    uint256 constant SECONDS_PER_YEAR = 365 days;
    uint256 constant ONE_APR = 1e12;
    uint8   constant BUFFER_SIZE = 10;

    /// @dev Minimum annualized rate (absolute) between consecutive entries for an update
    ///      to be considered meaningful.  0.5% APR = 5e9 in SD7x12 format.
    uint256 constant MIN_MEANINGFUL_APR = 5e9;

    /// @dev Minimum time delta for a rate-unchanged update to be recorded as a genuine
    ///      zero-yield period (rather than a duplicate submission / gas bump).
    uint256 constant MIN_UPDATE_PERIOD = 2 days;

    /// @dev Preferred maximum APR lookback window. The oldest-to-current span can exceed
    ///      this period if the Nest Accountant rarely updates the price or updateSnapshot()
    ///      is called infrequently. In that case, the calculation advances through the ring
    ///      buffer and uses the oldest available entry whose span is below this limit, if one exists.
    uint256 constant MAX_APR_PERIOD = 14 days;

    /// @dev APR boundaries matching AprPairFeed.sol clamping.
    int64 constant APR_BOUNDARY_MAX = 2e12; // 200%
    int64 constant APR_BOUNDARY_MIN = -0.5e12; // -50%

    /// @dev Packed snapshot: rate (uint96) + timestamp (uint64) = 160 bits per slot.
    struct TRound {
        uint96 answer;
        uint64 updatedAt;
    }

    INestAccountant public immutable accountant;

    /// @notice Fixed-size ring buffer of meaningful rate snapshots.
    TRound[10] public buffer;

    /// @notice Write head: index of the next slot to overwrite (0..BUFFER_SIZE-1).
    uint8 public head;

    /// @notice Static target APR — always 0 (no benchmark for Nest vaults).
    int64 public constant targetApr = 0;

    /// @notice Annualized base APR in SD7x12 format, computed from oldest->newest buffer entries.
    int64 public baseApr;

    /// @param accountant_ The Nest Accountant contract
    /// @param rounds_     Initial buffer contents — must be exactly BUFFER_SIZE entries,
    ///                     ordered oldest-first. The deployer prepares these from historical
    ///                     accountant rate snapshots so the APR is accurate from block 1.
    constructor(INestAccountant accountant_, TRound[10] memory rounds_) {
        require(address(accountant_) != address(0), "ZeroAddress");
        require(rounds_.length == BUFFER_SIZE, "InvalidRounds");
        accountant = accountant_;

        for (uint8 i = 0; i < BUFFER_SIZE; i++) {
            buffer[i] = rounds_[i];
        }
        // head stays at 0 — next write overwrites the oldest entry

        TRound memory r0 = rounds_[0];
        TRound memory r1 = rounds_[BUFFER_SIZE - 1];
        baseApr = calculateApr(r0.answer, r1.answer, r0.updatedAt, r1.updatedAt);
    }

    /// @notice Updates the APR snapshot if the latest accountant rate represents a
    ///         *meaningful* change relative to the previous buffer entry.
    /// @dev Permissionless. Called by the strategy on every deposit/withdraw.
    ///
    ///      An update is meaningful when at least ONE of these is true:
    ///        1. The absolute instantaneous APR vs the previous entry is >= 0.5%
    ///        2. The time since the previous entry is >= 2 days (even if rate unchanged)
    ///
    ///      When an update is meaningful:
    ///        - The (rate, timestamp) pair is written to the next buffer slot.
    ///        - baseApr is recomputed as the annualized return from the *oldest* buffer
    ///          entry to the *newest* entry (spanning BUFFER_SIZE entries).
    function updateSnapshot() public {
        INestAccountant.AccountantState memory state = accountant.accountantState();
        uint96 currentRate = state.exchangeRate;
        uint64 currentTimestamp = state.lastUpdateTimestamp;

        // Previous entry in the buffer (the most recently written).
        uint8 prevIdx = head == 0 ? BUFFER_SIZE - 1 : head - 1;
        TRound memory prev = buffer[prevIdx];

        // Guard: no time progression.
        if (currentTimestamp <= prev.updatedAt) {
            return;
        }

        uint256 timeDelta = currentTimestamp - prev.updatedAt;
        if (timeDelta < MIN_UPDATE_PERIOD) {
            // -- Negligible-update filter --
            // Compute the absolute instantaneous APR between prev and current.
            int256 roundApr = MathLib.calcAprFromExchangeRates(
                prev.answer, state.exchangeRate, prev.updatedAt, state.lastUpdateTimestamp
            );
            uint256 aprAbs = roundApr < 0 ? uint256(-roundApr) : uint256(roundApr);
            // Skip when the change is negligible: small APR AND short interval.
            if (aprAbs < MIN_MEANINGFUL_APR) {
                return;
            }
        }

        // -- Compute APR from oldest -> newest --
        // `head` points at the oldest slot
        TRound memory oldest = buffer[head];

        uint256 spanDelta = currentTimestamp - oldest.updatedAt;
        if (spanDelta > MAX_APR_PERIOD) {
            for (uint8 i = 1; i < BUFFER_SIZE; i++) {
                // Move forward from the oldest entry until the span satisfies MAX_APR_PERIOD
                oldest = buffer[(head + i) % BUFFER_SIZE];
                spanDelta = currentTimestamp - oldest.updatedAt;
                if (spanDelta < MAX_APR_PERIOD) {
                    break;
                }
            }
        }

        if (spanDelta == 0 || oldest.answer == 0) {
            return;
        }
        baseApr = calculateApr(oldest.answer, currentRate, oldest.updatedAt, currentTimestamp);

        // -- Write to ring buffer --
        buffer[head] = TRound({answer: currentRate, updatedAt: currentTimestamp});
        head = (head + 1) % BUFFER_SIZE;
    }

    /// @notice Returns true if the given (rate, timestamp) would be recorded as a meaningful
    ///         entry in the ring buffer.
    /// @dev Pure view -- does not modify state. Used by the strategy's totalAssets(latestNav, timestamp)
    ///      to avoid triggering reconciliation when the accountant rate change is negligible.
    ///      Replicates the exact same filter logic as updateSnapshot().
    function isMeaningfulUpdate(uint96 rate, uint64 timestamp) external view returns (bool) {
        uint8 prevIdx = head == 0 ? BUFFER_SIZE - 1 : head - 1;
        TRound memory prev = buffer[prevIdx];

        if (timestamp == prev.updatedAt) {
            // The entry was added to the buffer by an earlier `updateSnapshot` call
            // It is meaningful if it was added
            return true;
        }
        if (timestamp < prev.updatedAt) {
            // This should not happen: the timestamp always comes from the latest
            // accountant contract update. Ignore it just in case.
            return false;
        }

        uint256 timeDelta = timestamp - prev.updatedAt;
        if (timeDelta >= MIN_UPDATE_PERIOD) {
            // Meaningful if a) enough time has passed
            return true;
        }

        int256 apr = MathLib.calcAprFromExchangeRates(prev.answer, rate, prev.updatedAt, timestamp);
        uint256 aprAbs = apr < 0 ? uint256(-apr) : uint256(apr);
        // Meaningful if b) the APR is significant
        return aprAbs >= MIN_MEANINGFUL_APR;
    }

    /// @notice Returns true if the given rate is lower than the previous buffer entry
    /// @dev Used by the strategy to delay reconciliation of negative rate changes by 24h.
    ///      Compares against the most recently written ring buffer entry.
    function isNegativeChange(uint96 rate) external view returns (bool) {
        uint8 prevIdx = head == 0 ? BUFFER_SIZE - 1 : head - 1;
        return rate < buffer[prevIdx].answer;
    }

    /// @inheritdoc IStrategyAprPairProvider
    function getAprPair()
        external
        view
        returns (int64 aprTarget, int64 aprBase, uint64 timestamp)
    {
        // BaseAPR and TargetAPR are 0 for zero-projection DYS mode.
        // Reconciliation is driven by meaningful NAV changes, not APR projection.
        return (0, 0, uint64(block.timestamp));
    }

    /// @notice Returns the real projected APR pair for UI/off-chain display.
    /// @dev Unlike getAprPair() which returns (0, 0) for the accounting feed,
    ///      this function returns the actual computed targetApr and baseApr
    ///      derived from the ring buffer, suitable for displaying the projected APY.
    function getAprPairProjected()
        external
        view
        returns (int64, int64, uint64)
    {
        return (targetApr, baseApr, uint64(block.timestamp));
    }

    /// @notice Computes the annualized APR from two rate/timestamp pairs, clamped
    ///         to [APR_BOUNDARY_MIN, APR_BOUNDARY_MAX] matching AprPairFeed bounds.
    /// @param p0  Exchange rate at the earlier snapshot
    /// @param p1  Exchange rate at the later snapshot
    /// @param t0    Timestamp of the earlier snapshot
    /// @param t1    Timestamp of the later snapshot
    /// @return apr  The clamped annualized APR in SD7x12 format
    function calculateApr(uint96 p0, uint96 p1, uint64 t0, uint64 t1)
        internal
        pure
        returns (int64)
    {
        int256 apr = MathLib.calcAprFromExchangeRates(p0, p1, t0, t1);
        if (apr > APR_BOUNDARY_MAX) {
            return APR_BOUNDARY_MAX;
        }
        if (apr < APR_BOUNDARY_MIN) {
            return APR_BOUNDARY_MIN;
        }
        return int64(apr);
    }
}
