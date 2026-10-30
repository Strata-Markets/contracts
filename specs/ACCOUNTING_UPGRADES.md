# Accounting upgrades

## DiscreteAccounting to DYSAccounting or MTMAccounting

### Migration timing

DiscreteAccounting records Senior APR projection directly in `srtBaseNav`, funded from Junior, without a separate `srtPnLProjected` tracker. DYS and MTM need that tracker to unwind projection before allocating realized PnL. Their V3 initialization does not reconstruct projection embedded by Discrete.

Migrate after a genuine Discrete reconciliation, before another accounting update can embed new projection. Otherwise, Senior can retain the untracked projection and receive realized yield for the same period at the first reconciliation after migration, at Junior's expense. The approximate excess is Senior NAV multiplied by Senior APR and the elapsed fraction of a year, limited to projection actually recorded before the upgrade. Elapsed time alone does not write projection to storage.

### Preferred procedure: atomic reconciliation and upgrade

1. Wait for the strategy to report new settled NAV that differs from the NAV stored by Discrete accounting.
2. In one authorized batch, call `DiscreteAccounting.onAprChanged()`, then `ProxyAdmin.upgradeAndCall` with the new implementation and its applicable migration initializer. Do not insert another accounting or tranche action between those calls.
3. Verify that the first call actually reconciled: inspect the `Reconciled` event and the resulting NAV and reconciliation timestamp. Equality between stored and reported NAV alone is insufficient if they already matched before the call.
4. Verify the migrated NAVs, claims, APRs, and initialization state before resuming normal operation.

The batch must have the required `UPDATER_FEED_ROLE` and ProxyAdmin authority. Calling `onAprChanged()` without a new settled NAV can take the projection path instead of reconciling, so it is not sufficient by itself.

### Alternative: temporarily disable APR projection

If reconciliation and upgrade cannot be executed atomically:

1. Record the intended APR configuration. Set both `aprTarget` and `aprBase` in the APR feed to zero, then synchronize Discrete accounting through `onAprChanged()`. Verify that accounting's `aprSrt` and `aprBase` are zero.
2. After synchronization, perform a genuine Discrete reconciliation when the strategy reports new settled NAV. This settles projection recorded before the zero rates took effect.
3. Keep both APR inputs at zero through the upgrade. Ensure automated feed updates do not restore nonzero rates during this window.
4. Upgrade and run the applicable migration initializer. Restore the intended feed configuration and synchronize the new accounting before resuming normal operation.

Both inputs must be zero because Senior's rate is `max(aprTarget, aprBase * (1 - riskPremium))`. Setting only the target APR to zero can leave Senior projection active. Synchronizing the zero rates first checkpoints the old rate; it does not erase projection already embedded, which is why the subsequent genuine reconciliation remains necessary.

The zero-rate interval intentionally suspends target accrual. It does not stop the underlying strategy from earning or losing assets, and it is not a general pause of market activity.

### Initializer compatibility

Use `initializeV3` only if the proxy's initialization version permits it and the V3 migration has not already run. Verify the deployed predecessor's storage layout, migration bitmap, target implementation settings, and rate-mode initialization for the specific upgrade. If V3 has already been initialized, use an explicitly reviewed migration rather than assuming it will run again.

This procedure addresses Cyfrin #74 untracked Discrete projection; it is not a substitute for validating the complete upgrade against the deployed state.

## Temporary terminal Junior dust recovery

`contracts/tranches/accounting/recovery` contains a recovery subclass for each accounting variant. Normal implementations do not expose `settleTerminalJuniorDust`. The subclasses add no storage slots; their constructor parameters must match the original implementation's decimals and immutable accounting flags. Use the same accounting version and verify storage compatibility and deployed bytecode size before deploying the recovery implementation.

This recovery handles a terminal de-peg state, including strategy gains received afterwards. Current and applicable settled strategy NAV must agree, reserve and underwriter fees must be zero, and the entire insurance claim must be valuation credit. It checkpoints pending PnL without first unwinding valuation credit. The unsupported amount is valuation credit minus Senior NAV: it must be positive and no larger than one asset. Junior NAV minus that amount must equal the current strategy NAV. Recovery subtracts only that unsupported amount from Junior NAV, valuation credit and the insurance claim, preserving recovered strategy assets and synchronizing middleware backing. It does not transfer collateral or forgive a realized-loss claim.

For example, Junior NAV 1, Senior NAV 499, and claim/valuation credit 500 become Junior NAV 0, Senior NAV 499, and claim/credit 499. A later price recovery can unwind the credit without subtracting more than Senior holds. If the strategy has meanwhile recovered 1 asset, Junior NAV 2 becomes 1 instead of zero; the same 1 asset of unsupported credit is removed. Both an already-recorded gain and a gain checkpointed by recovery are supported. If live and settled strategy NAV differ, wait for a consistent snapshot before recovering.

### Atomic owner procedure

Deploy the matching recovery implementation, then execute these three calls in a single reverting batch from the accounting owner (for example, its Safe), which must also control the ProxyAdmin:

1. `ProxyAdmin.upgradeAndCall(accountingProxy, recoveryImplementation, "")`.
2. Call `accountingProxy.settleTerminalJuniorDust()` directly from the accounting owner.
3. `ProxyAdmin.upgradeAndCall(accountingProxy, originalImplementation, "")`.

Do not run an initializer. The recovery call uses `onlyOwner`; putting it in the upgrade calldata would make ProxyAdmin the caller and fail authorization. The batch must revert as a whole if any call fails, including restoration of the original implementation. Do not use a batch executor that changes the recovery caller away from the accounting owner or permits individual failures.

Verify `TerminalJuniorDustSettled`, the resulting NAV/claim identity, and restoration of the original implementation. The operation does not reopen the market, burn shares, or reset an empty tranche for new deposits. Existing funded surplus and unneeded slashed collateral remain subject to the separate surplus/return procedures.
