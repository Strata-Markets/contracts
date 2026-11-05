// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UD60x18} from "@prb/math/src/ud60x18/Math.sol";
import {IAccounting} from "./interfaces/IAccounting.sol";
import {IStrataCDO} from "./interfaces/IStrataCDO.sol";
import {IAprPairFeed} from "./interfaces/IAprPairFeed.sol";
import {AccountingStorage} from "./accounting/AccountingStorage.sol";
import {AccountingSetters} from "./accounting/AccountingSetters.sol";
import {AccountingOperations} from "./accounting/AccountingOperations.sol";
import {UD60x18Ext} from "./utils/UD60x18Ext.sol";
import {AccountingLib} from "./utils/AccountingLib.sol";
import {IRiskPremiumModel} from "./accounting/premium/IRiskPremiumModel.sol";
import {IInsurancePool} from "./symbiotic/interfaces/IInsurancePool.sol";

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
contract DYSAccounting is AccountingStorage, AccountingOperations, IAccounting {
    uint256 constant SECONDS_PER_YEAR = 31_536_000;

    int64 private constant APR_FEED_BOUNDARY_MAX = 2e12; // 200%
    int64 private constant APR_FEED_BOUNDARY_MIN = 0;
    uint256 private constant APR_FEED_DECIMALS = 12;
    uint256 constant PERCENTAGE_100 = 1e18;
    uint256 constant UNDERWRITER_FEE_BPS_MAX = 0.2e18;

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

    /// @notice Initializers and setters, executed via delegatecall on this contract's storage.
    address public immutable SETTERS;

    error InvalidNavSplit(
        uint256 navT1,
        uint256 jrtAssets,
        uint256 srtAssets,
        uint256 reserveAssets,
        uint256 underwriterFeeAssets
    );
    error ReserveTooLow(uint256 reserveNav, uint256 requestedNav);
    error UnderwriterFeeTooLow(uint256 underwriterFeeNav, uint256 requestedNav);

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
        // Underwriter fee and Symbiotic claim at the split boundary.
        uint256 underwriterFeeNav;
        uint256 insuranceAmount;
    }

    event AprPairFeedChanged(address aprPairFeed);
    event AprDataChangedViaPush(UD60x18 aprTarget, UD60x18 aprBase);
    event ReservePercentageChanged(uint256 reserveBps);
    event UnderwriterFeeReduced(uint256 amount);
    event InsuranceClaimed(uint256 amount, uint256 insuranceAmount);
    event RiskModelChanged(address riskPremiumModel);
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
        bool useConservativePrice_
    ) {
        ONE_ASSET = 10 ** navDecimals;
        useBenchmarkProjection = useBenchmarkProjection_;
        useNavAtReconciliation = useNavAtReconciliation_;
        useRatesForReconciliation = useRatesForReconciliation_;
        useJuniorCoversPaidSrtProjection = useJuniorCoversPaidSrtProjection_;
        useConservativePrice = useConservativePrice_;

        SETTERS = address(new AccountingSetters(useNavAtReconciliation_, useRatesForReconciliation_));
    }

    /*****************************************************************************
     *                  Setters module (AccountingSetters)                        *
     *****************************************************************************/

    /// @dev See AccountingSetters.initialize
    function initialize(address, address, IStrataCDO, IAprPairFeed) public virtual { _delegateToSetters(); }
    /// @dev See AccountingSetters.initializeV2
    function initializeV2() external { _delegateToSetters(); }
    /// @dev See AccountingSetters.initializeV3
    function initializeV3() external { _delegateToSetters(); }
    /// @dev See AccountingSetters.setRiskModel
    function setRiskModel(IRiskPremiumModel) external { _delegateToSetters(); }
    /// @dev See AccountingSetters.setAprPairFeed
    function setAprPairFeed(IAprPairFeed) external { _delegateToSetters(); }
    /// @dev See AccountingSetters.setFloorRate
    function setFloorRate(uint256) external { _delegateToSetters(); }
    /// @dev See AccountingSetters.setReserveBps
    function setReserveBps(uint256) external { _delegateToSetters(); }
    /// @dev See AccountingSetters.setFeeRetentionBps
    function setFeeRetentionBps(uint256, uint256) external { _delegateToSetters(); }
    /// @dev See AccountingSetters.setMinimumJrtSrtRatio
    function setMinimumJrtSrtRatio(uint256) external { _delegateToSetters(); }
    /// @dev See AccountingSetters.setMinimumJrtSrtRatioBuffer
    function setMinimumJrtSrtRatioBuffer(uint256) external { _delegateToSetters(); }
    /// @dev See AccountingSetters.setValuationGracePeriod
    function setValuationGracePeriod(uint64) external { _delegateToSetters(); }

    /// @notice Runs accounting math for the setters module; callable only by this contract.
    /// @dev Under delegatecall the module's address(this) is the proxy, so its call lands here.
    function selfCall(uint256 op) external {
        if (msg.sender != address(this)) {
            revert InvalidCaller(msg.sender);
        }
        if (op == OP_CHECKPOINT) {
            updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
            return;
        }
        if (op == OP_UPDATE_APR_SRT) {
            updateAprSrt(aprTarget, aprBase);
            return;
        }
        if (op == OP_SYNC_APRS) {
            syncAprs();
            return;
        }
        if (op == OP_RESET_FLOOR_WINDOW) {
            // Anchor settled Senior NAV, retaining valuation credit but excluding unpaid projection.
            uint256 liveProjection = useConservativePrice
                ? uint256(srtPnLProjected)
                : Math.saturatingSub(uint256(srtPnLProjected), srtPaidProjected);
            windowStartSrtNav = Math.saturatingSub(srtBaseNav, liveProjection);
            return;
        }
        revert("Unknown");
    }

    /// @dev Forwards the current call to the setters module and bubbles up its revert data.
    function _delegateToSetters() private {
        (bool ok, bytes memory ret) = SETTERS.delegatecall(msg.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /*****************************************************************************
     *                  DYS Asset-Time Tracking                                   *
     *****************************************************************************/

    /// @notice Accrues asset-time for all tranches. MUST be called before any state change.
    function _accrueAssetTime() internal {
        TNavSplitState memory state = _currentNavSplitState();
        _accrueAssetTime(state);
    }

    /// @notice Accrues asset-time for all tranches. MUST be called before any state change.
    function _accrueAssetTime(TNavSplitState memory state) internal {
        if (block.timestamp == state.lastAccrual) return;

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
            state
        );

        srtNavTime = state.srtNavTime;
        navTime = state.navTime;
        navTimeNet = state.navTimeNet;
        srtProjectedPnLTime = state.srtProjectedPnLTime;
        state.lastAccrual = block.timestamp;
        lastAccrual = block.timestamp;
    }

    function _currentNavSplitState() internal view returns (TNavSplitState memory state) {
        state.srtNavTime = srtNavTime;
        state.navTime = navTime;
        state.navTimeNet = navTimeNet;
        state.srtProjectedPnLTime = srtProjectedPnLTime;
        state.lastAccrual = lastAccrual;
        state.srtPnLProjected = uint256(srtPnLProjected);
        if (!useConservativePrice) {
            state.srtPaidProjected = srtPaidProjected;
        }
        state.srtPnLBenchmark = srtPnLBenchmark;
        state.feeWatermarkNav = feeWatermarkNav;
        state.underwriterFeeNav = underwriterFeeNav;
        state.insuranceAmount = insuranceAmount;
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
        TNavSplitState memory state
    )
        internal
        view
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

        uint256 dt = block.timestamp - state.lastAccrual;
        if (dt == 0) return (srtNavTime_, navTime_, navTimeNet_, srtProjectedPnLTime_);

        uint256 systemAssets = srtNavT0 + jrtNavT0Projected + reserveNavT0;

        // Insurance backs Senior outside the strategy and does not participate in strategy PnL.
        srtNavTime_ += Math.saturatingSub(srtNavT0, state.insuranceAmount) * dt;
        navTime_ += systemAssets * dt;
        navTimeNet_ += navT0 * dt;
        srtProjectedPnLTime_ += Math.saturatingSub(state.srtPnLProjected, state.srtPaidProjected) * dt;
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
        TNavSplitState memory state = _currentNavSplitState();
        uint256 jrtNavT1Real;
        (
            jrtNavT1Projected,
            jrtNavT1Real,
            srtNavT1,
            reserveNavT1,
            ,
        ) = calculateNAVSplit(
                nav,
                jrtNavProjected,
                jrtBaseNav,
                srtBaseNav,
                reserveNav,
                navT1,
                state
            );
        (jrtNavT1Projected, srtNavT1) = _effectiveLiveNav(jrtNavT1Projected, jrtNavT1Real, srtNavT1);
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
        TNavSplitState memory state = _currentNavSplitState();
        uint256 jrtNavT1Real;
        (
            jrtNavT1Projected,
            jrtNavT1Real,
            srtNavT1,
            reserveNavT1,
            ,
        ) = calculateNAVSplit(
                nav,
                jrtNavProjected,
                jrtBaseNav,
                srtBaseNav,
                reserveNav,
                navT1,
                state
            );
        (jrtNavT1Projected, srtNavT1) = _effectiveLiveNav(jrtNavT1Projected, jrtNavT1Real, srtNavT1);
        return (jrtNavT1Projected, srtNavT1, reserveNavT1);
    }

    /// @notice Returns the updated settled total assets for each tranche and the reserve
    function totalAssetsSettled()
        public
        view
        returns (
            uint256 jrtNavT1Real,
            uint256 srtNavT1,
            uint256 reserveNavT1
        )
    {
        uint256 navT1 = cdo.totalStrategyAssets(nav, _navAnchor());
        bool isReconciliation = _shouldReconcile(nav, navT1);
        TNavSplitState memory state = _currentNavSplitState();
        (
            ,
            jrtNavT1Real,
            srtNavT1,
            reserveNavT1,
            ,
        ) = calculateNAVSplit(
                nav,
                jrtNavProjected,
                jrtBaseNav,
                srtBaseNav,
                reserveNav,
                navT1,
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
            uint256(srtPnLProjected),
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
        uint256 navT1 = cdo.totalStrategyAssets(nav, _navAnchor());
        bool isReconciliation = _shouldReconcile(nav, navT1);
        uint256 reserveNavT1;
        uint256 srtNavT1;
        TNavSplitState memory state = _currentNavSplitState();
        (
            jrtNavLive,
            jrtNavSettled,
            srtNavT1,
            reserveNavT1,
            ,
        ) = calculateNAVSplit(
                nav,
                jrtNavProjected,
                jrtBaseNav,
                srtBaseNav,
                reserveNav,
                navT1,
                state
            );

        uint256 juniorReal = jrtNavSettled;
        if (isReconciliation) {
            // Reconciliation already replaces projected NAV with realized NAV.
            (jrtNavSettled, srtNavSettled) = calcEffectiveNav(jrtNavLive, srtNavT1);
        } else {
            (uint256 jrtNet, uint256 srtNet) = AccountingLib.undoProjection(
                srtNavT1,
                srtBaseNav,
                uint256(srtPnLProjected),
                srtPaidProjected,
                jrtNavSettled
            );
            (jrtNavSettled, srtNavSettled) = calcEffectiveNav(jrtNet, srtNet);
        }

        (jrtNavLive, srtNavLive) = _effectiveLiveNav(jrtNavLive, juniorReal, srtNavT1);
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
        (, , uint256 reserveNavT1) = totalAssets(
            cdo.totalStrategyAssets(nav, _navAnchor())
        );
        return reserveNavT1;
    }

    /*****************************************************************************
     *                  State-Mutating Methods (called by CDO)                    *
     *****************************************************************************/

    /// @notice Returns the current accrued underwriter fee value
    function totalUnderwriterFeeNav () external view returns (uint256 underwriterFeeNavT1) {
        TNavSplitState memory state = _currentNavSplitState();
        (
            ,
            ,
            ,
            ,
            underwriterFeeNavT1,
        ) = calculateNAVSplit(
            nav,
            jrtNavProjected,
            jrtBaseNav,
            srtBaseNav,
            reserveNav,
            cdo.totalStrategyAssets(nav, _navAnchor()),
            state
        );
    }

    /// @notice Reduces accrued underwriter fees and settled NAV by the amount paid out.
    /// @dev The CDO withdraws the corresponding tokens to its configured underwriter fee receiver.
    /// @param amount Fee payout in base-asset units.
    function reduceUnderwriterFee (uint256 amount) external onlyCDO {
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        if (amount > underwriterFeeNav) {
            revert UnderwriterFeeTooLow(underwriterFeeNav, amount);
        }
        underwriterFeeNav -= amount;
        nav -= amount;
        adjustFeeWatermark(0, amount);
        emit UnderwriterFeeReduced(amount);
    }


    /// @notice Sets the share of raw Senior risk premium used for the underwriter fee rate
    /// @dev Only callable by the CDO, which relays the rate from the Symbiotic insurance middleware
    function setUnderwriterFeeBps (uint256 bps) external onlyCDO {
        require(bps <= UNDERWRITER_FEE_BPS_MAX && bps != underwriterFeeBps, "InvalidNewUnderwriterFee");
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        underwriterFeeBps = bps;
    }

    /// @notice Sets the Symbiotic insurance pool queried for coverage.
    function setInsurancePool (IInsurancePool pool_) external onlyCDO {
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        insurancePool = pool_;
    }

    /// @dev Queries the insurance pool for how much of `loss` it can cover. View; returns 0 when unset.
    function _requestInsurance (uint256 loss) internal view returns (uint256) {
        if (loss == 0 || address(insurancePool) == address(0)) {
            return 0;
        }
        return insurancePool.request(address(cdo), loss);
    }

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
        (uint256 jrtNavEffective, uint256 srtNavEffective) = calcEffectiveNav(
            valuationPrice < 1e18 ? Math.min(jrtBaseNav, jrtNavProjected) : jrtBaseNav, srtBaseNav
        );
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
        (uint256 jrtNavEffective, uint256 srtNavEffective) = calcEffectiveNav(
            valuationPrice < 1e18 ? Math.min(jrtBaseNav, jrtNavProjected) : jrtBaseNav, srtBaseNav
        );
        uint256 maxSrt = (jrtNavEffective * 1e18) / minimumJrtSrtRatioBuffer;
        return Math.saturatingSub(maxSrt, srtNavEffective);
    }

    /// @notice Updates the accounting by fetching the current total assets from the strategy
    function updateAccounting() external onlyCDO {
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
    }

    /// @notice Writes down an unfunded realized-loss claim against accrued fees, then Senior principal.
    /// @dev CDO checkpoints first and supplies the vault funding valued in base assets.
    ///      The operator must finalize available slash proceeds and confirm that further funding is unavailable.
    ///      Fees absorb the gap first; the Senior loss limit excludes fees and valuation-credit unwind.
    ///      The whole call reverts if the remaining gap cannot be resolved within that limit.
    /// @param fundedBase Available vault funding, in base-asset units at the current valuation price.
    /// @param maxPrincipalLoss Maximum principal loss the operator accepts, excluding valuation-credit unwind.
    /// @return amount Principal loss recognized; zero if no principal loss is needed.
    function writeDownInsuranceClaim(uint256 fundedBase, uint256 maxPrincipalLoss) external onlyCDO returns (uint256 amount) {
        if (fundedBase >= insuranceAmount) {
            return 0;
        }
        // Release excess valuation credit before charging either fees or Senior principal.
        if (valuationPrice < 1e18) {
            _resyncInsuranceFundNav(valuationPrice);
        }
        // Only the realized-loss claim is eligible; accrued fees absorb its funding gap first.
        uint256 feeLoss = Math.min(underwriterFeeNav, Math.min(
            Math.saturatingSub(insuranceAmount, fundedBase),
            Math.saturatingSub(insuranceAmount, srtInsuranceFundNav)
        ));
        if (feeLoss > 0) {
            underwriterFeeNav -= feeLoss;
            insuranceAmount -= feeLoss;
            emit UnderwriterFeeWrittenDown(feeLoss);
        }
        uint256 seniorAvailable = Math.saturatingSub(srtBaseNav, Math.saturatingSub(uint256(srtPnLProjected), useConservativePrice ? 0 : srtPaidProjected));
        amount = AccountingLib.insuranceWriteDown(AccountingLib.InsuranceWriteDownState({
            claim: insuranceAmount,
            seniorNav: srtBaseNav,
            seniorAvailable: seniorAvailable,
            valuationCredit: srtInsuranceFundNav,
            fundedGross: srtFundedGrossNav,
            selfFund: srtFundNav,
            juniorAvailable: Math.saturatingSub(jrtBaseNav, ONE_ASSET),
            price: valuationPrice
        }), fundedBase, maxPrincipalLoss);
        if (valuationPrice < 1e18) {
            _scaleSrtFund(seniorAvailable, seniorAvailable - amount);
        }
        insuranceAmount -= amount;
        srtBaseNav -= amount;
        // The loss is accepted explicitly; the rolling floor must not restore it.
        windowNetFlows -= int256(amount);
        // Reduced principal can need less valuation credit; release it before checking funding.
        if (valuationPrice < 1e18) {
            _resyncInsuranceFundNav(valuationPrice);
        }
        require(insuranceAmount <= fundedBase, "InsuranceShortfallUnresolved");
        _syncInsuranceClaim();
        updateAprSrt(aprTarget, aprBase);
        emit InsuranceClaimWrittenDown(amount);
    }

    /// @notice Updates the Net Asset Values after deposits or withdrawals
    function updateBalanceFlow(
        uint256 jrtAssetsIn,
        uint256 jrtAssetsOut,
        uint256 srtAssetsIn,
        uint256 srtAssetsOut
    ) external onlyCDO returns (uint256 insuranceBaseOut) {
        _accrueAssetTime();
        if (useConservativePrice && jrtAssetsOut > 0) {
            // Use pre-flow redemption NAVs; Junior backing paid on a Senior exit is not a Junior redemption.
            uint256 jrtSettledNav = jrtBaseNav + uint256(srtPnLProjected);
            uint256 srtSettledNav = Math.saturatingSub(srtBaseNav, uint256(srtPnLProjected));
            uint256 jrtLiveNav = jrtNavProjected;
            if (valuationPrice < 1e18) {
                (jrtSettledNav, ) = calcEffectiveNav(jrtSettledNav, srtSettledNav);
                (jrtLiveNav, ) = calcEffectiveNav(jrtLiveNav, srtBaseNav);
            }
            if (jrtLiveNav > jrtSettledNav && jrtSettledNav > 0) {
                uint256 jrtProjection = jrtLiveNav - jrtSettledNav;
                uint256 unpaidProjection = Math.mulDiv(jrtAssetsOut, jrtProjection, jrtSettledNav);
                jrtNavProjected -= Math.min(unpaidProjection, jrtProjection);
            }
        }
        _trackSrtProjectionIn(srtAssetsIn);
        uint256 insuranceBaseOut_;
        bool valuationWithdrawal = valuationPrice < 1e18 && srtAssetsOut > 0;
        if (valuationWithdrawal) {
            uint256 juniorCoverageOut;
            uint256 seniorStrategyOut;
            (juniorCoverageOut, seniorStrategyOut, insuranceBaseOut_) = _splitValuationWithdrawal(srtAssetsOut);
            jrtAssetsOut += juniorCoverageOut;
            // Senior base NAV includes both strategy assets and insurance credit.
            srtAssetsOut = seniorStrategyOut + insuranceBaseOut_;
        }
        // New deposits must not change the funding attributed to an existing Senior withdrawal.
        srtFundNav += _trackSrtFundNavIn(srtAssetsIn);

        // Conservative exits forfeit their benchmark entitlement even when no projection is funded.
        // At par, the exit fraction uses net base NAV; valuation exits use effective NAV below.
        if (!valuationWithdrawal && useConservativePrice && useBenchmarkProjection && srtAssetsOut > 0 && srtPnLBenchmark > 0) {
            uint256 srtNetNav = Math.saturatingSub(srtBaseNav, uint256(srtPnLProjected));
            uint256 forfeitedBenchmark = Math.mulDiv(srtAssetsOut, srtPnLBenchmark, srtNetNav);
            srtPnLBenchmark -= Math.min(forfeitedBenchmark, srtPnLBenchmark);
        }

        if (!valuationWithdrawal && srtAssetsOut > 0 && (srtPnLProjected > 0 || (!useConservativePrice && srtBoughtProjection.net > 0))) {
            if (useConservativePrice) {
                // Conservative redemptions pay only net Senior assets
                // Return the unpaid projection to Junior real NAV
                // Historical Senior asset-time remains pooled; realized epoch PnL goes to remaining holders.
                uint256 srtNetNav = Math.saturatingSub(srtBaseNav, uint256(srtPnLProjected));
                uint256 unpaidProjection = Math.mulDiv(
                    srtAssetsOut,
                    uint256(srtPnLProjected),
                    srtNetNav
                );
                unpaidProjection = Math.min(unpaidProjection, uint256(srtPnLProjected));
                srtPnLProjected -= int256(unpaidProjection);
                // srtBaseNav includes Senior projection funded from jrtBaseNav
                srtBaseNav -= unpaidProjection;

                jrtBaseNav += unpaidProjection;
                jrtNavProjected = Math.max(jrtNavProjected, jrtBaseNav);
            } else {
                _trackSrtProjectionOut(Math.mulDiv(srtAssetsOut, _srtFlowProjection(), srtBaseNav));
            }
        }
        // Senior's exit takes its share of the outstanding coverage with it. That slice is paid from
        // the insurance vault rather than the strategy, so srtBaseNav drops by the full outflow while
        // nav drops only by what actually leaves the strategy. Both sides of
        // nav + insuranceAmount == jrt + srt + reserve + underwriter fee then move by srtAssetsOut.
        if (!valuationWithdrawal && insuranceAmount > 0 && srtAssetsOut > 0 && srtBaseNav > 0) {
            // The claim may also back Junior dust; insurance cannot pay more than this exit.
            insuranceBaseOut_ = Math.min(
                Math.min(insuranceAmount, srtAssetsOut),
                Math.mulDiv(srtAssetsOut, insuranceAmount, srtBaseNav)
            );
            srtInsuranceFundNav = Math.saturatingSub(srtInsuranceFundNav, insuranceBaseOut_);
        }
        insuranceAmount -= insuranceBaseOut_;
        if (insuranceBaseOut_ > 0) {
            _syncInsuranceClaim();
        }
        insuranceBaseOut = insuranceBaseOut_;

        jrtBaseNav = jrtBaseNav + jrtAssetsIn - jrtAssetsOut;
        jrtNavProjected = jrtNavProjected + jrtAssetsIn - jrtAssetsOut;
        srtBaseNav = srtBaseNav + srtAssetsIn - srtAssetsOut;
        // Net the vault-paid slice out of the Senior outflow first: only this much actually leaves
        // the strategy, and subtracting the full outflow from nav could underflow on the way.
        uint256 srtAssetsOutFromStrategy = srtAssetsOut - insuranceBaseOut_;
        adjustFeeWatermark(
            jrtAssetsIn + srtAssetsIn,
            jrtAssetsOut + srtAssetsOutFromStrategy
        );
        nav = nav + jrtAssetsIn + srtAssetsIn - jrtAssetsOut - srtAssetsOutFromStrategy;
        windowNetFlows += int256(srtAssetsIn) - int256(srtAssetsOut);
        navTimestamp = block.timestamp;
        (bool modified, UD60x18 aprTarget_, UD60x18 aprBase_) = fetchAprs();
        if (modified == false) {
            updateAprSrt(aprTarget_, aprBase_);
        }
    }

    /// @dev Include purchased projection when pricing flows, but not when undoing unrealized gains.
    ///      This preserves the projection fraction across deposits, including split deposits.
    function _srtFlowProjection() internal view returns (uint256) {
        return useConservativePrice
            ? uint256(srtPnLProjected)
            : Math.saturatingSub(uint256(srtPnLProjected), srtPaidProjected) + uint256(int256(srtBoughtProjection.net));
    }

    function _trackSrtProjectionIn(uint256 assetsIn) internal {
        if (useConservativePrice || assetsIn == 0 || srtBaseNav == 0) return;
        uint256 seniorNav = srtBaseNav;
        if (valuationPrice < 1e18) {
            (, seniorNav) = calcEffectiveNav(jrtBaseNav, seniorNav);
        }
        uint256 bought = Math.mulDiv(assetsIn, _srtFlowProjection(), seniorNav);
        uint256 matched = Math.min(bought, srtPaidProjected);
        srtPaidProjected -= matched;
        srtBoughtProjection.net = AccountingLib.toInt128(int256(srtBoughtProjection.net) + int256(bought - matched));
    }

    function _trackSrtProjectionOut(uint256 projectionOut) internal {
        uint256 matched = Math.min(projectionOut, uint256(int256(srtBoughtProjection.net)));
        srtBoughtProjection.net = AccountingLib.toInt128(int256(srtBoughtProjection.net) - int256(matched));
        require(srtBoughtProjection.net >= 0, "NegativeBoughtProjection");
        srtPaidProjected += projectionOut - matched;
    }

    /// @dev Consume each backing component using the same pre-exit effective Senior NAV.
    ///      Round component payouts down and assign the withdrawal remainder to Senior base NAV.
    function _splitValuationWithdrawal(uint256 assetsOut)
        internal returns (uint256 juniorOut, uint256 seniorStrategyOut, uint256 insuranceOut)
    {
        uint256 liveProjection = _srtFlowProjection();
        uint256 seniorNav = srtBaseNav;
        // Match the Junior backing used to price the exit, capped by settled NAV.
        uint256 juniorNav = Math.min(jrtBaseNav, jrtNavProjected);
        if (useConservativePrice) {
            liveProjection = Math.min(liveProjection, seniorNav);
            seniorNav -= liveProjection;
            juniorNav += liveProjection;
        }
        (, uint256 seniorEffective) = calcEffectiveNav(juniorNav, seniorNav);
        (juniorOut, seniorStrategyOut, insuranceOut) = AccountingLib.splitValuatedNavOut(
            seniorNav, seniorEffective, insuranceAmount, assetsOut
        );
        srtInsuranceFundNav -= Math.mulDiv(assetsOut, srtInsuranceFundNav, seniorEffective);
        srtFundedGrossNav -= Math.mulDiv(assetsOut, srtFundedGrossNav, seniorEffective);
        srtFundNav -= Math.mulDiv(assetsOut, srtFundNav, seniorEffective);

        uint256 projectionOut = Math.mulDiv(assetsOut, liveProjection, seniorEffective);
        if (useConservativePrice) {
            // Use the same pre-exit effective NAV as the projection and coverage payouts.
            if (useBenchmarkProjection && srtPnLBenchmark > 0) {
                uint256 forfeitedBenchmark = Math.mulDiv(assetsOut, srtPnLBenchmark, seniorEffective);
                srtPnLBenchmark -= Math.min(forfeitedBenchmark, srtPnLBenchmark);
            }
            srtPnLProjected -= int256(projectionOut);
            srtBaseNav -= projectionOut;
            jrtBaseNav += projectionOut;
            jrtNavProjected = Math.max(jrtNavProjected, jrtBaseNav);
        } else {
            _trackSrtProjectionOut(projectionOut);
        }
    }

    /// @notice Called by the CDO to account for a fee
    function accrueFee(bool isJrt, uint256 amount) external onlyCDO {
        _accrueAssetTime();
        uint256 retentionBps = isJrt ? feeJrtRetentionBps : feeSrtRetentionBps;
        uint256 amountToReserve = (amount * (1e18 - retentionBps)) / 1e18;
        if (!isJrt && insuranceAmount > 0) {
            // Retain the whole Senior fee while a claim is open: reserve cannot hold insurance backing.
            amountToReserve = 0;
        }
        if (isJrt) {
            jrtBaseNav -= amountToReserve;
            jrtNavProjected -= amountToReserve;
        } else if (amountToReserve > 0) {
            uint256 seniorOut = amountToReserve;
            if (valuationPrice < 1e18) {
                // The fee is priced in effective NAV; consume its backing just like a Senior exit.
                uint256 juniorOut;
                (juniorOut, seniorOut,) = _splitValuationWithdrawal(amountToReserve);
                jrtBaseNav -= juniorOut;
                jrtNavProjected -= juniorOut;
            } else if (useConservativePrice && useBenchmarkProjection && srtPnLBenchmark > 0) {
                // Reserve-bound fees forfeit benchmark on pre-fee net NAV; retained fees keep it.
                uint256 srtNetNav = Math.saturatingSub(srtBaseNav, uint256(srtPnLProjected));
                uint256 forfeitedBenchmark = Math.mulDiv(amountToReserve, srtPnLBenchmark, srtNetNav);
                srtPnLBenchmark -= Math.min(forfeitedBenchmark, srtPnLBenchmark);
            }
            srtBaseNav -= seniorOut;
            windowNetFlows -= int256(seniorOut);
        }
        reserveNav += amountToReserve;
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
        TNavSplitState memory state
    )
        internal
        view
        returns (
            uint256 jrtNavT1Projected,
            uint256 jrtNavT1Real,
            uint256 srtNavT1,
            uint256 reserveNavT1,
            uint256 underwriterFeeNavT1,
            uint256 insuranceAmountT1
        )
    {
        if (jrtNavT0Projected == 0 && srtNavT0 == 0 && navT1 > 0) {
            // Keep the underwriter fee capped to the remaining assets so a wipeout below the accrued underwriter fee
            // cannot underflow; the bucket absorbs the shortfall.
            underwriterFeeNavT1 = Math.min(navT1, state.underwriterFeeNav);
            return (0, 0, 0, navT1 - underwriterFeeNavT1, underwriterFeeNavT1, state.insuranceAmount);
        }

        if (!_shouldReconcile(navT0, navT1)) {
            // No realized gain yet; process using the projection
            (jrtNavT1Projected, jrtNavT1Real, srtNavT1, reserveNavT1) = calculateNAVSplitProjected(
                navT0,
                jrtNavT0Projected,
                jrtNavT0Real,
                srtNavT0,
                reserveNavT0
            );
            return (
                jrtNavT1Projected,
                jrtNavT1Real,
                srtNavT1,
                reserveNavT1,
                state.underwriterFeeNav,
                state.insuranceAmount
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
                navT1,
                state
            );
    }
    /// @notice Projection during the epoch - uses index-based aprSrt for smooth NAV evolution
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
        // Underwriter fee is modeled in projected Senior NAV but is not accrued into underwriterFeeNav.
        // The insurance claim is likewise untouched on the projection (no realized loss to cover).
        if (jrtNavT0Projected == 0 && srtNavT0 == 0) {
            return (0, 0, 0, 0);
        }

        uint256 navTargetIndexT1 = getNavTargetIndexT1();
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
        if (reserveBps > 0) {
            // Estimate prior projected gain without a separate tracker; fees and forfeitures can reduce it.
            uint256 navProjectedT0 = navT0 + Math.saturatingSub(jrtNavT0Projected, jrtNavT0Real);
            if (navProjectedT0 + gain_dTAbs > feeWatermarkNav) {
                uint256 feeableGain = Math.min(
                    gain_dTAbs,
                    navProjectedT0 + gain_dTAbs - feeWatermarkNav
                );
                uint256 reserve_dT = (feeableGain * reserveBps) / PERCENTAGE_100;
                gain_dTAbs -= reserve_dT;
            }
        }

        // Allocate the full gain to Junior first
        jrtNavT1Projected = jrtNavT0Projected + gain_dTAbs;

        // Calculate Srt projected gain
        uint256 srtTargetIndexT1 = getSrtTargetIndexT1();
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
        // Bound the gross debit by both Junior balances; projected NAV also excludes expected fees.
        uint256 srtGainTargetAbs = Math.min(
            uint256(srtGainTarget),
            Math.saturatingSub(Math.min(jrtNavT0Real, jrtNavT1Projected), ONE_ASSET)
        );
        if (srtGainTargetAbs > 0 && valuationPrice < 1e18) {
            // Junior must fund both the gain and its de-peg protection.
            (uint256 jrtEffective,) = calcEffectiveNav(jrtNavT0Real, srtNavT0);
            uint256 maxProtectedGain = Math.mulDiv(Math.saturatingSub(jrtEffective, ONE_ASSET), valuationPrice, 1e18);
            srtGainTargetAbs = Math.min(srtGainTargetAbs, maxProtectedGain);
        }

        uint256 expectedUnderwriterFee = 0;
        if (srtGainTargetAbs > 0 && underwriterFeeBps > 0) {
            uint256 underwriterFeePct = calculateRiskPremium().unwrap() * underwriterFeeBps / PERCENTAGE_100;
            expectedUnderwriterFee = srtGainTargetAbs * underwriterFeePct / PERCENTAGE_100;
        }

        // Projected Junior excludes the expected fee; real Junior funds only the net Senior gain.
        jrtNavT1Projected = jrtNavT1Projected - srtGainTargetAbs;
        jrtNavT1Real = Math.saturatingSub(jrtNavT0Real, Math.saturatingSub(srtGainTargetAbs, expectedUnderwriterFee));

        // Final Srt
        srtNavT1 = srtNavT0 + srtGainTargetAbs - expectedUnderwriterFee;

        // No changes to NAV and reserve on Projection
        reserveNavT1 = reserveNavT0;

        return (jrtNavT1Projected, jrtNavT1Real, srtNavT1, reserveNavT1);
    }
    function _calculateSrtPnLRealized(
        int256 pnl,
        uint256 reserveIncrease,
        uint256 navT0,
        uint256 srtNavT0,
        TNavSplitState memory state
    )
        internal
        view
        returns (int256 srtPnLRealized, uint256 riskPremium_)
    {
        uint256 srtNavTime_ = state.navTime > 0 ? state.srtNavTime : Math.saturatingSub(srtNavT0, state.insuranceAmount);
        uint256 navTime_ = state.navTime > 0 ? state.navTime : navT0;

        // Note: riskPremium is capped at 1e18 (100%) via setRiskModel validation
        riskPremium_ = calculateRiskPremium().unwrap();
        // Risk premium: srtFactor = 1 - riskPremium
        uint256 srtFactor = 1e18 - riskPremium_;

        // Without a starting rate, use proportional allocation until reconciliation seeds the checkpoint.
        if (useRatesForReconciliation && state.strategyRate > 0) {
            // Rate-based formula: senior earns (senior sub-strategy rate growth) * srtNavTime * srtFactor.
            // Used when the senior sub-strategy has a queryable exchange rate (e.g. IsolatedStrategy);
            // isolates senior returns regardless of junior sub-strategy performance.
            uint256 srtRateT1 = cdo.strategy().getRate();
            uint256 epochDt = block.timestamp > state.epochStart ? block.timestamp - state.epochStart : 0;
            bool isPositive = srtRateT1 > state.strategyRate;
            uint256 rateDeltaAbs = isPositive
                ? srtRateT1 - state.strategyRate
                : state.strategyRate - srtRateT1;
            if (epochDt > 0) {
                uint256 srtNavTimeReal = Math.saturatingSub(srtNavTime_, state.srtProjectedPnLTime);
                uint256 navTimeXGrowth = Math.mulDiv(srtNavTimeReal, rateDeltaAbs, state.strategyRate);
                uint256 pnlAbs = Math.mulDiv(navTimeXGrowth, srtFactor, 1e18 * epochDt);
                srtPnLRealized = isPositive
                    ?  int256(pnlAbs)
                    : -int256(pnlAbs);
            }
            // else: sub-strat had no growth this epoch - senior earns nothing (srtPnLRealized stays 0)
        } else {
            // Proportional nav-time formula (single strategy / no rate tracking).
            // srtPnL = totalUnderlyingProfit * srtFactor * srtNavTime / navTime
            uint256 srtNavTimeNet_ = Math.saturatingSub(srtNavTime_, state.srtProjectedPnLTime);
            uint256 navTimeNet_ = state.navTimeNet > 0 ? state.navTimeNet : navT0;

            // An insured wipeout can leave gross NAV-time positive with no strategy NAV-time.
            srtPnLRealized = (navTime_ == 0 || navTimeNet_ == 0)
                ? int256(0)
                : AccountingLib.proportionalPnL(pnl + int256(reserveIncrease), srtFactor, srtNavTimeNet_, navTimeNet_);
        }
    }

    /// @notice Reconciliation at epoch end - DYS-based PnL allocation with true-up
    /// @dev Uses asset-time weighting to allocate realized PnL between tranches
    function calculateNAVSplitReconciliation(
        uint256 navT0,
        uint256 jrtNavT0Projected,
        uint256 jrtNavT0Real,
        uint256 srtNavT0,
        uint256 reserveNavT0,
        uint256 navT1,
        TNavSplitState memory state
    )
        internal
        view
        returns (
            uint256 jrtNavT1Projected,
            uint256 jrtNavT1Real,
            uint256 srtNavT1,
            uint256 reserveNavT1,
            uint256 underwriterFeeNavT1,
            uint256 insuranceAmountT1
        )
    {
        int256 pnl = int256(navT1) - int256(navT0);
        insuranceAmountT1 = state.insuranceAmount;

        // Gains repay only NAV-loss claims; valuation claims unwind with their credit through price updates.
        if (pnl > 0 && insuranceAmountT1 > 0) {
            uint256 realizedClaim = Math.saturatingSub(insuranceAmountT1, srtInsuranceFundNav);
            uint256 unwind = Math.min(uint256(pnl), realizedClaim);
            insuranceAmountT1 -= unwind;
            pnl -= int256(unwind);
        }

        // Reserve allocation
        reserveNavT1 = reserveNavT0;
        if (pnl > 0 && navT1 > feeWatermarkNav && reserveBps > 0) {
            uint256 feeableGain = Math.min(uint256(pnl), navT1 - feeWatermarkNav);
            uint256 reserveIncrease = feeableGain * reserveBps / PERCENTAGE_100;
            pnl -= int256(reserveIncrease);
            reserveNavT1 += reserveIncrease;
        }

        underwriterFeeNavT1 = state.underwriterFeeNav;

        // Accrue the unpersisted interval before unwinding projected Senior NAV.
        (
            state.srtNavTime,
            state.navTime,
            state.navTimeNet,
            state.srtProjectedPnLTime
        ) = _accruedAssetTimeView(
            navT0,
            jrtNavT0Projected,
            srtNavT0,
            reserveNavT0,
            state
        );

        // Include the final interval before unwinding projection; views and settlement use the same entitlement.
        if (useBenchmarkProjection && Math.min(jrtNavT0Real, jrtNavT0Projected) > ONE_ASSET) {
            int256 benchmarkGain = calculateGain(srtNavT0, getBenchmarkIndexT1(), benchmarkIndex);
            if (benchmarkGain > 0) {
                uint256 pendingBenchmark = uint256(benchmarkGain);
                uint256 maxProtectedGain = Math.saturatingSub(Math.min(jrtNavT0Real, jrtNavT0Projected), ONE_ASSET);
                if (valuationPrice < 1e18) {
                    (uint256 jrtEffective,) = calcEffectiveNav(Math.min(jrtNavT0Real, jrtNavT0Projected), srtNavT0);
                    maxProtectedGain = Math.mulDiv(Math.saturatingSub(jrtEffective, ONE_ASSET), valuationPrice, 1e18);
                }
                // Reserve earlier entitlement not already embedded in Senior NAV before adding new benchmark.
                uint256 unprojectedBenchmark = Math.saturatingSub(state.srtPnLBenchmark, state.srtPnLProjected);
                pendingBenchmark = Math.min(pendingBenchmark, Math.saturatingSub(maxProtectedGain, unprojectedBenchmark));
                // If Junior depletes, the waterfall may fund the final interval from reserve or insurance, or reduce the gain.
                state.srtPnLBenchmark += pendingBenchmark;
            }
        }

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

        (int256 srtPnLRealized, uint256 riskPremium_) = _calculateSrtPnLRealized(
            pnl,
            reserveNavT1 - reserveNavT0,
            navT0,
            srtNavT0,
            state
        );

        // Value new realized yield at the current price; preserve prior benchmark entitlement below.
        if (valuationPrice < 1e18 && srtPnLRealized > 0) {
            srtPnLRealized = int256(Math.mulDiv(uint256(srtPnLRealized), valuationPrice, 1e18));
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
        uint256 juniorCover;
        if (useJuniorCoversPaidSrtProjection && projUndo > 0) {
            uint256 paidProjectedUnwound = projUndo == state.srtPnLProjected
                ? state.srtPaidProjected
                // Here, pre-unwind srtNavT0' < srtPnLProjected.
                // Recover pre-unwind srtNavT0' as srtNavT0 + projUndo.
                : Math.saturatingSub(srtNavT0 + projUndo + state.srtPaidProjected, state.srtPnLProjected);

            if (srtPnLRealized < int256(paidProjectedUnwound)) {
                // Only adjust if realized PnL does not already cover it
                if (srtPnLRealized > 0) {
                    juniorCover = paidProjectedUnwound - uint256(srtPnLRealized);
                    srtPnLRealized = int256(paidProjectedUnwound);
                } else {
                    juniorCover = paidProjectedUnwound;
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
            uint256 srtNavFloor = _computeSrtNavFloor(floorRate_);
            if (srtNavFloor > 0 && srtNavT1 < srtNavFloor) {
                uint256 floorDelta = srtNavFloor - srtNavT1;
                srtNavT1 += floorDelta;
                srtPnLRealized += int256(floorDelta);
            }
        }

        // Junior's reimbursement of paid projection restores principal; it is not feeable yield.
        uint256 srtFeeBase = srtPnLRealized > 0
            ? Math.saturatingSub(uint256(srtPnLRealized), juniorCover)
            : 0;
        if (srtFeeBase > 0 && underwriterFeeBps > 0) {
            uint256 underwriterFee_dT =
                srtFeeBase * riskPremium_ * underwriterFeeBps / PERCENTAGE_100 / PERCENTAGE_100;
            srtPnLRealized -= int256(underwriterFee_dT);
            srtNavT1 -= underwriterFee_dT;
            pnl -= int256(underwriterFee_dT);
            underwriterFeeNavT1 += underwriterFee_dT;
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
            // Loss waterfall: Junior -> reserve -> insurance -> accrued underwriter fees -> Senior.
            // This can cancel Senior's benchmark gain if Junior cannot cover it.
            uint256 loss = uint256(-jrtPnLRealized);
            uint256 jrtLoss = Math.min(jrtSafe, loss);
            loss -= jrtLoss;
            uint256 reserveLoss = Math.min(reserveNavT1, loss);
            loss -= reserveLoss;
            // Policy: insurance covers the full remainder after Junior and reserve, including
            // accrued underwriter fees and protected Junior dust, even when no Senior remains.
            uint256 covered = _requestInsurance(loss);
            loss -= covered;

            uint256 feeLoss = Math.min(underwriterFeeNavT1, loss);
            underwriterFeeNavT1 -= feeLoss;
            loss -= feeLoss;

            uint256 srtLoss = Math.min(srtNavT1, loss);
            // The market is considered abandoned if losses would consume the protected dust NAV.
            require(srtLoss == loss, "NavBelowMinimum");

            jrtNavT1Real = jrtNavT0Real - jrtLoss;
            srtNavT1 -= srtLoss;
            reserveNavT1 -= reserveLoss;
            insuranceAmountT1 = insuranceAmountT1 + covered;
        }

        // Invariant: Total new NAV must equal sum of all NAVs
        // Coverage holds a tranche whole against assets not yet injected, hence the added term.
        if (navT1 + insuranceAmountT1 != (jrtNavT1Real + srtNavT1 + reserveNavT1 + underwriterFeeNavT1)) {
            revert InvalidNavSplit(navT1, jrtNavT1Real, srtNavT1, reserveNavT1, underwriterFeeNavT1);
        }

        return (jrtNavT1Real, jrtNavT1Real, srtNavT1, reserveNavT1, underwriterFeeNavT1, insuranceAmountT1);
    }

    /// @notice Computes the Senior NAV floor based on the rolling 24h window
    /// @dev Returns 0 if floor is disabled or not yet initialized
    function _computeSrtNavFloor(uint256 floorRate_) internal view returns (uint256) {
        if (floorRate_ == 0) {
            return 0;
        }
        int256 baseline = int256(windowStartSrtNav) + windowNetFlows;
        if (baseline <= 0) {
            return 0;
        }

        if (block.timestamp > windowEnd) {
            // Window has expired — extend allowed loss for inactivity
            uint256 dT = block.timestamp - windowEnd;
            floorRate_ = floorRate_ * (1 days + dT) / 1 days;
        }

        uint256 minRate = Math.saturatingSub(1e18, floorRate_);
        uint256 srtNavFloor = minRate * uint256(baseline) / 1e18;
        return srtNavFloor;
    }

    /*****************************************************************************
     *                  Internal Accounting Logic                                 *
     *****************************************************************************/

    function updateAccountingInner(uint256 navT1) internal {
        checkpointAccountingInner(navT1);
        // Resize existing valuation credit after NAV changes, then cover any remaining shortfall.
        if (valuationPrice < 1e18) {
            _resyncInsuranceFundNav(valuationPrice);
            _coverValuationLoss(valuationPrice);
        }
    }

    /// @dev Checkpoints PnL and asset-time without resizing valuation coverage.
    ///      Keeping coverage separate lets valuation setters apply the new price first.
    function checkpointAccountingInner(uint256 navT1) internal {
        TNavSplitState memory state = _currentNavSplitState();
        _accrueAssetTime(state);

        bool isReconciliation = _shouldReconcile(nav, navT1);

        (
            uint256 jrtNavT1Projected,
            uint256 jrtNavT1Real,
            uint256 srtNavT1,
            uint256 reserveNavT1,
            uint256 underwriterFeeNavT1,
            uint256 insuranceAmountT1
        ) = calculateNAVSplit(
                nav,
                jrtNavProjected,
                jrtBaseNav,
                srtBaseNav,
                reserveNav,
                navT1,
                state
            );

        // Persist the underwriter fee bucket and insurance claim, and slash any newly booked insurance in the
        // same transaction. Done here so `state` dies early and so underfunded insurance reverts before NAVs
        // are persisted below.
        _persistInsuranceClaim(underwriterFeeNavT1, state.insuranceAmount, insuranceAmountT1);

        if (isReconciliation) {
            if (valuationPrice < 1e18) {
                // Remaining projection is assumed negligible for scaling.
                _scaleSrtFund(srtBaseNav, srtNavT1);
            }
            emit Reconciled(
                epochStart,
                block.timestamp,
                nav,
                navT1,
                jrtNavT1Real,
                srtNavT1,
                reserveNavT1
            );

            // Track projected PnL increment for the next epoch
            // The calculateNAVSplitProjected during the epoch accumulated srtPnLProjected
            // At reconciliation, the true-up was already applied, so reset
            srtPnLProjected = 0;
            srtPnLBenchmark = 0;
            if (!useConservativePrice) {
                srtPaidProjected = 0;
                delete srtBoughtProjection;
            }
            srtNavTime = 0;
            navTime = 0;
            navTimeNet = 0;
            srtProjectedPnLTime = 0;
            epochStart = block.timestamp;

            // Snapshot the senior sub-strategy exchange rate as T0 for the next epoch.
            if (useRatesForReconciliation) {
                uint256 newRate = cdo.strategy().getRate();
                if (newRate > 0) strategyRate = newRate;
            }
            if (useNavAtReconciliation) {
                lastReconciliation = block.timestamp;
            }
            if (navT1 > feeWatermarkNav) {
                feeWatermarkNav = navT1;
            }

            // Floor window rollover
            if (block.timestamp >= windowEnd) {
                windowStartSrtNav = srtNavT1;
                windowNetFlows = 0;
                windowEnd = block.timestamp + 1 days;
            }
        } else if (nav > 0) {
            // During epoch (projection): track the projected SRT gain
            uint256 srtGain = srtNavT1 > srtBaseNav ? srtNavT1 - srtBaseNav : 0;
            srtPnLProjected += int256(srtGain);

            // Accrue only for intervals where Junior stays above the floor; retain earlier entitlement.
            if (useBenchmarkProjection && Math.min(jrtNavT1Real, jrtNavT1Projected) > ONE_ASSET && Math.min(jrtBaseNav, jrtNavProjected) > ONE_ASSET) {
                uint256 benchmarkIndexT1 = getBenchmarkIndexT1();
                int256 srtBenchmarkGain = calculateGain(
                    srtBaseNav, benchmarkIndexT1, benchmarkIndex
                );
                if (srtBenchmarkGain > 0) {
                    uint256 benchmarkGain = uint256(srtBenchmarkGain);
                    uint256 maxProtectedGain = Math.saturatingSub(Math.min(jrtBaseNav, jrtNavProjected), ONE_ASSET);
                    if (valuationPrice < 1e18) {
                        (uint256 jrtEffective,) = calcEffectiveNav(Math.min(jrtBaseNav, jrtNavProjected), srtBaseNav);
                        maxProtectedGain = Math.mulDiv(Math.saturatingSub(jrtEffective, ONE_ASSET), valuationPrice, 1e18);
                    }
                    // Reserve earlier entitlement not already embedded in Senior NAV before adding new benchmark.
                    uint256 unprojectedBenchmark = Math.saturatingSub(srtPnLBenchmark, uint256(srtPnLProjected) - srtGain);
                    benchmarkGain = Math.min(benchmarkGain, Math.saturatingSub(maxProtectedGain, unprojectedBenchmark));
                    srtPnLBenchmark += benchmarkGain;
                }
            }
        }

        updateIndex();
        nav = navT1;
        navTimestamp = block.timestamp;
        lastAccrual = block.timestamp;
        srtBaseNav = srtNavT1;
        jrtNavProjected = jrtNavT1Projected;
        // Require a decrease to the floor or below so an empty market does not suspend fees.
        if (jrtNavT1Real <= ONE_ASSET && jrtNavT1Real < jrtBaseNav) {
            _disablePerformanceFee();
            _disableFeeReserveAccrual();
        }
        jrtBaseNav = jrtNavT1Real;
        reserveNav = reserveNavT1;
    }

    /// @notice Persists the split, securing coverage before storing any insurance claim increase.
    /// @dev Split out of checkpointAccountingInner to mirror MTMAccounting state flow and reduce stack pressure.
    function _persistInsuranceClaim(
        uint256 underwriterFeeNavT1,
        uint256 insuranceAmountT0,
        uint256 insuranceAmountT1
    )
        internal
    {
        underwriterFeeNav = underwriterFeeNavT1;
        if (insuranceAmountT1 == insuranceAmountT0) {
            return;
        }

        if (insuranceAmountT1 < insuranceAmountT0) {
            insuranceAmount = insuranceAmountT1;
            _syncInsuranceClaim();
            // Protection not needed
            return;
        }
        uint256 newClaim = insuranceAmountT1 - insuranceAmountT0;
        uint256 covered = _slashNewClaim(newClaim);
        // insuranceAmountT1 is capped by insurancePool.request(), so coverAndSlash()
        // must cover the full new claim in the same transaction.
        require(covered == newClaim, "CoverageUnderfunded");
        insuranceAmount = insuranceAmountT1;
        emit InsuranceClaimed(covered, insuranceAmount);
    }

    /// @dev Cap the middleware's already-slashed claim counter to the reduced insuranceAmount.
    ///      This updates bookkeeping only; it does not move or return slashed collateral.
    ///      Sync before any later claim increase; reusable funded surplus is accounted for separately.
    function _syncInsuranceClaim() internal {
        if (address(insurancePool) != address(0)) {
            insurancePool.syncInsuranceClaim(address(cdo));
        }
    }

    /// @notice Secures coverage before storing the new insurance claim.
    /// @dev The preview in `calculateNAVSplit` (via `request()`) sized `newClaim` within the current
    ///      available coverage, and this runs in the same tx, so the pool must cover it in full.
    function _slashNewClaim (uint256 newClaim) internal returns (uint256 covered) {
        if (address(insurancePool) == address(0)) {
            return newClaim;
        }
        covered = insurancePool.coverAndSlash(address(cdo), newClaim);
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

    function getBenchmarkIndexT1() internal view returns (uint256) {
        return
            calculateTargetIndex(
                benchmarkIndex,
                indexTimestamp,
                block.timestamp,
                aprTarget
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
        (
            uint256 jrtEffective,
            uint256 srtEffective
        ) = calcEffectiveNav(jrtNavProjected, srtBaseNav);

        UD60x18 tvlRatio = UD60x18.wrap(
            srtEffective == 0 ? 0 : ((srtEffective * 1e18) / (srtEffective + jrtEffective))
        );

        if (address(riskPremiumModel) == address(0)) {
            return UD60x18.wrap(0);
        }
        return riskPremiumModel.riskPremium(tvlRatio);
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
        if (useBenchmarkProjection) {
            benchmarkIndex = getBenchmarkIndexT1();
        }
        srtTargetIndex = getSrtTargetIndexT1();
        navTargetIndex = getNavTargetIndexT1();
        indexTimestamp = block.timestamp;
    }
    function updateAprSrt(UD60x18 aprTarget_, UD60x18 aprBase_) internal {
        UD60x18 risk = calculateRiskPremium();
        UD60x18 aprSrt1 = UD60x18Ext.mul(aprBase_, UD60x18.wrap(1e18) - risk);
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
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        syncAprs();
    }

    /// @dev Suspends performance fees after a loss; only setReserveBps can re-enable them.
    function _disablePerformanceFee() internal {
        if (reserveBps == 0) {
            return;
        }
        reserveBps = 0;
        emit ReservePercentageChanged(0);
    }

    /// @dev Retain all tranche fees after a depeg or Junior depletion; only setFeeRetentionBps can restore reserve accrual.
    function _disableFeeReserveAccrual() internal {
        if (feeJrtRetentionBps == PERCENTAGE_100 && feeSrtRetentionBps == PERCENTAGE_100) {
            return;
        }
        feeJrtRetentionBps = PERCENTAGE_100;
        feeSrtRetentionBps = PERCENTAGE_100;
        emit FeeRetentionChanged(PERCENTAGE_100, PERCENTAGE_100);
    }

    /// @notice Sets the valuation price for the base asset.
    function setValuationPrice (uint128 price) external onlyCDO returns (bool){
        bool isValuationLossPeriod = valuationPrice < 1e18;
        bool valuationLossEntered = isValuationLossPeriod == false && price < 1e18;
        // Allow the valuation price in range 0.0001-1
        require(0.0001e18 <= price && price <= 1e18, "InvalidValuationPrice");
        // Settle pending PnL first, without slashing valuation coverage at the old price.
        checkpointAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        if (price < 1e18) {
            _disablePerformanceFee();
            _disableFeeReserveAccrual();
        }
        _resyncsrtFundNav(price);
        valuationPrice = price;
        valuationUpdatedAt = uint64(block.timestamp);
        if (valuationLossEntered) {
            // Grace period starts; further grace periods in subsequent drops should handle PAUSER_ROLE
            valuationEnteredAt = uint64(block.timestamp);
        }
        _coverValuationLoss(price);
        emit ValuationPriceChanged(price);
        return valuationLossEntered;
    }

    /// @notice Covers the Senior-bound valuation loss Junior cannot absorb, synchronously slashing it.
    /// @dev Holds Senior whole against a de-peg: books the covered amount to both srtInsuranceFundNav
    ///      (so calcEffectiveNav stops charging Junior for it) and insuranceAmount (settled at redemption).
    ///      Any residual the pool cannot cover stays in the effective-NAV shortfall, i.e. Senior bears it.
    function _coverValuationLoss (uint128 price) internal {
        if (address(insurancePool) == address(0)) {
            return;
        }
        uint256 uncovered = _seniorValuationShortfall(price);
        if (uncovered == 0) {
            return;
        }
        uint256 covered = insurancePool.coverAndSlash(address(cdo), uncovered);
        if (covered > 0) {
            // Credit Senior the owed tokens now and hold the matching claim until it is paid out at
            // redemption, so nav + insuranceAmount == jrt + srt + reserve + underwriter fee keeps balancing.
            srtInsuranceFundNav += covered;
            srtBaseNav += covered;
            // Valuation credit is a Senior flow, not PnL, for the daily loss floor.
            windowNetFlows += int256(covered);
            insuranceAmount += covered;
            emit InsuranceClaimed(covered, insuranceAmount);
        }
    }

    /// @notice Senior-bound valuation loss at `price` that neither Senior's self-fund, the existing
    ///         Symbiotic fund, nor Junior can absorb.
    function _seniorValuationShortfall (uint128 price) internal view returns (uint256) {
        if (price >= 1e18) {
            return 0;
        }
        uint256 srtPrincipal = Math.saturatingSub(srtBaseNav, srtInsuranceFundNav);
        uint256 extraNeeded = Math.saturatingSub(Math.mulDiv(srtPrincipal, 1e18, price), srtBaseNav);
        extraNeeded = Math.saturatingSub(extraNeeded, _cappedSrtFundNav(price));
        uint256 juniorAvailable = Math.saturatingSub(jrtBaseNav, ONE_ASSET);
        return Math.saturatingSub(extraNeeded, juniorAvailable);
    }

    /// @dev Scale self-funding with Senior NAV reductions from fees or reconciliation.
    ///      Valuation insurance credit is compensation, not principal; exclude it from the ratio.
    function _scaleSrtFund(uint256 seniorBefore, uint256 seniorAfter) internal {
        if (seniorAfter >= seniorBefore || (srtFundedGrossNav == 0 && srtFundNav == 0)) {
            return;
        }
        uint256 principalBefore = Math.saturatingSub(seniorBefore, srtInsuranceFundNav);
        uint256 principalAfter = Math.saturatingSub(seniorAfter, srtInsuranceFundNav);
        if (principalBefore == 0) {
            return;
        }
        srtFundedGrossNav = Math.mulDiv(srtFundedGrossNav, principalAfter, principalBefore);
        srtFundNav = Math.mulDiv(srtFundNav, principalAfter, principalBefore);
    }

    function _trackSrtFundNavIn(uint256 amount) internal returns (uint256 srtFundAmountIn) {
        if (amount == 0 || valuationPrice == 1e18) {
            return 0;
        }
        srtFundAmountIn = Math.mulDiv(amount, 1e18 - valuationPrice, 1e18);
        srtFundedGrossNav += amount;
    }

    /// @dev Entry self-funding usable at this price, without erasing it on partial recovery.
    function _cappedSrtFundNav(uint256 price) internal view returns (uint256) {
        if (price >= 1e18) return 0;
        return Math.min(Math.mulDiv(srtFundNav, 1e18, price), Math.mulDiv(srtFundedGrossNav, 1e18 - price, price));
    }

    function _resyncsrtFundNav(uint128 price) internal {
        if (price == 1e18 && srtFundedGrossNav > 0) {
            srtFundedGrossNav = 0;
            srtFundNav = 0;
        }
        // Retain entry self-funding through partial recovery; cap it only when sizing coverage.
        _resyncInsuranceFundNav(price);
    }

    /// @notice On re-peg the Senior valuation shortfall shrinks; unwind the Symbiotic-covered part and
    ///         reduce the outstanding claim by the same amount. Collateral already slashed is not
    ///         returned: once injected it surfaces as a plain gain and flows to Junior, which took
    ///         the de-peg loss first.
    function _resyncInsuranceFundNav(uint128 price) internal {
        uint256 fund = srtInsuranceFundNav;
        if (fund == 0) {
            return;
        }
        uint256 stillNeeded = 0;
        if (price < 1e18) {
            uint256 srtPrincipal = Math.saturatingSub(srtBaseNav, fund);
            uint256 insuranceNeeded = Math.saturatingSub(
                Math.mulDiv(srtPrincipal, 1e18, price),
                srtPrincipal
            );
            insuranceNeeded = Math.saturatingSub(insuranceNeeded, _cappedSrtFundNav(price));
            insuranceNeeded = Math.saturatingSub(
                insuranceNeeded,
                Math.saturatingSub(jrtBaseNav, ONE_ASSET)
            );
            stillNeeded = Math.min(insuranceNeeded, fund);
        }
        if (fund > stillNeeded) {
            uint256 unwound = Math.min(fund - stillNeeded, insuranceAmount);
            srtInsuranceFundNav = fund - unwound;
            // Senior hands back the de-peg credit it no longer needs and the claim is cancelled by
            // the same amount, so nav is untouched and the identity still holds. The collateral
            // already slashed stays in the insurance vault rather than being credited to a tranche.
            insuranceAmount -= unwound;
            _syncInsuranceClaim();
            srtBaseNav -= unwound;
            // Returning valuation credit is not a Senior loss.
            windowNetFlows -= int256(unwound);
        }
    }

    /// @dev Only settled Junior backing protects Senior; unrealized Junior gains remain with Junior.
    function _effectiveLiveNav(uint256 juniorLive, uint256 juniorReal, uint256 seniorLive)
        internal view returns (uint256 juniorEffective, uint256 seniorEffective)
    {
        if (valuationPrice == 1e18) {
            return (juniorLive, seniorLive);
        }
        uint256 juniorBacking = Math.min(juniorLive, juniorReal);
        (juniorEffective, seniorEffective) = calcEffectiveNav(juniorBacking, seniorLive);
        juniorEffective += juniorLive - juniorBacking;
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
        // srtFact already includes any Symbiotic de-peg credit, which is compensation rather than
        // principal: exclude it when sizing how many tokens Senior needs to be whole at this price.
        uint256 srtPrincipal = Math.saturatingSub(srtFact, srtInsuranceFundNav);
        uint256 extraNeeded = Math.saturatingSub(Math.mulDiv(srtPrincipal, 1e18, valuationPrice), srtFact);
        extraNeeded = Math.saturatingSub(extraNeeded, _cappedSrtFundNav(valuationPrice));
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
