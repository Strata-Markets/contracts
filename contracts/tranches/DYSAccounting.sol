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
contract DYSAccounting is IAccounting, CDOComponent {
    uint256 constant SECONDS_PER_YEAR = 31_536_000;

    int64 private constant APR_FEED_BOUNDARY_MAX = 2e12; // 200%
    int64 private constant APR_FEED_BOUNDARY_MIN = 0;
    uint256 private constant APR_FEED_DECIMALS = 12;
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
    uint256 constant PERCENTAGE_100 = 1e18;
    uint256 constant RESERVE_BPS_MAX = 0.2e18;

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

    /*****************************************************************************
     *                  DYS-specific State Variables                              *
     *****************************************************************************/

    /// @notice Time-weighted Senior NAV (asset-time)
    uint256 public srtNavTime;

    /// @notice Time-weighted Junior NAV (asset-time, uses projected)
    uint256 public jrtNavTime;

    /// @notice Time-weighted total system NAV (asset-time)
    uint256 public navTime;

    /// @notice Timestamp of last asset-time accrual
    uint256 public lastAccrual;

    /// @notice Accumulated projected Senior PnL during the current epoch
    uint256 public srtPnLProjected;

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

    /// @notice Timestamp of the last oracle-detected NAV change; used as time anchor when useNavAtReconciliation is true
    uint256 public lastReconciliation;

    error InvalidNavSplit(
        uint256 navT1,
        uint256 jrtAssets,
        uint256 srtAssets,
        uint256 reserveAssets
    );
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

    constructor(uint256 navDecimals, bool useBenchmarkProjection_, bool useNavAtReconciliation_) {
        ONE_ASSET = 10 ** navDecimals;
        useBenchmarkProjection = useBenchmarkProjection_;
        useNavAtReconciliation = useNavAtReconciliation_;
    }

    function initialize(
        address owner_,
        address acm_,
        IStrataCDO cdo_,
        IAprPairFeed aprPairFeed_
    ) public virtual initializer {
        AccessControlled_init(owner_, acm_);
        cdo = cdo_;

        aprPairFeed = aprPairFeed_;

        riskX = UD60x18.wrap(0.2e18);
        riskY = UD60x18.wrap(0.2e18);
        riskK = UD60x18.wrap(0.3e18);

        srtTargetIndex = 1e18;
        navTargetIndex = 1e18;
        indexTimestamp = block.timestamp;
        lastAccrual = block.timestamp;
        epochStart = block.timestamp;
        minimumJrtSrtRatio = 0.05e18;
        minimumJrtSrtRatioBuffer = 0.06e18;

        windowEnd = block.timestamp + 1 days;
        windowStartSrtNav = 0;
        windowNetFlows = 0;
        floorRate = 0;
        valuationPrice = 1e18;
        if (useNavAtReconciliation) lastReconciliation = block.timestamp;
    }

    /*****************************************************************************
     *                  DYS Asset-Time Tracking                                   *
     *****************************************************************************/

    /// @notice Accrues asset-time for all tranches. MUST be called before any state change.
    function _accrueAssetTime() internal {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0) return;

        uint256 srAssets = srtBaseNav;
        uint256 jrAssets = jrtNavProjected;
        uint256 systemAssets = srAssets + jrAssets + reserveNav;

        srtNavTime += srAssets * dt;
        jrtNavTime += jrAssets * dt;
        navTime += systemAssets * dt;
        lastAccrual = block.timestamp;
    }

    function _navAnchor() private view returns (uint256) {
        return useNavAtReconciliation ? lastReconciliation : navTimestamp;
    }

    /*****************************************************************************
     *                  View Methods                                              *
     *****************************************************************************/

    /// @notice Returns the updated total assets for each tranche and the reserve
    function totalAssets(
        uint256 navT1
    )
        public
        view
        returns (
            uint256 jrtNavT1Projected,
            uint256 srtNavT1,
            uint256 reserveNavT1
        )
    {
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
                navT1
            );
        (jrtNavT1Projected, srtNavT1) = calcEffectiveNav(jrtNavT1Projected, srtNavT1);
        return (jrtNavT1Projected, srtNavT1, reserveNavT1);
    }

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
        uint256 navT1 = cdo.totalStrategyAssets(nav, _navAnchor());
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
                navT1
            );
        (jrtNavT1Projected, srtNavT1) = calcEffectiveNav(jrtNavT1Projected, srtNavT1);
        return (jrtNavT1Projected, srtNavT1, reserveNavT1);
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
        (, , uint256 reserveNavT1) = totalAssets(
            cdo.totalStrategyAssets(nav, _navAnchor())
        );
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
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        if (amount > reserveNav) {
            revert ReserveTooLow(reserveNav, amount);
        }
        if (amount < (jrtAmountIn + srtAmountIn)) {
            revert ReserveTooLow(amount, jrtAmountIn + srtAmountIn);
        }
        _accrueAssetTime();
        reserveNav = reserveNav - amount;
        nav = nav + jrtAmountIn + srtAmountIn - amount;
        navTimestamp = block.timestamp;
        jrtNavProjected += jrtAmountIn;
        jrtBaseNav += jrtAmountIn;
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
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
    }

    /// @notice Updates the Net Asset Values after deposits or withdrawals
    function updateBalanceFlow(
        uint256 jrtAssetsIn,
        uint256 jrtAssetsOut,
        uint256 srtAssetsIn,
        uint256 srtAssetsOut
    ) external onlyCDO {
        _accrueAssetTime();
        if (valuationPrice < 1e18 && srtAssetsOut > 0) {
            (jrtAssetsOut, srtAssetsOut) = AccountingLib.splitValuatedNavOut(
                jrtBaseNav,
                srtBaseNav,
                ONE_ASSET,
                valuationPrice,
                jrtAssetsOut,
                srtAssetsOut
            );
        }
        jrtBaseNav = jrtBaseNav + jrtAssetsIn - jrtAssetsOut;
        jrtNavProjected = jrtNavProjected + jrtAssetsIn - jrtAssetsOut;
        srtBaseNav = srtBaseNav + srtAssetsIn - srtAssetsOut;
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
        _accrueAssetTime();
        uint256 retentionBps = isJrt ? feeJrtRetentionBps : feeSrtRetentionBps;
        uint256 amountToReserve = (amount * (1e18 - retentionBps)) / 1e18;
        reserveNav += amountToReserve;
        if (isJrt) {
            jrtBaseNav -= amountToReserve;
            jrtNavProjected -= amountToReserve;
        } else {
            srtBaseNav -= amountToReserve;
        }
        emit FeeAccrued(isJrt, amountToReserve, amount - amountToReserve);
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
        uint256 navT1
    )
        public
        view
        returns (
            uint256 jrtNavT1Projected,
            uint256 jrtNavT1Real,
            uint256 srtNavT1,
            uint256 reserveNavT1
        )
    {
        if (jrtNavT0Projected == 0 && srtNavT0 == 0 && navT1 > 0) {
            return (0, 0, 0, navT1);
        }

        if (navT0 == navT1) {
            // No realized gain yet; process using the projection
            return
                calculateNAVSplitProjected(
                    navT0,
                    jrtNavT0Projected,
                    jrtNavT0Real,
                    srtNavT0,
                    reserveNavT0
                );
        }

        // Reconciliation: realized PnL detected (navT0 != navT1)
        return
            calculateNAVSplitReconciliation(
                navT0,
                jrtNavT0Projected,
                jrtNavT0Real,
                srtNavT0,
                reserveNavT0,
                navT1
            );
    }

    /// @notice Projection during the epoch — uses index-based aprSrt for smooth NAV evolution
    /// @dev Same approach as DiscreteAccounting, but also conceptually accumulates srtPnLProjected
    function calculateNAVSplitProjected(
        uint256 navT0,
        uint256 jrtNavT0Projected,
        uint256 jrtNavT0Real,
        uint256 srtNavT0,
        uint256 reserveNavT0
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

        uint256 navTargetIndexT1 = getNavTargetIndexT1();
        int256 gain_dT = calculateGain(navT0, navTargetIndexT1, navTargetIndex);

        if (gain_dT < 0) {
            uint256 loss = uint256(-gain_dT);

            uint256 jrtLoss = Math.min(
                loss,
                Math.saturatingSub(jrtNavT0Projected, ONE_ASSET)
            );

            loss -= jrtLoss;
            uint256 reserveLoss = Math.min(reserveNavT0, loss);

            loss -= reserveLoss;
            uint256 srtLoss = Math.min(srtNavT0, loss);
            require(srtLoss == loss, "Loss>navT0");

            jrtNavT1Projected = jrtNavT0Projected - jrtLoss;
            jrtNavT1Real = Math.min(jrtNavT1Projected, jrtNavT0Real);

            srtNavT1 = srtNavT0 - srtLoss;
            reserveNavT1 = reserveNavT0 - reserveLoss;

            return (jrtNavT1Projected, jrtNavT1Real, srtNavT1, reserveNavT1);
        }

        uint256 gain_dTAbs = uint256(gain_dT);

        // Decrease Projected Gain by expected performance fee
        if (reserveBps > 0) {
            uint256 reserve_dT = (gain_dTAbs * reserveBps) / PERCENTAGE_100;
            gain_dTAbs -= reserve_dT;
        }

        // Allocate the full gain to Juniors first
        jrtNavT1Projected = jrtNavT0Projected + gain_dTAbs;

        // Calculate Srt projected gain
        uint256 srtTargetIndexT1 = getSrtTargetIndexT1();
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
            Math.saturatingSub(jrtNavT1Projected, ONE_ASSET)
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
        uint256 navT1
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

        // Handle loss: JRT absorbs first, then Reserve, then SRT
        if (pnl < 0) {
            uint256 loss = uint256(-pnl);

            uint256 jrtLoss = Math.min(jrtNavT0Real, loss);
            loss -= jrtLoss;
            uint256 reserveLoss = Math.min(reserveNavT0, loss);
            loss -= reserveLoss;
            uint256 srtLoss = Math.min(srtNavT0, loss);
            require(srtLoss == loss, "Loss>navT0");

            jrtNavT0Real -= jrtLoss;
            jrtNavT0Projected = jrtNavT0Projected > jrtLoss
                ? jrtNavT0Projected - jrtLoss
                : 0;
            srtNavT0 -= srtLoss;
            reserveNavT0 -= reserveLoss;
            pnl = 0;
        }

        uint256 pnlAbs = uint256(pnl);

        // Reserve allocation
        uint256 reserve_dT = 0;
        if (pnlAbs > 0 && reserveBps > 0) {
            reserve_dT = (pnlAbs * reserveBps) / PERCENTAGE_100;
            pnlAbs -= reserve_dT;
        }
        reserveNavT1 = reserveNavT0 + reserve_dT;

        // DYS-based Senior PnL allocation
        int256 srtPnLRealized;
        if (navTime > 0 && pnlAbs > 0) {
            // Risk premium: srtFactor = 1 - riskPremium
            UD60x18 riskPremium = calculateRiskPremium();
            uint256 srtFactor = 1e18 - Math.min(riskPremium.unwrap(), PERCENTAGE_100);

            // srtPnL = totalUnderlyingProfit * srtFactor * srtNavTime / navTime
            srtPnLRealized = int256(
                ((((pnlAbs + reserve_dT) * srtFactor) / 1e18) * srtNavTime) / navTime
            );
        } else {
            srtPnLRealized = 0;
        }

        // Cap Senior PnL: cannot exceed total post-reserve PnL
        if (srtPnLRealized > int256(pnlAbs)) {
            srtPnLRealized = int256(pnlAbs);
        }

        // True-up: remove projected, add realized
        // srtNavT0 includes srtPnLProjected added during the epoch; undo it and apply realized.
        // When we subtract srtPnLProjected from SRT, that amount returns to JRT (who funded it).
        if (srtPnLRealized >= 0) {
            // Positive or zero realized PnL
            uint256 srtPnLRealizedAbs = uint256(srtPnLRealized);

            // Benchmark mode: Senior gets whichever is larger — projected or realized.
            // This prevents Senior NAV from dipping at reconciliation when the strategy
            // underperforms the benchmark, while still allowing upside when it outperforms.
            // Only applies when pnlAbs > 0 (positive return); in loss scenarios the
            // projection is unwound normally so Senior doesn't retain phantom gains.
            if (useBenchmarkProjection && pnlAbs > 0 && srtPnLProjected > srtPnLRealizedAbs) {
                srtPnLRealizedAbs = srtPnLProjected;
            }

            // Cannot take from Junior more than available (keep ONE_ASSET minimum)
            uint256 jrtAvailable = Math.saturatingSub(
                jrtNavT0Real + srtPnLProjected + pnlAbs,
                ONE_ASSET
            );
            srtPnLRealizedAbs = Math.min(srtPnLRealizedAbs, jrtAvailable);

            // Senior: undo projection, apply realized
            srtNavT1 = srtNavT0 - srtPnLProjected + srtPnLRealizedAbs;

            // Junior: gets back projected amount, plus remaining PnL
            jrtNavT1Real =
                jrtNavT0Real +
                srtPnLProjected +
                pnlAbs -
                srtPnLRealizedAbs;
        } else {
            // Negative realized PnL (floor kicked in)
            uint256 srtLoss = uint256(-srtPnLRealized);
            srtLoss = Math.min(srtLoss, srtNavT0);

            srtNavT1 = srtNavT0 - srtPnLProjected - srtLoss;
            jrtNavT1Real = jrtNavT0Real + srtPnLProjected + pnlAbs + srtLoss;
        }
        jrtNavT1Projected = jrtNavT1Real;

        // Apply rolling 24h Senior NAV floor
        uint256 srtNavFloor = _computeSrtNavFloor();
        if (srtNavFloor > 0 && srtNavT1 < srtNavFloor) {
            uint256 floorDelta = srtNavFloor - srtNavT1;
            // Cap: cannot take more from JRT than available (preserve navT1 invariant)
            floorDelta = Math.min(floorDelta, jrtNavT1Real);
            srtNavT1 += floorDelta;
            jrtNavT1Real -= floorDelta;
            jrtNavT1Projected = jrtNavT1Real;
        }

        if (navT1 != (jrtNavT1Real + srtNavT1 + reserveNavT1)) {
            revert InvalidNavSplit(navT1, jrtNavT1Real, srtNavT1, reserveNavT1);
        }

        return (jrtNavT1Projected, jrtNavT1Real, srtNavT1, reserveNavT1);
    }

    /// @notice Computes the Senior NAV floor based on the rolling 24h window
    /// @dev Returns 0 if floor is disabled or not yet initialized
    function _computeSrtNavFloor() internal view returns (uint256) {
        if (floorRate == 0 || windowStartSrtNav == 0) return 0;

        uint256 allowedLoss;
        if (block.timestamp >= windowEnd && windowEnd > 0) {
            // Window has expired — extend allowed loss for inactivity
            uint256 dT = block.timestamp - windowEnd;
            allowedLoss =
                (windowStartSrtNav * floorRate * (1 days + dT)) /
                (1 days * 1e18);
        } else {
            // Within the current window
            allowedLoss = (windowStartSrtNav * floorRate) / 1e18;
        }

        int256 floor = int256(windowStartSrtNav) +
            windowNetFlows -
            int256(allowedLoss);
        return floor > 0 ? uint256(floor) : 0;
    }

    /*****************************************************************************
     *                  Internal Accounting Logic                                 *
     *****************************************************************************/

    function updateAccountingInner(uint256 navT1) internal {
        _accrueAssetTime();

        bool isReconciliation = (nav != navT1) && nav > 0;

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
                navT1
            );

        if (isReconciliation) {
            // Track projected PnL increment for the next epoch
            // The calculateNAVSplitProjected during the epoch accumulated srtPnLProjected
            // At reconciliation, the true-up was already applied, so reset
            srtPnLProjected = 0;
            srtNavTime = 0;
            jrtNavTime = 0;
            navTime = 0;
            epochStart = block.timestamp;

            // Floor window rollover
            if (block.timestamp >= windowEnd) {
                windowStartSrtNav = srtNavT1;
                windowNetFlows = 0;
                windowEnd = block.timestamp + 1 days;
            }
        } else if (nav > 0) {
            // During epoch (projection): track the projected SRT gain
            uint256 srtGain = srtNavT1 > srtBaseNav ? srtNavT1 - srtBaseNav : 0;
            srtPnLProjected += srtGain;
        }

        updateIndex();
        if (useNavAtReconciliation && navT1 != nav) lastReconciliation = block.timestamp;
        nav = navT1;
        navTimestamp = block.timestamp;
        lastAccrual = block.timestamp;
        srtBaseNav = srtNavT1;
        jrtNavProjected = jrtNavT1Projected;
        jrtBaseNav = jrtNavT1Real;
        reserveNav = reserveNavT1;
    }

    /*****************************************************************************
     *                  Index & APR Calculation                                   *
     *****************************************************************************/

    function getSrtTargetIndexT1() internal view returns (uint256) {
        return
            calculateTargetIndex(
                srtTargetIndex,
                indexTimestamp,
                block.timestamp,
                aprSrt
            );
    }

    function getNavTargetIndexT1() internal view returns (uint256) {
        return
            calculateTargetIndex(
                navTargetIndex,
                indexTimestamp,
                block.timestamp,
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
        UD60x18 tvlRatio = UD60x18.wrap(
            srtBaseNav == 0 ? 0 : ((srtBaseNav * 1e18) / (srtBaseNav + jrtNavProjected))
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
        srtTargetIndex = getSrtTargetIndexT1();
        navTargetIndex = getNavTargetIndexT1();
        indexTimestamp = block.timestamp;
    }
    function updateAprSrt(UD60x18 aprTarget_, UD60x18 aprBase_) internal {
        if (useBenchmarkProjection) {
            // Benchmark mode: Senior projects at the benchmark APR only.
            // The risk-adjusted upside (if any) is allocated at reconciliation.
            aprSrt = aprTarget_;
        } else {
            // Default mode: Senior projects at the higher of benchmark or risk-adjusted rate.
            UD60x18 risk = calculateRiskPremium();
            UD60x18 aprSrt1 = mul(aprBase_, UD60x18.wrap(1e18) - risk);
            aprSrt = UD60x18Ext.max(aprTarget_, aprSrt1);
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
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        (bool modified, UD60x18 aprTarget_, UD60x18 aprBase_) = fetchAprs();
        if (modified) {
            emit AprDataChangedViaPush(aprTarget_, aprBase_);
        } else {
            updateAprSrt(aprTarget_, aprBase_);
        }
    }

    function setRiskParameters(
        UD60x18 riskX_,
        UD60x18 riskY_,
        UD60x18 riskK_
    ) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
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

    function setAprPairFeed(IAprPairFeed aprPairFeed_) external onlyOwner {
        require(aprPairFeed_.decimals() == APR_FEED_DECIMALS, "InvalidFeed");
        aprPairFeed = aprPairFeed_;
        emit AprPairFeedChanged(address(aprPairFeed_));
    }

    function setFloorRate(uint256 rate) external onlyOwner {
        require(rate <= 0.01e18, "FloorRateTooHigh"); // max 1%/day
        floorRate = rate;
        emit FloorRateChanged(rate);
    }


    function setReserveBps(uint256 bps) external onlyOwner {
        require(
            bps <= RESERVE_BPS_MAX && bps != reserveBps,
            "InvalidNewReserve"
        );
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
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
        valuationPrice = price;
        valuationUpdatedAt = uint64(block.timestamp);
        if (valuationLossEntered) {
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

    function calcEffectiveNav (uint256 jrtFact, uint256 srtFact) internal view returns (uint256 jrtEffective, uint256 srtEffective) {
        if (valuationPrice == 1e18) {
            return (jrtFact, srtFact);
        }
        uint256 extraNeeded = srtFact * (1e18 - valuationPrice) / valuationPrice;
        uint256 extraTaken = Math.min(
            Math.saturatingSub(jrtFact, ONE_ASSET),
            extraNeeded
        );
        return (jrtFact - extraTaken, srtFact + extraTaken);
    }
}
