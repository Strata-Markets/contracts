// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IStrategyAprPairProvider} from "../../interfaces/IAprPairFeed.sol";
import {
    IAccessControlManager
} from "../../../governance/interfaces/IAccessControlManager.sol";
import {IsUSDat} from "./IsUSDat.sol";

/// @dev V1 sUSDat interface - functions removed after V2 upgrade
interface IsUSDatV1 {
    function vestingPeriod() external view returns (uint256);
    function lastDistributionTimestamp() external view returns (uint256);
    function getUnvestedAmount() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function getStrcOracle() external view returns (address);
}

/// @dev V1 STRC price oracle - removed after V2 upgrade
interface IStrcPriceOracle {
    function getPrice() external view returns (uint256 price, uint8 decimals);
}

/**
 * @title SaturnAprPairProvider
 * @notice Provides target APR (Senior benchmark) and base APR for the Saturn CDO.
 *
 * Target APR:
 *   - Represents the Senior tranche benchmark: a fixed percentage of the STRC dividend rate.
 *   - Updatable by the feed role (the Keeper reads currentDividend from STRC API
 *     and applies a ratio, e.g. 0.7, to derive the target APR).
 *
 * Base APR:
 *   - The actual distribution rate that Saturn is currently vesting to sUSDat holders.
 *   - Supports both V1 (STRC vesting) and V2 (surplus vesting) sUSDat contracts.
 *   - getAPRbase probes vestingPeriod() to detect V1. If gone, falls back to V2.
 *   - This allows deploying the provider before Saturn upgrades to V2.
 *
 * V1: APR from STRC vesting state + STRC oracle price.
 * V2: APR from USDat surplus vesting - purely USDat distribution, no token price.
 */
contract SaturnAprPairProvider is IStrategyAprPairProvider {
    bytes32 public constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");

    uint256 constant SECONDS_PER_YEAR = 31_536_000;

    /// @notice Maximum allowed APR: 40% (scaled to 1e12)
    uint256 constant BOUND_MAX = .4e12;

    IAccessControlManager public immutable acm;
    IsUSDat public immutable sUSDat;

    /// @notice Senior benchmark APR: fixed % of STRC dividend rate
    /// @dev Updated by the Keeper when Saturn distributes new STRC rewards (~monthly).
    ///      Scaled by 1e12 (12 decimal places).
    int64 public aprTarget;

    event AprTargetUpdated(int64 oldApr, int64 newApr);

    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    modifier onlyRole(bytes32 role) {
        if (!acm.hasRole(role, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, role);
        }
        _;
    }

    constructor(IAccessControlManager acm_, IsUSDat sUSDat_, int64 aprTarget_) {
        acm = acm_;
        sUSDat = sUSDat_;
        aprTarget = aprTarget_;
    }

    function getAprPair()
        external
        view
        returns (int64 aprTarget_, int64 aprBase, uint64 timestamp)
    {
        timestamp = uint64(block.timestamp);
        aprTarget_ = aprTarget;
        aprBase = getAPRbase();
    }

    /**
     * @notice Update the target APR (benchmark for Senior tranche)
     * @dev Called by the Keeper when STRC announces the dividends.
     *      Keeper reads currentDividend from STRC API and applies seniorShare ratio.
     *      Example: currentDividend = 11.5%, seniorShare = 70% -> aprTarget = 8.05%
     * @param newAprTarget The new target APR, scaled by 1e12
     */
    function setAprTarget(int64 newAprTarget) external onlyRole(UPDATER_FEED_ROLE) {
        require(
            newAprTarget >= 0 && uint64(newAprTarget) <= BOUND_MAX,
            "InvalidAprTarget"
        );
        int64 old = aprTarget;
        aprTarget = newAprTarget;
        emit AprTargetUpdated(old, newAprTarget);
    }

    /**
     * @notice Returns the base APR - the actual distribution rate Saturn vests.
     * @dev Probes vestingPeriod() to detect V1. If it exists, uses V1 path.
     *      If vestingPeriod() is gone (post-upgrade), falls back to V2 path.
     * @return apr The annualized base APR, scaled by 1e12. Returns 0 if no active vesting.
     */
    function getAPRbase() public view returns (int64) {
        (bool isV1, uint256 period) = _probeV1();
        if (isV1) return _getAPRbaseV1(period);
        return _getAPRbaseV2();
    }

    // ============ V1: STRC Vesting ============

    /// @dev Probes whether sUSDat is V1 by calling vestingPeriod().
    ///      Returns (true, period) if V1 or (false, 0) if the function is gone.
    function _probeV1() internal view returns (bool ok, uint256 period) {
        bytes memory data;
        (ok, data) = address(sUSDat).staticcall(
            abi.encodeCall(IsUSDatV1.vestingPeriod, ())
        );
        if (ok && data.length >= 32) {
            period = abi.decode(data, (uint256));
        } else {
            ok = false;
        }
    }

    /**
     * @dev V1 base APR from STRC vesting state and STRC oracle price.
     *      Called only when the V1 probe succeeds - all V1 functions must exist.
     *      Formula: (unvestedStrc * strcPrice / 10^decimals) / remaining * YEAR / totalAssets
     */
    function _getAPRbaseV1(uint256 period) internal view returns (int64) {
        if (period == 0) return 0;

        IsUSDatV1 vault = IsUSDatV1(address(sUSDat));

        uint256 lastDist = vault.lastDistributionTimestamp();
        if (lastDist == 0) return 0;

        uint256 elapsed = block.timestamp - lastDist;
        if (elapsed >= period) return 0;

        uint256 unvestedStrc = vault.getUnvestedAmount();
        uint256 total = vault.totalAssets();
        if (total == 0 || unvestedStrc == 0) return 0;

        IStrcPriceOracle oracle = IStrcPriceOracle(vault.getStrcOracle());
        (uint256 strcPrice, uint8 priceDecimals) = oracle.getPrice();
        if (strcPrice == 0) return 0;

        uint256 unvestedUsd = unvestedStrc * strcPrice / (10 ** priceDecimals);
        uint256 remainingTime = period - elapsed;

        uint256 apr = unvestedUsd * SECONDS_PER_YEAR * 1e12 / (remainingTime * total);
        if (apr > BOUND_MAX) apr = BOUND_MAX;

        return int64(int256(apr));
    }

    // ============ V2: Surplus Vesting ============

    /**
     * @dev V2 base APR from USDat surplus vesting - pure distribution, no token price.
     *      Called only when V1 probe fails - sUSDat is V2, all V2 functions must exist.
     *      Same pattern as Ethena's sUSDeAprPairProvider.
     *      Formula: unvestedSurplus / remainingTime * SECONDS_PER_YEAR / totalAssets
     */
    function _getAPRbaseV2() internal view returns (int64) {
        uint256 vestingPeriod = sUSDat.surplusVestingPeriod();
        if (vestingPeriod == 0) return 0;

        uint256 elapsed = block.timestamp - sUSDat.surplusVestingStartTimestamp();
        if (elapsed >= vestingPeriod) return 0;

        uint256 unvestedSurplus = sUSDat.getUnvestedSurplus();
        if (unvestedSurplus == 0) return 0;

        uint256 totalAssets = sUSDat.totalAssets();
        if (totalAssets == 0) return 0;

        uint256 remainingTime = vestingPeriod - elapsed;
        uint256 apr = unvestedSurplus * SECONDS_PER_YEAR * 1e12 / (remainingTime * totalAssets);

        if (apr > BOUND_MAX) apr = BOUND_MAX;
        return int64(int256(apr));
    }
}
