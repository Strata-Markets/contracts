// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IsUSDe} from "../ethena/IsUSDe.sol";
import {IStrategyAprPairProvider} from "../../interfaces/IAprPairFeed.sol";
import {SparkUSDCStrategy} from "./SparkUSDCStrategy.sol";

/**
 * @title SparkAprPairProvider
 * @notice Fetches target APR from Ethena's sUSDe vesting and base APR from the Spark strategy's internal vesting state.
 */
contract SparkAprPairProvider is IStrategyAprPairProvider {
    uint256 constant SECONDS_PER_YEAR = 31_536_000;
    uint256 constant VESTING_PERIOD_sUSDe = 8 hours;

    uint256 constant BOUND_MIN = 0;
    uint256 constant BOUND_MAX = 0.4e12;

    IsUSDe public immutable sUSDe;
    SparkUSDCStrategy public immutable strategy;

    constructor(IsUSDe _sUSDe, SparkUSDCStrategy strategy_) {
        sUSDe = _sUSDe;
        strategy = strategy_;
    }

    function getAprPair() external view returns (int64 aprTarget, int64 aprBase, uint64 timestamp) {
        timestamp = uint64(block.timestamp);
        aprTarget = getAPRtarget();
        aprBase = getAPRbase();
    }

    /**
     * @notice Calculates the target APR based on Ethena's sUSDe vesting.
     * @return The target APR as an int64, scaled by 1e12 (12 decimal places).
     */
    function getAPRtarget() public view returns (int64) {
        uint256 t1 = block.timestamp;
        uint256 t0 = sUSDe.lastDistributionTimestamp();
        uint256 deltaT = t1 - t0;

        if (deltaT >= VESTING_PERIOD_sUSDe) {
            return 0;
        }

        uint256 unvestedAmount = sUSDe.getUnvestedAmount();
        uint256 totalAssets = sUSDe.totalAssets();
        if (totalAssets == 0) return 0;

        uint256 apr = unvestedAmount * SECONDS_PER_YEAR * 1e18 / (VESTING_PERIOD_sUSDe - deltaT)
            / totalAssets;

        return int64(int256(apr * 1e12 / 1e18));
    }

    /**
     * @notice Calculates the base APR from the Spark strategy's active 24-hour vesting window.
     * @return The base APR as an int64, scaled by 1e12 (12 decimal places).
     */
    function getAPRbase() public view returns (int64) {
        uint256 vestingPeriod_ = strategy.VESTING_PERIOD();
        uint256 t0 = strategy.lastDistributionTimestamp();
        uint256 deltaT = block.timestamp - t0;

        if (deltaT >= vestingPeriod_) return 0;

        uint256 unvestedAmount = strategy.getUnvestedAmount();
        uint256 totalAssets_ = strategy.totalAssets();

        if (totalAssets_ == 0) return 0;

        uint256 apr =
            unvestedAmount * SECONDS_PER_YEAR * 1e18 / (vestingPeriod_ - deltaT) / totalAssets_;

        int64 result = int64(int256(apr * 1e12 / 1e18));
        if (result < 0 || uint64(result) > BOUND_MAX) return 0;
        return result;
    }
}
