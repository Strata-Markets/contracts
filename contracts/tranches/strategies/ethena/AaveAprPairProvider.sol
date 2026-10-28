// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IsUSDe } from "./IsUSDe.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IStrategyAprPairProvider } from "../../interfaces/IAprPairFeed.sol";

/**
 * @title sUSDe AprPairProvider with Aave as Target
 * @notice Fetches target APR from supply weighted aave assets and base APR from Ethena's sUSDe
 */
contract AaveAprPairProvider is IStrategyAprPairProvider {

    uint256 constant SECONDS_PER_YEAR = 31_536_000;
    uint256 constant VESTING_PERIOD_sUSDe = 8 hours;

    uint256 constant BOUND_MIN = 0;
    uint256 constant BOUND_MAX = .4e12;

    IAavePool public aave;
    IsUSDe public sUSDe;
    address[] public benchmarkTokens;

    constructor (
        IAavePool _aave,
        address[] memory _benchmarkTokens,
        IsUSDe _sUSDe
    ) {
        aave = _aave;
        sUSDe = _sUSDe;
        benchmarkTokens = _benchmarkTokens;
    }

    function getAprPair () external view returns (int64 aprTarget, int64 aprBase, uint64 timestamp) {
        timestamp = uint64(block.timestamp);
        aprTarget = getAPRtarget();
        aprBase = getAPRbase();
    }

    /**
     * @notice Calculates the target APR based on supply weighted aave assets
     * @dev Fetches the current APRs and totalSupply from Aave's Protocol and calculate the weighted average
     * @return The target APR as an int64, scaled by 1e12 (12 decimal places)
     */
    function getAPRtarget () public view returns (int64) {
        uint256 totalWeight = 0;
        uint256 weightedSum  = 0;
        for (uint256 i = 0; i < benchmarkTokens.length; i++) {
            (uint256 apr, uint256 totalSupply) = getAaveAssetInner(i);
            weightedSum += apr * totalSupply;
            totalWeight += totalSupply;
        }
        if (totalWeight == 0) {
            return 0;
        }
        uint256 aprAvg = weightedSum / totalWeight;
        if (aprAvg > BOUND_MAX) {
            aprAvg = BOUND_MAX;
        }
        return int64(int256(aprAvg));
    }

    /**
     * @notice Calculates the base APR for sUSDe based on the current vesting amount
     */
    function getAPRbase () public view returns (int64) {
        uint256 t1 = block.timestamp;
        uint256 t0 = sUSDe.lastDistributionTimestamp();
        uint256 deltaT = t1 - t0;

        if (deltaT >= VESTING_PERIOD_sUSDe) {
            // No distribution yet;
            return 0;
        }

        uint256 unvestedAmount = sUSDe.getUnvestedAmount();
        uint256 totalAssets = sUSDe.totalAssets();

        uint256 apr = unvestedAmount * SECONDS_PER_YEAR * 1e18
            / (VESTING_PERIOD_sUSDe - deltaT)
            / totalAssets;

        return int64(int256(apr * 1e12 / 1e18));
    }

    function getAaveAsset (uint256 i) external view returns (uint256 apr, uint256 totalSupply) {
        return getAaveAssetInner(i);
    }

    /// @notice Fetch raw Aave reserve data needed for APR & total supplied.
    function getAaveAssetInner(uint256 i) internal view returns (uint256 apr, uint256 totalSupply) {
        address asset = benchmarkTokens[i];
        (
            ,
            ,
            uint128 currentLiquidityRate,
            ,
            ,
            ,
            ,
            ,
            address aTokenAddress,
            ,
            ,
            ,
            ,
            ,
        ) = aave.getReserveData(asset);

        uint256 ONE_in = 1e27;
        uint256 ONE_out = 1e12;
        uint256 totalAToken = IERC20Metadata(aTokenAddress).totalSupply();

        apr = currentLiquidityRate * ONE_out / ONE_in;
        totalSupply = totalAToken;
    }
}


interface IAavePool {
    struct ReserveDataLegacy {
        //stores the reserve configuration
        uint256 configuration;
        //the liquidity index. Expressed in ray
        uint128 liquidityIndex;
        //the current supply rate. Expressed in ray
        uint128 currentLiquidityRate;
        //variable borrow index. Expressed in ray
        uint128 variableBorrowIndex;
        //the current variable borrow rate. Expressed in ray
        uint128 currentVariableBorrowRate;
        // DEPRECATED on v3.2.0
        uint128 currentStableBorrowRate;
        //timestamp of last update
        uint40 lastUpdateTimestamp;
        //the id of the reserve. Represents the position in the list of the active reserves
        uint16 id;
        //aToken address
        address aTokenAddress;
        // DEPRECATED on v3.2.0
        address stableDebtTokenAddress;
        //variableDebtToken address
        address variableDebtTokenAddress;
        // DEPRECATED on v3.4.0, should use the `RESERVE_INTEREST_RATE_STRATEGY` variable from the Pool contract
        address interestRateStrategyAddress;
        //the current treasury balance, scaled
        uint128 accruedToTreasury;
        // DEPRECATED on v3.4.0
        uint128 unbacked;
        //the outstanding debt borrowed against this asset in isolation mode
        uint128 isolationModeTotalDebt;
    }
    function getReserveData(address asset) external view returns (
        uint256,
        uint128,
        uint128 currentLiquidityRate,
        uint128,
        uint128,
        uint128,
        uint40 lastUpdateTimestamp,
        uint16 id,
        address aTokenAddress,
        address,
        address,
        address,
        uint128,
        uint128,
        uint128
    );
}
