# SIP 07: Valuation Loss–Aware NAV Accounting with Junior-First Absorption

## 1. Summary
This proposal introduces a **valuation adjustment mechanism** for tranche-based ERC4626 vaults where:
* NAV reacts to **protocol-reported valuation changes** (e.g., Proof-of-Reserve / share price)
* **Valuation losses** are absorbed by Junior first
* Senior is protected up to available Junior capital
* During valuation loss:
    * Senior Deposits and Junior Redemptions are paused
    * Any yield from the underlying protocol is distributed using the new valuation factor: Seniors should receive their expected gain (APR) after the valuation factor is applied, and Juniors receive the rest, Or Junior will realize an additional loss to cover the Seniors' expected gain.

> This is the first of two components for the Valuation Loss Handling. The next one will describe the Valuation Loss Oracle.

## 2. Motivation
To eliminate any price fluctuations, current accounting assumes:
```plaintext
1 asset unit = 1 USD
```
This breaks when the underlying protocol **reports a lower valuation**, even if assets are still present.

Consequences today:
* NAV does not reflect valuation changes
* Loss absorption hierarchy is not enforced
* Tranche economics diverge from intended design

This SIP aligns accounting with **valuation-aware reality** while preserving ERC4626 compatibility.

## 3. Design Overview
### 3.1 Core Principles
1. **Base vs Effective accounting**
    * **Base assets**: nominal tranche accounting
    * **Effective assets**: valuation-adjusted NAVs
2. **Junior-first valuation loss absorption**
    * Valuation loss reduces Junior first
    * Senior is protected until Junior is exhausted
3. **Oracle-driven valuation**
    * Valuation price is **cached in storage**
    * Updated via **keeper** (Chainlink Automation) to optimized gas efficiency for users during normal functioning
    * No oracle reads on user paths

## 4. Definitions
### 4.1 State Variables
```solidity
uint256 public srtBaseAssets;
uint256 public jrtBaseAssets; // incl. jrtNavProjected (in Discrete Accounting)

uint256 public valuationPrice;      // 1e18 = $1
uint256 public valuationUpdatedAt;  // timestamp
```

### 4.2 Derived Values
```plaintext
nav = total underlying held by strategy
valuationFactor = 1e18 / valuationPrice
```

## 5. NAV Transformation
This SIP replaces static `srtNav` and `jrtNav` from previous versions with dynamic calculated getters by applying the valuation adjustment.

Formulation:
```plaintext
extraNeeded = srtBaseAssets * (valuationFactor - 1)
extraTaken = min(jrtBaseAssets, extraNeeded)

srtNav = srtBaseAssets + extraTaken
jrtNav = jrtBaseAssets - extraTaken
```

### Invariant remains
```plaintext
srtNav + jrtNav + reserveNav == poolAssets
```

## 7. Valuation Adjustment State
### Valuation Loss Condition
```plaintext
valuationLoss = (valuationPrice < 1e18)
```

## 8. Behavior During Valuation Loss
### 8.1 Activity states
* Senior Deposits and Junior Redemptions are paused

### 8.2 Yield Allocation
#### 8.2.1 Senior Yield
`srtBaseAssets` continues increasing based on the APR as before the valuation loss. The resulting gain increases `srtBaseAssets` directly and is later adjusted by the valuation factor.

#### 8.2.2 Junior Yield
`jrtBaseAssets` receives the remaining gain, or is reduced by the required amount to cover the Seniors gain.

### 8.3 Withdrawals
* Senior withdraws against **effective assets**
* Junior paused

When Symbiotic insurance covers a valuation shortfall, conservative Senior redemption excludes unreconciled projection from the non-insurance NAV but retains the exiter's pro-rata share of the current insurance claim, including coverage booked for existing projection. The claim may be resized by the accounting checkpoint before redemption. See [SIP-09, Section 3.1](SIP-09-conservative-redemption-price.md#31-conservative-senior-redemption-during-insured-valuation-loss) and the [insurance policy](../symbiotic/README.md#conservative-senior-redemptions-with-valuation-coverage).

## 9. Recovery Behavior
As valuation recovers:
```plaintext
valuationPrice → 1e18
valuationFactor → 1
```

Then:
```plaintext
srtNavEffective → srtNav
jrtNavEffective → jrtNav
```

No explicit rebalancing required.

## 10. Oracle, Keeper, and Strategy
### 10.1 Update Flow
```solidity
function refreshValuation() external onlyKeeper {
    (uint256 price, uint256 updatedAt) = oracle.fetch();

    require(updatedAt >= valuationUpdatedAt, "stale");
    require(price > 0 && price <= 1e18, "invalid");

    valuationPrice = price;
    valuationUpdatedAt = updatedAt;
}
```

### 10.2 Requirements
* Monotonic timestamp
* Valid bounds
* Optional freshness checks

### 10.3 Tranche Grace Period
Whenever the Oracle reports a valuation loss, the accounting should pause all deposits and redemptions for a configurable grace period (from 0 to 24 hours) in order to:
* prevent MEV and other manipulations
* allow additional off-chain checks
* max 24 hours to potentially cover the common oracle heartbeats

### 10.4 Granular Deposit and Redemption Limits
The protocol may optionally enforce granular limitations on deposits and redemptions. The keeper or pauser role may restrict specific deposit or redemption tokens and/or limit the maximum allowed amounts per token. This mechanism is independent from the valuation loss state and may be enabled during normal operation or during valuation adjustment periods. The feature is intended to mitigate operational risks, underlying protocol constraints, liquidity limitations, abnormal market conditions, or temporary integration issues without requiring a full protocol pause.

### 10.5 Strategy-Level Deposit and Withdrawal Limits
This SIP introduces maxDeposit and maxWithdraw interfaces on the Strategy layer. Each strategy implementation MUST define and enforce its own deposit and withdrawal limitations based on the underlying protocol requirements, liquidity conditions, cooldown restrictions, operational limits, or other strategy-specific constraints.

The tranche vaults and accounting layer MUST respect these limits during deposits and redemptions. The returned values may dynamically change depending on market conditions, protocol state, valuation adjustment state, or external limitations imposed by the underlying protocol.

This mechanism allows each strategy to implement custom protection logic while preserving a unified tranche and accounting architecture.

## 11. ERC4626 Integration
### totalAssets()
```plaintext
Senior: srtNavEffective
Junior: jrtNavEffective
```

### Conversion Functions
* Must use **effective assets**
* Ensures correct redemption pricing

## 12. Edge Cases
### 12.1 Junior Exhaustion
If:
```plaintext
jrtBaseAssets < extraNeeded
```

Then:
* Junior fully depleted
* Senior covered by total `jrtBaseAssets`; Remaining valuation loss realized by Senior

### 12.2 Valuation Recovery After Exits
* Recovery benefits **remaining participants only**
* No retroactive compensation

## 13. Security Considerations
### 13.1 No Recursive Scaling
```plaintext
DO NOT:
    srtNav *= valuationFactor
```

Always derive effective values from base.

### 13.2 Value Conservation
```plaintext
srtNavEffective + jrtNavEffective + reserveNav == poolAssets
```

Must always hold.

### 13.3 Oracle Integrity
* Enforce monotonic updates
* Validate bounds
* Consider staleness thresholds

## 15. Economic Interpretation
The system models:
* **Junior as first-loss capital**
* **Senior as protected tranche**
* **Valuation loss as external repricing event**
* **Yield as recapitalization of Junior**

### 15.1 Senior entries during a depeg

Senior entries record their entry loss as `amount * (1 - entryPrice)` in `srtFundNav`, in USD scaled to base-asset decimals. Using normalized prices, at a later price, the usable token allowance is `min(srtFundNav / price, srtFundedGrossNav * (1 - price) / price)`. This preserves entry dollar value on a deeper depeg and retains the entry basis through partial recoveries. Exits and principal reductions scale both trackers proportionally; a full repeg clears them. Different entry prices remain pooled rather than tracked per depositor.

## 16. Alternatives Considered
### Continuous oracle reads (rejected)
Rejected due to:
* gas inefficiency
* unnecessary complexity
