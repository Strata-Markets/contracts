---
SIP: 09
Title: Conservative Redemption Price
Author: Strata Protocol Contributors
Status: Draft
Type: Protocol
Created: 2026-07-20
---

# SIP-09: Conservative Redemption Price

## 1. Abstract

This specification defines a **conservative redemption price** for tranche vaults that use projected NAV between accounting reconciliations.

Under this mechanism:

* Deposits MAY use projected NAV.
* Redemptions MUST use redeemable NAV, excluding unreconciled projected gain.
* The redeemed share of projected gain is unwound during redemption.

The goal is to protect existing holders from deposit dilution while preventing redeemers from withdrawing projected yield before it is realized.

---

## 2. Motivation

Some accounting models increase Senior NAV during an epoch using projected yield. This improves deposit pricing because new depositors enter at a price that reflects expected accrual.

However, if redemptions also use projected NAV, a user can exit with yield that has not yet been realized. If the projection is later overestimated, the shortfall must be absorbed by another party.

The conservative redemption price avoids this by making projected yield non-withdrawable until reconciliation.

---

## 3. Price Model

Each tranche MAY expose two NAV views:

```
grossNAV      = reconciledNAV + projectedGain
redeemableNAV = reconciledNAV
```

Deposits use `grossNAV` when projection is enabled:

```
sharesOut = assetsIn * totalSupply / grossNAV
```

Redemptions use `redeemableNAV`:

```
assetsOut = sharesIn * redeemableNAV / totalSupply
```

The difference between `grossNAV` and `redeemableNAV` represents projected yield that has not yet been realized.

During an epoch, a redemption also removes the projected gain attached to the redeemed shares. This prevents an immediate artificial price increase for remaining holders at redemption. In `DYSAccounting` and `MTMAccounting`, Senior conservative redemptions reduce `srtPnLProjected` and `srtBaseNav` by the redeemed share of unreconciled Senior projection and return that amount to Junior real NAV. Junior conservative redemptions reduce `jrtNavProjected` by the redeemed share of unreconciled Junior projection, without reducing it below Junior real NAV.

Senior redemptions do not remove the redeemed capital's historical asset-time from the pooled Senior trackers. At reconciliation, realized Senior PnL is allocated using that history and credited to the Senior holders remaining then. Returning projection to Junior at redemption does not permanently assign the corresponding realized yield to Junior. A holder retaining a residual Senior position participates in that later allocation.

---

## 4. ERC-4626 Behavior

When enabled, ERC-4626 preview and execution functions MUST be internally consistent:

* `previewDeposit` and `deposit` use projected NAV.
* `previewMint` and `mint` use projected NAV.
* `previewWithdraw`, `withdraw`, `previewRedeem`, and `redeem` use redeemable NAV.
* `maxWithdraw` and `maxRedeem` MUST NOT include unreconciled projected gain.

This creates a conservative entry/exit spread while preserving ERC-4626 preview guarantees.

---

## 5. Reconciliation

At reconciliation, realized NAV replaces projected NAV according to the accounting contract's normal true-up rules.

If realized yield covers the projection, the previously non-withdrawable projected gain becomes part of redeemable NAV.

If realized yield is lower than projected yield, redeemers who exited before reconciliation do not receive the overestimated portion. The shortfall remains inside the normal tranche waterfall.

---

## 6. Trade-Offs

This mechanism is simple and robust, but it is conservative for redeemers:

* Accurate projected yield is not paid to users who exit before reconciliation.
* Remaining holders do not receive the redeemed projection at redemption, but do receive the Senior tranche's realized epoch PnL at reconciliation, including the contribution of exited capital.
* A user who redeems most of their shares can still receive that realized yield through a residual position.
* The protocol avoids paying projected yield to exited users before reconciliation.

Markets SHOULD document this behavior before enabling it.
