# Strata × Symbiotic Coverage Integration

Symbiotic underwriters post collateral (uniBTC) in a shared VaultV2. Strata pays them a premium
and, when a Strata market takes a loss, slashes that collateral to make the covered tranche whole.
It is a bonded backstop, not co-mingled tranche capital — the coverage lives outside the CDO pool
and re-enters only via the slash -> multisig -> true-up path.

One Symbiotic vault + one AppAdapter is shared across all Strata markets; the middleware keeps a
per-market registry keyed by CDO address.

## Flow

![Symbiotic integration flow](flow.png)

## Contracts

- **`NetworkMiddleware`** — the only custom contract. Owner-gated `slash(cdo)` reads a market's
  `pendingCoverageDeficit`, converts it to vault-asset via the market oracle, and slashes the
  AppAdapter; `confirmTrueUp` clears the in-flight amount (prevents double-slashing the same
  deficit). Registry: `setMarket`. Upgradeable / Ownable2Step / Pausable.
- **`OracleAdapter` / `IOracleAdapter`** — prices base assets and the vault asset (uniBTC) in a
  common quote so deficits can be sized in vault-asset terms.
- **`IAppAdapter` / `IStrataAccounting` / `INetworkMiddleware`** — trimmed local interfaces.

The Strata-side hooks live in the core contracts: `Accounting` tracks `premiumNav` and
`pendingCoverageDeficit`; `StrataCDO` exposes `payPremium` and `trueUp`.

## Premium

`premiumBps` skims a share of realized gains into a separate `premiumNav` bucket (threaded through
the accounting split like the reserve; it never absorbs losses). `payPremium` sends the accrued
premium — in the strategy share token — to the AppAdapter, which `convert()`s it to the vault asset;
a `deallocate` then pushes it into the vault so underwriter shares appreciate (no shares minted).

## Loss coverage & `coverageFirst`

On a loss, `Accounting` accrues `pendingCoverageDeficit`. `trueUp(shareAmount)` later injects the
recovered funds and restores the covered tranche (no share dilution), decrementing the deficit.

`coverageFirst` (owner switch) picks **which loss Symbiotic covers**:

| `coverageFirst` | Waterfall | Deficit accrued | `trueUp` credits |
|---|---|---|---|
| `false` (default) | SR -> JR -> Symbiotic (mezzanine) | Senior shortfall below its target path | **SR** |
| `true` | SR -> Symbiotic -> JR (Symbiotic *is* the junior) | The Junior NAV decline | **JR** |

In both modes the tranche carries the book loss until the true-up lands, since external coverage
capital cannot arrive atomically with the loss.
