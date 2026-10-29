---
SIP: 01
Title: Share Lock-Up Redemption Mechanism for Tranche Vaults
Author: Strata Protocol Contributors
Status: Final
Type: Protocol
Created: 2025-12-15
---

# Tranche Vault — Share Lock-Up Redemption Specification

## 1. Overview

This specification defines a **share lock-up redemption mechanism** for Tranche Vaults (Junior and Senior tranches) that introduces a cooldown period on shares rather than on assets.

Under this mechanism:

* Users initiate a redemption request by transferring shares into a Silo Contract.
* Shares remain locked for a predefined lock-up period.
* After the lock-up period elapses, the user may finalize the redemption.
* The final exchange rate is determined at the time of finalization.
* Asset transfer occurs directly from the Tranche Vault at finalization.

This design preserves ERC-4626 compatibility while enabling delayed liquidity and controlled redemption flows.

---

## 2. Actors

* **User**: An externally owned account (EOA) or contract initiating a redemption.
* **Receiver**: An account that receives the assets upon redemption. Per the ERC-4626 specification, the receiver MAY be different from the User.
* **Tranche Vault**: An ERC-4626-compatible vault managing Junior or Senior tranche shares.
* **Silo Contract**: - A contract responsible for holding locked shares and executing final redemption on behalf of users.
* **Strategy**: The underlying asset manager (may require unstaking prior to asset withdrawal, e.g., USDe).

---

## 3. Current Redemption Flow (Reference)

The current (non lock-up) redemption flow is as follows:

1. User calls `redeem` or `withdraw`
2. Vault calculates redeemable assets (excluding fees)
3. Vault burns the corresponding shares
4. Vault transfers assets:

   * Directly to the receiver, or
   * To an unstaking / cooldown contract used by the Strategy

---

## 4. Lock-Up Redemption Flow (When Enabled)

### 4.1 Redemption Request Phase

1. User initiates a redemption request via `redeem` or `withdraw`
2. Instead of burning shares:

   * The Tranche Vault transfers the specified shares to the Silo Contract

3. The Silo Contract records:

   * User address
   * Receiver address
   * Share amount
   * Lock-up end timestamp

At this stage:

* No assets are transferred
* Only fee shares are burned to accrue fees in accounting
* The user may finalize the redemption before the lock-up period expires only if an ExitFee is specified for the Vault by the Protocol
* The user may cancel the lock-up; in this case, the request is dismissed and the shares are transferred back to the user.

---

### 4.2 Finalization Phase

After the lock-up period has elapsed:

1. The user triggers finalization via the Silo Contract
2. The Silo Contract calls `redeem` on the Tranche Vault **on behalf of the user**
3. The Tranche Vault:

   * Detects that the caller is the Silo Contract
   * Skips any lock-up or cooldown logic
   * Skips fee accrual (if fees are active at the time of finalization)
   * Processes the redemption as a direct ERC4626 redemption request
4. The Tranche Vault:

   * Burns the locked shares
   * Calculates the redeemable assets using the **current exchange rate**
5. Asset handling:

   * If the asset is directly withdrawable, assets are transferred to the user
   * If unstaking is required (e.g. USDe), the unstaking process is executed before transfer
6. During finalization, the user MAY specify the desired output asset (e.g. USDe or sUSDe)

---

## 5. Exchange Rate Determination

* The exchange rate used for redemption is determined **at the time of finalization**
* No price or asset amount is snapshotted at request time
* Users remain fully exposed to vault performance (positive or negative) during the lock-up period

---

## 6. Lock-Up Duration and Fees

The protocol MAY apply a **coverage-dependent lock-up period** and associated fees to share redemptions when the Share Lock-Up mechanism is enabled.

All parameters described in this section are **evaluated at redemption request time** and remain immutable for the lifetime of the corresponding lock-up entry.

### 6.1 Lock-Up Duration

The protocol MAY define up to **two coverage thresholds** (`C₀`, `C₁`) that partition the coverage space into **three mutually exclusive ranges**, each associated with a predefined lock-up duration.

Let `Coverage` be the current coverage ratio at redemption request time.

| Coverage Range       | Applicable Lock-Up Duration |
| -------------------- | --------------------------- |
| `Coverage ≤ C₀`      | `lockupSeconds[0]`          |
| `C₀ < Coverage ≤ C₁` | `lockupSeconds[1]`          |
| `Coverage > C₁`      | `lockupSeconds[2]`          |

Properties:

* Coverage thresholds MUST be strictly increasing (`C₀ < C₁`) or equal (`C₀ == C₁`) - this effectively disables the `C₁` range
* Each range maps to exactly one lock-up duration
* A lock-up duration of `0` seconds represents **immediate finalization eligibility**
* The selected lock-up duration is recorded in the Silo Contract at request time and MUST NOT change afterwards

---

### 6.2 Redemption Fee (Request-Time Fee)

The protocol MAY apply a **redemption fee at request time**, expressed as a percentage of shares being redeemed.

Characteristics:

* The applicable fee tier is determined using the **same coverage range selection** as defined in Section 6.1
* The fee is accrued **immediately at redemption request**
* Fee collection is implemented via burning and assets distribution according to the accounting rules
* The fee is independent of whether the redemption is later finalized, cancelled, or early-exited

---

### 6.3 Early-Exit Fee

If enabled by the protocol, a user MAY finalize a redemption **before the lock-up period has elapsed** by paying an **early-exit fee**.

Early-exit fee rules:

* The fee is calculated based on the **remaining lock-up time** at the moment of finalization
* The fee rate is defined as a **per-day penalty**
* Early-exit fees are applied **in addition to** any redemption fee already accrued at request time

If early-exit is disabled:

* Finalization attempts prior to lock-up expiry MUST revert

---

## 7. Redemption Pause Handling (`PAUSER_ROLE`)

* If redemptions are fully paused at the Tranche Vault:

   * Finalization requests from the Silo Contract MUST revert.
      - Locked shares remain held in the Silo Contract until redemptions are unpaused.
   * Cancellation is allowed when enabled.
      - Locked shares are forwarded to the receiver as-is (without burning).

---

## 8. Junior Tranche Redemption Limits

The protocol enforces a maximum redeemable amount to preserve the MINIMUM Junior / Senior ratio.

With the new lock-up mechanism, shares that are already locked in the Silo contract are not included in the ratio formula, meaning the Net Asset Value for a Tranche is changed to:

$$
\text{JuniorNAV} = \text{JuniorTVL} - \text{JuniorTVLInSilo}
$$

$$
\text{SeniorNAV} = \text{SeniorTVL} - \text{SeniorTVLInSilo}
$$

---

## 9. Multiple Withdrawal Requests

### 9.1 Request Granularity

* Each redemption request is treated as a distinct lock-up entry
* Each entry has its own:

  * Share amount
  * Lock-up end timestamp

---

### 9.2 Aggregated Finalization

* The Silo Contract MAY aggregate multiple completed lock-up entries
* Finalization may redeem the sum of all eligible completed requests in a single transaction

---

### 9.3 Request Spam Prevention

To prevent request spamming, limits apply to active request slots **per tranche and receiver**:

* Up to **70** slots are available when the receiver is the caller or the share owner.
* At 70 slots, an eligible new request merges into the last request: its shares are added, and the unlock timestamp becomes the later of the existing and new timestamps. Non-empty strategy options must match the last request's options; otherwise the request reverts.
* If the receiver is neither the caller nor the share owner, a new request reverts with `ExternalReceiverRequestLimitReached` once that receiver already has **40** active slots. This check counts all of the receiver's active requests, not only third-party requests, and applies before merging.

The lower third-party limit prevents others from filling a receiver's slots and forcing their later requests into the merge path. Compatible requests with the same unlock timestamp may also merge below the 70-slot limit.


---

### 9.4 Request Finalizer Account

* A redemption request represents a **public intent** to exit the vault
* The receiver address is **recorded at request time** and **cannot be modified**
* The request has **no impact on the share exchange rate**

Based on these properties:

* The **finalization of a redemption request is permissionless**; any account MAY finalize an eligible redemption request.

---

🏁
