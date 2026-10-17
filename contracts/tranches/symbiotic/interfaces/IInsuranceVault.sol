// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IInsuranceVault
/// @notice Surface of the per-CDO vault holding the coverage assets that back `insuranceAmount`.
interface IInsuranceVault {
    /// @notice The token used for funded coverage (e.g. USDC).
    function coverageToken() external view returns (address);

    /// @notice Decimals of the coverage token, used to scale a base-asset amount into it.
    function coverageTokenDecimals() external view returns (uint8);

    /// @notice Funded coverage available to pay redeeming Seniors, in coverage-token units.
    function fundedCoverage() external view returns (uint256);

    /// @notice Funded coverage above the recorded claim, in coverage-token units.
    function surplusCoverage() external view returns (uint256);

    /// @notice Owner-only withdrawal of surplus after the operator checkpoints accounting.
    function withdrawSurplus(uint256 amount, address receiver) external;

    /// @notice Pays a redeeming Senior its covered slice. Reverts if the claim is not yet funded.
    function payCoverage(uint256 amount, address receiver) external;

    /// @notice Records funded coverage from the CDO, setting the coverage token if empty.
    function recordFunding(address token, uint256 amount) external;
}
