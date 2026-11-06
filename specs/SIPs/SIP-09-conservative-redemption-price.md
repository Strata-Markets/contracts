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
* During a covered valuation loss, Senior retains a pro-rata share of the current insurance claim, including coverage booked for existing projection (Section 3.1).

The goal is to protect existing holders from deposit dilution while preventing redeemers from withdrawing projected yield before it is realized.

---

## 2. Motivation

Some accounting models increase Senior NAV during an epoch using projected yield. This improves deposit pricing because new depositors enter at a price that reflects expected accrual.

However, if redemptions also use projected NAV, a user can exit with yield that has not yet been realized. If the projection is later overestimated, the shortfall must be absorbed by another party.

The conservative redemption price avoids this by making projected yield non-withdrawable until reconciliation.

---

## 3. Price Model

Excluding insurance coverage and valuation adjustments described in Section 3.1, each tranche MAY expose two NAV views:

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

### 3.1 Conservative Senior Redemption During Insured Valuation Loss

When `valuationPrice < 1e18`, Junior has insufficient headroom and an insurance claim is outstanding, conservative pricing excludes unrealized projection from Senior's non-insurance NAV. It does **not** strip projection-related coverage from the current insurance claim. The exiting Senior receives its pro-rata share of that claim, subject to the normal payout cap and vault funding requirements.

Existing projection may have accrued while Junior could fund it, before the depeg required insurance. Stopping further projection when Junior has no headroom does not cancel that existing projection or exclude it from valuation coverage. On conservative redemption, the projected gain itself is forfeited under the normal unwind rules, but its associated coverage is not separately forfeited. This is an intentional underwriter exposure, not a guarantee that the payout equals only the protected settled principal.

For example, with 1,000 settled Senior principal, 99 existing projection, 1,099 insurance credit and a valuation price of $0.50:

```text
Stored Senior NAV                 = 1,000 + 99 + 1,099 = 2,198 base units
Conservative Senior redemption NAV = 2,198 - 99        = 2,099 base units
Half-holder's strategy payout      = 500 base units   = $250.00
Half-holder's insurance payout     = 549.5 base units = $274.75
Total payout at the valuation price                   = $524.75
```

The example assumes zero fees and a fully funded coverage token valued at $1. The $24.75 above the holder's $500 protected settled principal is intentional. The same insurance policy applies in DYS and MTM accounting; it does not make the 99 projected base units directly redeemable.

During an open MTM epoch, conservative redemption still uses the lower of live and settled NAV. A live loss during a depeg can reduce Senior's payout before additional insurance protection is recognized at reconciliation; exiting holders receive no later reimbursement. Operators may remove that interval through a strategy-supported zero-duration epoch. See [SIP-10, Section 10.1](SIP-10-mtm-projection.md#101-live-losses-during-a-valuation-loss).

The claim is measured after the redemption's accounting checkpoint. Reconciliation, projection unwind or valuation recovery may reduce it before an exit. This policy neither freezes earlier coverage nor crystallizes projection permanently. See the [insurance specification](../symbiotic/README.md#conservative-senior-redemptions-with-valuation-coverage).

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
* The protocol avoids paying projected yield itself before reconciliation. During insured valuation loss, the associated insurance coverage remains pro-rata redeemable under Section 3.1.

Markets SHOULD document this behavior before enabling it.

For temporary MTM losses, the recovery allocation and deposit-pricing trade-offs are specified in [SIP-10, Sections 10.2 and 10.3](SIP-10-mtm-projection.md#102-senior-exit-losses-and-subsequent-recovery). Finalized Senior exit losses can benefit Junior on recovery; conservative deposit pricing does not reverse that finalization.
