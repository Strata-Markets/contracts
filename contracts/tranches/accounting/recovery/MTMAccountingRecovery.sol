// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { MTMAccounting } from "../../MTMAccounting.sol";

/// @notice Temporary recovery implementation for terminal Junior dust backed by valuation credit.
/// @dev Adds no storage. Deploy with the original implementation's immutable settings, then
///      upgrade, recover and restore the original implementation in one owner-controlled batch.
contract MTMAccountingRecovery is MTMAccounting {
    uint256 private immutable recoveryDustLimit;

    event TerminalJuniorDustSettled(uint256 amount);

    constructor(
        uint256 navDecimals,
        bool useBenchmarkProjection_,
        bool useNavAtReconciliation_,
        bool useRatesForReconciliation_,
        bool useJuniorCoversPaidSrtProjection_,
        bool useConservativePrice_,
        bool useMTMProjection_
    )
        MTMAccounting(navDecimals, useBenchmarkProjection_, useNavAtReconciliation_, useRatesForReconciliation_, useJuniorCoversPaidSrtProjection_, useConservativePrice_, useMTMProjection_) {
        recoveryDustLimit = 10 ** navDecimals;
    }

    /// @notice Removes unsupported Junior dust and matching valuation credit, preserving recovered assets.
    /// @dev Requires matching live/settled NAV, no Senior principal, reserve or fees, and only valuation claims.
    ///      Checkpoint without valuation resync: the inconsistent credit cannot safely unwind yet.
    function settleTerminalJuniorDust() external onlyOwner nonReentrant returns (uint256 amount) {
        uint256 strategyNav = cdo.totalStrategyAssets();
        uint256 anchor = useNavAtReconciliation ? lastReconciliation : navTimestamp;
        (uint256 settledNav, uint256 settledTime, uint256 liveNav, uint256 liveTime) =
            cdo.totalStrategyAssetsSnapshot(nav, anchor);
        require(settledNav == strategyNav && liveNav == strategyNav, "UnsettledStrategyNav");
        checkpointAccountingInner(settledNav, settledTime, liveNav, liveTime);

        require(
            valuationPrice < 1e18 && reserveNav == 0 && underwriterFeeNav == 0 &&
            insuranceAmount == srtInsuranceFundNav && srtInsuranceFundNav > srtBaseNav,
            "InvalidTerminalState"
        );
        // Only the excess credit is unsupported; Junior keeps any recovered strategy assets.
        amount = srtInsuranceFundNav - srtBaseNav;
        require(
            amount <= recoveryDustLimit && jrtBaseNav >= amount &&
            nav == strategyNav && jrtBaseNav - amount == nav,
            "InvalidTerminalState"
        );

        jrtBaseNav -= amount;
        jrtNavProjected -= amount;
        insuranceAmount -= amount;
        srtInsuranceFundNav -= amount;
        _syncInsuranceClaim();
        updateAprSrt(aprTarget, aprBase);
        emit TerminalJuniorDustSettled(amount);
    }
}
