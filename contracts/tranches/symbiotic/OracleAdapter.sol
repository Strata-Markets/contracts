// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;
import { AccessControlled } from "../../governance/AccessControlled.sol";
import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";
import { IRoundDataOracle } from "../oracles/interfaces/IRoundDataOracle.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OracleAdapter
/// @notice Shared asset price registry returning USD prices with 18 decimals.
/// @dev Quote assets link registered feeds into chains, with an independent heartbeat at each hop.
contract OracleAdapter is IOracleAdapter, AccessControlled {
    struct Feed {
        address asset;
        IRoundDataOracle aggregator;
        uint256 decimals;
        // Maximum round age in seconds; zero disables this feed's staleness check.
        uint256 heartbeat;
        // Registered quote asset; zero means the aggregator already quotes USD.
        address quoteAsset;
    }

    mapping(address asset => Feed) public feeds;

    error FeedNotSet(address asset);
    error InvalidPrice(address asset);
    error StalePrice(address asset, uint256 updatedAt);
    error CircularQuote(address asset);

    event FeedSet(address indexed asset, address aggregator, uint256 decimals, uint256 heartbeat, address quoteAsset);
    event FeedRemoved(address indexed asset);

    function initialize(address owner_, address acm_) external initializer {
        AccessControlled_init(owner_, acm_);
    }

    /// @notice Registers or replaces a feed. Register its quote chain first.
    function setFeed(Feed calldata feed) external onlyOwner {
        require(feed.asset != address(0), "ZeroAsset");
        require(address(feed.aggregator) != address(0), "ZeroAggregator");
        require(feed.decimals > 0 && feed.decimals <= 36, "InvalidDecimals");
        address quoteAsset = feed.quoteAsset;
        while (quoteAsset != address(0)) {
            if (quoteAsset == feed.asset) {
                revert CircularQuote(feed.asset);
            }
            Feed storage quote = feeds[quoteAsset];
            if (address(quote.aggregator) == address(0)) {
                revert FeedNotSet(quoteAsset);
            }
            quoteAsset = quote.quoteAsset;
        }
        feeds[feed.asset] = feed;
        emit FeedSet(feed.asset, address(feed.aggregator), feed.decimals, feed.heartbeat, feed.quoteAsset);
    }

    /// @notice Removes a feed. Prices depending on this asset also revert until it is registered again.
    function removeFeed(address asset) external onlyOwner {
        delete feeds[asset];
        emit FeedRemoved(asset);
    }

    /// @inheritdoc IOracleAdapter
    function getPrice(address asset) external view returns (uint256 price, uint256 decimals) {
        price = 1e18;
        do {
            Feed storage feed = feeds[asset];
            if (address(feed.aggregator) == address(0)) {
                revert FeedNotSet(asset);
            }
            price = Math.mulDiv(price, _read(feed), 1e18);
            asset = feed.quoteAsset;
        } while (asset != address(0));
        return (price, 18);
    }

    /// @dev Validates this hop using its own heartbeat and normalizes its answer to 18 decimals.
    function _read(Feed storage feed) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.aggregator.latestRoundData();
        if (answer <= 0) {
            revert InvalidPrice(feed.asset);
        }
        if (feed.heartbeat != 0 && block.timestamp - updatedAt > feed.heartbeat) {
            revert StalePrice(feed.asset, updatedAt);
        }
        return Math.mulDiv(uint256(answer), 1e18, 10 ** feed.decimals);
    }
}
