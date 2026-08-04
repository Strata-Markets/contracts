// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IStrataAccounting
/// @notice Minimal view surface of a Strata Accounting contract needed by the network middleware.
/// @dev Local interface so the Symbiotic integration does not modify the core IAccounting.
interface IStrataAccounting {
    /// @notice Coverage claimed from the insurance pool but not yet settled, in base asset.
    function insuranceAmount() external view returns (uint256);
}
