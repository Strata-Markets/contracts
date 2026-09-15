// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IOracleAdapter
/// @notice Prices assets in a common quote currency (e.g. USD) for coverage conversions.
interface IOracleAdapter {
    /// @notice Returns the price of an asset in the common quote currency.
    /// @param asset The asset to price.
    /// @return price The price of one whole asset unit, scaled by 10**decimals.
    /// @return decimals The decimals of the returned price.
    function getPrice(address asset) external view returns (uint256 price, uint256 decimals);
}
