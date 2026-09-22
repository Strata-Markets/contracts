# Symbiotic integration - preparation

Resources:
- https://symbioticfi.notion.site/Build-an-Application-with-Symbiotic-raw-draft-39781c079c17803fb2c8cff841f71cf1
- https://github.com/symbioticfi/core

## 1. Reference setup for the integration

| Item | Value |
| --- | --- |
| Market | Ethena (sUSDe) |
| Market base asset | USDe (18 decimals) |
| Symbiotic VaultV2 asset | uniBTC |
| Coverage token (`InsuranceVault`) | USDC |

## 2. Deploy sequence
1. **Strata** - Call [NetworkRegistry](https://etherscan.io/address/0xC773b1011461e7314CF05f97d95aa8e92C1Fd8aA)`.registerNetwork()`  with the address that will manage the application - the `DEDICATED_MULTISIG`
2. **Strata** - Deploy `OracleAdapter` and register the feeds [section #4](#4-oracleadapter)
3. **Curator** - Deploy the VaultV2 with asset `uniBTC`
4. **Strata** - Deploy the `AppAdapter` [section #3](#3-appadapter)
5. **Strata** - Deploy `NetworkMiddleware` (`InsuranceMiddleware`) (`initialize(owner, appAdapter, oracle)`)
6. **Strata** - Call [NetworkMiddlewareService](https://etherscan.io/address/0xD7dC9B366c027743D90761F71858BCa83C6899Ad)`.setMiddleware(middleware)` from the same `DEDICATED_MULTISIG` to set the `InsuranceMiddleware`
7. **Symbiotic** - Call `AdapterRegistry.setWhitelistedStatus(vault, adapter)`
8. **Curator** - Call `UniversalDelegator.addAdapter(adapter)` on the vault, then allocate collateral
9. **Strata** - Deploy one `InsuranceVault` per CDO (`initialize(owner, cdo, USDC)`)
10. **Strata** - Upgrade the market's accounting and CDO implementations
11. **Strata** - Post-deployment wiring [section #5](#5-post-deployment-wiring)

## 3. AppAdapter
We deploy the `AppAdapter` - https://github.com/symbioticfi/core/blob/delegator-simplify/script/adapters/DeployAppAdapter.s.sol.
For it we need:
- `ADAPTER_FACTORY` (Already there): deployed factory used to create the adapter.
- `VERSION` (Strata): adapter implementation version to deploy.
- `OWNER` (Strata - `DEDICATED_MULTISIG`): address that will own/admin the deployed adapter.
- `VAULT` (Curator): vault address that will allocate collateral to the adapter.
- `BURNER` (Strata - `DEDICATED_MULTISIG`): address that receives slashed collateral after `slash()` is called.
- `DURATION` (Strata): slashability / guarantee duration. This defines how long allocated collateral remains slashable after deallocation is requested.
- `OPERATOR` (Symbiotic): operator address being collateralized by this adapter.
- `SUBNETWORK` (Strata): application subnetwork identifier. This links the adapter to the registered network/application. From https://github.com/symbioticfi/core/blob/delegator-simplify/src/contracts/libraries/Subnetwork.sol#L9 should be `bytes32(uint256(uint160(network_)) << 96 | identifier_)` where network is `DEDICATED_MULTISIG` that called `registerNetwork()` in step 1.
- `CONVERTER` (Strata): Initial converters exempt from the prepared-request delay in [CoWSwapConverter](https://github.com/symbioticfi/core/blob/delegator-simplify/src/contracts/adapters/common/CoWSwapConverter.sol) - an allowlist of addresses, not a contract. They can call `convert()` immediately instead of `prepareConvert()` plus `EXECUTION_DELAY`, and can cancel pending orders via `invalidateConvert()` / `invalidateConverts()`.


## 4. OracleAdapter
`OracleAdapter` is keyed by asset and shared across markets. Every asset the middleware converts must have a
feed or `getPrice()` reverts. Two-hop feeds multiply base x quote and a heartbeat is enforced per feed.

| Asset | Feed | Hops |
| --- | --- | --- |
| uniBTC | uniBTC/BTC then BTC/USD | two |
| USDe | USDe/USD | one |
| USDC | USDC/USD | one |

- uniBTC/BTC: https://data.chain.link/feeds/ethereum/mainnet/unibtc-btc-exchange-rate
- BTC/USD: https://data.chain.link/feeds/ethereum/mainnet/btc-usd
- USDe/USD: https://data.chain.link/feeds/ethereum/mainnet/usde-usd
- USDC/USD: https://data.chain.link/feeds/ethereum/mainnet/usdc-usd

## 5. Post-deployment wiring

On the middleware:
- `setMarket(cdo, accounting, baseAsset, bufferBps, enabled)`
- `setMarketUnderwriterFeeBps(cdo, bps)` - the accounting contract only accepts this from the middleware
- `setOracle(oracleAdapter)` if not passed at init

On the CDO:
- `setInsuranceConfig(insuranceMiddleware, insuranceVault)`
- `setManualUnderwriterFeeDistribution(bool)` and, if manual, `setUnderwriterFeeRewardSafe(safe)`
- grant `RESERVE_MANAGER_ROLE` to the burner multisig - in order to call `StrataCDO.fundInsuranceClaim`

On the accounting contract:
- `setInsurancePool(middleware)` - the insurance middleware

## 6. Economic params to agree on
| Parameter | Where | Open question |
| --- | --- | --- |
| `underwriterFeeBps` | accounting, via the middleware | Share of the risk premium paid to underwriters. |
| `bufferBps` | `InsuranceMiddleware.setMarket` | Extra uniBTC slashed to pre-fund the uniBTC -> USDC swap discount. Capped at 50%. Sized from expected slippage plus the oracle/execution gap. |
| `DURATION` | `AppAdapter` init | Slashability window. |
| `manualUnderwriterFeeDistribution` | CDO | Automatic (uniBTC via CoW on the adapter) or manual (Strata asset to a safe). |

## 7. Operational runbook

Coverage, on a loss:
1. Keeper calls `updateAccounting` (or `setValuationPrice`). The accounting contract sizes the shortfall and
   calls `coverAndSlash` on the middleware **in the same transaction**, which slashes the adapter and books
   `insuranceAmount`.
2. The slashed uniBTC lands in the burner multisig.
3. The multisig swaps it to USDC.
4. The multisig approves the CDO and calls `fundInsuranceClaim(USDC, amount)`, which moves the USDC into the
   `InsuranceVault`, records it, and confirms the claim on the middleware.
5. Redeeming Seniors are paid their covered slice out of the vault. Until step 4 completes, a Senior
   redemption that needs coverage reverts rather than short-paying.

Because steps 2 to 4 are manual, the multisig must be able to act within one cycle. This is the main
operational SLA to agree internally.

Fee, on a gain:
The underwriter fee accrues in the accounting contract and is paid out by
`StrataCDO.payUnderwriterFee(token)`. `manualUnderwriterFeeDistribution` selects the route:

- **Automatic** (default) - the fee is sent to the `AppAdapter`, where the allowlisted converter places a
  CoWSwap order converting it into the VaultV2 asset (uniBTC).
- **Manual** - the fee is sent to `underwriterFeeRewardSafe` in a Strata asset (e.g. sUSDe) and distributed
  through the Symbiotic UI.

## 8. Questions
To Symbiotic:
1. Can you check the deploy flow and verify it is fine, since we deploy the `NetworkMiddleware` (`InsuranceMiddleware`) after the `AppAdapter` to [the doc you provided](https://symbioticfi.notion.site/Build-an-Application-with-Symbiotic-raw-draft-39781c079c17803fb2c8cff841f71cf1) ?
2. Can you confirm that the value for `SUBNETWORK` in [section #3](#3-appadapter) is correct ?
3. What should we set AppAdapter `VERSION` and `DURATION` to when deploying ? What values do you recommend ?
4. Would Symbiotic want to review `NetworkMiddleware` / `InsuranceMiddleware` before whitelisting ?
5. Is a plain safe wallet acceptable as burner address (slashed funds receiver) ?
6. Is the `delegator-simplify` branch is what will be/is deployed to mainnet ? Asking since it is the one referenced in Step 4. from the [provided doc](https://symbioticfi.notion.site/Build-an-Application-with-Symbiotic-raw-draft-39781c079c17803fb2c8cff841f71cf1)
7. What should we pass as `OPERATOR` ? No operator performs work here - the collateral just backs the insurance. Does it need to be registered in `OperatorRegistry` or opted into the vault ?
8. Can you confirm that the `AppAdapter` implementation behind the `VERSION` we deploy points at CoW's mainnet `GPv2Settlement` (`0x9008D19f58AAbD9eD0D60971565AA8510560ab41`) ? It is an immutable in the implementation, so we cannot set it ourselves.

## 9. Needed
From Strata:
- `DEDICATED_MULTISIG` (`BURNER`)
    - Is the registered network address (`registerNetwork()` / `setMiddleware()`), and holds `RESERVE_MANAGER_ROLE` on the CDO.
    - `AppAdapter._slash` transfers the slashed `uniBTC` to it.
    - Is responsible for swapping the `uniBTC` to `USDC` and calling `StrataCDO.fundInsuranceClaim(token, amount)`
- The `SUBNETWORK` value derived from the `DEDICATED_MULTISIG` address.
- The `InsuranceMiddleware` address, once deployed.
- The `AppAdapter` address, so the vault can be whitelisted for it.

From Symbiotic, Underwriter or Curator:
- `VAULT`: the deployed VaultV2 address
- Agree on `DURATION`
