// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IAprProvider} from '../../interfaces/IAprPairFeed.sol';
import {IRoundDataOracle} from '../interfaces/IRoundDataOracle.sol';

/**
 * @title Calculates APR from Oracle price increase for the latest Round
 * @notice
 */
library ChainlinkAprProviderLib {
    uint256 constant SECONDS_PER_YEAR = 31_536_000;
    int256 constant BOUND_MIN = 0;
    int256 constant BOUND_MAX = 1e12;

    /**
     * @notice Calculates the base APR for mHyper based on the exchange rate change in the latest Round
     */
    function getApr(IRoundDataOracle oracle) internal view returns (int64) {
        uint80 roundId;
        int256 ppsT1;
        uint256 t1;

        try oracle.latestRoundData() returns (
            uint80 _roundId,
            int256 _ppsT1,
            uint256,
            uint256 _t1,
            uint80
        ) {
            roundId = _roundId;
            ppsT1 = _ppsT1;
            t1 = _t1;
        } catch {
            return 0;
        }

        if (roundId == 0 || t1 == 0 || ppsT1 <= 0) {
            return 0;
        }

        uint64 originalRoundId = uint64(roundId);
        if (originalRoundId <= 1) {
            return 0;
        }

        int256 ppsT0;
        uint256 t0;
        try oracle.getRoundData(roundId - 1) returns (
            uint80,
            int256 pps,
            uint256,
            uint256 timestamp,
            uint80
        ) {
            ppsT0 = pps;
            t0 = timestamp;
        } catch {
            return 0;
        }

        if (t0 == 0 || t1 <= t0 || ppsT0 <= 0) {
            return 0;
        }

        int256 ppsChange = ppsT1 - ppsT0;
        uint256 deltaT = t1 - t0;

        int256 apr = (ppsChange * int256(SECONDS_PER_YEAR) * 1e12) / ppsT0 / int256(deltaT);

        if (apr < BOUND_MIN || apr > BOUND_MAX) {
            return 0;
        }
        return int64(apr);
    }
}
