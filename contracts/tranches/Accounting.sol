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
 * @title CDO::Accounting
 * @dev Pure math contract to track the in-flow and out-flow of assets and balance the gain/loss between Junior (Jrt) and Senior (Srt) Tranche Value Locked (TVL).
 */
contract Accounting is IAccounting, CDOComponent {
    uint256 private constant MIGRATION_V2 = 1 << 0;

    uint256 constant SECONDS_PER_YEAR = 31_536_000;

    int64   private constant APR_FEED_BOUNDARY_MAX = 2e12; // 200%
    int64   private constant APR_FEED_BOUNDARY_MIN = 0;
    uint256 private constant APR_FEED_DECIMALS = 12;
    uint256 private immutable ONE_ASSET;

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

     /** DiscreteAccounting Storage Compatibility **/
    uint256 private navTargetIndex;
    uint256 private navTimestamp;
    uint256 private jrtNavProjected;


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

    /// @notice Remaining self-funding recorded at entry, capped at the current valuation loss when used.
    /// @dev Per-entry valuation recovery is not bucketed; small mismatches are socialized through the Senior share price.
    uint256 public srtFundNav;

    /// @notice High-water mark used to charge performance fees only on new NAV gains.
    uint256 public feeWatermarkNav;

    uint256[16] private __gap_DYSAccounting;

    /// @notice Optional external risk premium model.
    /// @dev When unset, accounting falls back to the legacy `x + y * TVL_ratio_sr^k`
    ///      model configured by `riskX`, `riskY`, and `riskK`.
    IRiskPremiumModel public riskPremiumModel;

    /* Underwriter Fee (Symbiotic) Parameters */

    /// @notice Share of raw Senior risk premium used to derive the underwriter fee rate (1e18 = 100%)
    /// @dev underwriterFeePct = riskPremium * underwriterFeeBps / 1e18, applied to positive Senior PnL.
    uint256 public underwriterFeeBps;

    /// @notice Accrued underwriter fee owed to underwriters, not yet paid out
    /// @dev Reduced by `reduceUnderwriterFee()` when the CDO pays underwriter fee to the insurance middleware
    uint256 public underwriterFeeNav;

    /// @notice Coverage claimed from the insurance pool but not yet settled, in base assets
    /// @dev Holds a covered tranche whole against real assets that have not arrived yet, so the
    ///      NAV identity carries a `- insuranceAmount` term:
    ///          navT1 = jrtBaseNav + srtBaseNav + reserveNav + underwriterFeeNav - insuranceAmount
    ///      Increases when a loss is covered in `calculateNAVSplit()`, decreases when a later gain
    ///      unwinds the claim, and is cleared as redeeming Seniors are paid their covered slice from
    ///      the InsuranceVault. Read by the insurance middleware to size coverage slashes.
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

    constructor (uint256 navDecimals) {
        ONE_ASSET = 10 ** navDecimals;
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
        indexTimestamp = block.timestamp;
        minimumJrtSrtRatio = 0.05e18;
        minimumJrtSrtRatioBuffer = 0.06e18;
        valuationPrice = 1e18;
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
        migrationBitmap |= MIGRATION_V2;
    }

    /// @notice Returns the updated total assets for each tranche and the reserve
    /// @dev This method is used by the Tranches to get their updated total assets for the current block
    /// @param navT1 The current total Net Asset Value
    /// @return jrtNavT1 The updated Junior Tranche TVL
    /// @return srtNavT1 The updated Senior Tranche TVL
    /// @return reserveNavT1 The updated Reserve TVL
    function totalAssets (uint256 navT1) public view returns (uint256 jrtNavT1, uint256 srtNavT1, uint256 reserveNavT1) {
        (
            jrtNavT1,
            srtNavT1,
            reserveNavT1,
            /* underwriterFeeNavT1 */,
            /* insuranceAmountT1 */
        ) = calculateNAVSplit(nav, jrtBaseNav, srtBaseNav, reserveNav, underwriterFeeNav, insuranceAmount, navT1);

        (jrtNavT1, srtNavT1) = calcEffectiveNav(jrtNavT1, srtNavT1);
    }

    /// @notice Returns current amounts; continuous accounting has no projection.
    function totalAssetsSettled () external view returns (uint256 jrtNavSettled, uint256 srtNavSettled, uint256 reserveNavSettled) {
        return totalAssets();
    }

    /// @notice Returns current amounts for both; continuous accounting has no projection.
    function totalAssetsLiveAndSettled () external view returns (
        uint256 jrtNavLive,
        uint256 srtNavLive,
        uint256,
        uint256
    ) {
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
    /// @dev Actively reads NAV from the strategy.
    /// @return jrtNavT1 The updated Junior Tranche TVL
    /// @return srtNavT1 The updated Senior Tranche TVL
    /// @return reserveNavT1 The updated Reserve TVL
    function totalAssets () public view returns (uint256 jrtNavT1, uint256 srtNavT1, uint256 reserveNavT1) {
        return totalAssets(cdo.totalStrategyAssets());
    }

    /// @notice Returns the current saved total assets for each tranche and the reserve
    /// @dev These values represent the state at the last update, not necessarily the current block
    /// @return jrtNavT0 The last saved Junior Tranche TVL
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
        (,,uint256 reserveNavT1) = totalAssets(cdo.totalStrategyAssets());
        return reserveNavT1;
    }

    /// @notice Returns the current accrued underwriter fee value
    /// @dev This method returns the maximum amount that `reduceUnderwriterFee` can handle
    /// @return underwriterFeeNavT1 The current underwriter fee Net Asset Value (NAV)
    function totalUnderwriterFeeNav () external view returns (uint256 underwriterFeeNavT1) {
        (,,, underwriterFeeNavT1, ) = calculateNAVSplit(nav, jrtBaseNav, srtBaseNav, reserveNav, underwriterFeeNav, insuranceAmount, cdo.totalStrategyAssets());
    }

    function srtNav () external view returns (uint256 srtNavEffective) {
        (, srtNavEffective) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
    }

    function jrtNav () external view returns (uint256 jrtNavEffective) {
        (jrtNavEffective,) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
    }

    /// @notice Reduces the reserve by the specified amount
    /// @dev This function is called by the CDO contract to reduce the reserve
    /// @dev The CDO contract is responsible for withdrawing the appropriate amount to the treasury
    /// @param amount The amount by which to reduce the reserve NAV
    /// @param jrtAmountIn The amount to be credited to the Junior Tranche
    /// @param srtAmountIn The amount to be credited to the Senior Tranche
    function reduceReserve (uint256 amount, uint256 jrtAmountIn, uint256 srtAmountIn) external onlyCDO {
        updateAccountingInner(cdo.totalStrategyAssets());
        if (amount > reserveNav) {
            revert ReserveTooLow(reserveNav, amount);
        }
        if (amount < (jrtAmountIn + srtAmountIn)) {
            revert ReserveTooLow(amount, jrtAmountIn + srtAmountIn);
        }
        reserveNav = reserveNav - amount;
        adjustFeeWatermark(jrtAmountIn + srtAmountIn, amount);
        nav = nav + jrtAmountIn + srtAmountIn - amount;
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


    /// @notice Reduces the accrued underwriter fee by the specified amount
    /// @dev This function is called by the CDO contract when paying underwriter fee to the insurance middleware
    /// @dev The CDO contract is responsible for withdrawing the corresponding tokens to the middleware
    /// @param amount The amount by which to reduce the underwriter fee NAV
    function reduceUnderwriterFee (uint256 amount) external onlyCDO {
        updateAccountingInner(cdo.totalStrategyAssets());

        if (amount > underwriterFeeNav) {
            revert UnderwriterFeeTooLow(underwriterFeeNav, amount);
        }

        underwriterFeeNav -= amount;
        nav -= amount;

        emit UnderwriterFeeReduced(amount);
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

    /// @notice Updates the accounting for the CDO, calculating new TVL split
    /// @dev This method should be called before any deposits or withdrawals in tranches
    /// @dev It calculates the new TVL split, allowing tranches to accurately calculate their share prices
    /// @param navT1 The current total assets (Net Asset Value) held by the CDO in the strategy
    function updateAccounting (uint256 navT1) external onlyCDO {
        updateAccountingInner(navT1);
    }

    /// @notice Updates the accounting for the CDO, calculating new TVL split
    /// @dev This method reads the current strategy TVL and updates accounting.
    function updateAccounting () external onlyCDO {
        updateAccountingInner(cdo.totalStrategyAssets());
    }

    /// @notice Sizes an unfunded realized-loss claim write-down as a permanent Senior principal loss.
    /// @dev CDO checkpoints first and supplies the vault funding valued in base assets.
    ///      The operator must finalize available slash proceeds and confirm that further funding is unavailable.
    ///      Sizing includes any additional valuation-credit unwind; the whole call reverts if the limit is too low.
    /// @param fundedBase Available vault funding, in base-asset units at the current valuation price.
    /// @param maxPrincipalLoss Maximum principal loss the operator accepts, excluding valuation-credit unwind.
    /// @return amount Principal loss recognized; zero if no principal loss is needed.
    function writeDownInsuranceClaim(uint256 fundedBase, uint256 maxPrincipalLoss) external onlyCDO returns (uint256 amount) {
        uint256 seniorAvailable = srtBaseNav;
        if (fundedBase >= insuranceAmount) {
            return 0;
        }
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
        // Reduced principal can need less valuation credit; release it before checking funding.
        if (valuationPrice < 1e18) {
            _resyncInsuranceFundNav(valuationPrice);
        }
        require(insuranceAmount <= fundedBase, "InsuranceShortfallUnresolved");
        _syncInsuranceClaim();
        updateAprSrt(aprTarget, aprBase);
        emit InsuranceClaimWrittenDown(amount);
    }

    /// @notice Updates the Net Asset Values (NAVs) after deposits or withdrawals
    /// @dev This method should be called after any deposits or withdrawals are made in the tranches
    /// @dev It adjusts the NAVs for both Junior and Senior tranches, as well as the total NAV
    /// @param jrtAssetsIn Amount of assets deposited into the Junior tranche
    /// @param jrtAssetsOut Amount of assets withdrawn from the Junior tranche
    /// @param srtAssetsIn Amount of assets deposited into the Senior tranche
    /// @param srtAssetsOut Amount of assets withdrawn from the Senior tranche
    /// @return insuranceBaseOut The share of the outstanding coverage claim that leaves with this
    ///         Senior outflow, in base assets. The CDO pays it from the insurance vault instead of
    ///         the strategy, so it is already excluded from the nav reduction here.
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
        srtBaseNav = srtBaseNav + srtAssetsIn - srtAssetsOut;
        // Net the vault-paid slice out of the Senior outflow first: only this much actually leaves
        // the strategy, and subtracting the full outflow from nav could underflow on the way.
        uint256 srtAssetsOutFromStrategy = srtAssetsOut - insuranceBaseOut_;
        adjustFeeWatermark(
            jrtAssetsIn + srtAssetsIn,
            jrtAssetsOut + srtAssetsOutFromStrategy
        );
        nav = nav + jrtAssetsIn + srtAssetsIn - jrtAssetsOut - srtAssetsOutFromStrategy;
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
    /// @param jrtNavT0 Junior tranche NAV at the previous timestamp
    /// @param srtNavT0 Senior tranche NAV at the previous timestamp
    /// @param reserveNavT0 Reserve NAV at the previous timestamp
    /// @param underwriterFeeNavT0 Underwriter fee NAV at the previous timestamp
    /// @param navT1 Current total Net Asset Value
    /// @return jrtNavT1 Updated Junior tranche NAV
    /// @return srtNavT1 Updated Senior tranche NAV
    /// @return reserveNavT1 Updated Reserve NAV
    /// @return underwriterFeeNavT1 Updated Underwriter fee NAV
    function calculateNAVSplit (
        uint256 navT0,
        uint256 jrtNavT0,
        uint256 srtNavT0,
        uint256 reserveNavT0,
        uint256 underwriterFeeNavT0,
        uint256 insuranceAmountT0,

        uint256 navT1
    ) public view returns (
        uint256 jrtNavT1,
        uint256 srtNavT1,
        uint256 reserveNavT1,
        uint256 underwriterFeeNavT1,
        uint256 insuranceAmountT1
    ) {
        insuranceAmountT1 = insuranceAmountT0;

        if (jrtNavT0 == 0 && srtNavT0 == 0 && navT1 > 0) {
            // No deposits yet, however Strategy reports gain, move all to reserve; keep accrued
            // underwriter fee. Underwriter fee is capped to the remaining assets: after a wipeout that left assets
            // below the accrued underwriter fee, the bucket absorbs the shortfall instead of underflowing.
            uint256 underwriterFeeKept = Math.min(navT1, underwriterFeeNavT0);
            return (0, 0, navT1 - underwriterFeeKept, underwriterFeeKept, insuranceAmountT0);
        }
        int256 gain_dT = int256(navT1) - int256(navT0);

        if (gain_dT < 0) {
            // Loss waterfall: Jrt absorbs first (down to its dust floor), then the reserve. Only the
            // remaining Senior-bound loss is requested from the coverage pool: Srt is held whole and
            // the covered amount is booked to insuranceAmount (the compensation owed for the Senior
            // loss that would otherwise land on the tranches), settled later. The underwriter fee bucket
            // never absorbs losses.
            uint256 loss = uint256(-gain_dT);

            uint256 jrtLoss = Math.min(
                Math.saturatingSub(jrtNavT0, ONE_ASSET),
                loss
            );

            loss -= jrtLoss;
            uint256 reserveLoss = Math.min(reserveNavT0, loss);

            loss -= reserveLoss;

            // Coverage absorbs the Senior-bound remainder so Srt stays whole.
            uint256 covered = _requestInsurance(loss);
            loss -= covered;

            uint256 srtLoss = Math.min(srtNavT0, loss);
            // The market is considered abandoned if losses would consume the protected dust NAV
            require(srtLoss == loss, "NavBelowMinimum");

            jrtNavT0 -= jrtLoss;
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

        // Reserve skims from the total gain. The underwriter fee is charged only on Senior gain below.

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
        jrtNavT1 = jrtNavT0 + gain_dTAbs;

        // Calculate Srt gain
        uint256 srtTargetIndexT1 = getSrtTargetIndexT1();
        // Gain = Assets * (TargetIndex1 / TargetIndex0 - 1);
        int256 srtGainTarget = calculateGain(srtNavT0, srtTargetIndexT1, srtTargetIndex);


        if (srtGainTarget < 0) {
            // Should never happen, jic: transfer the loss to Juniors as profit
            uint256 loss = uint256(-srtGainTarget);
            uint256 srtLoss = Math.min(srtNavT0, loss);

            srtNavT0 -= srtLoss;
            jrtNavT1 += srtLoss;
            srtGainTarget = 0;
        }
        uint256 srtGainTargetAbs = Math.min(
            uint256(srtGainTarget),
            Math.saturatingSub(jrtNavT1, ONE_ASSET)
        );
        if (valuationPrice < 1e18 && srtGainTargetAbs > 0) {
            // Junior must fund both the gain and its de-peg protection.
            (uint256 jrtEffective,) = calcEffectiveNav(jrtNavT1, srtNavT0);
            uint256 maxProtectedGain = Math.mulDiv(Math.saturatingSub(jrtEffective, ONE_ASSET), valuationPrice, 1e18);
            srtGainTargetAbs = Math.min(srtGainTargetAbs, maxProtectedGain);
        }

        uint256 underwriterFee_dT = 0;
        if (srtGainTargetAbs > 0 && underwriterFeeBps > 0) {
            uint256 underwriterFeePct = calculateRiskPremium().unwrap() * underwriterFeeBps / PERCENTAGE_100;
            underwriterFee_dT = srtGainTargetAbs * underwriterFeePct / PERCENTAGE_100;
            underwriterFeeNavT1 += underwriterFee_dT;
        }

        // #2 Final new Jrt
        jrtNavT1 = jrtNavT1 - srtGainTargetAbs;
        // #3 Final new Srt
        srtNavT1 = srtNavT0 + srtGainTargetAbs - underwriterFee_dT;


        // Coverage holds a tranche whole against assets not yet injected, hence the added term:
        //   navT1 + insuranceAmountT1 == jrtNavT1 + srtNavT1 + reserveNavT1 + underwriterFeeNavT1
        if (navT1 + insuranceAmountT1 != (jrtNavT1 + srtNavT1 + reserveNavT1 + underwriterFeeNavT1)) {
            revert InvalidNavSplit(navT1, jrtNavT1, srtNavT1, reserveNavT1, underwriterFeeNavT1);
        }

        return (jrtNavT1, srtNavT1, reserveNavT1, underwriterFeeNavT1, insuranceAmountT1);
    }

    /// @dev Queries the insurance pool for how much of `loss` it can currently cover.
    ///      View only: reserves nothing. Returns 0 when no pool is configured.
    function _requestInsurance (uint256 loss) internal view returns (uint256) {
        if (loss == 0 || address(insurancePool) == address(0)) {
            return 0;
        }
        return insurancePool.request(address(cdo), loss);
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
            uint256 jrtNavT1,
            uint256 srtNavT1,
            uint256 reserveNavT1,
            uint256 underwriterFeeNavT1,
            uint256 insuranceAmountT1
        ) = calculateNAVSplit(nav, jrtBaseNav, srtBaseNav, reserveNav, underwriterFeeNav, insuranceAmount, navT1);
        updateIndex();
        if (navT1 > feeWatermarkNav) {
            feeWatermarkNav = navT1;
        }
        nav = navT1;
        // Require a decrease to the floor or below so an empty market does not suspend fees.
        if (jrtNavT1 <= ONE_ASSET && jrtNavT1 < jrtBaseNav) {
            _disablePerformanceFee();
        }
        if (valuationPrice < 1e18) {
            _scaleSrtFund(srtBaseNav, srtNavT1);
        }
        jrtBaseNav = jrtNavT1;
        srtBaseNav = srtNavT1;
        reserveNav = reserveNavT1;
        underwriterFeeNav = underwriterFeeNavT1;
        if (insuranceAmountT1 < insuranceAmountT0) {
            insuranceAmount = insuranceAmountT1;
            // Sync only decreases; increases are tracked by coverAndSlash via _slashNewClaim below.
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
        ) = calcEffectiveNav(jrtBaseNav, srtBaseNav);
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
        updateAccountingInner(cdo.totalStrategyAssets());
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
        updateAccountingInner(cdo.totalStrategyAssets());
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
        updateAccountingInner(cdo.totalStrategyAssets());
        if (address(riskPremiumModel_) != address(0)) {
            UD60x18 risk = riskPremiumModel_.riskPremium(UD60x18.wrap(1e18));
            require(risk.unwrap() < PERCENTAGE_100, ">=100%");
        }
        riskPremiumModel = riskPremiumModel_;
        emit RiskModelChanged(address(riskPremiumModel_));
        updateAprSrt(aprTarget, aprBase);
    }

    /// @notice Sets the APR feed contract for fetching APR target and APR base.
    /// @dev Finalizes accounting with the current feed before switching, then starts the new APR period.
    /// @param aprPairFeed_ The address of the new APR feed contract.
    function setAprPairFeed (IAprPairFeed aprPairFeed_) external onlyOwner {
        require(aprPairFeed_.decimals() == APR_FEED_DECIMALS, "InvalidFeed");
        updateAccountingInner(cdo.totalStrategyAssets());
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
        updateAccountingInner(cdo.totalStrategyAssets());
        reserveBps = bps;
        emit ReservePercentageChanged(reserveBps);
    }

    /// @notice Sets the share of raw Senior risk premium used for the underwriter fee rate
    /// @param bps The new underwriter fee percentage in basis points (1e18 = 100%)
    /// @dev Only callable by the CDO, which relays the rate from the Symbiotic insurance middleware
    /// @dev The maximum allowed value is defined by UNDERWRITER_FEE_BPS_MAX
    function setUnderwriterFeeBps (uint256 bps) external onlyCDO {
        require(bps <= UNDERWRITER_FEE_BPS_MAX && bps != underwriterFeeBps, "InvalidNewUnderwriterFee");
        updateAccountingInner(cdo.totalStrategyAssets());
        underwriterFeeBps = bps;
    }

    /// @notice Sets the Symbiotic insurance pool queried for coverage.
    /// @dev Setting address(0) disables coverage; losses then hit the tranches as usual.
    function setInsurancePool (IInsurancePool insurancePool_) external onlyCDO {
        updateAccountingInner(cdo.totalStrategyAssets());
        insurancePool = insurancePool_;
    }

    /// @notice Sets the portion of fees from each tranche that is returned to its TVL. The remainder goes to the reserve.
    /// @param jrtRetentionBps The percentage of junior fees that is retained by the junior tranche TVL.
    /// @param srtRetentionBps The percentage of junior fees that is retained by the senior tranche TVL.
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
        checkpointAccountingInner(cdo.totalStrategyAssets());
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
        extraNeeded = Math.saturatingSub(extraNeeded, _cappedSrtFundNav(price));
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

    /// @dev Entry self-funding usable at this price, without erasing it on partial recovery.
    function _cappedSrtFundNav(uint256 price) internal view returns (uint256) {
        if (price >= 1e18) return 0;
        return Math.min(srtFundNav, Math.mulDiv(srtFundedGrossNav, 1e18 - price, price));
    }

    function _resyncSrtFundNav(uint128 price) internal {
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
            // Total coverage needed, before deducting existing insurance.
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
        }
    }

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
}
