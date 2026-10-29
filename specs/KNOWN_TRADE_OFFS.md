# Known trade-offs

This register records explicitly accepted limitations and policy decisions so they can be reviewed later. Acceptance does not mean an issue is fixed or that its impact is negligible.

## Maintenance

- Give each entry a stable ID, status, source reference, affected behavior, acceptance rationale, impact, mitigation, and reconsideration criteria.
- Revisit affected entries when accounting, fees, limits, or integrations change. Record any new evidence or changed assumptions.
- For a fix, preserve the entry, mark it **Resolved**, and add the commit and regression-test references.
- Do not treat transaction simulation as a guarantee: state can change between simulation and execution.

## KT-001: Junior withdrawal maximum can omit the effect of fee booking

**Status:** Accepted implementation limitation
**Reference:** Cyfrin f-76, "Exit fees on Junior withdrawals"

### Behavior and conditions

When the Junior coverage limit binds and part of the exit fee goes to the reserve, `Tranche.maxWithdraw` can exceed the amount execution permits. The quote caps the net payout using the current accounting limit. Execution books the fee first, reducing Junior NAV, then checks the withdrawal against the reduced limit.

Example, in base-asset units:

1. Junior NAV is 100, Senior NAV is 900, and the minimum Junior/Senior ratio is 5%. The accounting withdrawal cap is 55.
2. The Junior exit fee is 0.1%, with 50% retained by Junior. The maximum view reports 55.
3. Withdrawing 55 net requires approximately 0.055055 in fees, of which 0.027527 goes to the reserve.
4. Junior NAV becomes approximately 99.972472 before the withdrawal check. The remaining cap is approximately 54.972472, so withdrawing 55 reverts with `WithdrawalCapReached`.

These figures illustrate the calculation; integer rounding applies in execution. The issue affects both base-asset and token-specific withdrawal maxima when this accounting cap binds.

### Acceptance rationale

Retain the simpler balance-based quote rather than add another redeemable-NAV lookup and conversion of the protocol cap into shares. Maximum views are also used during execution, so added calculation can increase transaction gas.

A conservative fix was evaluated and reverted: cap gross shares before deducting the exit fee. In the example it reports 54.945, treating the entire fee as consuming headroom even when Junior retains part of it.

### Impact and mitigation

A user or integration submitting the advertised maximum can encounter a revert and pay transaction gas. The transaction rolls back; the existing execution limit remains enforced. This is an optimistic maximum, not merely a conservative underestimate.

### Reconsider when

- Integrations require the reported maximum to execute reliably.
- Failed maximum withdrawals become frequent or fee settings make the gap material.
- A shared fee calculation can make the quote accurate at acceptable cost.

### Possible fix and validation

Cap gross shares before computing the net quote, or derive a tighter maximum that accounts for the reserve portion of the fee and rounding. Preserve the execution guards.

Replace `balanceOf(owner)` with a fee-aware `maxRedeem(owner)` calculation.

## KT-002: Senior deposit maximum can overstate capacity before an MTM update

**Status:** Accepted implementation limitation
**Reference:** Cyfrin f-76, "Open market-value gains (MTM markets)"

### Behavior and conditions

`MTMAccounting.maxDeposit` uses the stored Junior/Senior split. A deposit first refreshes accounting. With live MTM projection, an open gain can move value from Junior to Senior and reduce the room for new Senior deposits. The pre-update maximum can therefore exceed the limit checked during execution, even without a market change between the quote and transaction.

In the auditor's scenario, stored Junior NAV is 100 and Senior NAV is 500. With a 6% deposit coverage buffer, the view reports approximately 1,166.67. After a pending MTM gain of 100 is applied under that scenario's risk settings, the deposit capacity falls to approximately 430.56. Depositing the earlier maximum reverts with `DepositCapReached`.

### Acceptance rationale

Avoid reproducing the prospective accounting split in maximum views solely to match the state that execution will establish. Doing so adds calculation and maintenance complexity.

### Impact and mitigation

A deposit at the advertised maximum can revert. Execution still enforces the refreshed accounting limit and rolls back the failed transaction.

Simulate the exact deposit, including its accounting update, and adjust the amount if needed. Where supported, refreshing accounting before obtaining a new quote reduces this discrepancy, but does not guarantee unchanged state until execution. A small fixed margin is insufficient for potentially large MTM adjustments.


### Possible fix and validation

Derive the maximum from the same prospective Junior/Senior state that execution would establish, without mutating storage. Keep its fee, projection, valuation, and insurance treatment consistent with execution.

## KT-003: Projected reserve fees use an approximate cumulative gain

**Status:** Accepted approximation after mitigation
**Reference:** Cyfrin f-115, projected reserve fees below the high-water mark

### Behavior and conditions

DiscreteAccounting and the APR-projection paths in DYSAccounting and MTMAccounting estimate prior projected gain as `max(0, jrtNavProjected - jrtBaseNav)`. Adding this to settled NAV lets the projected reserve-fee calculation recognize progress toward the high-water mark across accounting updates, without a new storage tracker.

This is not cumulative gross strategy gain: previously projected reserve fees, expected underwriter fees, and projection forfeitures can reduce the estimate. Residual fee underestimation and update-frequency differences remain possible. Reconciliation continues to calculate the actual fee from realized NAV.

### Impact and mitigation

Projected Junior NAV can still be overstated relative to the eventual fee. Depositors may overpay and live-priced exits may benefit at remaining holders' expense. Conservative redemption pricing limits the exit exposure but does not correct deposit pricing. Reconciliation corrects remaining NAV, not completed flows.

In the tested 10-million-unit market, the original approximately 915.89-unit fee-related cadence gap becomes negligible without flows or underwriter fees. Flow cases and expected underwriter fees retain smaller discrepancies; these scenario results are not universal bounds.

### Possible fix and validation

Track cumulative gross projected gain with consistent treatment of flows, fees, forfeitures, and reconciliation resets. The current policy regressions are in `test/PoC/Cyfrin/ProjectedReserveFeeCadence.t.sol`, covering the auditor scenario, deposits, exits, underwriter fees, and conservative DYS/MTM exits. Their cadence tolerances apply only to those fixtures and do not guarantee exact fee amounts.
