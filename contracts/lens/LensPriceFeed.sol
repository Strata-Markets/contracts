// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IChainlinkPriceFeed} from "./CDOLens.sol";

/// @notice Chainlink-like fixed USD price feed for NUSD
contract LensPriceFeed is IChainlinkPriceFeed {
    uint8 public constant decimals = 8;
    uint80 internal constant ROUND_ID = 1;
    int256 internal PRICE = 1e8;

    address immutable public updater;

    constructor(address _updater) {
        updater = _updater;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 timestamp = block.timestamp;
        return (ROUND_ID, PRICE, timestamp, timestamp, ROUND_ID);
    }

    function updatePrice(int256 _price) external {
        require(msg.sender == updater, "OnlyUpdater");
        PRICE = _price;
    }
}
