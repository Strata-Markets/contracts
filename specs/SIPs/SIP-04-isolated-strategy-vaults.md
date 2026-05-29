---
SIP: 04
Title: Isolated Strategy Vaults
Author: Strata Protocol Contributors
Status: Draft
Type: Protocol
Created: 2026-03-21
---


# SIP-04: Isolated Strategy Vaults

## 1. Abstract

This specification defines a new tranche architecture where Senior and Junior assets are allocated to separate underlying strategies while preserving the existing top-level product shape of one `StrataCDO`, one Senior tranche vault, and one Junior tranche vault.

* Senior assets MUST be allocated to a dedicated base strategy.
* Junior assets MUST be allocated to a dedicated liquid strategy.
* Senior MUST pay a continuous risk premium to Junior.
* Senior redemptions MUST consume Junior strategy liquidity first, then fall back to Senior strategy liquidity and the existing async/cooldown path.
* Junior redemptions MUST consume Senior strategy liquidity first and the existing async/cooldown path, then fall back to Junior strategy liquidity.
* Senior strategy losses MUST be absorbed by Junior first, up to a configured protection capacity.

Both tranches have symmetric liquidity access: Senior may borrow Junior liquidity, and Junior may borrow Senior liquidity.

A privileged Rebalancer SHOULD be available to move assets between the two strategies in either direction, restoring target allocations and clearing inter-strategy debt. It SHOULD handle both instant and deferred (async cooldown) redemptions.

---

## 2. Design Goals

The implementation SHOULD preserve the following:

* one `StrataCDO` per product,
* one `strategy` address from the CDO's point of view,
* the existing `Tranche` ERC4626 and MetaVault UX,
* the existing cooldown and exit flow where possible,
* backward-compatible aggregate NAV reads for integrations that still expect them.

The implementation MUST introduce the following:

* separate entitlement NAV tracking for Junior (`jrtBaseNav`) and Senior (`srtBaseNav`) tranches,
* isolated tranche-native yield,
* explicit premium accrual,
* explicit Senior debt to Junior when Junior liquidity is used for Senior redemptions,
* explicit Junior debt to Senior when Senior liquidity is used for Junior redemptions,
* explicit Senior loss transfer to Junior up to a configurable protection cap.

---

## 3. High-Level Architecture

```text
               Users
                 |
                 v
         JRT / SRT Tranche Vaults
                 |
                 v
        StrataCDO (AccountingIsolated)
                 |
                 v
          IsolatedStrategy  -> Rebalancer
         |                |
         v                v
JuniorLiquidStrategy   SeniorBaseStrategy
```

Responsibilities:

* `Tranche`: mint/burn shares, previews, cooldown integration.
* `StrataCDO`: orchestration, access control, fees, accounting refresh, reserve management.
* `IsolatedStrategy`: tranche-aware routing and liquidity sourcing.
* `JuniorLiquidStrategy`: holds Junior liquidity strategy assets.
* `SeniorBaseStrategy`: holds Senior base strategy assets.
* `AccountingIsolated`: entitlement accounting split across Junior (`jrtBaseNav`) and Senior (`srtBaseNav`) tranches.
* `Rebalancer`: moves assets between strategies; handles instant and deferred rebalances, clears inter-strategy debt on completion.

---

## 4. Economics

### 4.1 Per-Strategy NAV

The system MUST distinguish between assets physically held by each sub-strategy and tranche economic entitlements.

At reconciliation time, each sub-strategy is queried for its current `totalAssets()`. These per-strategy values are transient — they are not stored as state variables. The combined `navT1` equals the sum of both sub-strategy NAVs plus any in-flight assets held by the Rebalancer.

### 4.2 Tranche Entitlement NAV

Let:

* `jrtNav` = Junior economic entitlement after premium, loss absorption, and debt adjustments.
* `srtNav` = Senior economic entitlement after premium, loss absorption, and debt adjustments.

These values are accounting-layer facts.

### 4.3 Premium

Senior MUST continuously transfer premium to Junior.

Premium MUST be computed using the legacy risk approach based on tranche TVL ratio and APR feed values.

Risk formula:

```text
tvlRatioSrt = srtNav / (srtNav + jrtNav)
riskPremium = riskX + riskY * (tvlRatioSrt ^ riskK)
```

Senior target APR:

```text
aprSrt = max(aprTarget, aprBase * (1 - riskPremium))
```

Where:

* `riskX`, `riskY`, `riskK` are configurable risk parameters.
* `aprTarget` and `aprBase` come from the APR pair feed (or equivalent source).

Premium transfer is the implied transfer from Senior to Junior derived from the difference between:

* realized Senior strategy economics, and
* Senior economics capped by `aprSrt` over the accrual interval.

Operationally, this means Senior retains up to the target return implied by `aprSrt`, and any excess Senior strategy return is transferred to Junior.

For compatibility with existing accounting mechanics, implementations MAY use target-index accounting to realize this transfer.

Reference target-index form:

```text
srtTargetIndexT1 = f(srtTargetIndexT0, aprSrt, dt)
targetGainSrt = gain(srtNavT0, srtTargetIndexT1, srtTargetIndexT0)
premiumTransfer = max(0, realizedSeniorGain - targetGainSrt)
```

Accounting effect:

```text
srtNav += targetGainSrt
jrtNav += (realizedSeniorGain - targetGainSrt)
```

If `realizedSeniorGain < targetGainSrt` (Senior strategy underperformed its target), the difference is negative and JRT is reduced to fund the shortfall. This guarantees Senior always receives its full target return as long as Junior has sufficient balance.

### 4.4 Senior Loss Waterfall

If total NAV decreases between accounting checkpoints (`navT1 < navT0`), that loss MUST be allocated in the following waterfall order:

1. Junior absorbs losses first (up to its full balance).
2. Reserve absorbs any remaining loss.
3. Senior absorbs any remaining loss.

This is consistent with the legacy `Accounting` contract loss allocation.

### 4.5 Senior Debt To Junior

If Senior redeems using Junior strategy liquidity, an implicit debt arises: Junior physically paid but its accounting entitlement (`jrtBaseNav`) is unchanged, while Senior's accounting entitlement (`srtBaseNav`) decreases by the redeemed amount. This gap is exposed by `IsolatedStrategy.debts()`:

```text
srSurplus = saturatingSub(srtAssets, srtBaseNav)
jrDeficit = saturatingSub(jrtBaseNav, jrtAssets)
toJunior  = min(srSurplus, jrDeficit)
```

`toJunior > 0` signals outstanding Senior-to-Junior debt. No explicit state variable is stored; the debt is fully derived from live strategy balances and accounting NAV at query time.

The debt is cleared by `Rebalancer.initiateRebalance(fromIdx=1, toIdx=0, ...)` or `Rebalancer.initiateRebalanceByDebt(...)`, which physically moves assets from the Senior strategy to the Junior strategy. It is also cleared passively via deposit routing when incoming SRT deposits are redirected to the Junior strategy (see §4.8).

### 4.6 Junior Debt To Senior

If Junior redeems using Senior strategy liquidity, a symmetric implicit debt arises: Senior physically paid but its accounting entitlement (`srtBaseNav`) is unchanged, while Junior's accounting entitlement (`jrtBaseNav`) decreases. `IsolatedStrategy.debts()` exposes this as:

```text
jrSurplus = saturatingSub(jrtAssets, jrtBaseNav)
srDeficit = saturatingSub(srtBaseNav, srtAssets)
toSenior  = min(jrSurplus, srDeficit)
```

`toSenior > 0` signals outstanding Junior-to-Senior debt. No explicit state variable is stored.

The debt is cleared by `Rebalancer.initiateRebalance(fromIdx=0, toIdx=1, ...)` or `Rebalancer.initiateRebalanceByDebt(...)`.

Note: `toSenior` and `toJunior` are mutually exclusive — `debts()` only returns a non-zero `toJunior` when `toSenior` is zero.

### 4.7 Junior Redemption Liquidity Sourcing

Junior redemptions MUST attempt to source liquidity from the Senior strategy first, before falling back to the Junior strategy:

1. If the Senior strategy supports the requested token and has available liquidity, source up to `baseAssets` from the Senior strategy.
2. Source any remaining amount from the Junior strategy (via the normal cooldown path if needed).

The resulting debt is tracked implicitly (see §4.6) — no explicit recording step is required.

### 4.8 Junior Allocation Floor

A configurable `juniorAllocationFloor` (WAD ratio, `1e18 = 100%`, default `0` = disabled) MAY be set by the owner to enforce a minimum share of total TVL held by the Junior strategy.

When `juniorAllocationFloor > 0`, `debts()` raises `jrTarget` above `jrtNavT0` to enforce the floor:

```text
jrTarget = max(jrtNavT0, navTotal * juniorAllocationFloor / 1e18)
```

This means `toJunior > 0` whenever Junior's physical assets fall below the floor-adjusted target, not just when a cross-strat borrow has occurred.

On every deposit, `_depositStratIndex` checks `debts()` and applies the following routing:

* If `toJunior > 0` and `baseAssets <= toJunior` and the Junior strategy supports the token → route to Junior.
* If `toSenior > 0` and `baseAssets <= toSenior` and the Senior strategy supports the token → route to Senior.
* Otherwise → route to the tranche's natural strategy.

The `baseAssets <= toJunior/toSenior` guard prevents a single large deposit from overshooting the target and creating debt in the opposite direction. Deposits larger than the outstanding debt fall through to normal routing.

---

## 5. Accounting Update Algorithm

On `updateAccounting()` the implementation SHOULD follow this order:

1. **Fetch combined NAV** — the strategy SHOULD be queried with the `lastReconciliation` timestamp anchor rather than `navTimestamp`. Each sub-strategy SHOULD be queried with `latestNav=0`:
   * If any sub-strategy returns `0` (its oracle has not updated since `lastReconciliation`), the strategy SHOULD return `navT0` unchanged — no reconciliation SHOULD occur.
   * Otherwise, `navT1` SHOULD equal the sum of all sub-strategy NAVs plus any in-flight rebalance assets held by the Rebalancer.

2. **Reconciliation gate** — if `navT1 == navT0`, the implementation SHOULD take the projection path (step 3). Otherwise it SHOULD take the full reconciliation path (step 4).

3. **Projection path** — when no new rewards are detected, the implementation SHOULD accrue a projected gain using target indices (`navTargetIndex`, `srtTargetIndex`) over the elapsed interval and distribute between Junior and Senior. `lastReconciliation` SHOULD NOT advance.

4. **Full reconciliation** — when new rewards are detected (`navT1 != navT0`), the implementation SHOULD:
   * Recompute Senior target APR:
     ```text
     tvlRatioSrt = srtNav / (srtNav + jrtNav)
     riskPremium = riskX + riskY * (tvlRatioSrt ^ riskK)
     aprSrt = max(aprTarget, aprBase * (1 - riskPremium))
     ```
   * Accrue Senior target gain using `srtTargetIndex` over the elapsed interval; transfer any excess to Junior.
   * Apply loss waterfall if `navT1 < navT0`:
     * Junior SHOULD absorb first (up to its full balance),
     * Reserve SHOULD absorb any remaining loss,
     * Senior SHOULD absorb any remaining loss.
   * Apply reserve fee if configured.
   * Persist updated entitlement NAVs (`jrtBaseNav`, `srtBaseNav`, `reserveNav`, `nav`).
   * `lastReconciliation` SHOULD advance to the current block timestamp.
