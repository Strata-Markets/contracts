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

This specification defines a new tranche architecture where Senior and Junior assets are allocated to separate underlying strategy sleeves while preserving the existing top-level product shape of one `StrataCDO`, one Senior tranche vault, and one Junior tranche vault.

* Senior assets MUST be allocated to a dedicated base strategy sleeve.
* Junior assets MUST be allocated to a dedicated liquid strategy sleeve.
* Senior MUST pay a continuous risk premium to Junior.
* Senior redemptions MUST consume Junior sleeve liquidity first, then fall back to Senior sleeve liquidity and the existing async/cooldown path.
* Junior redemptions MUST consume Senior sleeve liquidity first, then fall back to Junior sleeve liquidity and the existing async/cooldown path.
* Senior sleeve losses MUST be absorbed by Junior first, up to a configured protection capacity.

Both tranches have symmetric liquidity access: Senior may borrow Junior liquidity, and Junior may borrow Senior liquidity.

---

## 2. Design Goals

The implementation SHOULD preserve the following:

* one `StrataCDO` per product,
* one `strategy` address from the CDO's point of view,
* the existing `Tranche` ERC4626 and MetaVault UX,
* the existing cooldown and exit flow where possible,
* backward-compatible aggregate NAV reads for integrations that still expect them.

The implementation MUST introduce the following:

* separate raw NAV tracking for Junior and Senior sleeves,
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
StrataCDO
  |
  v
IsolatedCompositeStrategy (IsolatedAccounting)
  |                         |
  v                         v
JuniorLiquiditySleeve       SeniorBaseSleeve

```

Responsibilities:

* `Tranche`: mint/burn shares, previews, cooldown integration.
* `StrataCDO`: orchestration, access control, fees, accounting refresh, reserve management.
* `IsolatedCompositeStrategy`: tranche-aware routing and liquidity sourcing.
* `JuniorLiquiditySleeve`: holds Junior liquidity strategy assets.
* `SeniorBaseSleeve`: holds Senior base strategy assets.
* `IsolatedAccounting`: entitlement accounting based on split raw NAVs.

---

## 4. Economics

### 4.1 Raw Sleeve NAV

The system MUST distinguish between physical sleeve assets and tranche economic entitlements.

Let:

* `rawJrtNav` = assets physically held by the Junior sleeve.
* `rawSrtNav` = assets physically held by the Senior sleeve.

These values are strategy-layer facts.

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

* realized Senior sleeve economics, and
* Senior economics capped by `aprSrt` over the accrual interval.

Operationally, this means Senior retains up to the target return implied by `aprSrt`, and any excess Senior sleeve return is transferred to Junior.

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

If `realizedSeniorGain < targetGainSrt` (Senior sleeve underperformed its target), the difference is negative and JRT is reduced to fund the shortfall. This guarantees Senior always receives its full target return as long as Junior has sufficient balance.

### 4.4 Senior Loss Waterfall

If `rawSrtNav` decreases between accounting checkpoints, that loss MUST be allocated in the following waterfall order:

1. Junior absorbs losses first (up to its full balance).
2. Reserve absorbs any remaining loss.
3. Senior absorbs any remaining loss.

This is consistent with the legacy `Accounting` contract loss allocation.

### 4.5 Senior Debt To Junior

If Senior redeems using Junior sleeve liquidity, the accounting system MUST record:

```text
seniorDebtToJunior += amountBorrowed
```

This debt represents value owed by Senior economics to Junior economics and MUST be considered during future accounting updates and redemptions.

The debt MUST be repayable via a privileged `repaySeniorDebtToJunior()` function that withdraws from the Senior sleeve and re-deposits into the Junior sleeve.

### 4.6 Junior Debt To Senior

If Junior redeems using Senior sleeve liquidity, the accounting system MUST record:

```text
juniorDebtToSenior += amountBorrowed
```

This debt represents value owed by Junior economics to Senior economics and MUST be considered during future accounting updates and redemptions.

The net debt used in accounting delta calculations is:

```text
netDebt = seniorDebtToJunior - juniorDebtToSenior
```

The debt MUST be repayable via a privileged `repayJuniorDebtToSenior()` function that withdraws from the Junior sleeve and re-deposits into the Senior sleeve.

### 4.7 Junior Redemption Liquidity Sourcing

Junior redemptions MUST attempt to source liquidity from the Senior sleeve first, before falling back to the Junior sleeve:

1. If the Senior sleeve supports the requested token and has available liquidity, source up to `baseAssets` from the Senior sleeve.
2. Record `juniorDebtToSenior += amountBorrowed`.
3. Source any remaining amount from the Junior sleeve (via the normal cooldown path if needed).

---
## 5. Accounting Update Algorithm

On `updateAccounting(rawJrtNavT1, rawSrtNavT1)` the implementation SHOULD follow this order:

1. Recompute risk-premium inputs and Senior target APR:
   * `tvlRatioSrt = srtNav / (srtNav + jrtNav)`
   * `riskPremium = riskX + riskY * (tvlRatioSrt ^ riskK)`
   * `aprSrt = max(aprTarget, aprBase * (1 - riskPremium))`
2. Accrue premium from Senior to Junior using the legacy target-return approach for the elapsed interval.
3. Compute `netDebt = seniorDebtToJunior - juniorDebtToSenior`.
4. Compute raw sleeve deltas adjusted for net debt:
   * `jrtDelta = (rawJrtNavT1 - rawJrtNav) + netDebtDelta`
   * `srtDelta = (rawSrtNavT1 - rawSrtNav) - netDebtDelta`
5. If Senior sleeve lost value, apply the waterfall:
   * Junior absorbs first (up to its full balance),
   * Reserve absorbs any remaining loss,
   * Senior absorbs any remaining loss.
6. If Junior sleeve lost value:
   * allocate the loss to Junior.
7. Apply reserve fee logic if configured.
8. Persist the new raw NAV snapshot.
9. Persist the new entitlement NAV snapshot.

