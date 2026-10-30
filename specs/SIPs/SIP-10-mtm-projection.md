---
SIP: 10
Title: MTM Projection Accounting
Author: Strata Protocol Contributors
Status: Draft
Type: Protocol
Replaces: SIP-09
Created: 2026-09-03
---

# SIP-10: MTM Projection Accounting

## 1. Abstract

This specification defines `MTMAccounting`, a Dynamic Yield Split accounting variant where intra-epoch projection is driven by strategy-reported mark-to-market NAV instead of expected APR accrual.

The accounting layer MUST distinguish:

- **Epoch NAV**: the latest settled NAV available for reconciliation.
- **MTM NAV**: the latest live mark-to-market NAV available during the open epoch.
- **Epoch Price**: tranche share price derived from settled tranche NAV.
- **MTM Price**: tranche share price derived from live MTM-projected tranche NAV.

When conservative pricing is enabled, deposits MUST use the worse entry price for the depositor:

```text
deposit price = max(Epoch Price, MTM Price)
```

Redemptions MUST use the worse exit price for the redeemer:

```text
redemption price = min(Epoch Price, MTM Price)
```

This prevents deposits from minting at stale low prices during MTM gains and prevents redemptions from exiting at stale high prices during MTM losses.

---

## 2. Supersession

This SIP replaces SIP-09. SIP-09 specified only conservative redemption pricing for `DYSAccounting`, where live tranche NAV was produced by APR-indexed projection and redemptions used settled NAV to make unreconciled projected gains non-withdrawable.

`MTMAccounting` generalizes that rule for MTM-based projection. It introduces both Epoch Price and MTM Price for each tranche, and applies conservative pricing symmetrically:

- deposits and mints use `max(Epoch Price, MTM Price)`,
- withdrawals and redemptions use `min(Epoch Price, MTM Price)`.

Therefore SIP-10 is the active specification for conservative tranche pricing when MTM projection is enabled. SIP-09 remains historical context for the settled-redemption rule used with APR-projected DYS accounting.

---

## 3. Motivation

APR-indexed projection assumes smooth yield accrual between oracle updates. That works for predictable yield strategies, but it is not accurate for strategies whose economic value changes through a live market price before the next settled NAV checkpoint.

`MTMAccounting` keeps the existing DYS true-up model but replaces the intra-epoch projection source:

- DYS projection estimates NAV using expected APR.
- MTM projection estimates NAV using the strategy's current MTM NAV.
- Settled NAV still controls reconciliation and final realized accounting.

The result is a live tranche price that reacts to strategy MTM movements while preserving epoch-based settlement and reconciliation.

---

## 4. Terminology

- **`navT0`**: Stored total settled NAV from the previous accounting state.
- **`navT1`**: Strategy-reported settled NAV for the next reconciliation point.
- **`navT1Timestamp`**: Timestamp represented by `navT1`.
- **`navMTM`**: Strategy-reported live mark-to-market NAV.
- **`navMTMTimestamp`**: Timestamp represented by `navMTM`.
- **Live NAV**: Tranche NAV returned by `totalAssets()` after applying projection, including MTM projection when enabled.
- **Settled NAV**: Tranche NAV returned by `totalAssetsSettled()`, excluding unrealized MTM projection.
- **Depositable NAV**: Tranche NAV used by deposit and mint previews.
- **Redeemable NAV**: Tranche NAV used by withdraw and redeem previews.

---

## 5. Strategy Snapshot Interface

Strategies MUST expose both settled and MTM NAV through `totalAssetsSnapshot(latestNav, timestamp)`:

```solidity
function totalAssetsSnapshot(
    uint256 latestNav,
    uint256 timestamp
) external view returns (
    uint256 navT1,
    uint256 navT1Timestamp,
    uint256 navMTM,
    uint256 navMTMTimestamp
);
```

The default strategy implementation SHOULD derive:

```text
navMTM     = totalAssets()
navMTMTimestamp = block.timestamp
navT1      = totalAssets(latestNav, timestamp)
navT1Timestamp  = navMTM != navT1 ? timestamp : navMTMTimestamp
```

The strategy is responsible for notifying accounting about both:

- settled NAV, used for reconciliation, and
- MTM NAV, used for live projection during the open epoch.

Snapshot validity requirements:

- `navMTMTimestamp` MUST be greater than or equal to `navT1Timestamp`.
- If `navMTMTimestamp == navT1Timestamp`, then `navMTM` MUST equal `navT1`.
- The accounting timestamp MUST NOT move backwards before `lastAccrual`.

Invalid snapshots MUST revert with `InvalidAssetsSnapshot`.

---

## 6. MTMAccounting

`MTMAccounting` SHOULD preserve the DYS accounting model:

- asset-time tracking,
- Senior true-up at reconciliation,
- Senior floor support,
- benchmark projection mode,
- rate-based reconciliation mode,
- valuation loss handling,
- reserve fee and high-watermark handling,
- Junior/Senior flow accounting.

It introduces `useMTMProjection`:

```text
useMTMProjection = true  -> projection uses navMTM
useMTMProjection = false -> projection uses APR-indexed DYS projection
```

It also introduces `useConservativePrice`, which controls whether tranche ERC4626 previews use depositable/redeemable NAV or regular live NAV.

---

## 7. View Methods

The accounting contract MUST expose:

```solidity
function totalAssets()
    external
    view
    returns (
        uint256 jrtNavLive,
        uint256 srtNavLive,
        uint256 reserveNavLive
    );

function totalAssetsSettled()
    external
    view
    returns (
        uint256 jrtNavSettled,
        uint256 srtNavSettled,
        uint256 reserveNavSettled
    );

function totalAssetsLiveAndSettled()
    external
    view
    returns (
        uint256 jrtNavLive,
        uint256 srtNavLive,
        uint256 jrtNavSettled,
        uint256 srtNavSettled
    );
```

`StrataCDO` MUST expose per-tranche pricing NAVs:

```text
totalAssetsDepositable(JRT) = max(jrtNavLive, jrtNavSettled)
totalAssetsDepositable(SRT) = max(srtNavLive, srtNavSettled)

totalAssetsRedeemable(JRT) = min(jrtNavLive, jrtNavSettled)
totalAssetsRedeemable(SRT) = min(srtNavLive, srtNavSettled)
```

`Tranche` MUST use these NAVs for ERC4626 conversions when `useConservativePrice` is enabled:

- `previewDeposit()` and `previewMint()` use depositable NAV.
- `quoteDeposit()` and `quoteMint()` use depositable NAV.
- `previewRedeem()` and `previewWithdraw()` use redeemable NAV.
- `quoteRedeem()` and `quoteWithdraw()` use redeemable NAV.
- `maxMint()` uses `previewDeposit(maxDeposit)`.
- `maxRedeem()` caps shares using redeemable NAV.
- withdrawal fee accounting uses redeemable NAV.

When `useConservativePrice` is disabled, the tranche MAY use regular live NAV for both deposits and redemptions.

---

## 8. Accounting Algorithm

On `updateAccounting()`, `MTMAccounting` MUST read:

```text
(navT1, navT1Timestamp, navMTM, navMTMTimestamp) = cdo.totalStrategyAssetsSnapshot(nav, navAnchor)
```

Where `navAnchor` MUST be `lastReconciliation`.

The accounting path is:

1. Validate the snapshot.
2. Determine reconciliation:
   ```text
   isReconciliation = navT1 != navT0
   ```
3. If reconciliation occurs and `navMTMTimestamp > navT1Timestamp`, accrue and reconcile at `navT1Timestamp`.
4. If no reconciliation occurs and `useMTMProjection` is enabled, project using `navMTM`.
5. If no reconciliation occurs and `useMTMProjection` is disabled, fall back to APR-indexed DYS projection.
6. If reconciliation occurred and a newer MTM snapshot exists after `navT1Timestamp`, apply the MTM projection as a second step after the settled reconciliation state.

Reconciliation MUST update stored settled state:

- `nav`,
- `navTimestamp`,
- `jrtBaseNav`,
- `jrtNavProjected`,
- `srtBaseNav`,
- `reserveNav`,
- `lastReconciliation`,
- fee high-water mark,
- floor window state when the floor window rolls over.

Projection MUST NOT realize MTM reserve fees into `reserveNav` before reconciliation.

---

## 9. MTM Projection Formula

During an open epoch, when `navT1 == navT0` and `useMTMProjection == true`, the system SHOULD run the reconciliation allocation formula against `navMTM`, but treat the result as projection.

Conceptually:

```text
mtmPnL = navMTM - navT0
srtProjected = seniorAllocation(mtmPnL, assetTime, riskPremium, floor, benchmark)
jrtProjected = navMTM - srtProjected - projectedReserveFee
```

Where:

- Senior gain is based on DYS exposure through asset-time.
- Senior projected PnL MUST be tracked as the current embedded projection, not accumulated repeatedly across multiple MTM updates.
- Junior projected NAV absorbs MTM losses first unless the Senior floor or benchmark rules require Senior support.
- Settled tranche NAVs MUST remain based on `navT0` until reconciliation.

MTM projection reuses reconciliation allocation but MUST keep:

```text
reserveNavT1 = reserveNavT0
```

Projected reserve fees MAY affect live projected tranche NAV, but they MUST become settled reserve NAV only after reconciliation.

When Senior MTM projection increases Senior NAV, the projected Senior movement is reflected against Junior real NAV for the purpose of settled/live split calculations. When Senior MTM projection decreases Senior NAV, the inverse adjustment is applied.

---

## 10. Deposits And Redemptions During MTM Epochs

Deposits and redemptions MUST first update accounting so share conversions use the current live and settled prices.

With conservative pricing enabled:

- Deposits and mints use `max(Epoch Price, MTM Price)`.
- Withdrawals and redeems use `min(Epoch Price, MTM Price)`.
- User flows MUST update settled NAV by the actual asset amount in or out.
- Pure MTM changes MUST NOT change settled NAV.

This means an MTM gain does not let new depositors mint at the older cheaper epoch price, and an MTM loss does not let redeemers withdraw against the older richer epoch price.

With conservative pricing disabled, users interact against live projected NAV. Any paid-out Senior projection MUST be tracked so reconciliation can unwind projected PnL before applying realized PnL.

---

## 11. Invariants

Implementations MUST preserve the following:

- Settled tranche NAV plus reserve NAV MUST sum to stored settled `nav`.
- Live tranche NAV plus reserve NAV SHOULD represent the latest MTM-projected system NAV.
- Pure MTM updates MUST NOT advance settled NAV.
- Multiple MTM updates in one epoch MUST NOT double count Senior projection.
- Temporary MTM losses or gains MAY recover before reconciliation without changing settled NAV.
- Reconciliation MUST replace MTM projection with realized NAV allocation.
- If the final settled NAV is lower or higher than an earlier MTM quote, the earlier projected allocation MUST be unwound before realized allocation.
- `navMTMTimestamp` MUST NOT be older than `navT1Timestamp`.
- Equal snapshot timestamps MUST NOT report different NAV values.

---

## 12. Compatibility

`MTMAccounting` is intended as an accounting implementation alongside existing DYS accounting. Existing strategies that only support settled NAV MAY use the default `Strategy.totalAssetsSnapshot()` implementation.

The default snapshot reports the settled NAV for both observations when the supplied accounting anchor is at or after the current block timestamp. This avoids conflicting equal-time observations after same-block flows, including rounding differences. A distinct live NAV change during that interval, including a genuine gain or loss, is deferred until the timestamp advances. Strategies requiring different observation timing MUST override the default snapshot with consistent NAVs and timestamps; MTM accounting continues to reject inconsistent snapshots.

Deployments SHOULD enable `useMTMProjection` only for strategies that can provide a meaningful live MTM NAV. Deployments SHOULD enable `useConservativePrice` when deposits and redemptions must be protected from stale epoch prices during open MTM epochs.
