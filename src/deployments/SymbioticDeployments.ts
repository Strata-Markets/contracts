import { Deployments } from 'dequanto/contracts/deploy/Deployments';
import { Web3Client } from 'dequanto/clients/Web3Client';
import { TEth } from 'dequanto/models/TEth';
import { $require } from 'dequanto/utils/$require';
import { InsuranceMiddleware } from '@0xc/hardhat/InsuranceMiddleware/InsuranceMiddleware';
import { OracleAdapter } from '@0xc/hardhat/OracleAdapter/OracleAdapter';
import { InsuranceVault } from '@0xc/hardhat/InsuranceVault/InsuranceVault';
import { StrataCDO } from '@0xc/hardhat/StrataCDO/StrataCDO';
import { Addresses, ChainlinkFeeds } from '@s/constants';
import { SymbioticConfig } from '@s/platforms/symbiotic/SymbioticConfig';
import { $address } from 'dequanto/utils/$address';
import { IAppAdapter } from '@0xc/hardhat/IAppAdapter/IAppAdapter';
import { SymbioticAdapterFactory } from '@0xc/eth/SymbioticAdapterFactory/SymbioticAdapterFactory';
import { $abiCoder } from 'dequanto/abi/$abiCoder';
import { $abiParser } from 'dequanto/utils/$abiParser';
import { SymbioticVaultFactory } from '@0xc/eth/SymbioticVaultFactory/SymbioticVaultFactory';
import { $abi } from 'dequanto/abi/$abi';
import { Eth } from '@s/platforms/Eth';
import { $contract } from 'dequanto/utils/$contract';
import { SymbioticVaultImpl } from '@0xc/eth/SymbioticVaultImpl/SymbioticVaultImpl';
import { SymbioticAppAdapterImpl } from '@0xc/eth/SymbioticAppAdapterImpl/SymbioticAppAdapterImpl';
import { SymbioticUniversalDelegatorImpl } from '@0xc/eth/SymbioticUniversalDelegatorImpl/SymbioticUniversalDelegatorImpl';

// Registry identifier for native BTC (not an ERC20 contract).
export const BTC_QUOTE_ASSET: TEth.Address = '0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB';

/// Default staleness bound for the registered feeds (seconds). Overridable per-feed.
const DEFAULT_HEARTBEAT = 86400n; // 24h

/// A market entry to register in the middleware's coverage registry.
export interface ISymbioticMarket {
    cdo: TEth.Address;
    accounting: TEth.Address;
    baseAsset: TEth.Address;
    bufferBps: bigint;
    /// Token the market's InsuranceVault holds coverage in (the slashed collateral is swapped into
    /// it off-chain). One vault is deployed per CDO.
    coverageToken: TEth.Address;
    enabled: boolean;
}

/// A Chainlink feed to register in the shared OracleAdapter, keyed by the priced asset.
/// Register quote assets before the feeds that reference them; omit quoteAsset for USD feeds.
export interface ISymbioticFeed {
    asset: TEth.Address;
    aggregator: TEth.Address;
    decimals: bigint;
    heartbeat: bigint;
    quoteAsset?: TEth.Address;
}

export interface ISymbioticNMParams {
    client: Web3Client;
    deployer: TEth.EoAccount;
    /// Owner of the middleware (governance / timelock multisig). Defaults to the deployer.
    owner?: TEth.IAccount;

    /// The Symbiotic AppAdapter this middleware drives (deployed on the Symbiotic side).
    /// Defaults to SymbioticConfig[network].appAdapter when omitted.
    appAdapter?: TEth.Address;
    /// Chainlink feeds to register in the shared OracleAdapter. Defaults to the constants-derived
    /// set for the network. Must cover every market's base asset and the vault asset.
    feeds?: ISymbioticFeed[];
    /// Markets sharing this middleware's AppAdapter. Defaults to SymbioticConfig[network].markets.
    markets?: ISymbioticMarket[];
    /// Dedicated safe for manual underwriter fee distribution, registered on every market's CDO
    /// (setUnderwriterFeeRewardSafe). Defaults to SymbioticConfig[network].underwriterFeeRewardSafe. Unset = skip.
    underwriterFeeRewardSafe?: TEth.Address;
    /// Deploys a per-CDO InsuranceVault and wires it with the InsuranceMiddleware on the CDO.
    /// @dev Off by default: it requires the CDO upgrade that adds setInsuranceConfig to be live, so
    ///      enable it only once every configured market's CDO has been upgraded.
    insuranceVaults?: boolean;
    /// Behaviour when the deployed bytecode differs; mirrors DeploymentsBase.
    deployments?: 'throw' | 'redeploy';
    isTest?: boolean;

    acm?: TEth.Address;
}

/// @notice Deploys the single, shared Symbiotic InsuranceMiddleware (+ the shared OracleAdapter) and
///         registers the Strata markets that share its AppAdapter.
/// @dev The middleware is NOT per-CDO: one instance is shared across all markets, so this is a
///      standalone deployment (not a per-CDO DeploymentsBase). The AppAdapter is deployed on the
///      Symbiotic side and passed in.
export class SymbioticDeployments {

    ds: Deployments;
    owner: TEth.IAccount;

    constructor(public params: ISymbioticNMParams) {
        this.owner = params.owner ?? params.deployer;
        this.ds = new Deployments(params.client, params.deployer, {
            directory: `./deployments/symbiotic/${params.isTest ? 'test/' : ''}`,
            whenBytecodeChanged: params.deployments ?? null,
        });
    }

    /// Deploys the shared, upgradeable OracleAdapter (project-wide, per-asset feed registry).
    private async ensureOracle(): Promise<OracleAdapter> {
        console.log('✅ ensureOracle', this.owner.address);
        const { contract } = await this.ds.ensureWithProxy(OracleAdapter, {
            id: 'SymbioticOracleAdapter',
            arguments: [],
            initialize: [this.owner.address, this.params.acm],
        });
        return contract;
    }

    /// Resolves the AppAdapter address from params, falling back to the network config.
    private appAdapter(): TEth.Address {
        const network = this.ds.client.network;
        const address = this.params.appAdapter ?? SymbioticConfig[network]?.appAdapter;
        return $require.Address(address, `No AppAdapter configured for network '${network}'`);
    }

    public async ensureVault(vaultParams: {
        owner: TEth.Address
        asset: {
            address: TEth.Address
        }
    }) {
        // original deployment:
        // a) https://github.com/symbioticfi/core/blob/delegator-simplify/script/DeployVaultV2.s.sol
        // b) https://github.com/symbioticfi/core/blob/delegator-simplify/script/base/DeployVaultV2Base.sol
        // Factory: https://etherscan.io/address/0xAEb6bdd95c502390db8f52c8909F703E9Af6a346
        // Implementation: https://etherscan.io/address/0x41069A712FaCc421fE194cAa59667456863a780e
        // e.g.

        const factory = new SymbioticVaultFactory(void 0, this.ds.client);

        const vaultV2ParamsAbi = `
            struct InitParams {
                string name;
                string symbol;
                address asset;
                bool depositWhitelist;
                address depositorToWhitelist;
                uint256 depositLimit;
                bool isDepositLimit;
                address defaultAdminRoleHolder;
                address managementFeeRoleHolder;
                address performanceFeeRoleHolder;
                address depositLimitSetRoleHolder;
                address depositorWhitelistRoleHolder;
                address isDepositLimitSetRoleHolder;
                address depositWhitelistSetRoleHolder;
                bytes delegatorParams;
            }

        `;
        const delegatorParamsAbi = `
            struct InitParams {
                address allocateRoleHolder;
                address deallocateRoleHolder;
                address addAdapterRoleHolder;
                address swapAdaptersRoleHolder;
                address defaultAdminRoleHolder;
                address removeAdapterRoleHolder;
                address forceDeallocateRoleHolder;
                address setAdapterLimitsRoleHolder;
                address setAutoAllocateAdaptersRoleHolder;
            }
        `;

        const NAME = 'Strata Insurance Vault';
        const SYMBOL = 'SIV';
        const ASSET = Eth.Tokens.uniBTC.address;
        const OWNER = this.owner.address;
        const DEPOSITOR_TO_WHITELIST = $address.ZERO;
        const DEPOSIT_LIMIT = 10_000e8;

        const vaultV2ParamsHex = $abi.encode(vaultV2ParamsAbi, {

            name: NAME,
            symbol: SYMBOL,
            asset: ASSET,
            depositWhitelist: false,
            depositorToWhitelist: DEPOSITOR_TO_WHITELIST,
            depositLimit: DEPOSIT_LIMIT,
            isDepositLimit: DEPOSIT_LIMIT != 0,
            defaultAdminRoleHolder: OWNER,
            managementFeeRoleHolder: OWNER,
            performanceFeeRoleHolder: OWNER,
            depositLimitSetRoleHolder: OWNER,
            depositorWhitelistRoleHolder: OWNER,
            isDepositLimitSetRoleHolder: OWNER,
            depositWhitelistSetRoleHolder: OWNER,
            delegatorParams: $abi.encode(delegatorParamsAbi, {
                allocateRoleHolder: OWNER,
                deallocateRoleHolder: OWNER,
                forceDeallocateRoleHolder: OWNER,
                addAdapterRoleHolder: OWNER,
                swapAdaptersRoleHolder: OWNER,
                defaultAdminRoleHolder: OWNER,
                removeAdapterRoleHolder: OWNER,
                setAdapterLimitsRoleHolder: OWNER,
                setAutoAllocateAdaptersRoleHolder: OWNER
            })

        });
        let createDataHex = $abiCoder.encode(['address', 'bytes'], [
            this.owner.address,
            vaultV2ParamsHex
        ]);


        //createDataHex = `0x000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000220000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000638cc04874d0874d04140b72cc72bcd6fc4f6abd000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4000000000000000000000000000000000000000000000000000000000000026000000000000000000000000000000000000000000000000000000000000000094361737361205257410000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b4c4c4361737361555344430000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000120000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4000000000000000000000000638cc04874d0874d04140b72cc72bcd6fc4f6abd000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4000000000000000000000000eef44faf5fe0cc1fab04bb052bff750cf37a7fc4`;
        createDataHex = vaultV2ParamsHex;
        const tx = await factory.$receipt().create(
            this.ds.deployer, 3, vaultParams.owner, createDataHex
        );
        const [ entityLog ] = factory
            .extractLogsAddEntity(tx.receipt)
            .filter(x => $address.eq(x.address, factory.address));
        const vault = entityLog.params.entity;
        return new SymbioticVaultImpl(vault, this.ds.client);
    }

    public async ensureAppAdapter(adapterParams: {
        owner: TEth.Address
        vault: TEth.Address
        params: {
            burner: TEth.Address
            duration: number
            operator: TEth.Address
            subnetwork: TEth.Hex
            converters: TEth.Address[]
        }
    }) {
        // original deployment:
        // Factory: https://etherscan.io/address/0x161954842B7EA47CBd050cAb4875DAa4D6599476#code
        // v1 implementation: https://etherscan.io/address/0xfe8cFC5Dbb9c77A32a5Eb77C17F0317593f2c133
        const factory = new SymbioticAdapterFactory(void 0, this.ds.client);
        const { owner, params } = adapterParams;
        const vault = adapterParams.vault;

        const initParamsAbi = $abiParser.parseStruct(`
            struct InitParams {
                address burner;
                uint48 duration;
                address operator;
                bytes32 subnetwork;
                address[] converters;
            }
        `);
        let initDataHex = $abiCoder.encode([initParamsAbi], [{
            burner: $require.AddressNotEmpty(params.burner),
            duration: params.duration,
            operator: $require.AddressNotEmpty(params.operator),
            subnetwork: params.subnetwork,
            converters: []
        }]);
        let createDataHex = $abiCoder.encode(['address', 'bytes'], [
            vault,
            initDataHex
        ]);

        const vaultFactory = new SymbioticVaultFactory(void 0, this.ds.client);
        const isVaultEntity = await vaultFactory.isEntity(vault);
        $require.True(isVaultEntity, `${vault} must be the VaultEntity`);

        const version = 1;
        const writer = await factory.$receipt().create(this.ds.deployer, version, owner, createDataHex);

        const [ entityLog ] = factory
            .extractLogsAddEntity(writer.receipt)
            .filter(x => $address.eq(x.address, factory.address));
        const appAdapter = entityLog.params.entity;
        return new SymbioticAppAdapterImpl(appAdapter, this.ds.client);
    }

    /// Deploys the shared InsuranceMiddleware behind a proxy, initialized with the AppAdapter and oracle.
    private async ensureMiddleware(oracle: OracleAdapter): Promise<InsuranceMiddleware> {
        const appAdapter = this.appAdapter();
        const { contract } = await this.ds.ensureWithProxy(InsuranceMiddleware, {
            id: 'SymbioticInsuranceMiddleware',
            arguments: [],
            initialize: [
                this.owner.address,
                this.params.acm,
                appAdapter,
                oracle.address,
            ],
        });
        return contract;
    }

    /// Builds the feed set for the current network from src/constants.ts (Addresses + ChainlinkFeeds):
    /// USDe/USDC price single-hop against USD; uniBTC prices two-hop as uniBTC/BTC x BTC/USD.
    private defaultFeeds(): ISymbioticFeed[] {
        const network = this.ds.client.network;
        const Addr = Addresses[network];
        const Feeds = ChainlinkFeeds[network];
        $require.notNull(Feeds, `No Chainlink feeds configured for network '${network}'`);

        const feeds: ISymbioticFeed[] = [];
        if (Addr?.USDe && Feeds['USDe/USD']) {
            feeds.push({
                asset: Addr.USDe,
                aggregator: Feeds['USDe/USD'].address,
                decimals: BigInt(Feeds['USDe/USD'].decimals),
                heartbeat: DEFAULT_HEARTBEAT
            });
        }
        if (Addr?.USDC && Feeds['USDC/USD']) {
            feeds.push({
                asset: Addr.USDC,
                aggregator: Feeds['USDC/USD'].address,
                decimals: BigInt(Feeds['USDC/USD'].decimals),
                heartbeat: DEFAULT_HEARTBEAT
            });
        }
        if (Addr?.uniBTC && Feeds['uniBTC/BTC'] && Feeds['BTC/USD']) {
            feeds.push({
                asset: BTC_QUOTE_ASSET,
                aggregator: Feeds['BTC/USD'].address,
                decimals: BigInt(Feeds['BTC/USD'].decimals),
                heartbeat: 3600n,
            });
            feeds.push({
                asset: Addr.uniBTC,
                aggregator: Feeds['uniBTC/BTC'].address, decimals: BigInt(Feeds['uniBTC/BTC'].decimals),
                quoteAsset: BTC_QUOTE_ASSET,
                heartbeat: DEFAULT_HEARTBEAT,
            });
        }
        return feeds;
    }

    /// Builds the market set for the current network from src/platforms/symbiotic/SymbioticConfig.ts,
    /// resolving each market's base-asset symbol to an address via Addresses[network].
    private defaultMarkets(): ISymbioticMarket[] {
        const network = this.ds.client.network;
        const cfg = SymbioticConfig[network];
        $require.notNull(cfg, `No Symbiotic markets configured for network '${network}'`);
        const A = Addresses[network];

        return cfg.markets.map(m => {
            const baseAsset = A?.[m.baseAsset as keyof typeof A] as TEth.Address | undefined;
            $require.Address(baseAsset, `No address for base asset '${m.baseAsset}' (market ${m.name}) on '${network}'`);
            const coverageSymbol = m.coverageToken ?? 'USDC';
            const coverageToken = A?.[coverageSymbol as keyof typeof A] as TEth.Address | undefined;
            $require.Address(coverageToken, `No address for coverage token '${coverageSymbol}' (market ${m.name}) on '${network}'`);
            return {
                cdo: m.cdo,
                accounting: m.accounting,
                baseAsset: baseAsset!,
                bufferBps: m.bufferBps,
                coverageToken: coverageToken!,
                enabled: m.enabled,
            };
        });
    }

    /// Full deployment: oracle + feeds + middleware, then register the configured markets.
    async ensureDeployment(params?: {
        appAdapter?: TEth.Address
    }): Promise<{
        middleware: InsuranceMiddleware;
        oracle: OracleAdapter;
        vaults: Record<string, InsuranceVault>;
    }> {
        if (params?.appAdapter) {
            this.params.appAdapter = params.appAdapter;
        }
        const oracle = await this.ensureOracle();

        // Explicit feeds/markets override the config-derived defaults for the current network.
        const feeds = this.params.feeds ?? this.defaultFeeds();
        for (const feed of feeds) {
            await this.configureFeed(oracle, feed);
        }

        const middleware = await this.ensureMiddleware(oracle);

        const markets = this.params.markets ?? this.defaultMarkets();
        const vaults: Record<string, InsuranceVault> = {};
        for (const market of markets) {
            await this.configureMarket(middleware, market);
            // Per-CDO vault holding the coverage that backs this market's insuranceAmount.
            if (this.params.insuranceVaults === true) {
                const vault = await this.ensureInsuranceVault(market);
                vaults[market.cdo] = vault;
                await this.configureInsuranceConfig(market.cdo, middleware.address, vault.address);
            }
        }

        // Pre-provision the manual-distribution underwriter fee safe on each CDO (does not switch to manual mode).
        const network = this.ds.client.network;
        const underwriterFeeSafe = this.params.underwriterFeeRewardSafe ?? SymbioticConfig[network]?.underwriterFeeRewardSafe;
        if (underwriterFeeSafe != null) {
            for (const market of markets) {
                await this.configureUnderwriterFeeRewardSafe(market.cdo, underwriterFeeSafe);
            }
        }
        return { middleware, oracle, vaults };
    }

    /// Deploys the market's InsuranceVault behind a proxy.
    /// @dev One vault per CDO: it holds the swapped coverage proceeds and pays redeeming Seniors
    ///      their covered slice. Its owner is the reserve-manager multisig that funds it.
    private async ensureInsuranceVault(market: ISymbioticMarket): Promise<InsuranceVault> {
        console.log('✅ ensureInsuranceVault', market.cdo);
        const cdo = new StrataCDO(market.cdo, this.ds.client);
        const { contract } = await this.ds.ensureWithProxy(InsuranceVault, {
            id: `SymbioticInsuranceVault_${market.cdo}`,
            arguments: [],
            initialize: [
                this.owner.address,
                await cdo.acm(),
                market.cdo,
                market.coverageToken,
            ],
        });
        return contract;
    }

    /// Points a market's CDO at its InsuranceMiddleware and InsuranceVault, idempotently.
    /// @dev setInsuranceConfig is owner-gated on the CDO, so `this.owner` must be the CDO owner.
    private async configureInsuranceConfig(cdo: TEth.Address, middleware: TEth.Address, vault: TEth.Address): Promise<void> {
        const contract = new StrataCDO(cdo, this.ds.client);
        const currentMiddleware = await contract.insuranceMiddleware();
        const currentVault = await contract.insuranceVault();
        if ($address.eq(currentMiddleware, middleware) && $address.eq(currentVault, vault)) {
            return;
        }
        await contract.$receipt().setInsuranceConfig(this.owner, middleware, vault);
    }

    /// Registers the manual-distribution underwriter fee safe on a market's CDO, idempotently.
    /// @dev setUnderwriterFeeRewardSafe is owner-gated on the CDO, so `this.owner` must be the CDO owner.
    private async configureUnderwriterFeeRewardSafe(cdo: TEth.Address, safe: TEth.Address): Promise<void> {
        const contract = new StrataCDO(cdo, this.ds.client);
        const current = await contract.underwriterFeeRewardSafe();
        if (current.toLowerCase() === safe.toLowerCase()) {
            return;
        }
        await contract.$receipt().setUnderwriterFeeRewardSafe(this.owner, safe);
    }

    /// Registers or updates a single asset feed in the shared OracleAdapter, idempotently.
    private async configureFeed(oracle: OracleAdapter, feed: ISymbioticFeed): Promise<void> {
        const quoteAsset = feed.quoteAsset ?? $address.ZERO;
        const current = await oracle.feeds(feed.asset);
        const needsUpdate =
            $address.eq(current.aggregator, feed.aggregator) === false ||
            current.decimals !== feed.decimals ||
            $address.eq(current.quoteAsset, quoteAsset) === false ||
            current.heartbeat !== feed.heartbeat;

        await this.ds.configure(oracle, {
            shouldUpdate: () => needsUpdate,
            updater: async () => {
                await oracle.$receipt().setFeed(this.owner, { ...feed, quoteAsset });
            },
        });
    }

    /// Registers or updates a single market, idempotently.
    private async configureMarket(middleware: InsuranceMiddleware, market: ISymbioticMarket): Promise<void> {
        const current = await middleware.markets(market.cdo);
        const needsUpdate =
            current.accounting?.toLowerCase() !== market.accounting.toLowerCase() ||
            current.baseAsset?.toLowerCase() !== market.baseAsset.toLowerCase() ||
            current.bufferBps !== market.bufferBps ||
            current.enabled !== market.enabled;

        await this.ds.configure(middleware, {
            shouldUpdate: () => needsUpdate,
            updater: async () => {
                await middleware.$receipt().setMarket(
                    this.owner,
                    market.cdo,
                    market.accounting,
                    market.baseAsset,
                    market.bufferBps,
                    market.enabled,
                );
            },
        });
    }
}
