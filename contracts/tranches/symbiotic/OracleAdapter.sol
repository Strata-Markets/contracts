// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";

/// @title OracleAdapter
/// @notice Prices a market's base asset (and the vault asset) in a common USD quote for the
///         deficit -> vault-asset conversion in NetworkMiddleware.
/// @dev All current Strata markets are denominated in stablecoins, so we hardcode a 1:1 USD peg.
///      A small peg deviation is harmless: the slash amount is sized off this price, and if a
///      depeg makes us over- or under-slash, the surplus slashed collateral can always be swapped
///      back to the vault asset and released/refunded to underwriters (see NetworkMiddleware.release).
///      This adapter exists as the extension point for the day a market's base asset is NOT a
///      stablecoin (e.g. an ETH- or BTC-denominated market): then getPrice must return a real feed
///      price (e.g. Chainlink) for that asset and for the vault asset.
contract OracleAdapter is IOracleAdapter {
    /// @inheritdoc IOracleAdapter
    function getPrice(address /*asset*/) external pure returns (uint256 price, uint256 decimals) {
        // Stablecoin base assets and the vault asset are treated as $1 (18 decimals).
        return (1e18, 18);
    }
}
