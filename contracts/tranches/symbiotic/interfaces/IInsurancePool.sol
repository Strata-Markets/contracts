// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IInsurancePool
/// @notice Shared Symbiotic insurance pool (the SymbioticManager) that tracks all covered CDOs
///         and the available insurance NAV, denominated in each market's base asset.
interface IInsurancePool {
    /// @notice Returns how much of `lossAmount` the pool can currently cover for `cdo`.
    /// @dev View: does NOT reserve or slash. The returned amount is bounded by the pool's
    ///      available insurance NAV and the market's coverage limit. Actual funds are pulled
    ///      only at settlement (settleInsurance / trueUp).
    /// @param cdo The market requesting coverage.
    /// @param lossAmount The uncovered loss, in the market's base asset.
    /// @return covered The coverable portion, in the market's base asset (<= lossAmount).
    function request(address cdo, uint256 lossAmount) external view returns (uint256 covered);
}
