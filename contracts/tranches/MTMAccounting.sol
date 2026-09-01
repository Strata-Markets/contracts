// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UD60x18, pow, mul} from "@prb/math/src/ud60x18/Math.sol";
import {IAccounting} from "./interfaces/IAccounting.sol";
import {IStrataCDO} from "./interfaces/IStrataCDO.sol";
import {IAprPairFeed} from "./interfaces/IAprPairFeed.sol";
import {CDOComponent} from "./base/CDOComponent.sol";
import {UD60x18Ext} from "./utils/UD60x18Ext.sol";
import {AccountingLib} from "./utils/AccountingLib.sol";

/**
 * @title CDO::DYSAccounting
 * @dev Dynamic Yield Split (DYS) accounting for volatile strategies like mKRALPHA.
 *
 * Key differences from DiscreteAccounting:
 * 1. Asset-time tracking: accumulates srtNavTime, jrtNavTime, navTime before every state change
 * 2. Senior true-up at reconciliation: projected Senior PnL is replaced with realized PnL
 * 3. Senior PnL = PnL * (1 - RiskPremium) * srtNavTime / navTime
 * 4. Senior floor: srtFloorPnL = -srtFloorBps * avgSrAssets
 *
 * During the epoch (between oracle updates):
 *   - Senior NAV is continuously increased using projected returns (aprSrt-based index)
 *   - srtPnLProjected accumulates the projected gain
 *   - Asset-time is accrued before every deposit/withdrawal
 *
 * At reconciliation (oracle update detected):
 *   - Realized PnL replaces projected PnL
 *   - srtNav = srtNav - srtPnLProjected + srtPnLRealized
 *   - Asset-time counters are reset
 */
contract MTMAccounting is IAccounting, CDOComponent {
    uint256 private constant MIGRATION_V2 = 1 << 0;
    uint256 private constant MIGRATION_V3 = 1 << 1;

    uint256 constant SECONDS_PER_YEAR = 31_536_000;

    int64 private constant APR_FEED_BOUNDARY_MAX = 2e12; // 200%
    int64 private constant APR_FEED_BOUNDARY_MIN = 0;
    uint256 private constant APR_FEED_DECIMALS = 12;
    uint256 constant PERCENTAGE_100 = 1e18;
    uint256 constant RESERVE_BPS_MAX = 0.2e18;

    uint256 private immutable ONE_ASSET;

    /// @notice When true, Senior earns at BenchmarkAPR (aprTarget) only during projection,
    ///         and at reconciliation gets max(projected, realized) so Senior never dips below
    ///         their projected level. Junior absorbs any shortfall vs benchmark.
    ///         When false (default), Senior earns at max(aprTarget, aprBase*(1-riskPremium))
    ///         and reconciliation replaces projected with realized (current mKRAlpha behavior).
    bool public immutable useBenchmarkProjection;

    /// @notice When true, totalStrategyAssets uses lastReconciliation instead of navTimestamp
    ///         as the time anchor, so that deposits/withdrawals between oracle updates do not
    ///         generate phantom yield in the projected NAV.
    bool private immutable useNavAtReconciliation;

    /// @notice When true, snapshots the senior sub-strategy exchange rate after each reconciliation
    ///         and uses the rate-based senior true-up formula instead of the proportional nav-time formula.
    bool public immutable useRatesForReconciliation;

    /// @notice When true, Junior covers paid-out projected Senior assets unwound at reconciliation.
    bool public immutable useJuniorCoversPaidSrtProjection;

    /// @notice When true, deposits use depositable NAV and redemptions use redeemable NAV.
    bool public immutable useConservativePrice;

    /// @notice When true, projection uses current strategy MTM NAV instead of APR-indexed NAV.
    bool public immutable useMTMProjection;

    /// @dev The oracle to fetch the latest APR floor and APR base.
    IAprPairFeed public aprPairFeed;

    /// @dev External floor target APR for Srt
    UD60x18 public aprTarget;

    /// @dev External APR for the underlying protocol
    UD60x18 public aprBase;

    /// @dev The calculated target APR for Srt; the primary objective in calculations.
    UD60x18 public aprSrt;

    uint256 public indexTimestamp;
    uint256 public srtTargetIndex;

    uint256 public reserveBps;

    /// @dev Latest balances at T0 (latest protocol interrogation)
    uint256 public nav;
    uint256 public jrtBaseNav;
    uint256 public srtBaseNav;
    uint256 public reserveNav;

    /// @dev Risk parameters for Risk Premium calculation.
    UD60x18 public riskX;
    UD60x18 public riskY;
    UD60x18 public riskK;

    /// @notice The hard minimum TVLjrt/TVLsrt ratio.
    uint256 public minimumJrtSrtRatio;

    /// @notice The protective buffer above the minimum Jrt/Srt ratio.
    uint256 public minimumJrtSrtRatioBuffer;

    /// @notice The portion of Junior fees that is returned to its TVL. The remainder goes to the reserve.
    uint256 public feeJrtRetentionBps;

    /// @notice The portion of Senior fees that is returned to the Senior tranche TVL.
    uint256 public feeSrtRetentionBps;

    /** Accounting Storage Compatibility **/

    // The index for NAV during projection
    uint256 public navTargetIndex;

    /// @notice Latest changes to "nav"
    uint256 public navTimestamp;

    /// @notice Projected Junior NAV during the rewardless periods
    uint256 public jrtNavProjected;

    /** ValuationLoss Parameters */

    /// @notice The current valuation price of the underlying asset in USD terms
    /// @dev Scaled to 1e18 where 1e18 = $1.00. Maximum value is 1e18 (representing $1.00)
    ///      When below 1e18, indicates a valuation loss has occurred
    uint128 public valuationPrice;

    /// @notice Timestamp of the last valuation price update
    /// @dev Updated whenever the valuation keeper pushes a new valuation price
    uint64 public valuationUpdatedAt;

    /// @notice Timestamp when the valuation loss state was entered
    /// @dev Set when valuationPrice drops below 1e18 for the first time
    ///      Used to calculate the grace period during which deposits/withdrawals are restricted
    uint64 public valuationEnteredAt;

    /// @notice Duration in seconds of the grace period after entering valuation loss
    /// @dev During this period after valuationEnteredAt, deposits and withdrawals are disabled
    ///      to prevent front-running and allow for proper loss validation
    uint64 public valuationGracePeriod;

    /// @notice Gross Senior NAV deposited during valuation loss and self-funded by Senior.
    uint256 public srtFundedGrossNav;

    /// @notice Portion of funded Senior NAV that covers its own valuation loss.
    /// @dev Per-entry valuation recovery is not bucketed; small mismatches are socialized through the Senior share price.
    uint256 public srtFundNav;

    /// @notice High-water mark used to charge performance fees only on new NAV gains.
    uint256 public feeWatermarkNav;

    /// @notice Timestamp of the last oracle-detected NAV change; used as time anchor when useNavAtReconciliation is true
    uint256 public lastReconciliation;


    /*****************************************************************************
     *                  DYS-specific State Variables                              *
     *****************************************************************************/

    /// @notice Benchmark index for tracking Senior Benchmark PnL during projection (used in Benchmark mode)
    uint256 public benchmarkIndex;

    /// @notice Time-weighted Senior NAV (asset-time)
    uint256 public srtNavTime;

    /// @notice Time-weighted total system NAV (asset-time) (incl. projected assets)
    uint256 public navTime;

    /// @notice Time-weighted total system NAV (asset-time) (net assets during projection)
    uint256 public navTimeNet;

    /// @notice Timestamp of last asset-time accrual
    uint256 public lastAccrual;

    /// @notice Accumulated projected Senior PnL during the current epoch
    uint256 public srtPnLProjected;

    uint256 public srtProjectedPnLTime;

    /// @notice Track paid-out projected amount during the current epoch
    uint256 public srtPaidProjected;

    /// @notice Accumulated benchmark Senior PnL during the current epoch
    uint256 public srtPnLBenchmark;

    /// @notice Senior NAV at the start of the current floor window (anchor)
    uint256 public windowStartSrtNav;

    /// @notice Cumulative net Senior flows (deposits - withdrawals) during the window
    int256 public windowNetFlows;

    /// @notice End timestamp of the current floor window
    uint256 public windowEnd;

    /// @notice Daily floor rate (1e18 = 100%). E.g. 0.001e18 = 0.1%/day
    uint256 public floorRate;

    /// @notice Timestamp of the epoch start (last reconciliation)
    uint256 public epochStart;

    /// @notice Exchange rate of the senior sub-strategy at the start of the current epoch.
    /// @dev Stored after each reconciliation as T0 for the next epoch's true-up.
    ///      0 means rate tracking is not enabled; the proportional nav-time formula is used instead.
    uint256 public strategyRate;


    error InvalidNavSplit(
        uint256 navT1,
        uint256 jrtAssets,
        uint256 srtAssets,
        uint256 reserveAssets
    );
    error InvalidAssetsSnapshot(
        uint256 lastAccrual,
        uint256 navT1,
        uint256 navT1Time,
        uint256 navMTM,
        uint256 navMTMTime
    );

    struct TNavSplitState {
        uint256 srtNavTime;
        uint256 navTime;
        uint256 navTimeNet;
        uint256 srtProjectedPnLTime;
        uint256 lastAccrual;
        uint256 srtPnLProjected;
        uint256 srtPaidProjected;
        uint256 srtPnLBenchmark;
        uint256 epochStart;
        uint256 strategyRate;
        uint256 feeWatermarkNav;
    }
    error ReserveTooLow(uint256 reserveNav, uint256 requestedNav);

    event AprPairFeedChanged(address aprPairFeed);
    event AprDataChangedViaPush(UD60x18 aprTarget, UD60x18 aprBase);
    event ReservePercentageChanged(uint256 reserveBps);
    event RiskParametersChanged(UD60x18 x, UD60x18 y, UD60x18 k);
    event MinimumJrtSrtRatioChanged(uint256 ratio);
    event MinimumJrtSrtRatioBufferChanged(uint256 ratio);
    event FeeAccrued(
        bool isJrt,
        uint256 amountToReserve,
        uint256 amountToTranche
    );
    event FeeRetentionChanged(uint256 feeJrtRetention, uint256 feeSrtRetention);
    event FloorRateChanged(uint256 floorRate);

    constructor(
        uint256 navDecimals,
        bool useBenchmarkProjection_,
        bool useNavAtReconciliation_,
        bool useRatesForReconciliation_,
        bool useJuniorCoversPaidSrtProjection_,
        bool useConservativePrice_,
        bool useMTMProjection_
    ) {
        ONE_ASSET = 10 ** navDecimals;
        useBenchmarkProjection = useBenchmarkProjection_;
        useNavAtReconciliation = useNavAtReconciliation_;
        useRatesForReconciliation = useRatesForReconciliation_;
        useJuniorCoversPaidSrtProjection = useJuniorCoversPaidSrtProjection_;
        useConservativePrice = useConservativePrice_;
        useMTMProjection = useMTMProjection_;
    }

    function initialize(
        address owner_,
        address acm_,
        IStrataCDO cdo_,
        IAprPairFeed aprPairFeed_
    ) public virtual reinitializer(3) {
        // This function sets the initializer version directly to the latest version.
        // The guard ensures it can only be used for fresh deployments.
        require(address(cdo) == address(0), "AlreadyInitialized");
        AccessControlled_init(owner_, acm_);
        cdo = cdo_;

        aprPairFeed = aprPairFeed_;

        riskX = UD60x18.wrap(0.2e18);
        riskY = UD60x18.wrap(0.2e18);
        riskK = UD60x18.wrap(0.3e18);

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

    /// @notice Migration V3: DYS asset-time tracking, Senior true-up, and Senior loss floor.
    /// @dev V3 migration upgrades Strata accountings to DYS accounting.
    function _initV3() internal {
        if (migrationBitmap & MIGRATION_V3 != 0) {
            return;
        }
        benchmarkIndex = 1e18;
        lastAccrual = block.timestamp;
        epochStart = block.timestamp;
        windowEnd = block.timestamp + 1 days;
        windowStartSrtNav = 0;
        windowNetFlows = 0;
        floorRate = 0;
        if (useRatesForReconciliation) {
            strategyRate = cdo.strategy().getRate();
        }
        migrationBitmap |= MIGRATION_V3;
    }

    /*****************************************************************************
     *                  DYS Asset-Time Tracking                                   *
     *****************************************************************************/

    /// @notice Accrues asset-time for all tranches. MUST be called before any state change.
    function _accrueAssetTime(uint256 accrualTime, TNavSplitState memory state) internal {
        if (accrualTime <= state.lastAccrual) {
            return;
        }
        (
            state.srtNavTime,
            state.navTime,
            state.navTimeNet,
            state.srtProjectedPnLTime
        ) = _accruedAssetTimeView(
            nav,
            jrtNavProjected,
            srtBaseNav,
            reserveNav,
            accrualTime,
            state
        );

        srtNavTime = state.srtNavTime;
        navTime = state.navTime;
        navTimeNet = state.navTimeNet;
        srtProjectedPnLTime = state.srtProjectedPnLTime;
        state.lastAccrual = accrualTime;
        lastAccrual = accrualTime;
    }

    function _currentNavSplitState() internal view returns (TNavSplitState memory state) {
        state.srtNavTime = srtNavTime;
        state.navTime = navTime;
        state.navTimeNet = navTimeNet;
        state.srtProjectedPnLTime = srtProjectedPnLTime;
        state.lastAccrual = lastAccrual;
        state.srtPnLProjected = srtPnLProjected;
        state.srtPaidProjected = srtPaidProjected;
        state.srtPnLBenchmark = srtPnLBenchmark;
        state.feeWatermarkNav = feeWatermarkNav;
        if (useRatesForReconciliation) {
            state.epochStart = epochStart;
            state.strategyRate = strategyRate;
        }
    }

    function _accruedAssetTimeView(
        uint256 navT0,
        uint256 jrtNavT0Projected,
        uint256 srtNavT0,
        uint256 reserveNavT0,
        uint256 accrualTime,
        TNavSplitState memory state
    )
        internal
        pure
        returns (
            uint256 srtNavTime_,
            uint256 navTime_,
            uint256 navTimeNet_,
            uint256 srtProjectedPnLTime_
        )
    {
        srtNavTime_ = state.srtNavTime;
        navTime_ = state.navTime;
        navTimeNet_ = state.navTimeNet;
        srtProjectedPnLTime_ = state.srtProjectedPnLTime;

        uint256 dt = accrualTime - state.lastAccrual;

        uint256 systemAssets = srtNavT0 + jrtNavT0Projected + reserveNavT0;

        srtNavTime_ += srtNavT0 * dt;
        navTime_ += systemAssets * dt;
        navTimeNet_ += navT0 * dt;
        srtProjectedPnLTime_ += Math.saturatingSub(state.srtPnLProjected, state.srtPaidProjected) * dt;
    }

    function _navAnchor() private view returns (uint256) {
        return useNavAtReconciliation ? lastReconciliation : navTimestamp;
    }

    function _currentNavs()
        private
        view
        returns (
            uint256 navT1,
            uint256 navT1Time,
            uint256 navMTM,
            uint256 navMTMTime
        )
    {
        (navT1, navT1Time, navMTM, navMTMTime) = cdo.totalStrategyAssetsSnapshot(nav, _navAnchor());
    }

    /*****************************************************************************
     *                  View Methods                                              *
     *****************************************************************************/

    /// @notice Returns the updated total assets, reading NAV from the strategy
    function totalAssets()
        public
        view
        returns (
            uint256 jrtNavT1Projected,
            uint256 srtNavT1,
            uint256 reserveNavT1
        )
    {
        (uint256 navT1, uint256 navT1Time, uint256 navMTM, uint256 navMTMTime) = _currentNavs();

        bool isReconciliation = _shouldReconcile(nav, navT1);
        bool hasMTMAfterReconciliation = isReconciliation && navMTMTime > navT1Time;
        uint256 timestamp = hasMTMAfterReconciliation ? navT1Time : block.timestamp;
        TNavSplitState memory state = _currentNavSplitState();
        (
            jrtNavT1Projected,
            ,
            /*jrtNavT1Real*/ srtNavT1,
            reserveNavT1
        ) = calculateNAVSplit(
                nav,
                jrtNavProjected,
                jrtBaseNav,
                srtBaseNav,
                reserveNav,
                navT1,
                navT1Time,
                navMTM,
                navMTMTime,
                timestamp,
                state
            );

        if (hasMTMAfterReconciliation) {
            // Reconciliation resets the asset-time and projection fields
            state.srtNavTime = 0;
            state.navTime = 0;
            state.navTimeNet = 0;
            state.srtProjectedPnLTime = 0;
            state.srtPnLProjected = 0;
            state.srtPaidProjected = 0;
            state.srtPnLBenchmark = 0;
            state.lastAccrual = navT1Time;
            state.feeWatermarkNav = navT1 > state.feeWatermarkNav ? navT1 : state.feeWatermarkNav;
            if (useRatesForReconciliation) {
                state.epochStart = navT1Time;
            }
            (
                jrtNavT1Projected,
                ,
                /*jrtNavT1Real*/ srtNavT1,
                reserveNavT1
            ) = calculateNAVSplitProjectedMTM(
                    navT1,
                    jrtNavT1Projected,
                    jrtNavT1Projected,
                    srtNavT1,
                    reserveNavT1,
                    navMTM,
                    navMTMTime,
                    state
                );
        }
        (jrtNavT1Projected, srtNavT1) = calcEffectiveNav(jrtNavT1Projected, srtNavT1);
        return (jrtNavT1Projected, srtNavT1, reserveNavT1);
    }

    /// @notice Returns the updated total assets excluding projection for each tranche and the reserve
    function totalAssetsSettled()
        public
        view
        returns (
            uint256 jrtNavT1Real,
            uint256 srtNavT1,
            uint256 reserveNavT1
        )
    {
        (uint256 navT1, uint256 navT1Time, uint256 navMTM, uint256 navMTMTime) = _currentNavs();
        bool isReconciliation = _shouldReconcile(nav, navT1);
        TNavSplitState memory state = _currentNavSplitState();
        uint256 jrtNavT1Projected;
        (
            jrtNavT1Projected,
            jrtNavT1Real,
            srtNavT1,
            reserveNavT1
        ) = calculateNAVSplit(
                nav,
                jrtNavProjected,
                jrtBaseNav,
                srtBaseNav,
                reserveNav,
                navT1,
                navT1Time,
                navMTM,
                navMTMTime,
                block.timestamp,
                state
            );

        if (isReconciliation) {
            // Reconciliation already replaces projected NAV with realized NAV.
            (jrtNavT1Real, srtNavT1) = calcEffectiveNav(jrtNavT1Real, srtNavT1);
            return (jrtNavT1Real, srtNavT1, reserveNavT1);
        }

        (uint256 jrtNet, uint256 srtNet) = AccountingLib.undoProjection(
            srtNavT1,
            srtBaseNav,
            srtPnLProjected,
            srtPaidProjected,
            jrtNavT1Real
        );

        (jrtNet, srtNet) = calcEffectiveNav(jrtNet, srtNet);
        return (jrtNet, srtNet, reserveNavT1);
    }

    /// @notice Returns the updated total assets and settled NAVs
    function totalAssetsLiveAndSettled()
        public
        view
        returns (
            uint256 jrtNavLive,
            uint256 srtNavLive,
            uint256 jrtNavSettled,
            uint256 srtNavSettled
        )
    {
        (uint256 navT1, uint256 navT1Time, uint256 navMTM, uint256 navMTMTime) = _currentNavs();

        bool isReconciliation = _shouldReconcile(nav, navT1);
        bool hasMTMAfterReconciliation = isReconciliation && navMTMTime > navT1Time;
        uint256 timestamp = hasMTMAfterReconciliation ? navT1Time : block.timestamp;

        uint256 reserveNavT1;
        uint256 jrtNavT1Real;
        uint256 srtNavT1;

        TNavSplitState memory state = _currentNavSplitState();
        (
            jrtNavLive,
            jrtNavT1Real,
            srtNavT1,
            reserveNavT1
        ) = calculateNAVSplit(
                nav,
                jrtNavProjected,
                jrtBaseNav,
                srtBaseNav,
                reserveNav,
                navT1,
                navT1Time,
                navMTM,
                navMTMTime,
                timestamp,
                state
            );

        if (isReconciliation) {
            // Reconciliation already replaces projected NAV with realized NAV.
            (jrtNavSettled, srtNavSettled) = calcEffectiveNav(jrtNavLive, srtNavT1);
        } else {
            (uint256 jrtNet, uint256 srtNet) = AccountingLib.undoProjection(
                srtNavT1,
                srtBaseNav,
                srtPnLProjected,
                srtPaidProjected,
                jrtNavT1Real
            );
            (jrtNavSettled, srtNavSettled) = calcEffectiveNav(jrtNet, srtNet);
        }

        if (hasMTMAfterReconciliation) {
            // Reconciliation resets the asset-time and projection fields
            state.srtNavTime = 0;
            state.navTime = 0;
            state.navTimeNet = 0;
            state.srtProjectedPnLTime = 0;
            state.srtPnLProjected = 0;
            state.srtPaidProjected = 0;
            state.srtPnLBenchmark = 0;
            state.lastAccrual = navT1Time;
            state.feeWatermarkNav = navT1 > state.feeWatermarkNav
                ? navT1
                : state.feeWatermarkNav;
            if (useRatesForReconciliation) {
                state.epochStart = navT1Time;
            }
            (
                jrtNavLive,
                ,
                /*jrtNavT1Real*/ srtNavT1,
                reserveNavT1
            ) = calculateNAVSplitProjectedMTM(
                    navT1,
                    jrtNavLive,
                    jrtNavLive,
                    srtNavT1,
                    reserveNavT1,
                    navMTM,
                    navMTMTime,
                    state
                );
        }
        (jrtNavLive, srtNavLive) = calcEffectiveNav(jrtNavLive, srtNavT1);
        return (
            jrtNavLive,
            srtNavLive,
            jrtNavSettled,
            srtNavSettled
        );
    }

    /// @notice Returns the current saved real total assets
    function totalAssetsT0()
        public
        view
        returns (uint256 jrtNavT0, uint256 srtNavT0, uint256 reserveNavT0)
    {
        (jrtNavT0, srtNavT0) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
        reserveNavT0 = reserveNav;
    }

    function srtNav () external view returns (uint256 srtNavEffective) {
        (, srtNavEffective) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
    }

    function jrtNav () external view returns (uint256 jrtNavEffective) {
        (jrtNavEffective,) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
    }

    /// @notice Returns current reserve value
    function totalReserve() external view returns (uint256) {
        (, , uint256 reserveNavT1) = totalAssets();
        return reserveNavT1;
    }

    /*****************************************************************************
     *                  State-Mutating Methods (called by CDO)                    *
     *****************************************************************************/

    /// @notice Reduces the reserve by the specified amount
    function reduceReserve(
        uint256 amount,
        uint256 jrtAmountIn,
        uint256 srtAmountIn
    ) external onlyCDO {
        (uint256 navT1, uint256 navT1Time, uint256 navMTM, uint256 navMTMTime) = _currentNavs();
        updateAccountingInner(navT1, navT1Time, navMTM, navMTMTime);
        if (amount > reserveNav) {
            revert ReserveTooLow(reserveNav, amount);
        }
        if (amount < (jrtAmountIn + srtAmountIn)) {
            revert ReserveTooLow(amount, jrtAmountIn + srtAmountIn);
        }
        reserveNav = reserveNav - amount;
        adjustFeeWatermark(jrtAmountIn + srtAmountIn, amount);
        nav = nav + jrtAmountIn + srtAmountIn - amount;
        navTimestamp = block.timestamp;
        jrtNavProjected += jrtAmountIn;
        jrtBaseNav += jrtAmountIn;
        srtFundNav += _trackSrtFundNavIn(srtAmountIn);
        srtBaseNav += srtAmountIn;
        windowNetFlows += int256(srtAmountIn);

        (bool modified, UD60x18 aprTarget_, UD60x18 aprBase_) = fetchAprs();
        if (modified == false) {
            updateAprSrt(aprTarget_, aprBase_);
        }
    }

    function maxWithdraw(bool isJrt) external view returns (uint256) {
        return maxWithdrawInner(isJrt, false);
    }
    function maxWithdraw(
        bool isJrt,
        bool ownerIsSharesCooldown
    ) external view returns (uint256) {
        return maxWithdrawInner(isJrt, ownerIsSharesCooldown);
    }
    function maxWithdrawInner(
        bool isJrt,
        bool ownerIsSharesCooldown
    ) internal view returns (uint256) {
        if (valuationPrice < 1e18 && block.timestamp < valuationEnteredAt + valuationGracePeriod) {
            // Disable withdrawals during grace period after valuation loss
            return 0;
        }
        (uint256 jrtNavEffective, uint256 srtNavEffective) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
        if (ownerIsSharesCooldown) {
            return isJrt ? jrtNavEffective : srtNavEffective;
        }
        if (isJrt) {
            uint256 minJrt = (srtNavEffective * minimumJrtSrtRatio) / 1e18;
            return Math.saturatingSub(jrtNavEffective, minJrt);
        }
        return srtNavEffective;
    }
    function maxDeposit(bool isJrt) external view returns (uint256) {
        if (valuationPrice < 1e18 && block.timestamp < valuationEnteredAt + valuationGracePeriod) {
            // Disable deposits during grace period after valuation loss
            return 0;
        }
        if (isJrt) {
            return type(uint256).max;
        }
        (uint256 jrtNavEffective, uint256 srtNavEffective) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
        uint256 maxSrt = (jrtNavEffective * 1e18) / minimumJrtSrtRatioBuffer;
        return Math.saturatingSub(maxSrt, srtNavEffective);
    }

    /// @notice Updates the accounting by fetching the current total assets from the strategy
    function updateAccounting() external onlyCDO {
        (uint256 navT1, uint256 navT1Time, uint256 navMTM, uint256 navMTMTime) = _currentNavs();
        updateAccountingInner(navT1, navT1Time, navMTM, navMTMTime);
    }

    /// @notice Updates the Net Asset Values after deposits or withdrawals
    function updateBalanceFlow(
        uint256 jrtAssetsIn,
        uint256 jrtAssetsOut,
        uint256 srtAssetsIn,
        uint256 srtAssetsOut
    ) external onlyCDO {

        TNavSplitState memory state = _currentNavSplitState();
        _accrueAssetTime(block.timestamp, state);
        srtFundNav += _trackSrtFundNavIn(srtAssetsIn);


        if (valuationPrice < 1e18 && srtAssetsOut > 0) {
            uint256 fundedFundOut;
            if (srtFundedGrossNav > 0) {
                (, uint256 srtNavEffective) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
                uint256 fundedGrossOut = Math.min(
                    srtAssetsOut,
                    Math.mulDiv(srtAssetsOut, srtFundedGrossNav, srtNavEffective)
                );
                fundedFundOut = Math.min(
                    srtFundNav,
                    Math.mulDiv(fundedGrossOut, 1e18 - valuationPrice, valuationPrice)
                );
                srtFundedGrossNav -= fundedGrossOut;
                srtFundNav -= fundedFundOut;
            }

            uint256 jrtAssetsOutEffective = jrtAssetsOut;
            (jrtAssetsOut, srtAssetsOut) = AccountingLib.splitValuatedNavOut(
                jrtBaseNav,
                srtBaseNav,
                ONE_ASSET,
                valuationPrice,
                jrtAssetsOut,
                srtAssetsOut
            );
            uint256 jrtCoverage = jrtAssetsOut - jrtAssetsOutEffective;
            // Use the Senior-funded top-up to reduce Junior's realized coverage loss.
            // Cap it by remaining Senior base capacity to avoid over-withdrawing Senior NAV.
            uint256 remainingSrtCapacity = Math.saturatingSub(srtBaseNav + srtAssetsIn, srtAssetsOut);
            uint256 coveredByFund = Math.min(
                Math.min(Math.mulDiv(fundedFundOut, valuationPrice, 1e18), jrtCoverage),
                remainingSrtCapacity
            );
            jrtAssetsOut -= coveredByFund;
            srtAssetsOut += coveredByFund;
        }
        if (srtAssetsOut > 0 && srtPnLProjected > 0) {
            if (useConservativePrice) {
                // Conservative redemptions pay only net Senior assets
                // Return the unpaid projection to Junior real NAV
                uint256 srtNetNav = Math.saturatingSub(srtBaseNav, srtPnLProjected);
                uint256 unpaidProjection = Math.mulDiv(
                    srtAssetsOut,
                    srtPnLProjected,
                    srtNetNav
                );
                unpaidProjection = Math.min(unpaidProjection, srtPnLProjected);
                srtPnLProjected -= unpaidProjection;
                // srtBaseNav includes Senior projection funded from jrtBaseNav
                srtBaseNav -= unpaidProjection;

                jrtBaseNav += unpaidProjection;
                jrtNavProjected = Math.max(jrtNavProjected, jrtBaseNav);
            } else {
                // Paid projection = srtAssetsOut * liveProjection / srtGrossNav
                srtPaidProjected += Math.mulDiv(
                    srtAssetsOut,
                    srtPnLProjected - srtPaidProjected,
                    srtBaseNav
                );
            }
        }
        if (useConservativePrice && jrtAssetsOut > 0 && jrtNavProjected > jrtBaseNav && jrtBaseNav > 0) {
            uint256 jrtProjection = jrtNavProjected - jrtBaseNav;
            uint256 unpaidProjection = Math.mulDiv(
                jrtAssetsOut,
                jrtProjection,
                jrtBaseNav
            );

            unpaidProjection = Math.min(unpaidProjection, jrtProjection);
            jrtNavProjected -= unpaidProjection;
            jrtNavProjected = Math.max(jrtNavProjected, jrtBaseNav);
        }

        jrtBaseNav = jrtBaseNav + jrtAssetsIn - jrtAssetsOut;
        jrtNavProjected = jrtNavProjected + jrtAssetsIn - jrtAssetsOut;
        srtBaseNav = srtBaseNav + srtAssetsIn - srtAssetsOut;
        adjustFeeWatermark(jrtAssetsIn + srtAssetsIn, jrtAssetsOut + srtAssetsOut);
        nav = nav + jrtAssetsIn + srtAssetsIn - jrtAssetsOut - srtAssetsOut;
        windowNetFlows += int256(srtAssetsIn) - int256(srtAssetsOut);
        navTimestamp = block.timestamp;
        (bool modified, UD60x18 aprTarget_, UD60x18 aprBase_) = fetchAprs();
        if (modified == false) {
            updateAprSrt(aprTarget_, aprBase_);
        }
    }

    /// @notice Called by the CDO to account for a fee
    function accrueFee(bool isJrt, uint256 amount) external onlyCDO {
        TNavSplitState memory state = _currentNavSplitState();
        _accrueAssetTime(block.timestamp, state);
        uint256 retentionBps = isJrt ? feeJrtRetentionBps : feeSrtRetentionBps;
        uint256 amountToReserve = (amount * (1e18 - retentionBps)) / 1e18;
        reserveNav += amountToReserve;
        if (isJrt) {
            jrtBaseNav -= amountToReserve;
            jrtNavProjected -= amountToReserve;
        } else {
            srtBaseNav -= amountToReserve;
            windowNetFlows -= int256(amountToReserve);
        }
        emit FeeAccrued(isJrt, amountToReserve, amount - amountToReserve);
    }

    function adjustFeeWatermark(uint256 assetsIn, uint256 assetsOut) internal {
        if (assetsIn > assetsOut) {
            feeWatermarkNav += assetsIn - assetsOut;
        } else if (assetsOut > assetsIn) {
            feeWatermarkNav = Math.saturatingSub(feeWatermarkNav, assetsOut - assetsIn);
        }
    }

    /*****************************************************************************
     *                  NAV Split Calculation                                     *
     *****************************************************************************/

    /// @notice Routes to projection (no oracle update) or reconciliation (oracle update detected)
    function calculateNAVSplit(
        uint256 navT0,
        uint256 jrtNavT0Projected,
        uint256 jrtNavT0Real,
        uint256 srtNavT0,
        uint256 reserveNavT0,
        uint256 navT1,
        uint256 navT1Time,
        uint256 navMTM,
        uint256 navMTMTime,
        uint256 timestamp,
        TNavSplitState memory state
    )
        internal
        view
        returns (
            uint256 jrtNavT1Projected,
            uint256 jrtNavT1Real,
            uint256 srtNavT1,
            uint256 reserveNavT1
        )
    {
        if (jrtNavT0Projected == 0 && srtNavT0 == 0) {
            return (0, 0, 0, Math.max(navT1, navMTM));
        }

        if (_shouldReconcile(navT0, navT1)) {
            // Reconciliation: realized PnL detected (navT0 != navT1)
            return
                calculateNAVSplitReconciliation(
                    navT0,
                    jrtNavT0Projected,
                    jrtNavT0Real,
                    srtNavT0,
                    reserveNavT0,
                    navT1,
                    timestamp,
                    state
                );
        }
        if (useMTMProjection) {
            return
                calculateNAVSplitProjectedMTM(
                    navT0,
                    jrtNavT0Projected,
                    jrtNavT0Real,
                    srtNavT0,
                    reserveNavT0,
                    navMTM,
                    timestamp,
                    state
                );
        }
        // No realized gain yet; process using the APR projection
        return
            calculateNAVSplitProjected(
                navT0,
                jrtNavT0Projected,
                jrtNavT0Real,
                srtNavT0,
                reserveNavT0,
                timestamp
            );
    }

    /// @notice Projection during the epoch using current strategy MTM NAV.
    /// @dev Reuses reconciliation allocation against navMTM, but keeps reserve and real NAV at T0.
    function calculateNAVSplitProjectedMTM(
        uint256 navT0,
        uint256 jrtNavT0Projected,
        uint256 jrtNavT0Real,
        uint256 srtNavT0,
        uint256 reserveNavT0,
        uint256 navMTM,
        uint256 timestamp,
        TNavSplitState memory state
    )
        internal
        view
        returns (
            uint256 jrtNavT1Projected,
            uint256 jrtNavT1Real,
            uint256 srtNavT1,
            uint256 reserveNavT1
        )
    {
        (
            jrtNavT1Projected,
            jrtNavT1Real,
            srtNavT1,
        ) = calculateNAVSplitReconciliation(
                navT0,
                jrtNavT0Projected,
                jrtNavT0Real,
                srtNavT0,
                reserveNavT0,
                navMTM,
                timestamp,
                state
            );

        // No changes to reserve on MTM Projection
        reserveNavT1 = reserveNavT0;

        // Reflect Senior MTM projected movement in Junior real NAV.
        if (srtNavT1 >= srtNavT0) {
            uint256 srtProjection = srtNavT1 - srtNavT0;
            jrtNavT1Real = jrtNavT0Real - Math.min(
                srtProjection,
                Math.saturatingSub(jrtNavT0Real, ONE_ASSET)
            );
        } else {
            jrtNavT1Real = jrtNavT0Real + (srtNavT0 - srtNavT1);
        }
    }

    /// @notice Projection during the epoch - uses index-based aprSrt for smooth NAV evolution
    /// @dev Same approach as DiscreteAccounting, but also conceptually accumulates srtPnLProjected
    function calculateNAVSplitProjected(
        uint256 navT0,
        uint256 jrtNavT0Projected,
        uint256 jrtNavT0Real,
        uint256 srtNavT0,
        uint256 reserveNavT0,
        uint256 timestamp
    )
        internal
        view
        returns (
            uint256 jrtNavT1Projected,
            uint256 jrtNavT1Real,
            uint256 srtNavT1,
            uint256 reserveNavT1
        )
    {
        if (jrtNavT0Projected == 0 && srtNavT0 == 0) {
            return (0, 0, 0, 0);
        }

        uint256 navTargetIndexT1 = getNavTargetIndexT1(timestamp);
        // Gain = Assets * (TargetIndex1 / TargetIndex0 - 1);
        // Calculate gain based on real NAV, not projected
        int256 gain_dT = calculateGain(navT0, navTargetIndexT1, navTargetIndex);

        if (gain_dT < 0) {
            // never happens in projection, jic: cover by Jrt, then Reserve, then Srt
            uint256 loss = uint256(-gain_dT);

            uint256 jrtLoss = Math.min(
                loss,
                Math.saturatingSub(jrtNavT0Projected, ONE_ASSET)
            );

            loss -= jrtLoss;
            uint256 reserveLoss = Math.min(reserveNavT0, loss);

            loss -= reserveLoss;
            uint256 srtLoss = Math.min(srtNavT0, loss);
            // The market is considered abandoned if losses would consume the protected dust NAV
            require(srtLoss == loss, "NavBelowMinimum");

            jrtNavT1Projected = jrtNavT0Projected - jrtLoss;
            jrtNavT1Real = Math.min(jrtNavT1Projected, jrtNavT0Real);

            srtNavT1 = srtNavT0 - srtLoss;
            reserveNavT1 = reserveNavT0 - reserveLoss;

            return (jrtNavT1Projected, jrtNavT1Real, srtNavT1, reserveNavT1);
        }

        uint256 gain_dTAbs = uint256(gain_dT);

        // Decrease projected gain by the expected performance fee only above the high-water mark.
        if (reserveBps > 0 && navT0 + gain_dTAbs > feeWatermarkNav) {
            uint256 feeableGain = Math.min(
                gain_dTAbs,
                navT0 + gain_dTAbs - feeWatermarkNav
            );
            uint256 reserve_dT = (feeableGain * reserveBps) / PERCENTAGE_100;
            gain_dTAbs -= reserve_dT;
        }

        // Allocate the full gain to Junior first
        jrtNavT1Projected = jrtNavT0Projected + gain_dTAbs;

        // Calculate Srt projected gain
        uint256 srtTargetIndexT1 = getSrtTargetIndexT1(timestamp);
        // Gain = Assets * (TargetIndex1 / TargetIndex0 - 1);
        int256 srtGainTarget = calculateGain(
            srtNavT0,
            srtTargetIndexT1,
            srtTargetIndex
        );
        if (srtGainTarget < 0) {
            uint256 loss = uint256(-srtGainTarget);
            uint256 srtLoss = Math.min(srtNavT0, loss);

            srtNavT0 -= srtLoss;
            jrtNavT0Real += srtLoss;
            jrtNavT1Projected += srtLoss;
            srtGainTarget = 0;
        }
        uint256 srtGainTargetAbs = Math.min(
            uint256(srtGainTarget),
            Math.saturatingSub(jrtNavT0Real, ONE_ASSET)
        );

        // Final Jrt (after srt funding)
        jrtNavT1Projected = jrtNavT1Projected - srtGainTargetAbs;
        jrtNavT1Real = Math.saturatingSub(jrtNavT0Real, srtGainTargetAbs);

        // Final Srt
        srtNavT1 = srtNavT0 + srtGainTargetAbs;

        // No changes to NAV and reserve on Projection
        reserveNavT1 = reserveNavT0;

        return (jrtNavT1Projected, jrtNavT1Real, srtNavT1, reserveNavT1);
    }

    /// @notice Reconciliation at epoch end — DYS-based PnL allocation with true-up
    /// @dev Uses asset-time weighting to allocate realized PnL between tranches
    function calculateNAVSplitReconciliation(
        uint256 navT0,
        uint256 jrtNavT0Projected,
        uint256 jrtNavT0Real,
        uint256 srtNavT0,
        uint256 reserveNavT0,
        uint256 navT1,
        uint256 timestamp,
        TNavSplitState memory state
    )
        internal
        view
        returns (
            uint256 jrtNavT1Projected,
            uint256 jrtNavT1Real,
            uint256 srtNavT1,
            uint256 reserveNavT1
        )
    {
        int256 pnl = int256(navT1) - int256(navT0);

        // Reserve allocation
        uint256 reserve_dT = 0;
        if (pnl > 0 && navT1 > state.feeWatermarkNav && reserveBps > 0) {
            uint256 feeableGain = navT1 - state.feeWatermarkNav;
            reserve_dT = feeableGain * reserveBps / PERCENTAGE_100;
            pnl -= int256(reserve_dT);
        }
        reserveNavT1 = reserveNavT0 + reserve_dT;

        // Accrue the unpersisted interval before unwinding projected Senior NAV.
        (
            uint256 srtNavTimeAccrued,
            uint256 navTimeAccrued,
            uint256 navTimeNetAccrued,
            uint256 srtProjectedPnLTimeAccrued
        ) = _accruedAssetTimeView(
            navT0,
            jrtNavT0Projected,
            srtNavT0,
            reserveNavT0,
            timestamp,
            state
        );

        // srtNavT0 includes srtPnLProjected added during the epoch
        // unwind it and rollback to real T0 assets for SRT and JRT
        // Guard: large Senior withdrawals during the epoch can make srtNavT0 < srtPnLProjected
        uint256 projUndo = Math.min(state.srtPnLProjected, srtNavT0);
        srtNavT0 = srtNavT0 - projUndo;
        jrtNavT0Real = jrtNavT0Real + projUndo;

        // Safe assets for SRT and JRT to move around
        uint256 srtSafe = Math.saturatingSub(srtNavT0, ONE_ASSET);
        uint256 jrtSafe = Math.saturatingSub(jrtNavT0Real, ONE_ASSET);

        // True-UP: calculate Senior PnL:
        // 1. Realized based on the RiskPremium (for negative PnL - RiskPremium lowers the loss)
        // 2. if Benchmark mode: take the Projected PnL if > realized
        // 3. Check and apply the floored loss for Senior
        //
        // Whenever Senior realized PnL is settled, calculate Junior PnL:
        // 1. Decrease received PnL by Senior's PnL:
        // 2.   when positive, add to Junior NAV
        // 3.   when negative, apply the loss waterfall: Junior loss, Reserve loss, then Senior loss

        // Calculate Senior PnL allocation using asset-time weighting.
        // Use accumulated asset-time if available, otherwise use snapshot NAVs.
        uint256 srtNavTime_ = navTimeAccrued > 0 ? srtNavTimeAccrued : srtNavT0;
        uint256 navTime_ = navTimeAccrued > 0 ? navTimeAccrued : navT0;

        // Note: riskPremium is capped at 1e18 (100%) via setRiskParameters validation
        UD60x18 riskPremium = calculateRiskPremium();
        // Risk premium: srtFactor = 1 - riskPremium
        uint256 srtFactor = 1e18 - riskPremium.unwrap();

        int256 srtPnLRealized;
        if (useRatesForReconciliation) {
            // Rate-based formula: senior earns (senior sub-strategy rate growth) * srtNavTime * srtFactor.
            // Used when the senior sub-strategy has a queryable exchange rate (e.g. IsolatedStrategy);
            // isolates senior returns regardless of junior sub-strategy performance.
            uint256 srtRateT1 = cdo.strategy().getRate();
            uint256 epochDt = timestamp > state.epochStart ? timestamp - state.epochStart : 0;
            bool isPositive = srtRateT1 > state.strategyRate;
            uint256 rateDeltaAbs = isPositive
                ? srtRateT1 - state.strategyRate
                : state.strategyRate - srtRateT1;
            if (epochDt > 0) {
                uint256 srtNavTimeReal = Math.saturatingSub(srtNavTime_, srtProjectedPnLTimeAccrued);
                uint256 navTimeXGrowth = Math.mulDiv(srtNavTimeReal, rateDeltaAbs, state.strategyRate);
                uint256 pnlAbs = Math.mulDiv(navTimeXGrowth, srtFactor, 1e18 * epochDt);
                srtPnLRealized = isPositive
                    ?  int256(pnlAbs)
                    : -int256(pnlAbs);
            }
            // else: sub-strat had no growth this epoch — senior earns nothing (srtPnLRealized stays 0)
        } else {
            // Proportional nav-time formula (single strategy / no rate tracking).
            // srtPnL = totalUnderlyingProfit * srtFactor * srtNavTime / navTime
            uint256 srtNavTimeNet_ = Math.saturatingSub(srtNavTime_, srtProjectedPnLTimeAccrued);
            uint256 navTimeNet_ = navTimeNetAccrued > 0 ? navTimeNetAccrued : navT0;

            srtPnLRealized = navTime_ == 0
                ? int256(0)
                : (pnl + int256(reserve_dT)) * int256(srtFactor) * int256(srtNavTimeNet_) / (int256(navTimeNet_) * 1e18);
        }

        // Benchmark mode: Use max(realized PnL, benchmark gain)
        // Note: Benchmark APR changes during the epoch, so we separately track the benchmark gain during the projection
        if (useBenchmarkProjection && srtPnLRealized < int256(state.srtPnLBenchmark)) {
            srtPnLRealized = int256(state.srtPnLBenchmark);
        }

        uint256 floorRate_ = floorRate;

        if (!useBenchmarkProjection && srtPnLRealized < 0 && floorRate_ == 0) {
            // No loss for Senior with BaseAPR mode, negative PnL, and the floor rate at 0
            srtPnLRealized = 0;
        }

        // Make Junior cover paid-out projected Senior assets charged to the remaining Senior NAV.
        // Cap srtPaidProjected by the paid projection actually included in `projUndo`.
        if (useJuniorCoversPaidSrtProjection && projUndo > 0) {
            uint256 paidProjectedUnwound = projUndo == state.srtPnLProjected
                ? state.srtPaidProjected
                // Here, pre-unwind srtNavT0' < srtPnLProjected.
                // Recover pre-unwind srtNavT0' as srtNavT0 + projUndo.
                : Math.saturatingSub(srtNavT0 + projUndo + state.srtPaidProjected, state.srtPnLProjected);

            if (srtPnLRealized < int256(paidProjectedUnwound)) {
                // Only adjust if realized PnL does not already cover it
                if (srtPnLRealized > 0) {
                    srtPnLRealized = int256(paidProjectedUnwound);
                } else {
                    srtPnLRealized += int256(paidProjectedUnwound);
                }
            }
        }

        // Cap Senior loss to available safe assets
        if (srtPnLRealized < -int256(srtSafe)) {
            srtPnLRealized = -int256(srtSafe);
        }

        // Senior: apply realized PnL
        srtNavT1 = uint256(int256(srtNavT0) + srtPnLRealized);

        if (srtPnLRealized < 0 && floorRate_ > 0) {
            // Senior: calculate and apply the rolling 24h Senior NAV floor
            // Note: The floor can only be reached when Senior has a negative return in the current reconciliation
            uint256 srtNavFloor = _computeSrtNavFloor(floorRate_, timestamp);
            if (srtNavFloor > 0 && srtNavT1 < srtNavFloor) {
                uint256 floorDelta = srtNavFloor - srtNavT1;
                srtNavT1 += floorDelta;
                srtPnLRealized += int256(floorDelta);
            }
        }

        // Junior PnL scenarios after Senior allocation:
        // pnl < 0 and srtPnLRealized < 0: reduces JRT Loss
        // pnl < 0 and srtPnLRealized > 0: increases JRT Loss (benchmark mode)
        // pnl > 0 and srtPnLRealized > 0: reduces JRT Profit, can push JRT into loss (benchmark mode)
        // pnl > 0 and srtPnLRealized < 0: increases JRT profit (edge case)
        int256 jrtPnLRealized = pnl - srtPnLRealized;

        if (jrtPnLRealized >= 0) {
            jrtNavT1Real = jrtNavT0Real + uint256(jrtPnLRealized);
        } else {
            // Apply the Loss-Waterfall: Junior -> Reserve -> Senior
            // Note: This can cancel Senior's benchmark gain if Junior cannot cover it
            uint256 loss = uint256(-jrtPnLRealized);
            uint256 jrtLoss = Math.min(jrtSafe, loss);
            loss -= jrtLoss;
            uint256 reserveLoss = Math.min(reserveNavT1, loss);
            loss -= reserveLoss;
            // Apply SRT loss to recently accrued balance
            uint256 srtLoss = Math.min(srtNavT1, loss);
            // The market is considered abandoned if losses would consume the protected dust NAV
            require(srtLoss == loss, "NavBelowMinimum");

            jrtNavT1Real = jrtNavT0Real - jrtLoss;
            srtNavT1 -= srtLoss;
            reserveNavT1 -= reserveLoss;
        }

        // Invariant: Total new NAV must equal sum of all NAVs
        // This ensures no value is created or destroyed during reconciliation
        if (navT1 != (jrtNavT1Real + srtNavT1 + reserveNavT1)) {
            revert InvalidNavSplit(navT1, jrtNavT1Real, srtNavT1, reserveNavT1);
        }

        return (jrtNavT1Real, jrtNavT1Real, srtNavT1, reserveNavT1);
    }

    /// @notice Computes the Senior NAV floor based on the rolling 24h window
    /// @dev Returns 0 if floor is disabled or not yet initialized
    function _computeSrtNavFloor(uint256 floorRate_, uint256 timestamp) internal view returns (uint256) {
        if (floorRate_ == 0) {
            return 0;
        }
        int256 baseline = int256(windowStartSrtNav) + windowNetFlows;
        if (baseline <= 0) {
            return 0;
        }

        if (timestamp > windowEnd) {
            // Window has expired — extend allowed loss for inactivity
            uint256 dT = timestamp - windowEnd;
            floorRate_ = floorRate_ * (1 days + dT) / 1 days;
        }

        uint256 minRate = Math.saturatingSub(1e18, floorRate_);
        uint256 srtNavFloor = minRate * uint256(baseline) / 1e18;
        return srtNavFloor;
    }

    /*****************************************************************************
     *                  Internal Accounting Logic                                 *
     *****************************************************************************/

    function updateAccountingInner(
        uint256 navT1,
        uint256 navT1Time,
        uint256 navMTM,
        uint256 navMTMTime
    ) internal {

        bool isReconciliation = _shouldReconcile(nav, navT1);
        bool hasMTMAfterReconciliation = isReconciliation && navMTMTime > navT1Time;
        uint256 timestamp = hasMTMAfterReconciliation ? navT1Time : block.timestamp;

        if (timestamp < lastAccrual || navMTMTime < navT1Time || (navT1Time == navMTMTime && navT1 != navMTM)) {
            revert InvalidAssetsSnapshot(lastAccrual, navT1, navT1Time, navMTM, navMTMTime);
        }

        TNavSplitState memory state = _currentNavSplitState();
        _accrueAssetTime(timestamp, state);
        (
            uint256 jrtNavT1Projected,
            uint256 jrtNavT1Real,
            uint256 srtNavT1,
            uint256 reserveNavT1
        ) = calculateNAVSplit(
                nav,
                jrtNavProjected,
                jrtBaseNav,
                srtBaseNav,
                reserveNav,
                navT1,
                navT1Time,
                navMTM,
                navMTMTime,
                timestamp,
                state
            );

        if (isReconciliation) {
            // Track projected PnL increment for the next epoch
            // The calculateNAVSplitProjected during the epoch accumulated srtPnLProjected
            // At reconciliation, the true-up was already applied, so reset
            srtPnLProjected = 0;
            srtPnLBenchmark = 0;
            srtPaidProjected = 0;
            srtNavTime = 0;
            navTime = 0;
            navTimeNet = 0;
            srtProjectedPnLTime = 0;
            epochStart = navT1Time;

            // Snapshot the senior sub-strategy exchange rate as T0 for the next epoch.
            if (useRatesForReconciliation) {
                uint256 newRate = cdo.strategy().getRate();
                if (newRate > 0) strategyRate = newRate;
            }
            if (useNavAtReconciliation) {
                lastReconciliation = navT1Time;
            }
            if (navT1 > feeWatermarkNav) {
                feeWatermarkNav = navT1;
            }

            // Floor window rollover
            if (navT1Time >= windowEnd) {
                windowStartSrtNav = srtNavT1;
                windowNetFlows = 0;
                windowEnd = navT1Time + 1 days;
            }
        } else if (nav > 0) {
            // During epoch, srtBaseNav already includes live Senior projection.
            // Keep srtPnLProjected equal to the current embedded projection,
            // not the sum of all intermediate MTM updates.
            uint256 liveProjection = Math.saturatingSub(srtPnLProjected, srtPaidProjected);
            uint256 srtBaseNavReal = srtBaseNav - Math.min(liveProjection, srtBaseNav);
            uint256 srtGain = srtNavT1 > srtBaseNavReal ? srtNavT1 - srtBaseNavReal : 0;
            srtPnLProjected = srtPaidProjected + srtGain;

            if (useBenchmarkProjection) {
                uint256 benchmarkIndexT1 = getBenchmarkIndexT1(navMTMTime);
                int256 srtBenchmarkGain = calculateGain(
                    srtBaseNav, benchmarkIndexT1, benchmarkIndex
                );
                if (srtBenchmarkGain > 0) {
                    srtPnLBenchmark += uint256(srtBenchmarkGain);
                }
            }
        }

        updateIndex(timestamp);
        nav = navT1;
        navTimestamp = timestamp;
        lastAccrual = timestamp;
        srtBaseNav = srtNavT1;
        jrtNavProjected = jrtNavT1Projected;
        jrtBaseNav = jrtNavT1Real;
        reserveNav = reserveNavT1;

        if (hasMTMAfterReconciliation) {
            updateAccountingInner(
                navT1,
                navT1Time,
                navMTM,
                navMTMTime
            );
        }
    }

    /*****************************************************************************
     *                  Index & APR Calculation                                   *
     *****************************************************************************/

    function getSrtTargetIndexT1(uint256 timestamp) internal view returns (uint256) {
        return
            calculateTargetIndex(
                srtTargetIndex,
                indexTimestamp,
                timestamp,
                aprSrt
            );
    }

    function getBenchmarkIndexT1(uint256 timestamp) internal view returns (uint256) {
        return
            calculateTargetIndex(
                benchmarkIndex,
                indexTimestamp,
                timestamp,
                aprTarget
            );
    }

    function getNavTargetIndexT1(uint256 timestamp) internal view returns (uint256) {
        return
            calculateTargetIndex(
                navTargetIndex,
                indexTimestamp,
                timestamp,
                aprBase
            );
    }

    function calculateTargetIndex(
        uint256 targetIndex,
        uint256 t0,
        uint256 t1,
        UD60x18 apr
    ) internal pure returns (uint256) {
        uint256 dt = t1 - t0;
        if (dt == 0) {
            return targetIndex;
        }
        uint256 interestFactor = (apr.unwrap() * dt) / SECONDS_PER_YEAR;
        uint256 targetIndexT1 = (targetIndex * (1e18 + interestFactor)) / 1e18;
        return targetIndexT1;
    }

    function calculateRiskPremium() internal view returns (UD60x18) {
        (
            uint256 jrtEffective,
            uint256 srtEffective
        ) = calcEffectiveNav(jrtNavProjected, srtBaseNav);

        UD60x18 tvlRatio = UD60x18.wrap(
            srtEffective == 0 ? 0 : ((srtEffective * 1e18) / (srtEffective + jrtEffective))
        );
        UD60x18 riskPremium = calculateRiskPremiumInner(
            riskX,
            riskY,
            riskK,
            tvlRatio
        );
        return riskPremium;
    }
    function calculateRiskPremiumInner(
        UD60x18 x,
        UD60x18 y,
        UD60x18 k,
        UD60x18 tvlRatioSrt
    ) internal pure returns (UD60x18) {
        UD60x18 riskPremium = x + y * pow(tvlRatioSrt, k);
        return riskPremium;
    }

    // Fetch APRs from Feed
    function fetchAprs()
        internal
        returns (bool modified, UD60x18 aprTargetT1, UD60x18 aprBaseT1)
    {
        if (address(aprPairFeed) == address(0)) {
            return (false, aprTarget, aprBase);
        }
        IAprPairFeed.TRound memory round = aprPairFeed.latestRoundData();

        aprTargetT1 = normalizeAprFromFeed(round.aprTarget);
        aprBaseT1 = normalizeAprFromFeed(round.aprBase);

        if (aprTargetT1 != aprTarget || aprBaseT1 != aprBase) {
            aprTarget = aprTargetT1;
            aprBase = aprBaseT1;
            updateAprSrt(aprTargetT1, aprBaseT1);
            return (true, aprTargetT1, aprBaseT1);
        }
        return (false, aprTargetT1, aprBaseT1);
    }

    function updateIndex() internal {
        updateIndex(block.timestamp);
    }

    function updateIndex(uint256 timestamp) internal {
        if (timestamp == indexTimestamp) {
            return;
        }
        if (useBenchmarkProjection) {
            benchmarkIndex = getBenchmarkIndexT1(timestamp);
        }
        srtTargetIndex = getSrtTargetIndexT1(timestamp);
        navTargetIndex = getNavTargetIndexT1(timestamp);
        indexTimestamp = timestamp;
    }
    function updateAprSrt(UD60x18 aprTarget_, UD60x18 aprBase_) internal {
        UD60x18 risk = calculateRiskPremium();
        UD60x18 aprSrt1 = mul(aprBase_, UD60x18.wrap(1e18) - risk);
        aprSrt = UD60x18Ext.max(aprTarget_, aprSrt1);
    }

    function syncAprs() internal {
        (bool modified, UD60x18 aprTarget_, UD60x18 aprBase_) = fetchAprs();
        if (modified) {
            emit AprDataChangedViaPush(aprTarget_, aprBase_);
        } else {
            updateAprSrt(aprTarget_, aprBase_);
        }
    }

    function calculateGain(
        uint256 navT0,
        uint256 targetIndexT1,
        uint256 targetIndexT0
    ) internal pure returns (int256) {
        return int256((navT0 * targetIndexT1) / targetIndexT0) - int256(navT0);
    }

    function normalizeAprFromFeed(
        /* SD7x12 */ int64 apr
    ) internal pure returns (UD60x18) {
        if (apr < APR_FEED_BOUNDARY_MIN) {
            apr = APR_FEED_BOUNDARY_MIN;
        }
        if (apr > APR_FEED_BOUNDARY_MAX) {
            apr = APR_FEED_BOUNDARY_MAX;
        }
        return
            UD60x18.wrap(
                uint256(int256(apr)) * (10 ** (18 - APR_FEED_DECIMALS))
            );
    }

    /*****************************************************************************
     *                  External configuration Methods                           *
     *****************************************************************************/

    // Trigger fetching new APRs to update srtTargetIndex
    function onAprChanged() external onlyRole(UPDATER_FEED_ROLE) {
        (uint256 navT1, uint256 navT1Time, uint256 navMTM, uint256 navMTMTime) = _currentNavs();
        updateAccountingInner(navT1, navT1Time, navMTM, navMTMTime);
        syncAprs();
    }

    function setRiskParameters(
        UD60x18 riskX_,
        UD60x18 riskY_,
        UD60x18 riskK_
    ) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        (uint256 navT1, uint256 navT1Time, uint256 navMTM, uint256 navMTMTime) = _currentNavs();
        updateAccountingInner(navT1, navT1Time, navMTM, navMTMTime);
        riskX = riskX_;
        riskY = riskY_;
        riskK = riskK_;
        UD60x18 risk = calculateRiskPremiumInner(
            riskX_,
            riskY_,
            riskK_,
            UD60x18.wrap(1e18)
        );
        require(risk.unwrap() < PERCENTAGE_100, ">=100%");
        emit RiskParametersChanged(riskX_, riskY_, riskK_);
        updateAprSrt(aprTarget, aprBase);
    }

    /// @notice Sets the APR feed contract for fetching APR target and APR base.
    /// @dev Finalizes accounting with the current feed before switching, then starts the new APR period.
    /// @param aprPairFeed_ The address of the new APR feed contract.
    function setAprPairFeed(IAprPairFeed aprPairFeed_) external onlyOwner {
        require(aprPairFeed_.decimals() == APR_FEED_DECIMALS, "InvalidFeed");
        (uint256 navT1, uint256 navT1Time, uint256 navMTM, uint256 navMTMTime) = _currentNavs();
        updateAccountingInner(navT1, navT1Time, navMTM, navMTMTime);
        syncAprs();
        aprPairFeed = aprPairFeed_;
        emit AprPairFeedChanged(address(aprPairFeed_));
        syncAprs();
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
        (uint256 navT1, uint256 navT1Time, uint256 navMTM, uint256 navMTMTime) = _currentNavs();
        updateAccountingInner(navT1, navT1Time, navMTM, navMTMTime);
        floorRate = rate;

        windowStartSrtNav = srtBaseNav;
        windowNetFlows = 0;
        windowEnd = block.timestamp + 1 days;
        emit FloorRateChanged(rate);
    }

    function setReserveBps(uint256 bps) external onlyOwner {
        require(
            bps <= RESERVE_BPS_MAX && bps != reserveBps,
            "InvalidNewReserve"
        );
        (uint256 navT1, uint256 navT1Time, uint256 navMTM, uint256 navMTMTime) = _currentNavs();
        updateAccountingInner(navT1, navT1Time, navMTM, navMTMTime);
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

    /// @notice Sets the valuation price for the base asset.
    function setValuationPrice (uint128 price) external onlyCDO returns (bool){
        bool isValuationLossPeriod = valuationPrice < 1e18;
        bool valuationLossEntered = isValuationLossPeriod == false && price < 1e18;
        // Allow the valuation price in range 0.0001-1
        require(0.0001e18 <= price && price <= 1e18, "InvalidValuationPrice");
        _resyncsrtFundNav(price);
        valuationPrice = price;
        valuationUpdatedAt = uint64(block.timestamp);
        if (valuationLossEntered) {
            // Grace period starts; further grace periods in subsequent drops should handle PAUSER_ROLE
            valuationEnteredAt = uint64(block.timestamp);
        }
        emit ValuationPriceChanged(price);
        return valuationLossEntered;
    }

    /// @notice Sets the grace period
    function setValuationGracePeriod (uint64 period) external onlyRole(PAUSER_ROLE) {
        require(period <= 1 days, "GracePeriodTooLong");
        valuationGracePeriod = period;
        emit ValuationGracePeriodChanged(period);
    }

    function _trackSrtFundNavIn(uint256 amount) internal returns (uint256 srtFundAmountIn) {
        if (amount == 0 || valuationPrice == 1e18) {
            return 0;
        }
        srtFundAmountIn = Math.mulDiv(amount, 1e18 - valuationPrice, valuationPrice);
        srtFundedGrossNav += amount;
    }

    function _resyncsrtFundNav(uint128 price) internal {
        uint256 fundedGrossNav = srtFundedGrossNav;
        if (fundedGrossNav == 0) {
            return;
        }
        if (price == 1e18) {
            srtFundedGrossNav = 0;
            srtFundNav = 0;
            return;
        }
        // Senior deposits self-fund only the valuation loss that existed at deposit time.
        // On further de-peg, Junior still covers the additional Senior loss.
        srtFundNav = Math.min(srtFundNav, Math.mulDiv(fundedGrossNav, 1e18 - price, price));
    }

    /// @notice Adjusts Junior and Senior NAVs when the base asset is trading below par (valuation loss)
    /// @dev When valuationPrice < 1e18, transfers value from Junior to Senior to compensate for the
    ///      Senior tranche's exposure to the devalued asset. This ensures Senior holders maintain
    ///      their expected value despite the underlying asset trading at a discount.
    ///
    ///      **Important**: This function returns **virtual/effective NAVs** for view calculations only.
    ///      The actual stored state variables (jrtBaseNav, srtBaseNav) remain unchanged. The effective
    ///      NAVs are used in:
    ///      - `totalAssets()` and `totalAssetsT0()` for share price calculations
    ///      - `maxWithdraw()` and `maxDeposit()` for deposit/withdrawal limits
    ///      - Price-per-share queries by external contracts
    ///
    ///      The valuation adjustment is applied at withdrawal time via `splitValuatedNavOut()` in
    ///      `updateBalanceFlow()`, which ensures the actual asset distribution matches the effective
    ///      NAV ratios.
    ///
    /// @param jrtFact The factual Junior NAV before adjustment (from storage)
    /// @param srtFact The factual Senior NAV before adjustment (from storage)
    /// @return jrtEffective The adjusted Junior NAV after transferring value to Senior (virtual)
    /// @return srtEffective The adjusted Senior NAV after receiving value from Junior (virtual)
    /// @custom:example If valuationPrice = 0.95e18 (5% discount) and srtFact = 1000 USDC,
    ///                 Senior needs an additional ~52.63 USDC from Junior to maintain full value.
    ///                 The transfer is capped by Junior's available safe assets (jrtFact - ONE_ASSET).
    /// @custom:invariant jrtEffective + srtEffective == jrtFact + srtFact (total NAV preserved)
    function calcEffectiveNav (uint256 jrtFact, uint256 srtFact) internal view returns (uint256 jrtEffective, uint256 srtEffective) {
        if (valuationPrice == 1e18) {
            return (jrtFact, srtFact);
        }
        uint256 extraNeeded = srtFact * (1e18 - valuationPrice) / valuationPrice;
        extraNeeded = Math.saturatingSub(extraNeeded, srtFundNav);
        uint256 extraTaken = Math.min(
            Math.saturatingSub(jrtFact, ONE_ASSET),
            extraNeeded
        );
        return (jrtFact - extraTaken, srtFact + extraTaken);
    }

    /// @notice Determines if reconciliation should occur based on NAV changes
    /// @param navT0 The NAV at time T0 (previous state)
    /// @param navT1 The NAV at time T1 (current state)
    /// @return bool True if reconciliation should occur, false otherwise
    function _shouldReconcile (uint256 navT0, uint256 navT1) internal pure returns (bool) {
        return navT0 != navT1;
    }
}
