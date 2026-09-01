---
SIP: 08
Title: Strategy Options for Tranche Operations
Author: Strata Protocol Contributors
Status: Final
Type: Protocol
Created: 2026-03-21
---

# SIP-08: Strategy Options for Tranche Operations

## 1. Abstract

This specification defines a mechanism for users to pass custom configuration data (strategy options) to underlying strategies during deposit and redemption operations. Strategy options enable per-operation customization of strategy behavior without requiring protocol-level changes or new contract deployments.

The ERC4626 Tranche Vaults are extended to allow users to pass custom strategy options to the underlying strategy. Strategy options are arbitrary `bytes` data that a strategy implementation may decode and use to process deposits or redemptions according to user-provided configuration.

The feature is optional and depends entirely on the underlying strategy implementation. For redemptions, if a request enters the `SharesCooldown` flow, the `SharesCooldown` contract stores the strategy options associated with the request. During finalization, the options are forwarded to the strategy. The request owner MAY override the strategy options during finalization.

The existing 2-slot storage packing for cooldown requests is preserved. Strategy options and other metadata are stored in a separate mapping, allowing future extensions beyond strategy options.

---

## 2. Motivation

Different strategies may support multiple operational modes or configurations for deposits and redemptions. Strategy options provide a flexible and gas-efficient mechanism for users to specify operational preferences directly in their deposit and redemption calls.

---

## 3. Design Goals

The implementation MUST:

* Allow users to pass arbitrary bytes data to strategies during deposits and redemptions.
* Preserve backward compatibility with existing Tranche and SharesCooldown interfaces.
* Maintain the existing 2-slot storage packing for cooldown requests.
* Support strategy option updates during redemption finalization.
* Remain optional — strategies that do not require options can ignore them.

The implementation SHOULD:

* Minimize gas overhead for users who do not use strategy options.
* Enable future extensions beyond strategy options (e.g., user metadata or routing hints).
* Provide clear interfaces for strategy implementations to decode and validate options.

---

## 4. Architecture

### 4.1 Tranche Vault Extensions

The `Tranche` contract MUST expose **overloads** of `deposit`, `mint`, `redeem`, and `withdraw` that accept strategy options. Equivalent Meta Token variants MUST also support strategy options.

These methods MUST forward the `strategyOptions` bytes to the underlying strategy during execution.

The existing methods MUST remain unchanged and MUST pass empty bytes (`""`) as strategy options for backward compatibility.

### 4.2 Strategy Interface Extensions

Strategies that support strategy options MUST implement extended interfaces for deposit and withdrawal flows.

Strategies MAY validate and decode `strategyOptions` according to their own requirements. Invalid options SHOULD revert with a descriptive error message.

Strategies that do not support options MAY either ignore the `strategyOptions` parameter or revert.

### 4.3 SharesCooldown Extensions

When a redemption enters the cooldown period, the `SharesCooldown` contract MUST store the strategy options alongside the request.

The existing 2-slot request structure MUST remain unchanged.

Strategy options and other metadata MUST be stored in a separate mapping.

### 4.4 Finalization with Strategy Options

During finalization, users MUST be able to override the original strategy options. The overridden options MUST be forwarded to the strategy instead of the options stored with the request.

---

## 5. Security Considerations

### 5.1 Strategy Option Validation

Strategies MUST validate strategy options before processing operations. Invalid options MUST revert with clear error messages.

Strategies MUST NOT trust strategy options to be well-formed or safe. All decoding MUST be defensive.

### 5.2 Finalization Override

Users MUST only be able to override strategy options for their own requests. The `finalizeWithOptions` method MUST verify that `msg.sender` is the request owner.

Overriding strategy options MUST NOT allow users to bypass cooldown periods, fee structures, or other protocol invariants.

### 5.3 Backward Compatibility

All existing deposit and redemption flows MUST continue to work without modification. Empty strategy options MUST be treated as a no-op by all strategies.

---
