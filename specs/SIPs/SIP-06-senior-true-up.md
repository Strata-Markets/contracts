# SIP 06: Senior True-Up

## Overview

This SIP defines the mechanism for reconciling Senior (SRT) NAV at epoch boundaries under Discrete Accounting.

During the epoch:

- Senior NAV (`srtNav`) is continuously increased using projected returns
- This increase is funded by a continuous transfer of value from Junior (JRT)

At reconciliation:

- Realized PnL from the underlying strategy replaces the projected Senior PnL

This ensures:

- Smooth NAV evolution during the epoch
- Correct economic allocation at true-up

## Terminology

- **PnL**: Absolute profit/loss over the epoch (can be negative)
- **Gain**: Deprecated, replaced by PnL
- **srtNav**: Senior NAV during the epoch. Includes projected PnL and represents effective Senior assets
- **jrtNav**: Junior real NAV after continuous transfers to Senior
- **jrtNavProjected**: Junior NAV used for projection
- **srtPnLProjected**: Accumulated projected Senior PnL during the epoch
- **srtNavTime / jrtNavTime**: Time-weighted NAV (asset-time) - includes the Projected Assets, Projected PnL
- **srtProjectedPnLTime**: Time-weighted Senior PnL Projection to calculate later the `srtNavTimeNet`
- **navTime**: Total system asset-time (incl. projection)
- **navTimeNet**: Total system asset-time (excl. projection)

## Senior NAV During the Epoch

Senior NAV is continuously increased using projected returns:

```solidity
srtNav += calculatedPnL;
srtPnLProjected += calculatedPnL;
```

Important:

- `srtNav` is both:
  - projected NAV
  - effective Senior asset balance during the epoch
- this works because projected PnL is continuously transferred from Junior to Senior
- therefore, Junior NAV decreases accordingly during the epoch

## Asset-Time Tracking (DYS)

To correctly compute the true-up, the system MUST track time-weighted NAV.

### Accrual Rule

On every deposit, redemption, and before reconciliation:

```solidity
function _accrueAssetTime() internal {
    uint256 dt = block.timestamp - lastAccrual;
    if (dt == 0) return;

    uint256 srAssets = srtNav;
    uint256 jrAssets = jrtNavProjected;
    uint256 systemAssets = srAssets + jrAssets + reserveNav;

    srtNavTime += srAssets * dt;
    jrtNavTime += jrAssets * dt;
    navTime    += systemAssets * dt;

    lastAccrual = block.timestamp;
}
```

Critical:

- MUST be called **before any state change**
- MUST use the same NAV definition as accounting (`srtNav`)

## True-Up (Reconciliation)

At epoch end:

1. Accrue asset-time up to the current timestamp
2. Use realized PnL from the underlying strategy

### Senior Allocation

```
srtFactor = (1 - RiskPremium)
srtPnL = PnL * srtFactor * srtNavTime / navTime
```

### Senior Floor

```
avgSrAssets = srtNavTime / T
srtFloorPnL = (-10 bps) * avgSrAssets
srtPnL = max(srtPnL, srtFloorPnL)
```

### Junior Allocation

```
jrtPnL = PnL - srtPnL
```

## True-Up Based on Exchange Rates

The contract may track the underlying exchange rate at the projection start (`rateT0`) and at the reconciliation (`rateT1`) to calculate the expected realized PnL for Seniors.
This allows tracking specific sub-strategy performance in multi-strategy setups.

### NAV Updates

```solidity
// Junior
jrtNav = jrtNav + jrtPnL;
jrtNavProjected = jrtNav;

// Senior
srtNav = srtNav - srtPnLProjected + srtPnL;
srtPnLProjected = 0;
```

Explanation:

- during the epoch, `srtNav` includes projected PnL
- at true-up:
  - remove projected PnL
  - add realized PnL
- Junior absorbs the difference

### Reset After True-Up

```solidity
srtNavTime = 0;
jrtNavTime = 0;
navTime = 0;
srtPnLProjected = 0;

lastAccrual = block.timestamp;
```

### Summary

Senior PnL is computed as:

```
srtPnL = PnL * (1 - RiskPremium) * (srtNavTime / navTime)
```

This formulation:

- avoids explicit APR conversion
- is consistent with DYS-based accounting
- correctly reflects time-weighted exposure

# Daily Loss Floor (Senior Tranche)

The Accounting contract enforces a configurable **daily loss floor** for the Senior tranche (e.g. `-0.1%` per day). A zero `floorRate` disables the floor.

The floor uses a **rolling 24h window with a fixed starting NAV and a flow-adjusted baseline**. The loss allowance scales with that baseline rather than remaining a fixed amount throughout the window.

### Definitions

- `windowStartSrtNav` - Senior NAV at window start (anchor)
- `windowNetFlows` - cumulative net Senior flows and adjustments to the protected position during the window
- `windowEnd` - end timestamp of the current window

### Core formulas

For an enabled floor, using fractional rates (`floorRate = 0.001` for a 0.1% allowance):

```
baseline = max(0, windowStartSrtNav + windowNetFlows)
allowedLoss = baseline * min(1, floorRate)
srtNavFloor = baseline * max(0, 1 - floorRate)
```

Ordinary deposits and withdrawals update net flows as:

```
windowNetFlows = windowNetFlows + srtAssetsIn - srtAssetsOut
```

Deposits increase the absolute loss allowance; withdrawals reduce it. Neither is treated as PnL, and neither unconditionally restarts the window.

Valuation insurance credit is part of the protected Senior position. Credit additions increase `windowNetFlows`, and credit unwinds decrease it. Senior fees transferred to the reserve and explicitly accepted insurance claim write-downs also reduce the baseline.

For a window-start NAV of 1,000 and a 1% allowance:

| Net Senior flows | Baseline | Allowed loss | Senior floor |
| --- | ---: | ---: | ---: |
| 0 | 1,000 | 10 | 990 |
| +500 | 1,500 | 15 | 1,485 |
| -900 | 100 | 1 | 99 |

### Accounting during the window

The floor sets the Senior target before the loss waterfall:

```
srtNavRealized = srtNav + realizedPnL
srtNavTarget = max(srtNavRealized, srtNavFloor)
```

Actual protection remains subject to the available backing and the accounting contract's loss waterfall.

Properties:

- The starting NAV stays fixed within the window, but the baseline and absolute loss allowance change with net flows.
- Withdrawals do not leave the remaining Senior capital with the original, larger absolute loss allowance.
- Deposits increase the absolute loss allowance in proportion to the added capital.
- Gains are unrestricted by the floor.

### Window rollover

At reconciliation, when its accounting timestamp reaches or exceeds `windowEnd`, apply the existing window's floor before starting a new window. DYS uses `block.timestamp`; MTM uses the timestamp of the accounting checkpoint.

#### Step 1 - extend the rate for inactivity

If the accounting timestamp is later than `windowEnd`, extend the rate proportionally:

```
dT = timestamp - windowEnd
extendedRate = floorRate * (24 hours + dT) / 24 hours
```

The extended allowance uses the **flow-adjusted baseline**, not the window-start NAV alone:

```
allowedLoss = baseline * min(1, extendedRate)
srtNavFloor = baseline * max(0, 1 - extendedRate)
```

The floor is bounded at zero once the extended rate reaches 100%.

#### Step 2 - apply accounting using the extended floor

Apply the Senior target and loss waterfall using `srtNavFloor`.

#### Step 3 - start a new window

After reconciliation:

```
windowStartSrtNav = srtNav
windowNetFlows = 0
windowEnd = timestamp + 24 hours
```

Changing the configured floor rate explicitly resets the window as well.

#### Key properties

- The floor is relative to a fixed starting NAV adjusted for net flows.
- The loss allowance scales with the protected position and extends proportionally during inactivity.
- Ordinary flows do not unconditionally reset the window.
- There is no dependency on calendar timestamps such as midnight.
