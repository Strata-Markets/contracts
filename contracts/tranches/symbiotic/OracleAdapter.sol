// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";
import { IRoundDataOracle } from "../oracles/interfaces/IRoundDataOracle.sol";

/// @title OracleAdapter
/// @notice Shared, project-wide price source for the Symbiotic coverage conversions. Prices are
///         keyed by asset (not by market), so a feed registered once is reused by every market
///         whose base asset it prices, plus the shared vault asset. Every price is returned
///         normalized to 18 decimals of USD.
/// @dev Supports an optional second hop for assets with no direct USD feed. E.g. uniBTC prices as
///      uniBTC/BTC (base) x BTC/USD (quote). Single-hop assets (USDC/USD, USDe/USD) leave quote unset.
///      getPrice() reverts for any asset without a registered feed, so the middleware cannot
///      onboard or slash a market whose base (or vault) asset is unpriced.
contract OracleAdapter is Initializable, Ownable2StepUpgradeable, PausableUpgradeable, IOracleAdapter {

    struct Feed {
        // First-hop Chainlink feed (e.g. USDC/USD, or uniBTC/BTC). address(0) = feed not set.
        IRoundDataOracle base;
        uint256 baseDecimals;
        // Optional second-hop feed to reach USD (e.g. BTC/USD). address(0) = base already quotes USD.
        IRoundDataOracle quote;
        uint256 quoteDecimals;
        // Max age (seconds) of a round before it is rejected as stale, applied to both hops. 0 = no check.
        uint256 heartbeat;
    }

    /// @notice Project-wide price registry, keyed by asset address.
    mapping(address asset => Feed) public feeds;

    error FeedNotSet(address asset);
    error InvalidPrice(address asset);
    error StalePrice(address asset, uint256 updatedAt);

    event FeedSet(address indexed asset, address base, address quote, uint256 heartbeat);
    event FeedRemoved(address indexed asset);

    uint256[49] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
    }

    // ===============================================
    // Only Owner functions

    /// @notice Registers (or replaces) an asset's price feed.
    /// @param asset The asset to price.
    /// @param base First-hop Chainlink feed read via latestRoundData().
    /// @param baseDecimals Decimals of the base feed's answer.
    /// @param quote Optional second-hop feed to reach USD; pass address(0) if base already quotes USD.
    /// @param quoteDecimals Decimals of the quote feed's answer (ignored when quote is unset).
    /// @param heartbeat Max age (seconds) before a round is rejected as stale. 0 disables the check.
    function setFeed(
        address asset,
        IRoundDataOracle base,
        uint256 baseDecimals,
        IRoundDataOracle quote,
        uint256 quoteDecimals,
        uint256 heartbeat
    ) external onlyOwner {
        require(address(base) != address(0), "ZeroAggregator");
        feeds[asset] = Feed(base, baseDecimals, quote, quoteDecimals, heartbeat);
        emit FeedSet(asset, address(base), address(quote), heartbeat);
    }

    /// @notice Removes an asset's feed. Subsequent getPrice() calls for it revert.
    function removeFeed(address asset) external onlyOwner {
        delete feeds[asset];
        emit FeedRemoved(asset);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ===============================================
    // Views

    /// @inheritdoc IOracleAdapter
    /// @dev Always returns an 18-decimal USD price. Two-hop feeds multiply base x quote.
    function getPrice(address asset) external view whenNotPaused returns (uint256 price, uint256 decimals) {
        Feed storage feed = feeds[asset];
        if (address(feed.base) == address(0)) {
            revert FeedNotSet(asset);
        }

        price = _read(asset, feed.base, feed.baseDecimals, feed.heartbeat);
        if (address(feed.quote) != address(0)) {
            uint256 quotePrice = _read(asset, feed.quote, feed.quoteDecimals, feed.heartbeat);
            price = price * quotePrice / 1e18;
        }
        return (price, 18);
    }

    /// @notice Reads one Chainlink hop and normalizes its answer to 18 decimals.
    function _read(address asset, IRoundDataOracle aggregator, uint256 feedDecimals, uint256 heartbeat) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = aggregator.latestRoundData();
        if (answer <= 0) {
            revert InvalidPrice(asset);
        }
        if (heartbeat != 0 && block.timestamp - updatedAt > heartbeat) {
            revert StalePrice(asset, updatedAt);
        }
        return uint256(answer) * 1e18 / (10 ** feedDecimals);
    }
}
