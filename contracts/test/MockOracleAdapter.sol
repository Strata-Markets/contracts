// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOracleAdapter } from "../tranches/symbiotic/interfaces/IOracleAdapter.sol";

/// @notice Mock oracle adapter with per-asset settable prices. Assets without a set price
///         default to $1. Placeholder until real feeds are wired. All prices are 18-decimals USD.
contract MockOracleAdapter is IOracleAdapter {

    struct TPrice {
        uint256 price;
        uint256 decimals;
        bool set;
    }

    mapping(address asset => TPrice) public prices;

    /// @notice Sets the price for an asset.
    /// @param asset The asset to price.
    /// @param price The price of one whole asset unit, scaled by 10**decimals.
    /// @param decimals The decimals of the price.
    function setPrice(address asset, uint256 price, uint256 decimals) external {
        prices[asset] = TPrice(price, decimals, true);
    }

    /// @inheritdoc IOracleAdapter
    function getPrice(address asset) external view returns (uint256 price, uint256 decimals) {
        TPrice memory p = prices[asset];
        if (p.set) {
            return (p.price, p.decimals);
        }
        // Default: $1 with 18 decimals.
        return (1e18, 18);
    }
}
