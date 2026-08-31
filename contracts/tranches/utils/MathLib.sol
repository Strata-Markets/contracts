// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title Calculation Utility Library
 */
library MathLib {
    uint256 constant SECONDS_PER_YEAR = 365 days;
    uint256 constant ONE_APR = 1e12;

    function calcAprFromExchangeRates (uint256 p0, uint256 p1, uint256 t0, uint256 t1) internal pure returns (int256 apr){
        uint256 dt = t1 - t0;
        if (dt == 0 || p1 == p0 || p0 == 0) {
            return 0;
        }

        if (p1 > p0) {
            apr = int256((p1 - p0) * SECONDS_PER_YEAR * ONE_APR / p0 / dt);
        } else {
            uint256 aprAbs = (p0 - p1) * SECONDS_PER_YEAR * ONE_APR / p0 / dt;
            apr = -int256(aprAbs);
        }
    }
}
