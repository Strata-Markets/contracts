// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Accounting Utility Library
 */
library AccountingLib {

    /// @dev Full-precision proportional PnL, rounded toward zero for both gains and losses.
    ///      Assumes input/output magnitudes fit int256 and totalTime > 0.
    ///      Scaled asset-time products must fit uint256; the PnL product may exceed it.
    function proportionalPnL(int256 pnl, uint256 factor, uint256 seniorTime, uint256 totalTime)
        internal pure returns (int256)
    {
        uint256 magnitude = uint256(pnl < 0 ? -pnl : pnl);
        magnitude = Math.mulDiv(magnitude, factor * seniorTime, totalTime * 1e18);
        int256 result = int256(magnitude);
        return pnl < 0 ? -result : result;
    }

    struct InsuranceWriteDownState {
        uint256 claim;
        uint256 seniorNav;
        uint256 seniorAvailable;
        uint256 valuationCredit;
        uint256 fundedGross;
        uint256 selfFund;
        uint256 juniorAvailable;
        uint256 price;
    }

    /// @dev Finds the smallest principal loss that funds the remaining claim, including credit unwind.
    ///      Only the realized claim and settled principal can absorb a permanent write-down.
    function insuranceWriteDown(
        InsuranceWriteDownState memory state,
        uint256 fundedBase,
        uint256 maxPrincipalLoss
    ) internal pure returns (uint256) {
        uint256 shortfall = Math.saturatingSub(state.claim, fundedBase);
        if (shortfall == 0) {
            return 0;
        }
        uint256 limit = state.seniorAvailable;
        if (state.price < 1e18) {
            limit = Math.min(
                Math.saturatingSub(limit, state.valuationCredit),
                Math.saturatingSub(state.claim, state.valuationCredit)
            );
        }
        limit = Math.min(limit, shortfall);
        if (state.price == 1e18 || state.valuationCredit == 0) {
            require(shortfall <= limit, "InsuranceShortfallUnresolved");
            require(shortfall <= maxPrincipalLoss, "ExceedsMaxPrincipalLoss");
            return shortfall;
        }
        require(_insuranceClaimReduction(state, limit) >= shortfall, "InsuranceShortfallUnresolved");
        uint256 high = Math.min(limit, maxPrincipalLoss);
        require(_insuranceClaimReduction(state, high) >= shortfall, "ExceedsMaxPrincipalLoss");
        uint256 low;
        // Search cached values only; no storage writes or external calls in the loop.
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (_insuranceClaimReduction(state, mid) >= shortfall) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return low;
    }

    /// @dev Mirrors _scaleSrtFund followed by _resyncInsuranceFundNav, including rounding.
    function _insuranceClaimReduction(InsuranceWriteDownState memory state, uint256 amount)
        private pure returns (uint256)
    {
        uint256 principalBefore = Math.saturatingSub(state.seniorAvailable, state.valuationCredit);
        uint256 gross = state.fundedGross;
        uint256 selfFund = state.selfFund;
        if (principalBefore > 0) {
            gross = Math.mulDiv(gross, principalBefore - amount, principalBefore);
            selfFund = Math.mulDiv(selfFund, principalBefore - amount, principalBefore);
        }
        uint256 principalAfter = Math.saturatingSub(state.seniorNav - amount, state.valuationCredit);
        uint256 needed = Math.mulDiv(principalAfter, 1e18, state.price) - principalAfter;
        uint256 cappedFund = Math.min(selfFund, Math.mulDiv(gross, 1e18 - state.price, state.price));
        needed = Math.saturatingSub(Math.saturatingSub(needed, cappedFund), state.juniorAvailable);
        uint256 unwound = Math.min(Math.saturatingSub(state.valuationCredit, needed), state.claim - amount);
        return amount + unwound;
    }

    /// @notice Split a valuation-loss redemption using Senior's pre-exit backing.
    /// @dev The caller supplies live or settled NAV to match its redemption policy.
    ///      Junior and insurance contributions round down; Senior strategy assets bear the remainder.
    /// @return juniorOut Junior coverage consumed, excluding any separate Junior withdrawal.
    /// @return seniorStrategyOut Senior assets paid by the strategy, excluding insurance.
    /// @return insuranceOut Senior assets paid by insurance, in base-asset units.
    function splitValuatedNavOut(
        uint256 seniorNav,
        uint256 seniorEffective,
        uint256 insuranceAmount,
        uint256 assetsOut
    ) internal pure returns (uint256 juniorOut, uint256 seniorStrategyOut, uint256 insuranceOut) {
        require(assetsOut <= seniorEffective, "InsufficientSeniorNav");
        if (assetsOut == 0) {
            return (0, 0, 0);
        }
        juniorOut = Math.mulDiv(assetsOut, seniorEffective - seniorNav, seniorEffective);
        // A claim backing Junior dust can exceed Senior NAV; cap it at the remaining payout.
        insuranceOut = Math.min(assetsOut - juniorOut, Math.mulDiv(assetsOut, insuranceAmount, seniorEffective));
        seniorStrategyOut = assetsOut - juniorOut - insuranceOut;
    }

    function undoProjection (
        uint256 srtNavT1,
        uint256 srtBaseNav,
        uint256 srtPnLProjected,
        uint256 srtPaidProjected,
        uint256 jrtNavT1Real
    ) internal pure returns (uint256 jrtNavSettled, uint256 srtNavSettled) {

        uint256 storedLiveProjection = Math.saturatingSub(srtPnLProjected, srtPaidProjected);
        uint256 srtBaseNavReal = srtBaseNav - Math.min(storedLiveProjection, srtBaseNav);
        uint256 projUndo = srtNavT1 > srtBaseNavReal
            ? srtNavT1 - srtBaseNavReal
            : 0;
        projUndo = Math.min(projUndo, srtNavT1);

        srtNavSettled = srtNavT1 - projUndo;
        jrtNavSettled = jrtNavT1Real + projUndo;
        return (jrtNavSettled, srtNavSettled);
    }
}
