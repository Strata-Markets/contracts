// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { DiscreteAccounting } from "../../DiscreteAccounting.sol";

/// @notice Temporary recovery implementation for terminal Junior dust backed by valuation credit.
/// @dev Adds no storage. Deploy with the original implementation's immutable settings, then
///      upgrade, recover and restore the original implementation in one owner-controlled batch.
contract DiscreteAccountingRecovery is DiscreteAccounting {
    uint256 private immutable recoveryDustLimit;
    bool private immutable recoveryUsesReconciliationNav;

    event TerminalJuniorDustSettled(uint256 amount);

    constructor(uint256 navDecimals, bool useNavAtReconciliation_)
        DiscreteAccounting(navDecimals, useNavAtReconciliation_) {
        recoveryDustLimit = 10 ** navDecimals;
        recoveryUsesReconciliationNav = useNavAtReconciliation_;
    }

    /// @notice Removes unsupported Junior dust and matching valuation credit, preserving recovered assets.
    /// @dev Requires matching live/settled NAV, no Senior principal, reserve or fees, and only valuation claims.
    ///      Checkpoint without valuation resync: the inconsistent credit cannot safely unwind yet.
    function settleTerminalJuniorDust() external onlyOwner nonReentrant returns (uint256 amount) {
        uint256 strategyNav = cdo.totalStrategyAssets();
        uint256 anchor = recoveryUsesReconciliationNav ? lastReconciliation : navTimestamp;
        require(cdo.totalStrategyAssets(nav, anchor) == strategyNav, "UnsettledStrategyNav");
        checkpointAccountingInner(strategyNav);

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
