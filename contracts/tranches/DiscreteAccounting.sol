// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { UD60x18, pow, mul } from "@prb/math/src/ud60x18/Math.sol";
import { IAccounting } from "./interfaces/IAccounting.sol";
import { IStrataCDO } from "./interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "./interfaces/IAprPairFeed.sol";
import { CDOComponent } from "./base/CDOComponent.sol";
import { UD60x18Ext } from "./utils/UD60x18Ext.sol";
import { AccountingLib } from "./utils/AccountingLib.sol";
import { IRiskPremiumModel } from "./accounting/premium/IRiskPremiumModel.sol";
import { IInsurancePool } from "./symbiotic/interfaces/IInsurancePool.sol";

/**
 * @title CDO::DiscreteAccounting
 * @dev Pure math contract to track the in-flow and out-flow of assets and balance the gain/loss between Junior (Jrt) and Senior (Srt) Tranche Value Locked (TVL).
 */
contract DiscreteAccounting is IAccounting, CDOComponent {
    uint256 private constant MIGRATION_V2 = 1 << 0;

    uint256 constant SECONDS_PER_YEAR = 31_536_000;

    int64   private constant APR_FEED_BOUNDARY_MAX = 2e12; // 200%
    int64   private constant APR_FEED_BOUNDARY_MIN = 0;
    uint256 private constant APR_FEED_DECIMALS = 12;
    uint256 private immutable ONE_ASSET;
    bool private immutable useNavAtReconciliation;

    /// @dev The oracle to fetch the latest APR floor and APR base.
    /// @notice When the oracle is updated, it can actively push the latest values to this contract, allowing us to adjust srtTargetIndex.
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
    uint256 constant UNDERWRITER_FEE_BPS_MAX = 0.2e18;

    /// @dev Latest balances at T0 (latest protocol interrogation)
    uint256 public nav;
    uint256 public jrtBaseNav;
    uint256 public srtBaseNav;
    uint256 public reserveNav;

    /// @dev Risk parameters for Risk Premium calculation.
    /// @notice See `calculateRiskPremium()` for usage details.
    UD60x18 public riskX;
    UD60x18 public riskY;
    UD60x18 public riskK;

    /// @notice The hard minimum TVLjrt/TVLsrt ratio.
    /// @dev If the Jrt TVL falls below this ratio relative to Srt,
    ///      Jrt withdrawals are no longer allowed.
    //       In case of low APR, Jrt will still be responsible for funding Srt returns, even if it falls below this ratio
    uint256 public minimumJrtSrtRatio;

    /// @notice The protective buffer above the minimum Jrt/Srt ratio.
    /// @dev If the ratio falls below this threshold, deposits into the Srt vault
    ///      are disabled earlier to prevent front-running the hard floor.
    ///      Jrt withdrawals remain possible until the hard minimum is reached.
    uint256 public minimumJrtSrtRatioBuffer;

    /// @notice The portion of Junior fees that is returned to its TVL. The remainder goes to the reserve.
    uint256 public feeJrtRetentionBps;

    /// @notice The portion of Senior fees that is returned to the Senior tranche TVL.
    uint256 public feeSrtRetentionBps;

    /** Accounting Storage Compatibility **/

    // The index for NAV during projection
    uint256 public navTargetIndex;

    /// @notice Timestamp of the last balance flow (deposit, withdrawal, or reserve reduction).
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

    /// @notice Timestamp of the last successful NAV reconciliation.
    /// @dev Used for reconciliations when useNavAtReconciliation is true. Passed to totalStrategyAssets so
    ///      sub-strategies gate their reward signal on this value, which only advances when
    ///      real rewards are detected — not on every deposit.
    uint256 public lastReconciliation;

    uint256[15] private __gap_DYSAccounting;

    /// @notice Optional external risk premium model.
    /// @dev When unset, accounting falls back to the legacy `x + y * TVL_ratio_sr^k`
    ///      model configured by `riskX`, `riskY`, and `riskK`.
    IRiskPremiumModel public riskPremiumModel;

    /* Underwriter Fee (Symbiotic) Parameters. Appended for storage-layout compatibility */

    /// @notice Share of raw Senior risk premium used to derive the underwriter fee rate (1e18 = 100%)
    uint256 public underwriterFeeBps;

    /// @notice Accrued underwriter fee owed to underwriters, not yet paid out (part of nav)
    uint256 public underwriterFeeNav;

    /// @notice Coverage claimed from the insurance pool but not yet settled, in base assets
    /// @dev Holds Senior whole against assets not yet in the strategy, so the NAV identity carries a
    ///      `- insuranceAmount` term. Increases on a covered loss, unwinds on a later gain, and is
    ///      cleared as redeeming Seniors are paid from the InsuranceVault. See base Accounting.
    uint256 public insuranceAmount;

    /// @notice The Symbiotic insurance pool queried for coverage
    /// @dev When unset (address(0)) no coverage is requested and losses hit the tranches as usual.
    IInsurancePool public insurancePool;

    /// @notice Portion of the Senior valuation loss (base-asset de-peg) covered by Symbiotic.
    /// @dev Tops Senior up in calcEffectiveNav for the de-peg loss Junior could not absorb, so Senior
    ///      reads whole. It is external capital backed by slashed collateral and tracked in
    ///      insuranceAmount. Booked in setValuationPrice, unwound on re-peg in _resyncSrtFundNav.
    uint256 public srtInsuranceFundNav;

    error InvalidNavSplit(uint256 navT1, uint256 jrtAssets, uint256 srtAssets, uint256 reserveAssets, uint256 underwriterFeeAssets);
    error ReserveTooLow(uint256 reserveNav, uint256 requestedNav);
    error UnderwriterFeeTooLow(uint256 underwriterFeeNav, uint256 requestedNav);

    event AprPairFeedChanged(address aprPairFeed);
    event AprDataChangedViaPush(UD60x18 aprTarget, UD60x18 aprBase);
    event ReservePercentageChanged(uint256 reserveBps);
    event UnderwriterFeeReduced(uint256 amount);
    event InsuranceClaimed(uint256 amount, uint256 insuranceAmount);
    event RiskParametersChanged(UD60x18 x, UD60x18 y, UD60x18 k);
    event RiskModelChanged(address riskPremiumModel);
    event MinimumJrtSrtRatioChanged(uint256 ratio);
    event MinimumJrtSrtRatioBufferChanged(uint256 ratio);
    event FeeAccrued(bool isJrt, uint256 amountToReserve, uint256 amountToTranche);
    event FeeRetentionChanged(uint256 feeJrtRetention, uint256 feeSrtRetention);

    constructor (uint256 navDecimals, bool useNavAtReconciliation_) {
        ONE_ASSET = 10 ** navDecimals;
        useNavAtReconciliation = useNavAtReconciliation_;
    }

    function _navAnchor() private view returns (uint256) {
        return useNavAtReconciliation ? lastReconciliation : navTimestamp;
    }

    function initialize(
        address owner_,
        address acm_,
        IStrataCDO cdo_,
        IAprPairFeed aprPairFeed_
    ) public virtual reinitializer(2) {
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
    }

    function initializeV2() external reinitializer(2) {
        _initV2();
    }
    /// @notice Migration V2: valuation loss support and performance fee high-watermark.
    /// @dev V2 migration is compatible across all Strata accounting contracts.
    function _initV2() internal {
        if (migrationBitmap & MIGRATION_V2 != 0) {
            return;
        }
        valuationPrice = 1e18;
        feeWatermarkNav = nav;
        lastReconciliation = navTimestamp;
        migrationBitmap |= MIGRATION_V2;
    }

    /// @notice Returns the updated total assets for each tranche and the reserve
    /// @dev This method is used by the Tranches to get their updated total assets for the current block
    /// @param navT1 The current total Net Asset Value
    /// @return jrtNavT1Projected The updated Junior Tranche TVL
    /// @return srtNavT1 The updated Senior Tranche TVL
    /// @return reserveNavT1 The updated Reserve TVL
    function totalAssets (uint256 navT1) public view returns (uint256 jrtNavT1Projected, uint256 srtNavT1, uint256 reserveNavT1) {
        (
            jrtNavT1Projected,
            /*jrtNavT1Real*/,
            srtNavT1,
            reserveNavT1,
            /*underwriterFeeNavT1*/,
            /*insuranceAmountT1*/
        ) = calculateNAVSplit(nav, jrtNavProjected, jrtBaseNav, srtBaseNav, reserveNav, underwriterFeeNav, insuranceAmount, navT1);
        (jrtNavT1Projected, srtNavT1) = calcEffectiveNav(jrtNavT1Projected, srtNavT1);
    }

    /// @notice Returns projected or reconciled amounts without projection unwind.
    /// @dev Settled redemption pricing is not supported. Use DYSAccounting if projection unwind is required.
    function totalAssetsSettled () external view returns (uint256 jrtNavSettled, uint256 srtNavSettled, uint256 reserveNavSettled) {
        return totalAssets();
    }

    /// @notice Returns projected or reconciled amounts without projection unwind.
    /// @dev Settled redemption pricing is not supported. Use DYS/MTMAccounting if projection unwind is required.
    function totalAssetsLiveAndSettled()
        public
        view
        returns (
            uint256 jrtNavLive,
            uint256 srtNavLive,
            uint256,
            uint256
        )
    {
        (jrtNavLive, srtNavLive,) = totalAssets();
        return (
            jrtNavLive,
            srtNavLive,
            jrtNavLive,
            srtNavLive
        );
    }

    /// @notice Returns the updated total assets for each tranche and the reserve
    /// @dev This method is used by the Tranches to get their updated total assets for the current block
    /// @dev The strategy must return NAV with new rewards, using accounting's current NAV and timestamp.
    /// @return jrtNavT1Projected The updated Junior Tranche TVL
    /// @return srtNavT1 The updated Senior Tranche TVL
    /// @return reserveNavT1 The updated Reserve TVL
    function totalAssets () public view returns (uint256 jrtNavT1Projected, uint256 srtNavT1, uint256 reserveNavT1) {
        uint256 navT1 = cdo.totalStrategyAssets(nav, _navAnchor());
        return totalAssets(navT1);
    }

    /// @notice Returns the current saved real total assets for each tranche and the reserve
    /// @dev These values represent the state at the last update, not necessarily the current block
    /// @return jrtNavT0 The last saved Junior Real Tranche TVL
    /// @return srtNavT0 The last saved Senior Tranche TVL
    /// @return reserveNavT0 The last saved Reserve TVL
    function totalAssetsT0 () public view returns (uint256 jrtNavT0, uint256 srtNavT0, uint256 reserveNavT0) {
        (jrtNavT0, srtNavT0) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
        reserveNavT0 = reserveNav;
    }

    /// @notice Returns current reserve value
    /// @dev This method returns the maximum amount that `reduceReserve` can handle
    /// @return The current reserve Net Asset Value (NAV)
    function totalReserve () external view returns (uint256) {
        (,,uint256 reserveNavT1) = totalAssets(cdo.totalStrategyAssets(nav, _navAnchor()));
        return reserveNavT1;
    }

    /// @notice Sets the share of raw Senior risk premium used for the underwriter fee rate
    /// @dev Only callable by the CDO, which relays the rate from the Symbiotic insurance middleware
    function setUnderwriterFeeBps (uint256 bps) external onlyCDO {
        require(bps <= UNDERWRITER_FEE_BPS_MAX && bps != underwriterFeeBps, "InvalidNewUnderwriterFee");
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        underwriterFeeBps = bps;
    }

    /// @notice Sets the Symbiotic insurance pool queried for coverage.
    function setInsurancePool (IInsurancePool insurancePool_) external onlyCDO {
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        insurancePool = insurancePool_;
    }

    /// @dev Queries the insurance pool for how much of `loss` it can cover. View; returns 0 when unset.
    function _requestInsurance (uint256 loss) internal view returns (uint256) {
        if (loss == 0 || address(insurancePool) == address(0)) {
            return 0;
        }
        return insurancePool.request(address(cdo), loss);
    }

    function srtNav () external view returns (uint256 srtNavEffective) {
        (, srtNavEffective) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
    }
    function jrtNav () external view returns (uint256 jrtNavEffective) {
        (jrtNavEffective,) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
    }

    /// @notice Returns the current accrued underwriter fee value
    function totalUnderwriterFeeNav () external view returns (uint256 underwriterFeeNavT1) {
        (,,,, underwriterFeeNavT1,) = calculateNAVSplit(
            nav, jrtNavProjected, jrtBaseNav, srtBaseNav, reserveNav, underwriterFeeNav, insuranceAmount,
            cdo.totalStrategyAssets(nav, _navAnchor())
        );
    }

    /// @notice Reduces the accrued underwriter fee by the specified amount
    /// @dev Called by the CDO when paying underwriter fee to the insurance middleware; the CDO withdraws
    ///      the corresponding tokens, so nav (which includes the underwriter fee bucket) drops too.
    function reduceUnderwriterFee (uint256 amount) external onlyCDO {
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        if (amount > underwriterFeeNav) {
            revert UnderwriterFeeTooLow(underwriterFeeNav, amount);
        }
        underwriterFeeNav -= amount;
        nav -= amount;
        emit UnderwriterFeeReduced(amount);
    }


    /// @notice Reduces the reserve by the specified amount
    /// @dev This function is called by the CDO contract to reduce the reserve
    /// @dev The CDO contract is responsible for withdrawing the appropriate amount to the treasury
    /// @param amount The amount by which to reduce the reserve NAV
    /// @param jrtAmountIn The amount to be credited to the Junior Tranche
    /// @param srtAmountIn The amount to be credited to the Senior Tranche
    function reduceReserve (uint256 amount, uint256 jrtAmountIn, uint256 srtAmountIn) external onlyCDO {
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

        // Fetch APRs and force recalculate aprSrt, as JRT and SRT TVLs may have changed.
        (bool modified, UD60x18 aprTarget_, UD60x18 aprBase_) = fetchAprs();
        if (modified == false) {
            // Recalculates aprSrt based on new TVL ratio and old APRs
            updateAprSrt(aprTarget_, aprBase_);
        }
    }

    function maxWithdraw(bool isJrt) external view returns (uint256) {
        return maxWithdrawInner(isJrt, false);
    }
    function maxWithdraw(bool isJrt, bool ownerIsSharesCooldown) external view returns (uint256) {
        return maxWithdrawInner(isJrt, ownerIsSharesCooldown);
    }
    function maxWithdrawInner(bool isJrt, bool ownerIsSharesCooldown) internal view returns (uint256) {
        if (valuationPrice < 1e18 && block.timestamp < valuationEnteredAt + valuationGracePeriod) {
            // Disable withdrawals during grace period after valuation loss
            return 0;
        }
        (uint256 jrtNavEffective, uint256 srtNavEffective) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
        if (ownerIsSharesCooldown) {
            return isJrt ? jrtNavEffective : srtNavEffective;
        }
        if (isJrt) {
            uint256 minJrt = srtNavEffective * minimumJrtSrtRatio / 1e18;
            return Math.saturatingSub(jrtNavEffective, minJrt);
        }
        // srt
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
        uint256 maxSrt = jrtNavEffective * 1e18 / minimumJrtSrtRatioBuffer;
        return Math.saturatingSub(maxSrt, srtNavEffective);
    }

    /// @notice Updates the accounting by fetching the current total assets from the strategy
    /// @dev Fetches total assets by providing the last accounted NAV and timestamp to the strategy,
    ///      allowing it to determine if new yield has arrived and should be reconciled.
    ///      This triggers a true-up between projected and realized Junior NAV if rewards are detected.
    function updateAccounting () external onlyCDO {
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
    }

    /// @notice Updates the Net Asset Values (NAVs) after deposits or withdrawals
    /// @dev This method should be called after any deposits or withdrawals are made in the tranches
    /// @dev It adjusts the NAVs for both Junior and Senior tranches, as well as the total NAV
    /// @param jrtAssetsIn Amount of assets deposited into the Junior tranche
    /// @param jrtAssetsOut Amount of assets withdrawn from the Junior tranche
    /// @param srtAssetsIn Amount of assets deposited into the Senior tranche
    /// @param srtAssetsOut Amount of assets withdrawn from the Senior tranche
    function updateBalanceFlow (
        uint256 jrtAssetsIn,
        uint256 jrtAssetsOut,
        uint256 srtAssetsIn,
        uint256 srtAssetsOut
    ) external onlyCDO returns (uint256 insuranceBaseOut) {
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

        // Senior's exit takes its share of the outstanding coverage with it. That slice is paid from
        // the insurance vault rather than the strategy, so srtBaseNav drops by the full outflow while
        // nav drops only by what actually leaves the strategy. Both sides of
        // nav + insuranceAmount == jrt + srt + reserve + underwriter fee then move by srtAssetsOut.
        if (!valuationWithdrawal && insuranceAmount > 0 && srtAssetsOut > 0 && srtBaseNav > 0) {
            insuranceBaseOut_ = Math.min(
                insuranceAmount,
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
        navTimestamp = block.timestamp;
        (bool modified, UD60x18 aprTarget_, UD60x18 aprBase_) = fetchAprs();
        if (modified == false) {
            // Recalculates aprSrt based on new TVL ratio and old APRs
            updateAprSrt(aprTarget_, aprBase_);
        }
    }

    /// @dev Consume all backing components using the same pre-exit effective Senior NAV.
    function _splitValuationWithdrawal(uint256 assetsOut)
        internal returns (uint256 juniorOut, uint256 seniorStrategyOut, uint256 insuranceOut)
    {
        (, uint256 seniorEffective) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
        (juniorOut, seniorStrategyOut, insuranceOut) = AccountingLib.splitValuatedNavOut(
            srtBaseNav, seniorEffective, insuranceAmount, assetsOut
        );
        srtInsuranceFundNav -= Math.mulDiv(assetsOut, srtInsuranceFundNav, seniorEffective);
        srtFundedGrossNav -= Math.mulDiv(assetsOut, srtFundedGrossNav, seniorEffective);
        srtFundNav -= Math.mulDiv(assetsOut, srtFundNav, seniorEffective);
    }

    /// @notice Called by the CDO to account for a fee by moving NAV from a tranche to the reserve.
    function accrueFee (bool isJrt, uint256 amount) external onlyCDO {
        uint256 retentionBps = isJrt ? feeJrtRetentionBps : feeSrtRetentionBps;
        uint256 amountToReserve = amount * (1e18 - retentionBps) / 1e18;
        reserveNav += amountToReserve;
        if (isJrt) {
            jrtBaseNav -= amountToReserve;
            jrtNavProjected -= amountToReserve;
        } else {
            if (valuationPrice < 1e18) {
                _scaleSrtFund(srtBaseNav, srtBaseNav - amountToReserve);
            }
            srtBaseNav -= amountToReserve;
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

    /// @notice Calculates the updated Net Asset Values (NAVs) for Junior, Senior tranches, and Reserve
    /// @dev This function performs the following operations:
    /// 1. Calculates and distributes gains or losses across tranches
    /// 2. Allocates Reserve from total gains, then accrues Underwriter fee from Senior realized gain
    /// 3. Junior tranche initially receives all gain, but this is later adjusted
    /// 4. Ensures the Senior tranche reaches its target APR using Junior tranche funds
    /// 5. Verifies the final NAV split is consistent with the total NAV
    /// @param navT0 Total Net Asset Value at the previous timestamp
    /// @param jrtNavT0Projected Junior tranche Projected NAV at the previous timestamp
    /// @param jrtNavT0Real Junior tranche Real NAV at the previous timestamp
    /// @param srtNavT0 Senior tranche NAV at the previous timestamp
    /// @param reserveNavT0 Reserve NAV at the previous timestamp
    /// @param navT1 Current total Net Asset Value
    /// @return jrtNavT1Projected Updated Junior tranche Projected NAV
    /// @return jrtNavT1Real Updated Junior tranche Real NAV
    /// @return srtNavT1 Updated Senior tranche NAV
    /// @return reserveNavT1 Updated Reserve NAV
    function calculateNAVSplit (
        uint256 navT0,
        uint256 jrtNavT0Projected,
        uint256 jrtNavT0Real,
        uint256 srtNavT0,
        uint256 reserveNavT0,
        uint256 underwriterFeeNavT0,
        uint256 insuranceAmountT0,

        uint256 navT1
    ) public view returns (
        uint256 jrtNavT1Projected,
        uint256 jrtNavT1Real,
        uint256 srtNavT1,
        uint256 reserveNavT1,
        uint256 underwriterFeeNavT1,
        uint256 insuranceAmountT1
    ) {
        underwriterFeeNavT1 = underwriterFeeNavT0;
        insuranceAmountT1 = insuranceAmountT0;
        if (jrtNavT0Projected == 0 && srtNavT0 == 0 && navT1 > 0) {
            // No deposits yet, however Strategy reports gain, move all to reserve; keep the underwriter fee
            // capped to the remaining assets so a wipeout below the accrued underwriter fee cannot underflow.
            uint256 underwriterFeeKept = Math.min(navT1, underwriterFeeNavT0);
            return (0, 0, 0, navT1 - underwriterFeeKept, underwriterFeeKept, insuranceAmountT0);
        }

        if (navT0 == navT1) {
            // Still no realized gain; process using the projection.
            return calculateNAVSplitProjected(
                navT0,
                jrtNavT0Projected,
                jrtNavT0Real,
                srtNavT0,
                reserveNavT0,
                underwriterFeeNavT0,
                insuranceAmountT0
            );
        }

        int256 gain_dT = int256(navT1) - int256(navT0);

        if (gain_dT < 0) {
            // Loss waterfall: Jrt absorbs first, then the reserve, then the Symbiotic coverage takes
            // the Senior-bound remainder (Srt held whole, booked to insuranceAmount).
            uint256 loss = uint256(-gain_dT);

            uint256 jrtLoss = Math.min(jrtNavT0Real, loss);

            loss -= jrtLoss;
            uint256 reserveLoss = Math.min(reserveNavT0, loss);

            loss -= reserveLoss;

            uint256 covered = _requestInsurance(loss);
            loss -= covered;

            uint256 srtLoss = Math.min(srtNavT0, loss);
            // The market is considered abandoned if losses would consume the protected dust NAV
            require(srtLoss == loss, "NavBelowMinimum");

            jrtNavT0Real -= jrtLoss;
            srtNavT0  -= srtLoss;
            reserveNavT0 -= reserveLoss;
            insuranceAmountT1 = insuranceAmountT0 + covered;
            gain_dT = 0;
        }
        uint256 gain_dTAbs = uint256(gain_dT);

        // Gains repay only NAV-loss claims; valuation claims unwind with their credit through price updates.
        if (gain_dTAbs > 0 && insuranceAmountT1 > 0) {
            uint256 realizedClaim = Math.saturatingSub(insuranceAmountT1, srtInsuranceFundNav);
            uint256 unwind = Math.min(gain_dTAbs, realizedClaim);
            insuranceAmountT1 -= unwind;
            gain_dTAbs -= unwind;
        }

        // #1 Final new reserve
        uint256 reserve_dT = 0;
        if (navT1 > feeWatermarkNav && reserveBps > 0) {
            uint256 feeableGain = Math.min(gain_dTAbs, navT1 - feeWatermarkNav);
            reserve_dT = feeableGain * reserveBps / PERCENTAGE_100;
            gain_dTAbs -= reserve_dT;
        }
        reserveNavT1 = reserveNavT0 + reserve_dT;

        underwriterFeeNavT1 = underwriterFeeNavT0;

        // Allocate the full gain to Junior first; later, subtract Senior's gross target gain from Junior.
        jrtNavT1Real = jrtNavT0Real + gain_dTAbs;


        // Calculate Srt gain
        uint256 srtTargetIndexT1 = getSrtTargetIndexT1();
        // Gain = Assets * (TargetIndex1 / TargetIndex0 - 1);
        int256 srtGainTarget = calculateGain(srtNavT0, srtTargetIndexT1, srtTargetIndex);
        if (srtGainTarget < 0) {
            // Should never happen, jic: transfer the loss to Juniors as profit
            uint256 loss = uint256(-srtGainTarget);
            uint256 srtLoss = Math.min(srtNavT0, loss);

            srtNavT0 -= srtLoss;
            jrtNavT1Real += srtLoss;
            srtGainTarget = 0;
        }
        uint256 srtGainTargetAbs = Math.min(
            uint256(srtGainTarget),
            Math.saturatingSub(jrtNavT1Real, ONE_ASSET)
        );

        uint256 underwriterFee_dT = 0;
        if (srtGainTargetAbs > 0 && underwriterFeeBps > 0) {
            uint256 underwriterFeePct = calculateRiskPremium().unwrap() * underwriterFeeBps / PERCENTAGE_100;
            underwriterFee_dT = srtGainTargetAbs * underwriterFeePct / PERCENTAGE_100;
            underwriterFeeNavT1 += underwriterFee_dT;
        }

        // #2 Final new Jrt
        jrtNavT1Real = jrtNavT1Real - srtGainTargetAbs;
        jrtNavT1Projected = jrtNavT1Real;

        // #3 Final new Srt
        srtNavT1 = srtNavT0 + srtGainTargetAbs - underwriterFee_dT;

        if (navT1 + insuranceAmountT1 != (jrtNavT1Real + srtNavT1 + reserveNavT1 + underwriterFeeNavT1)) {
            revert InvalidNavSplit(navT1, jrtNavT1Real, srtNavT1, reserveNavT1, underwriterFeeNavT1);
        }

        return (jrtNavT1Projected, jrtNavT1Real, srtNavT1, reserveNavT1, underwriterFeeNavT1, insuranceAmountT1);
    }

    function calculateNAVSplitProjected (
        uint256 navT0,
        uint256 jrtNavT0Projected,
        uint256 jrtNavT0Real,
        uint256 srtNavT0,
        uint256 reserveNavT0,
        uint256 underwriterFeeNavT0,
        uint256 insuranceAmountT0
    ) internal view returns (
        uint256 jrtNavT1Projected,
        uint256 jrtNavT1Real,
        uint256 srtNavT1,
        uint256 reserveNavT1,
        uint256 underwriterFeeNavT1,
        uint256 insuranceAmountT1
    ) {
        // Underwriter fee is modeled in projected Senior NAV but is not accrued into underwriterFeeNav.
        // The insurance claim is likewise untouched on the projection (no realized loss to cover).
        underwriterFeeNavT1 = underwriterFeeNavT0;
        insuranceAmountT1 = insuranceAmountT0;
        if (jrtNavT0Projected == 0 && srtNavT0 == 0) {
            // No deposits yet, the projected NAV remain 0.
            return (0, 0, 0, 0, underwriterFeeNavT0, insuranceAmountT0);
        }

        uint256 navTargetIndexT1 = getNavTargetIndexT1();
        // Gain = Assets * (TargetIndex1 / TargetIndex0 - 1);
        // Calculate gain based on real NAV, not projected
        int256 gain_dT = calculateGain(navT0, navTargetIndexT1, navTargetIndex);

        if (gain_dT < 0) {
            // never happens, jic: cover by Jrt, then Reserve, then Srt
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

            return (
                jrtNavT1Projected,
                jrtNavT1Real,
                srtNavT1,
                reserveNavT1,
                underwriterFeeNavT0,
                insuranceAmountT0
            );
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

        // Allocate the full gain to Junior first; later, subtract Senior's gross target gain from Junior.
        jrtNavT1Projected = jrtNavT0Projected + gain_dTAbs;

        // Calculate Srt gain
        uint256 srtTargetIndexT1 = getSrtTargetIndexT1();
        // Gain = Assets * (TargetIndex1 / TargetIndex0 - 1);
        int256 srtGainTarget = calculateGain(srtNavT0, srtTargetIndexT1, srtTargetIndex);
        if (srtGainTarget < 0) {
            // Should never happen; transfer the loss to Junior as profit.
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


        uint256 expectedUnderwriterFee = 0;
        if (srtGainTargetAbs > 0 && underwriterFeeBps > 0) {
            uint256 underwriterFeePct = calculateRiskPremium().unwrap() * underwriterFeeBps / PERCENTAGE_100;
            expectedUnderwriterFee = srtGainTargetAbs * underwriterFeePct / PERCENTAGE_100;
        }

        // #2 Final new Jrt (after srt funding)
        jrtNavT1Projected = jrtNavT1Projected - srtGainTargetAbs;
        jrtNavT1Real = Math.saturatingSub(jrtNavT0Real, Math.saturatingSub(srtGainTargetAbs, expectedUnderwriterFee));

        // #3 Final new Srt
        srtNavT1 = srtNavT0 + srtGainTargetAbs - expectedUnderwriterFee;

        // #4 No changes to NAV and reserve on Projection
        reserveNavT1 = reserveNavT0;

        return (
            jrtNavT1Projected,
            jrtNavT1Real,
            srtNavT1,
            reserveNavT1,
            underwriterFeeNavT0,
            insuranceAmountT0
        );
    }

    function updateAccountingInner(uint256 navT1) internal {
        checkpointAccountingInner(navT1);
        // Realized losses can consume Junior NAV backing Senior's de-peg protection.
        // Cover any resulting valuation shortfall after checkpointing.
        if (valuationPrice < 1e18) {
            _coverValuationLoss(valuationPrice);
        }
    }

    /// @dev Checkpoints PnL without topping up valuation coverage.
    ///      Keeping coverage separate lets valuation setters apply the new price first.
    function checkpointAccountingInner(uint256 navT1) internal {
        uint256 insuranceAmountT0 = insuranceAmount;
        (
            uint256 jrtNavT1Projected,
            uint256 jrtNavT1Real,
            uint256 srtNavT1,
            uint256 reserveNavT1,
            uint256 underwriterFeeNavT1,
            uint256 insuranceAmountT1
        ) = calculateNAVSplit(nav, jrtNavProjected, jrtBaseNav, srtBaseNav, reserveNav, underwriterFeeNav, insuranceAmount, navT1);
        updateIndex();
        if (navT1 != nav) {
            emit Reconciled(
                lastReconciliation,
                block.timestamp,
                nav,
                navT1,
                jrtNavT1Real,
                srtNavT1,
                reserveNavT1
            );
            lastReconciliation = block.timestamp;
            if (navT1 > feeWatermarkNav) {
                feeWatermarkNav = navT1;
            }
            if (valuationPrice < 1e18) {
                _scaleSrtFund(srtBaseNav, srtNavT1);
            }
        }

        nav = navT1;
        navTimestamp = block.timestamp;
        srtBaseNav = srtNavT1;
        jrtNavProjected = jrtNavT1Projected;
        // Require a decrease to the floor or below so an empty market does not suspend fees.
        if (jrtNavT1Real <= ONE_ASSET && jrtNavT1Real < jrtBaseNav) {
            _disablePerformanceFee();
        }
        jrtBaseNav = jrtNavT1Real;
        reserveNav = reserveNavT1;
        underwriterFeeNav = underwriterFeeNavT1;
        if (insuranceAmountT1 < insuranceAmountT0) {
            insuranceAmount = insuranceAmountT1;
            _syncInsuranceClaim();
        }

        if (insuranceAmountT1 > insuranceAmountT0) {
            uint256 newClaim = insuranceAmountT1 - insuranceAmountT0;
            uint256 covered = _slashNewClaim(newClaim);
            // insuranceAmountT1 is capped by insurancePool.request(), so coverAndSlash()
            // must cover the full new claim in the same transaction.
            require(covered == newClaim, "CoverageUnderfunded");
            insuranceAmount = insuranceAmountT1;
            emit InsuranceClaimed(covered, insuranceAmount);
        }
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

    /// @notice Calculates the target index for the current block
    function getSrtTargetIndexT1 () internal view returns (uint256) {
        return calculateTargetIndex(srtTargetIndex, indexTimestamp, block.timestamp, aprSrt);
    }

    /// @notice Calculates Junior's net target index for the current block
    function getNavTargetIndexT1 () internal view returns (uint256) {
        return calculateTargetIndex(navTargetIndex, indexTimestamp, block.timestamp, aprBase);
    }

    /// @notice Computes the accrual index at t1 given the prior index, elapsed time, and APR
    function calculateTargetIndex (uint256 targetIndex, uint256 t0, uint256 t1, UD60x18 apr) internal pure returns (uint256) {
        uint256 dt = t1 - t0;
        if (dt == 0) {
            return targetIndex;
        }
        // Calculate the interest factor: (APR * time elapsed) / seconds per year
        uint256 interestFactor = apr.unwrap() * dt / SECONDS_PER_YEAR;
        // Apply the interest factor to the initial target index
        // newIndex = oldIndex * (1 + interestFactor)
        uint256 targetIndexT1 = targetIndex * (1e18 + interestFactor) / 1e18;
        return targetIndexT1;
    }


    function calculateRiskPremium () internal view returns (UD60x18){
        (
            uint256 jrtEffective,
            uint256 srtEffective
        ) = calcEffectiveNav(jrtNavProjected, srtBaseNav);
        UD60x18 tvlRatio = UD60x18.wrap(srtEffective == 0 ? 0 : (srtEffective * 1e18 / (srtEffective + jrtEffective)));

        if (address(riskPremiumModel) != address(0)) {
            return riskPremiumModel.riskPremium(tvlRatio);
        }

        UD60x18 riskPremium = calculateRiskPremiumInner(riskX, riskY, riskK, tvlRatio);
        return riskPremium;
    }
    function calculateRiskPremiumInner (UD60x18 x, UD60x18 y, UD60x18 k, UD60x18 tvlRatioSrt) internal pure returns (UD60x18){
        // RiskPremium = x + y * TVL_ratio_sr ^ k
        UD60x18 riskPremium = x + y * pow(tvlRatioSrt, k);
        return riskPremium;
    }

    // Fetch APRs from Feed
    function fetchAprs () internal returns (bool modified, UD60x18 aprTargetT1, UD60x18 aprBaseT1) {
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

    function updateIndex () internal {
        srtTargetIndex = getSrtTargetIndexT1();
        navTargetIndex = getNavTargetIndexT1();
        indexTimestamp = block.timestamp;
    }
    function updateAprSrt (UD60x18 aprTarget_, UD60x18 aprBase_) internal {
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
    /// @dev Calculates the desired gain based on the change in target index over a period
    /// @return The calculated gain (positive) or loss (negative) as an int256
    function calculateGain (uint256 navT0, uint256 targetIndexT1, uint256 targetIndexT0) internal pure returns (int256) {
        // Gain = Assets * (TargetIndex1 / TargetIndex0 - 1);
        return int256(navT0 * targetIndexT1 / targetIndexT0) - int256(navT0);
    }

    /// @dev Converts APR from Feed's compact format (12 decimal places, stored in 1 SLOT) to UD60x18
    /// @dev Ensures the APR is within the acceptable range for Accounting
    /// @return The APR value as a UD60x18
    function normalizeAprFromFeed (/* SD7x12 */ int64 apr) internal pure returns (UD60x18) {
        if (apr < APR_FEED_BOUNDARY_MIN) {
            apr = APR_FEED_BOUNDARY_MIN;
        }
        if (apr > APR_FEED_BOUNDARY_MAX) {
            apr = APR_FEED_BOUNDARY_MAX;
        }
        return UD60x18.wrap(uint256(int256(apr)) * (10 ** (18 - APR_FEED_DECIMALS)));
    }


    /*****************************************************************************
     *                  External configuration Methods                           *
     *****************************************************************************/

    // Trigger fetching new APRs to update srtTargetIndex
    function onAprChanged () external onlyRole(UPDATER_FEED_ROLE)  {
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        syncAprs();
    }

    /// @notice Sets the risk premium parameters used in calculating the risk-adjusted APR
    /// @param riskX_ Base risk premium
    /// @param riskY_ Coefficient for the TVL ratio-dependent component
    /// @param riskK_ Exponent for the TVL ratio in the risk calculation
    /// @dev Only callable by accounts with UPDATER_STRAT_CONFIG_ROLE
    function setRiskParameters (
        UD60x18 riskX_,
        UD60x18 riskY_,
        UD60x18 riskK_
    ) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        riskX = riskX_;
        riskY = riskY_;
        riskK = riskK_;
        UD60x18 risk = calculateRiskPremiumInner(riskX_, riskY_, riskK_, UD60x18.wrap(1e18));
        require(risk.unwrap() <= PERCENTAGE_100, ">100%");
        emit RiskParametersChanged(riskX_, riskY_, riskK_);
        updateAprSrt(aprTarget, aprBase);
    }

    /// @notice Sets the optional external risk premium model.
    /// @dev Set to the zero address to use the legacy `x + y * TVL_ratio_sr^k` model.
    ///      Non-zero models must return less than 100% risk premium at full Senior TVL ratio.
    /// @param riskPremiumModel_ External model contract, or zero address for the legacy model.
    function setRiskModel (IRiskPremiumModel riskPremiumModel_) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        if (address(riskPremiumModel_) != address(0)) {
            UD60x18 risk = riskPremiumModel_.riskPremium(UD60x18.wrap(1e18));
            require(risk.unwrap() < PERCENTAGE_100, ">=100%");
        }
        riskPremiumModel = riskPremiumModel_;
        emit RiskModelChanged(address(riskPremiumModel_));
    }

    /// @notice Sets the APR feed contract for fetching APR target and APR base.
    /// @dev Finalizes accounting with the current feed before switching, then starts the new APR period.
    /// @param aprPairFeed_ The address of the new APR feed contract.
    function setAprPairFeed (IAprPairFeed aprPairFeed_) external onlyOwner {
        require(aprPairFeed_.decimals() == APR_FEED_DECIMALS, "InvalidFeed");
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        syncAprs();
        aprPairFeed = aprPairFeed_;
        emit AprPairFeedChanged(address(aprPairFeed_));
        syncAprs();
    }

    /// @notice Sets the percentage of gains allocated to the reserve
    /// @param bps The new reserve percentage in basis points (1e18 = 100%)
    /// @dev Only callable by the protocol owner
    /// @dev The maximum allowed value is defined by RESERVE_BPS_MAX
    function setReserveBps (uint256 bps) external onlyOwner {
        require(bps <= RESERVE_BPS_MAX && bps != reserveBps, "InvalidNewReserve");
        updateAccountingInner(cdo.totalStrategyAssets(nav, _navAnchor()));
        reserveBps = bps;
        emit ReservePercentageChanged(reserveBps);
    }

    /// @notice Sets the portion of fees from each tranche that is returned to its TVL. The remainder goes to the reserve.
    /// @param jrtRetentionBps The percentage of junior fees that is retained by the junior tranche TVL.
    /// @param srtRetentionBps The percentage of senior fees that is retained by the senior tranche TVL.
    function setFeeRetentionBps (uint256 jrtRetentionBps, uint256 srtRetentionBps) external onlyOwner {
        require(jrtRetentionBps <= PERCENTAGE_100, "InvalidJrtRetention");
        require(srtRetentionBps <= PERCENTAGE_100, "InvalidSrtRetention");
        feeJrtRetentionBps = jrtRetentionBps;
        feeSrtRetentionBps = srtRetentionBps;
        emit FeeRetentionChanged(feeJrtRetentionBps, feeSrtRetentionBps);
    }

    /// @notice Sets the hard minimum Jrt/Srt ratio below which Jrt withdrawals are blocked.
    function setMinimumJrtSrtRatio (uint256 ratio) external onlyOwner {
        // initial: min Jrt = .05x Srt; allow up-to min Jrt = 100x Srt
        require(ratio <= minimumJrtSrtRatioBuffer, "RatioAboveSoftFloor");
        minimumJrtSrtRatio = ratio;
        emit MinimumJrtSrtRatioChanged(ratio);
    }

    /// @notice Sets the protective buffer ratio at which Srt deposits are halted.
    function setMinimumJrtSrtRatioBuffer (uint256 ratio) external onlyOwner {
        // initial: min Jrt = .05x Srt; allow up-to min Jrt = 100x Srt
        require(ratio <= 100 * PERCENTAGE_100, "RatioTooHigh");
        require(ratio >= minimumJrtSrtRatio && ratio != 0, "RatioBelowHardFloor");
        minimumJrtSrtRatioBuffer = ratio;
        emit MinimumJrtSrtRatioBufferChanged(ratio);
    }

    /// @dev Suspends performance fees after a loss; only setReserveBps can re-enable them.
    function _disablePerformanceFee() internal {
        if (reserveBps == 0) {
            return;
        }
        reserveBps = 0;
        emit ReservePercentageChanged(0);
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
        }
        _resyncSrtFundNav(price);
        valuationPrice = price;
        valuationUpdatedAt = uint64(block.timestamp);
        if (valuationLossEntered) {
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
        extraNeeded = Math.saturatingSub(extraNeeded, srtFundNav);
        uint256 juniorAvailable = Math.saturatingSub(jrtBaseNav, ONE_ASSET);
        return Math.saturatingSub(extraNeeded, juniorAvailable);
    }

    /// @notice Sets the grace period
    function setValuationGracePeriod (uint64 period) external onlyRole(PAUSER_ROLE) {
        require(period <= 1 days, "GracePeriodTooLong");
        valuationGracePeriod = period;
        emit ValuationGracePeriodChanged(period);
    }


    /// @dev Write down self-funding only when fees or realized losses reduce Senior principal.
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
        srtFundAmountIn = Math.mulDiv(amount, 1e18 - valuationPrice, valuationPrice);
        srtFundedGrossNav += amount;
    }

    function _resyncSrtFundNav(uint128 price) internal {
        uint256 fundedGrossNav = srtFundedGrossNav;
        if (fundedGrossNav > 0) {
            if (price == 1e18) {
                srtFundedGrossNav = 0;
                srtFundNav = 0;
            } else {
                // Senior deposits self-fund only the valuation loss that existed at deposit time.
                // On further de-peg, Junior still covers the additional Senior loss.
                srtFundNav = Math.min(srtFundNav, Math.mulDiv(fundedGrossNav, 1e18 - price, price));
            }
        }
        // Size retained insurance using Senior's self-funded coverage at the new price.
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
            insuranceNeeded = Math.saturatingSub(insuranceNeeded, srtFundNav);
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
        }
    }

    /// @notice Calculates valuation-adjusted NAVs for Junior and Senior tranches
    /// @dev Applies the valuation loss adjustment mechanism where Junior absorbs Senior's valuation losses first.
    ///      The effective NAVs are **always calculated on-the-fly** from base NAVs and are never stored in state.
    ///      This design enables seamless recovery as valuation improves - no explicit rebalancing is required.
    ///
    ///      **Valuation Loss Mechanics:**
    ///      - When valuationPrice < 1e18, Senior's effective NAV is reduced proportionally
    ///      - Junior's effective NAV is reduced by the amount needed to cover Senior's shortfall
    ///      - Junior is protected by ONE_ASSET minimum to prevent complete depletion
    ///
    ///      **Recovery Behavior:**
    ///      - As valuationPrice → 1e18, effective NAVs converge back to base NAVs automatically
    ///      - No state changes or rebalancing transactions needed
    ///      - Recovery benefits all remaining participants proportionally
    ///
    ///      **Invariant Maintained:**
    ///      ```
    ///      jrtEffective + srtEffective == jrtFact + srtFact
    ///      ```
    function calcEffectiveNav (uint256 jrtFact, uint256 srtFact) internal view returns (uint256 jrtEffective, uint256 srtEffective) {
        if (valuationPrice == 1e18) {
            return (jrtFact, srtFact);
        }
        // srtFact already includes any Symbiotic de-peg credit, which is compensation rather than
        // principal: exclude it when sizing how many tokens Senior needs to be whole at this price.
        uint256 srtPrincipal = Math.saturatingSub(srtFact, srtInsuranceFundNav);
        uint256 extraNeeded = Math.saturatingSub(Math.mulDiv(srtPrincipal, 1e18, valuationPrice), srtFact);
        extraNeeded = Math.saturatingSub(extraNeeded, srtFundNav);
        uint256 extraTaken = Math.min(
            Math.saturatingSub(jrtFact, ONE_ASSET),
            extraNeeded
        );
        return (jrtFact - extraTaken, srtFact + extraTaken);
    }
}
