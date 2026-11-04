// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UD60x18} from "@prb/math/src/ud60x18/Math.sol";
import {IStrataCDO} from "../interfaces/IStrataCDO.sol";
import {IAprPairFeed} from "../interfaces/IAprPairFeed.sol";
import {IRiskPremiumModel} from "./premium/IRiskPremiumModel.sol";
import {AccountingStorage} from "./AccountingStorage.sol";
import {AccountingOperations} from "./AccountingOperations.sol";

/// @notice Accounting math exposed by MTMAccounting and DYSAccounting to their setters module.
interface IAccountingSelfCall {
    function selfCall(uint256 op) external;
}

/// @title AccountingSetters
/// @notice Initializers and configuration setters shared by MTMAccounting and DYSAccounting, run via delegatecall on the accounting proxy.
/// @dev Deployed by the accounting constructor. Accounting math stays in the accounting and is reached through selfCall.
contract AccountingSetters is AccountingStorage, AccountingOperations {
    uint256 private constant MIGRATION_V2 = 1 << 0;
    uint256 private constant MIGRATION_V3 = 1 << 1;

    uint256 private constant APR_FEED_DECIMALS = 12;
    uint256 private constant PERCENTAGE_100 = 1e18;
    uint256 private constant RESERVE_BPS_MAX = 0.2e18;

    /// @dev Mirrors the accounting's useNavAtReconciliation.
    bool private immutable useNavAtReconciliation;

    /// @dev Mirrors the accounting's useRatesForReconciliation.
    bool private immutable useRatesForReconciliation;

    event AprPairFeedChanged(address aprPairFeed);
    event ReservePercentageChanged(uint256 reserveBps);
    event RiskModelChanged(address riskPremiumModel);
    event MinimumJrtSrtRatioChanged(uint256 ratio);
    event MinimumJrtSrtRatioBufferChanged(uint256 ratio);
    event FeeRetentionChanged(uint256 feeJrtRetention, uint256 feeSrtRetention);
    event FloorRateChanged(uint256 floorRate);
    event ValuationGracePeriodChanged(uint64 period);

    constructor(bool useNavAtReconciliation_, bool useRatesForReconciliation_) {
        useNavAtReconciliation = useNavAtReconciliation_;
        useRatesForReconciliation = useRatesForReconciliation_;
    }

    function initialize(
        address owner_,
        address acm_,
        IStrataCDO cdo_,
        IAprPairFeed aprPairFeed_
    ) external reinitializer(3) {
        // This function sets the initializer version directly to the latest version.
        // The guard ensures it can only be used for fresh deployments.
        require(address(cdo) == address(0), "AlreadyInitialized");
        AccessControlled_init(owner_, acm_);
        cdo = cdo_;

        aprPairFeed = aprPairFeed_;

        srtTargetIndex = 1e18;
        navTargetIndex = 1e18;
        indexTimestamp = block.timestamp;
        navTimestamp = block.timestamp;
        minimumJrtSrtRatio = 0.05e18;
        minimumJrtSrtRatioBuffer = 0.06e18;

        _initV2();
        _initV3();
    }

    function initializeV2() external reinitializer(2) {
        _initV2();
    }

    function initializeV3() external reinitializer(3) {
        _initV2();
        _initV3();
    }

    /// @notice Migration V2: valuation loss support and performance fee high-watermark.
    /// @dev V2 migration is compatible across all Strata accounting contracts.
    function _initV2() internal {
        if (migrationBitmap & MIGRATION_V2 != 0) {
            return;
        }
        valuationPrice = 1e18;
        feeWatermarkNav = nav;
        if (useNavAtReconciliation) {
            lastReconciliation = navTimestamp;
        }
        migrationBitmap |= MIGRATION_V2;
    }

    /// @notice Migration V3: asset-time tracking, Senior true-up, and Senior loss floor.
    /// @dev V3 migration upgrades Strata accountings to DYS/MTM accounting.
    function _initV3() internal {
        if (migrationBitmap & MIGRATION_V3 != 0) {
            return;
        }
        if (navTimestamp == 0) {
            navTimestamp = block.timestamp;
        }
        if (navTargetIndex == 0) {
            // Accounting->DYS/MTM; Keeps DiscreteAccounting projection
            navTargetIndex = 1e18;
            jrtNavProjected = jrtBaseNav;
            lastReconciliation = block.timestamp;
        }

        benchmarkIndex = 1e18;
        lastAccrual = block.timestamp;
        epochStart = block.timestamp;
        windowEnd = block.timestamp + 1 days;
        windowStartSrtNav = 0;
        windowNetFlows = 0;
        floorRate = 0;
        // Fresh CDOs configure the strategy later; their first reconciliation uses proportional allocation.
        if (useRatesForReconciliation && address(cdo.strategy()) != address(0)) {
            strategyRate = cdo.strategy().getRate();
        }
        migrationBitmap |= MIGRATION_V3;
    }

    /// @notice Sets the external risk premium model.
    /// @param riskPremiumModel_ External model contract, or zero address for no risk premium.
    function setRiskModel(IRiskPremiumModel riskPremiumModel_) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        _selfCall(OP_CHECKPOINT);
        if (address(riskPremiumModel_) != address(0)) {
            UD60x18 risk = riskPremiumModel_.riskPremium(UD60x18.wrap(1e18));
            require(risk.unwrap() <= PERCENTAGE_100, ">100%");
        }
        riskPremiumModel = riskPremiumModel_;
        emit RiskModelChanged(address(riskPremiumModel_));
        _selfCall(OP_UPDATE_APR_SRT);
    }

    /// @notice Sets the APR feed contract for fetching APR target and APR base.
    /// @dev Finalizes accounting with the current feed before switching, then starts the new APR period.
    /// @param aprPairFeed_ The address of the new APR feed contract.
    function setAprPairFeed(IAprPairFeed aprPairFeed_) external onlyOwner {
        require(aprPairFeed_.decimals() == APR_FEED_DECIMALS, "InvalidFeed");
        _selfCall(OP_CHECKPOINT);
        _selfCall(OP_SYNC_APRS);
        aprPairFeed = aprPairFeed_;
        emit AprPairFeedChanged(address(aprPairFeed_));
        _selfCall(OP_SYNC_APRS);
    }

    /// @notice Sets the maximum allowed daily loss rate for the Senior tranche
    /// @dev The floor rate defines the maximum percentage loss Senior can experience over a rolling
    ///      24-hour window. This protection mechanism ensures Senior holders have a predictable
    ///      worst-case scenario during periods of strategy underperformance.
    ///      **Mechanism**:
    ///      - The floor is calculated as: `srtNavFloor = (windowStartSrtNav + windowNetFlows) * (1 - floorRate)`
    ///      - At reconciliation, if `srtNavT1 < srtNavFloor`, Junior transfers assets to bring Senior back to the floor
    ///      - The window resets every 24 hours at reconciliation, capturing the new baseline Senior NAV
    ///      **Window Extension**:
    ///      If no reconciliation occurs for >24h, the allowed loss extends proportionally
    ///      **State Reset**:
    ///      Calling this function triggers accounting update and immediately resets the floor window
    /// @param rate The maximum daily loss rate in 18-decimal fixed-point (e.g., 0.01e18 = 1% per day)
    /// @custom:example If floorRate = 0.005e18 (0.5%/day) and windowStartSrtNav = 1000 USDC:
    ///                 - Floor = 1000 * (1 - 0.005) = 995 USDC
    ///                 - If reconciliation shows srtNavT1 = 990 USDC, Junior transfers 5 USDC to Senior
    ///                 - If Junior cannot cover the full 5 USDC, it transfers up to its safe assets
    function setFloorRate(uint256 rate) external onlyOwner {
        require(rate <= 0.01e18, "FloorRateTooHigh"); // max 1%/day
        _selfCall(OP_CHECKPOINT);
        floorRate = rate;

        // Anchor settled Senior NAV, retaining valuation credit but excluding unrealized PnL.
        _selfCall(OP_RESET_FLOOR_WINDOW);
        windowNetFlows = 0;
        windowEnd = block.timestamp + 1 days;
        emit FloorRateChanged(rate);
    }

    function setReserveBps(uint256 bps) external onlyOwner {
        require(
            bps <= RESERVE_BPS_MAX && bps != reserveBps,
            "InvalidNewReserve"
        );
        _selfCall(OP_CHECKPOINT);
        reserveBps = bps;
        emit ReservePercentageChanged(reserveBps);
    }

    function setFeeRetentionBps(
        uint256 jrtRetentionBps,
        uint256 srtRetentionBps
    ) external onlyOwner {
        require(jrtRetentionBps <= PERCENTAGE_100, "InvalidJrtRetention");
        require(srtRetentionBps <= PERCENTAGE_100, "InvalidSrtRetention");
        feeJrtRetentionBps = jrtRetentionBps;
        feeSrtRetentionBps = srtRetentionBps;
        emit FeeRetentionChanged(feeJrtRetentionBps, feeSrtRetentionBps);
    }

    function setMinimumJrtSrtRatio(uint256 ratio) external onlyOwner {
        require(ratio <= minimumJrtSrtRatioBuffer, "RatioAboveSoftFloor");
        minimumJrtSrtRatio = ratio;
        emit MinimumJrtSrtRatioChanged(ratio);
    }

    function setMinimumJrtSrtRatioBuffer(uint256 ratio) external onlyOwner {
        require(ratio <= 100 * PERCENTAGE_100, "RatioTooHigh");
        require(
            ratio >= minimumJrtSrtRatio && ratio != 0,
            "RatioBelowHardFloor"
        );
        minimumJrtSrtRatioBuffer = ratio;
        emit MinimumJrtSrtRatioBufferChanged(ratio);
    }

    /// @notice Sets the grace period
    function setValuationGracePeriod(uint64 period) external onlyRole(PAUSER_ROLE) {
        require(period <= 1 days, "GracePeriodTooLong");
        valuationGracePeriod = period;
        emit ValuationGracePeriodChanged(period);
    }

    /// @dev Runs accounting math in the accounting; address(this) is the proxy, so the call routes back to it.
    function _selfCall(uint256 op) private {
        IAccountingSelfCall(address(this)).selfCall(op);
    }
}
