// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IStrategyAprPairProvider} from "../../interfaces/IAprPairFeed.sol";
import {
    IAccessControlManager
} from "../../../governance/interfaces/IAccessControlManager.sol";
import {IsUSDat} from "./IsUSDat.sol";

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
 *   - V1: Computed on-chain from sUSDat's STRC vesting state and STRC oracle price.
 *   - V2: STRCon yield is continuous in the token price (mark-to-market, no discrete vesting).
 *     The vesting surface is removed from the vault and moved into STRCMirrorModule,
 *     which is retired after the STRC→STRCon migration.
 *     getAPRbase() returns 0 as there is no discrete yield event to annualize.
 *     With riskPremium = 100%, the Senior APR equals aprTarget regardless of aprBase.
 *
 * @dev V2 Changes:
 *   - Removed: getStrcOracle() from vault — constructor no longer reads it
 *   - Removed: vestingPeriod(), lastDistributionTimestamp(), getUnvestedAmount() from vault
 *   - getAPRbase() always returns 0 (STRCon yield is continuous, not discrete)
 *   - The strcOracle immutable is removed from this contract
 *
 * TODO: Consider whether a V2-specific APR computation is needed that reads STRCon price
 *       changes over time, or whether the keeper-driven aprTarget is sufficient.
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
     *      Example: currentDividend = 11.5%, seniorShare = 70% → aprTarget = 8.05%
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
     * @notice Returns the base APR.
     * @dev V2: STRCon yield is continuous in the token price (sValue accumulation),
     *      so there is no discrete vesting event to annualize. Returns 0.
     *      With riskPremium = 100%, Senior APR = max(aprTarget, aprBase * 0) = aprTarget.
     *      This function is retained for interface compatibility and monitoring.
     *
     *      TODO: Consider computing a trailing STRCon yield from price changes
     *      if an on-chain APR signal is needed beyond the keeper-driven aprTarget.
     * @return apr Always returns 0 in V2
     */
    function getAPRbase() public pure returns (int64) {
        return 0;
    }
}
