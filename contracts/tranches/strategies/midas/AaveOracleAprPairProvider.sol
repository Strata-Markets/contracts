// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IStrategyAprPairProvider} from "../../interfaces/IAprPairFeed.sol";
import {
    IAccessControlManager
} from "../../../governance/interfaces/IAccessControlManager.sol";

/**
 * @title AprPairProvider with Aave as Target APR and Oracle as Base APR
 * @notice Fetches target APR from supply weighted aave assets and base APR from Oracle price increase for the latest Round
 */
contract AaveOracleAprPairProvider is IStrategyAprPairProvider {
    bytes32 public constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");

    uint256 constant SECONDS_PER_YEAR = 31_536_000;

    uint256 constant BOUND_MIN = 0;
    uint256 constant BOUND_MAX = .4e12;

    IAccessControlManager immutable public acm;
    IAavePool immutable public aave;
    IRoundDataOracle immutable public oracle;
    address[] public benchmarkTokens;

    /// @notice Risk premium spread added on top of the Aave weighted average target APR
    int64 public spread;

    event SpreadChanged(int64 spread);

    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    modifier onlyRole(bytes32 role) {
        if (!acm.hasRole(role, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, role);
        }
        _;
    }

    constructor(
        IAccessControlManager _acm,
        IAavePool _aave,
        address[] memory _benchmarkTokens,
        IRoundDataOracle _oracle
    ) {
        acm = _acm;
        aave = _aave;
        oracle = _oracle;
        benchmarkTokens = _benchmarkTokens;
    }

    function getAprPair()
        external
        view
        returns (int64 aprTarget, int64 aprBase, uint64 timestamp)
    {
        timestamp = uint64(block.timestamp);
        aprTarget = getAPRtarget();
        aprBase = getAPRbase();
    }

    /**
     * @notice Calculates the target APR based on supply weighted aave assets
     * @dev Fetches the current APRs and totalSupply from Aave's Protocol and calculate the weighted average
     * @return The target APR as an int64, scaled by 1e12 (12 decimal places)
     */
    function getAPRtarget() public view returns (int64) {
        uint256 totalWeight = 0;
        uint256 weightedSum = 0;
        for (uint256 i = 0; i < benchmarkTokens.length; i++) {
            (uint256 apr, uint256 totalSupply) = getAaveAssetInner(i);
            weightedSum += apr * totalSupply;
            totalWeight += totalSupply;
        }
        if (totalWeight == 0) {
            return spread;
        }
        uint256 aprAvg = weightedSum / totalWeight;
        if (aprAvg > BOUND_MAX) {
            aprAvg = BOUND_MAX;
        }
        return int64(int256(aprAvg)) + spread;
    }

    /**
     * @notice Calculates the base APR for mHyper based on the exchange rate change in the latest Round
     */
    function getAPRbase() public view returns (int64) {
        (uint80 roundId, int256 ppsT1, , uint256 t1, ) = oracle
            .latestRoundData();
        if (roundId == 0 || t1 == 0 || ppsT1 <= 0) {
            return 0;
        }

        (, int256 ppsT0, , uint256 t0, ) = oracle.getRoundData(roundId - 1);

        if (t0 == 0 || t1 <= t0 || ppsT0 <= 0) {
            return 0;
        }

        int256 ppsChange = ppsT1 - ppsT0;
        uint256 deltaT = t1 - t0;

        int256 apr = (ppsChange * int256(SECONDS_PER_YEAR) * 1e12) /
            ppsT0 /
            int256(deltaT);

        if (apr < int256(BOUND_MIN) || apr > int256(BOUND_MAX)) {
            return 0;
        }
        return int64(apr);
    }

    /**
     * @notice Updates the risk premium spread applied to the target APR
     * @param _spread The new spread value, scaled by 1e12 (12 decimal places)
     */
    function setSpread(int64 _spread) external onlyRole(UPDATER_FEED_ROLE) {
        require(
            _spread >= 0 && _spread <= int64(int256(BOUND_MAX)),
            "InvalidSpread"
        );
        spread = _spread;
        emit SpreadChanged(_spread);
    }

    function getAaveAsset(
        uint256 i
    ) external view returns (uint256 apr, uint256 totalSupply) {
        return getAaveAssetInner(i);
    }

    /// @notice Fetch raw Aave reserve data needed for APR & total supplied.
    function getAaveAssetInner(
        uint256 i
    ) internal view returns (uint256 apr, uint256 totalSupply) {
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

        apr = (currentLiquidityRate * ONE_out) / ONE_in;
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
    function getReserveData(
        address asset
    )
        external
        view
        returns (
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

interface IRoundDataOracle {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function getRoundData(
        uint80 roundId
    )
        external
        view
        returns (
            uint80 _roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
