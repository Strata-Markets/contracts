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
    /// @dev Only used when useNavAtReconciliation is true. Passed to totalStrategyAssets so
    ///      sub-strategies gate their reward signal on this value, which only advances when
    ///      real rewards are detected — not on every deposit.
    uint256 public lastReconciliation;

    uint256[15] private __gap_DYSAccounting;

    /// @notice Optional external risk premium model.
    /// @dev When unset, accounting falls back to the legacy `x + y * TVL_ratio_sr^k`
    ///      model configured by `riskX`, `riskY`, and `riskK`.
    IRiskPremiumModel public riskPremiumModel;

    error InvalidNavSplit(uint256 navT1, uint256 jrtAssets, uint256 srtAssets, uint256 reserveAssets);
    error ReserveTooLow(uint256 reserveNav, uint256 requestedNav);

    event AprPairFeedChanged(address aprPairFeed);
    event AprDataChangedViaPush(UD60x18 aprTarget, UD60x18 aprBase);
    event ReservePercentageChanged(uint256 reserveBps);
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
        if (useNavAtReconciliation) {
            lastReconciliation = navTimestamp;
        }
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
            reserveNavT1
        ) = calculateNAVSplit(nav, jrtNavProjected, jrtBaseNav, srtBaseNav, reserveNav, navT1);
        (jrtNavT1Projected, srtNavT1) = calcEffectiveNav(jrtNavT1Projected, srtNavT1);
    }

    /// @notice Returns projected or reconciled amounts without projection unwind.
    /// @dev Unprojected redemption pricing is not supported. Use DYSAccounting if projection unwind is required.
    function totalAssetsUnprojected () external view returns (uint256 jrtNavUnprojected, uint256 srtNavUnprojected, uint256 reserveNavUnprojected) {
        return totalAssets();
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
    ) external onlyCDO {
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
        jrtBaseNav = jrtBaseNav + jrtAssetsIn - jrtAssetsOut;
        jrtNavProjected = jrtNavProjected + jrtAssetsIn - jrtAssetsOut;
        srtBaseNav = srtBaseNav + srtAssetsIn - srtAssetsOut;
        adjustFeeWatermark(jrtAssetsIn + srtAssetsIn, jrtAssetsOut + srtAssetsOut);
        nav = nav + jrtAssetsIn + srtAssetsIn - jrtAssetsOut - srtAssetsOut;
        navTimestamp = block.timestamp;
        (bool modified, UD60x18 aprTarget_, UD60x18 aprBase_) = fetchAprs();
        if (modified == false) {
            // Recalculates aprSrt based on new TVL ratio and old APRs
            updateAprSrt(aprTarget_, aprBase_);
        }
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
    /// 2. Allocates a portion of gains to the Reserve based on reserveBps
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

        uint256 navT1
    ) public view returns (uint256 jrtNavT1Projected, uint256 jrtNavT1Real, uint256 srtNavT1, uint256 reserveNavT1) {
        if (jrtNavT0Projected == 0 && srtNavT0 == 0 && navT1 > 0) {
            // No deposits yet, however Strategy reports gain, move all to reserve.
            return (0, 0, 0, navT1);
        }

        if (navT0 == navT1) {
            // Still no realized gain; process using the projection.
            return calculateNAVSplitProjected(
                navT0,
                jrtNavT0Projected,
                jrtNavT0Real,
                srtNavT0,
                reserveNavT0
            );
        }

        int256 gain_dT = int256(navT1) - int256(navT0);

        if (gain_dT < 0) {
            // Should never happen to USDe, jic: cover by Jrt, then Reserve, then Srt
            uint256 loss = uint256(-gain_dT);

            uint256 jrtLoss = Math.min(jrtNavT0Real, loss);

            loss -= jrtLoss;
            uint256 reserveLoss = Math.min(reserveNavT0, loss);

            loss -= reserveLoss;
            uint256 srtLoss = Math.min(srtNavT0, loss);
            // The market is considered abandoned if losses would consume the protected dust NAV
            require(srtLoss == loss, "NavBelowMinimum");

            jrtNavT0Real -= jrtLoss;
            srtNavT0  -= srtLoss;
            reserveNavT0 -= reserveLoss;
            gain_dT = 0;
        }
        uint256 gain_dTAbs = uint256(gain_dT);

        // #1 Final new reserve
        uint256 reserve_dT = 0;
        if (navT1 > feeWatermarkNav && reserveBps > 0) {
            uint256 feeableGain = navT1 - feeWatermarkNav;
            reserve_dT = feeableGain * reserveBps / PERCENTAGE_100;
            gain_dTAbs -= reserve_dT;
        }
        reserveNavT1 = reserveNavT0 + reserve_dT;

        // Allocate the full gain (if any) to Juniors; later, subtract Seniors' target gain from Juniors.
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

        // #2 Final new Jrt
        jrtNavT1Real = jrtNavT1Real - srtGainTargetAbs;
        jrtNavT1Projected = jrtNavT1Real;

        // #3 Final new Srt
        srtNavT1 = srtNavT0 + srtGainTargetAbs;

        if (navT1 != (jrtNavT1Real + srtNavT1 + reserveNavT1)) {
            revert InvalidNavSplit(navT1, jrtNavT1Real, srtNavT1, reserveNavT1);
        }

        return (jrtNavT1Projected, jrtNavT1Real, srtNavT1, reserveNavT1);
    }

    function calculateNAVSplitProjected (
        uint256 navT0,
        uint256 jrtNavT0Projected,
        uint256 jrtNavT0Real,
        uint256 srtNavT0,
        uint256 reserveNavT0
    ) internal view returns (
        uint256 jrtNavT1Projected,
        uint256 jrtNavT1Real,
        uint256 srtNavT1,
        uint256 reserveNavT1
    ) {
        if (jrtNavT0Projected == 0 && srtNavT0 == 0) {
            // No deposits yet, the projected NAV remain 0.
            return (0, 0, 0, 0);
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
                reserveNavT1
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

        // Allocate the full gain (if any) to Juniors; later, subtract Seniors' target gain from Juniors.
        jrtNavT1Projected = jrtNavT0Projected + gain_dTAbs;

        // Calculate Srt gain
        uint256 srtTargetIndexT1 = getSrtTargetIndexT1();
        // Gain = Assets * (TargetIndex1 / TargetIndex0 - 1);
        int256 srtGainTarget = calculateGain(srtNavT0, srtTargetIndexT1, srtTargetIndex);
        if (srtGainTarget < 0) {
            // Should never happen, jic: transfer the loss to Juniors as profit
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


        // #2 Final new Jrt (after srt funding)
        jrtNavT1Projected = jrtNavT1Projected - srtGainTargetAbs;
        jrtNavT1Real = Math.saturatingSub(jrtNavT0Real, srtGainTargetAbs);

        // #3 Final new Srt
        srtNavT1 = srtNavT0 + srtGainTargetAbs;

        // #4 No changes to NAV and reserve on Projection
        reserveNavT1 = reserveNavT0;

        return (
            jrtNavT1Projected,
            jrtNavT1Real,
            srtNavT1,
            reserveNavT1
        );
    }

    function updateAccountingInner (uint256 navT1) internal {
        (
            uint256 jrtNavT1Projected,
            uint256 jrtNavT1Real,
            uint256 srtNavT1,
            uint256 reserveNavT1
        ) = calculateNAVSplit(nav, jrtNavProjected, jrtBaseNav, srtBaseNav, reserveNav, navT1);
        updateIndex();
        if (useNavAtReconciliation && navT1 != nav) lastReconciliation = block.timestamp;
        if (navT1 != nav && navT1 > feeWatermarkNav) {
            feeWatermarkNav = navT1;
        }
        nav = navT1;
        navTimestamp = block.timestamp;
        srtBaseNav = srtNavT1;
        jrtNavProjected = jrtNavT1Projected;
        jrtBaseNav = jrtNavT1Real;
        reserveNav = reserveNavT1;
    }

    /// @notice Calculates the target index for the current block
    function getSrtTargetIndexT1 () internal view returns (uint256) {
        return calculateTargetIndex(srtTargetIndex, indexTimestamp, block.timestamp, aprSrt);
    }

    /// @notice Calculates the Juniors NET target index for the current block
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

    /// @notice Sets the valuation price for the base asset.
    function setValuationPrice (uint128 price) external onlyCDO returns (bool){
        bool isValuationLossPeriod = valuationPrice < 1e18;
        bool valuationLossEntered = isValuationLossPeriod == false && price < 1e18;
        // Allow the valuation price in range 0.0001-1
        require(0.0001e18 <= price && price <= 1e18, "InvalidValuationPrice");
        _resyncSrtFundNav(price);
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


    function _trackSrtFundNavIn(uint256 amount) internal returns (uint256 srtFundAmountIn) {
        if (amount == 0 || valuationPrice == 1e18) {
            return 0;
        }
        srtFundAmountIn = Math.mulDiv(amount, 1e18 - valuationPrice, valuationPrice);
        srtFundedGrossNav += amount;
    }

    function _resyncSrtFundNav(uint128 price) internal {
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
        uint256 extraNeeded = srtFact * (1e18 - valuationPrice) / valuationPrice;
        extraNeeded = Math.saturatingSub(extraNeeded, srtFundNav);
        uint256 extraTaken = Math.min(
            Math.saturatingSub(jrtFact, ONE_ASSET),
            extraNeeded
        );
        return (jrtFact - extraTaken, srtFact + extraTaken);
    }
}
