// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Accounting Utility Library
 */
library AccountingLib {

    /// @notice Splits Senior redemption amounts during valuation loss into base and loss components
    /// @dev Called during asset flow accounting when valuationPrice < 1e18 to decompose Senior's
    ///      effective NAV withdrawal into: (1) Senior's base amount, and (2) Junior's realized loss
    /// @param jrtBaseNav Current Junior base NAV
    /// @param srtBaseNav Current Senior base NAV
    /// @param ONE_ASSET Minimum asset amount to leave in each NAV
    /// @param valuationPrice Current valuation price (1e18 = $1.00)
    /// @param jrtAssetsOutEffective Junior assets being withdrawn (effective terms)
    /// @param srtAssetsOutEffective Senior assets being withdrawn (effective terms)
    /// @return jrtAssetsOut Junior base assets to deduct (includes realized loss)
    /// @return srtAssetsOut Senior base assets to deduct
    function splitValuatedNavOut(
        uint256 jrtBaseNav,
        uint256 srtBaseNav,
        uint256 ONE_ASSET,
        uint128 valuationPrice,
        uint256 jrtAssetsOutEffective,
        uint256 srtAssetsOutEffective
    ) internal pure returns (uint256 jrtAssetsOut, uint256 srtAssetsOut) {
        // During valuation loss, srtAssetsOut is in effective terms (includes Junior's contribution).
        // Split it into: Senior's base portion (adjusted by valuationPrice) and Junior's portion
        // (the difference), which realizes Junior's loss for this Senior redemption.

        uint256 jrtAvailableNav = Math.saturatingSub(jrtBaseNav, jrtAssetsOutEffective + ONE_ASSET);
        uint256 jrtLossCoverage = srtAssetsOutEffective - (srtAssetsOutEffective * valuationPrice) / 1e18;
        if (jrtLossCoverage <= jrtAvailableNav) {
            // JRT has sufficient capital to cover Senior's loss
            jrtAssetsOut = jrtAssetsOutEffective + jrtLossCoverage;
            srtAssetsOut = Math.min(
                srtAssetsOutEffective - jrtLossCoverage,
                Math.saturatingSub(srtBaseNav, ONE_ASSET)
            );
            return (jrtAssetsOut, srtAssetsOut);
        }

        // JRT is depleted. Calculate the SRT base portion (amount originally owned by the user in the Senior tranche)
        // and the remaining amount as JRT's coverage contribution
        uint256 srtTotalEffectiveNav = srtBaseNav + jrtAvailableNav;
        uint256 srtBaseWithdrawal = Math.mulDiv(
            srtAssetsOutEffective,
            srtBaseNav,
            srtTotalEffectiveNav ,
            Math.Rounding.Ceil
        );
        jrtLossCoverage = Math.min(
            srtAssetsOutEffective - srtBaseWithdrawal,
            jrtAvailableNav
        );

        jrtAssetsOut = jrtAssetsOutEffective + jrtLossCoverage;
        srtAssetsOut = srtAssetsOutEffective - jrtLossCoverage;
        return (jrtAssetsOut, srtAssetsOut);
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
