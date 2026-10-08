// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Accounting Utility Library
 */
library AccountingLib {

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
        insuranceOut = Math.mulDiv(assetsOut, insuranceAmount, seniorEffective);
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
