// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UD60x18} from "@prb/math/src/ud60x18/Math.sol";
import {IAccountingState} from "../interfaces/IAccountingState.sol";
import {IAprPairFeed} from "../interfaces/IAprPairFeed.sol";
import {CDOComponent} from "../base/CDOComponent.sol";
import {IRiskPremiumModel} from "./premium/IRiskPremiumModel.sol";
import {IInsurancePool} from "../symbiotic/interfaces/IInsurancePool.sol";

/// @title AccountingStorage
/// @notice State variables of MTMAccounting and DYSAccounting, shared with AccountingSetters so all use the exact layout.
/// @dev Order and types MUST NOT change: deployed proxies rely on these slots. Append only.
abstract contract AccountingStorage is CDOComponent, IAccountingState {

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

    /// @dev Deprecated legacy risk parameters, kept for storage layout; see riskPremiumModel.
    UD60x18 private __deprecatedRiskX;
    UD60x18 private __deprecatedRiskY;
    UD60x18 private __deprecatedRiskK;

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

    /// @notice Remaining entry loss in USD, scaled to base-asset decimals; converted and capped when used.
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

    /// @notice Signed Senior projection for the epoch, including projection already paid out.
    int256 public srtPnLProjected;

    /// @notice Asset-time of positive unpaid Senior projection.
    /// @dev Negative projection is restored directly when accruing srtNavTime.
    uint256 public srtProjectedPnLTime;

    /// @notice Projection paid during this epoch that is not offset by projection purchased by deposits.
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
    ///      A zero starting rate uses proportional NAV-time allocation for that epoch, even in rate mode.
    uint256 public strategyRate;

    /// @notice External risk premium model; when unset, Senior pays no risk premium.
    IRiskPremiumModel public riskPremiumModel;

    /* Underwriter Fee (Symbiotic) Parameters */

    /// @notice Share of raw Senior risk premium used to derive the underwriter fee rate (1e18 = 100%)
    uint256 public underwriterFeeBps;

    /// @notice Accrued underwriter fee owed to underwriters, not yet paid out (part of nav)
    uint256 public underwriterFeeNav;

    /// @notice Coverage claimed from the insurance pool but not yet settled, in base assets
    /// @dev Holds Senior whole against assets not yet in the strategy, so the NAV identity carries a
    ///      `- insuranceAmount` term. Cleared as redeeming Seniors are paid their covered slice from
    ///      the InsuranceVault. See base Accounting for the full model.
    uint256 public insuranceAmount;

    /// @notice The Symbiotic insurance pool queried for coverage
    /// @dev When unset (address(0)) no coverage is requested and losses hit the tranches as usual.
    IInsurancePool public insurancePool;

    /// @notice Portion of the Senior valuation loss (base-asset de-peg) covered by Symbiotic.
    /// @dev Tops Senior up in calcEffectiveNav for the de-peg loss Junior could not absorb, so Senior
    ///      reads whole. It is external capital backed by slashed collateral and tracked in
    ///      insuranceAmount. Booked in setValuationPrice, unwound on re-peg in _resyncsrtFundNav.
    uint256 public srtInsuranceFundNav;

    struct BoughtProjection {
        // Signed net purchases, excluded from unrealized PnL and matched on exits.
        int128 net;
        // Unmatched purchased losses. Purchased gains equal net + int256(losses).
        uint128 losses;
    }

    /// @dev Live-priced Senior purchases for the epoch; both fields occupy one slot.
    BoughtProjection public srtBoughtProjection;

}
