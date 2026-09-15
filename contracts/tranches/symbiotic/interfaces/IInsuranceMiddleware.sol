// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IAppAdapter } from "./IAppAdapter.sol";
import { IInsurancePool } from "./IInsurancePool.sol";

/// @notice Functions a Strata network middleware must expose to drive its Symbiotic AppAdapter.
interface IInsuranceMiddleware is IInsurancePool {
    /// @notice The AppAdapter this middleware controls.
    function appAdapter() external view returns (IAppAdapter);

    /// @notice Trigger a slash on the adapter to cover the given market's deficit.
    /// @param cdo The CDO address identifying the market in the coverage registry.
    function slash(address cdo) external;

    /// @notice Marks a completed insurance claim funding for a market, reducing its in-flight slashed amount.
    /// @param cdo The CDO address identifying the market in the coverage registry.
    /// @param amount The funded claim amount.
    function confirmInsuranceClaimFunding(address cdo, uint256 amount) external;

    /// @notice Release slashable coverage back to the vault.
    function release(uint256 amount) external;
}
