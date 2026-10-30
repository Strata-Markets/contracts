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
