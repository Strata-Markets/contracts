---
SIP: 03
Title: Discrete Accounting
Author: Strata Protocol Contributors
Status: Final
Type: Protocol
Created: 2026-02-20
---


# SIP-03: Discrete Accounting

## 1. Abstract

This specification defines a new Accounting contract that implements **provisional accrual followed by settlement true-up**.

The existing `Accounting.sol` contract continuously receives yield from underlying protocols that vest rewards each block and accounts for Senior, Junior, and Reserve accordingly.

The `DiscreteAccounting` contract:

* MUST continuously accrue yield for the Senior tranche based on the Benchmark APR and Risk Premium.
* MUST provisionally increase the Junior NAV based on the expected Base APR.
* MUST perform a true-up (reconciliation) between expected and realized Junior NAV immediately after the underlying strategy reports new rewards.

---

## 2. Senior Tranche

* Yield is calculated as before, based on the configured Benchmark APR and Risk Premium parameters.
* The Junior tranche covers the Senior yield by continuously transferring the required yield from Junior NAV to Senior NAV.

---

## 3. Junior Tranche

* `APRbase` (collateral APR) is defined as the expected base yield from the underlying strategy.
* `APRjr` is derived from `APRbase` and `APRsr`.
* `DiscreteAccounting` MUST continuously increase the **projected NAVjr** to reflect `APRjr`.
* Junior price per share is calculated using `projectedNAVjr`.

---

# 4. True-Up (Reconciliation)

When the contract detects realized gain from the underlying strategy:

```solidity
int256 receivedGain = int256(navT1) - int256(navT0);
```

where:

* `navT0` is the total NAV stored at the previous accounting checkpoint.
* `navT1` is the current total NAV reported by the strategy.

If `receivedGain > 0`, the contract MUST perform a true-up.

First, compute:

```
projectedGain = projectedNAVjr - realNAVjr
```

### Case 1: `receivedGain >= projectedGain`

1. Apply `receivedGain` to `realNAVjr` and `projectedNAVjr` so that:

   ```
   projectedNAVjr == realNAVjr
   ```

---

### Case 2: `receivedGain < projectedGain`

1. Add `receivedGain` to `realNAVjr`.
2. Compute the shortfall:

   ```
   shortfall = projectedGain - receivedGain
   ```

3. Decrease the `projectedNAVjr` by the `shortfall`.
4. Finally Junior NAVs should be equal:

   ```
   projectedNAVjr == realNAVjr
   ```

## 5. Redemptions

### 5.1 Junior

Because Junior **Real NAV** declines continuously between reconciliation events while Junior **Projected NAV** continues to increase, the Accounting contract MUST calculate `maxWithdraw` for the Junior tranche using Real NAV.

### 5.2 Senior

No changes to Senior redemption are required, as the Junior tranche continuously covers Senior liquidity.

## 6. Coverage

Coverage MUST be calculated using Junior **Real NAV**. Given the invariant `Real <= Projected`, this allows the protocol to pause Senior deposits and Junior redemptions earlier.

## 7. Risk Premium

The risk premium is based on the TVL ratio, calculated as `srtNav / (srtNav + jrtNav)`. Discrete Accounting MUST use **Projected NAV** for Junior TVL.

----

> ⚠️ True-Up pitfalls that MUST be handled:

### Strategy gain manipulation

A donation to the Strategy can incorrectly trigger reward detection.

When rewards are detected as:

```sol
navT1 = totalAssets * price
rewards = navT1 - navT0
```

An attacker can manipulate `totalAssets` by donating X wei of assets. The protocol may then detect a gain, assume it came from the underlying protocol, and trigger a true-up. This can cause accounting to prematurely finalize the Junior tranche's temporary reward shortfall. _The value may be corrected later when real rewards are distributed._


The Accounting contract depends on the Strategy contract to report rewards correctly for the previous period.

The accounting contract will provide its latest NAV and timestamp so the strategy can better determine whether rewards can be reported.

🏁

