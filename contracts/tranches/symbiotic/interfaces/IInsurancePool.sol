// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IInsurancePool
/// @notice Shared Symbiotic insurance pool (the InsuranceMiddleware) that tracks all covered CDOs
///         and the available insurance NAV, denominated in each market's base asset.
interface IInsurancePool {
    /// @notice Returns how much of `lossAmount` the pool can currently cover for `cdo`.
    /// @dev View: does NOT reserve or slash. The returned amount is bounded by the pool's
    ///      available insurance NAV. Accounting calls coverAndSlash synchronously when booking
    ///      new coverage; fundInsuranceClaim subsequently delivers the slashed collateral.
    /// @param cdo The market requesting coverage.
    /// @param lossAmount The uncovered loss, in the market's base asset.
    /// @return covered The coverable portion, in the market's base asset (<= lossAmount).
    function request(address cdo, uint256 lossAmount) external view returns (uint256 covered);

    /// @notice Slashes coverage for `lossAmount` and returns the base actually covered.
    /// @dev State-changing counterpart to {request}, called synchronously in the same transaction the
    ///      claim is booked, so the slashable stake previewed by request() is the value slashed here.
    ///      Only the market's registered accounting may call.
    /// @param cdo The market requesting coverage.
    /// @param lossAmount The Senior-bound loss to cover, in the market's base asset.
    /// @return covered The base actually covered (<= lossAmount).
    function coverAndSlash(address cdo, uint256 lossAmount) external returns (uint256 covered);

    /// @notice Synchronizes already-slashed backing after accounting reduces its outstanding claim.
    /// @dev Only the registered accounting may call; must precede any later claim increase.
    function syncInsuranceClaim(address cdo) external;
}
