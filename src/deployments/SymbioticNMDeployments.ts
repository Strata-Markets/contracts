import { Deployments } from 'dequanto/contracts/deploy/Deployments';
import { Web3Client } from 'dequanto/clients/Web3Client';
import { TEth } from 'dequanto/models/TEth';
import { $require } from 'dequanto/utils/$require';
import { NetworkMiddleware } from '@0xc/hardhat/NetworkMiddleware/NetworkMiddleware';
import { OracleAdapter } from '@0xc/hardhat/OracleAdapter/OracleAdapter';
import { StrataCDO } from '@0xc/hardhat/StrataCDO/StrataCDO';
import { Addresses, ChainlinkFeeds } from '@s/constants';
import { SymbioticConfig } from '@s/platforms/symbiotic/SymbioticConfig';

/// Default staleness bound for the registered feeds (seconds). Overridable per-feed.
const DEFAULT_HEARTBEAT = 86400n; // 24h

const ZERO_ADDRESS: TEth.Address = '0x0000000000000000000000000000000000000000';

/// A market entry to register in the middleware's coverage registry.
export interface ISymbioticMarket {
    cdo: TEth.Address;
    accounting: TEth.Address;
    baseAsset: TEth.Address;
    bufferBps: bigint;
    enabled: boolean;
}

/// A Chainlink feed to register in the shared OracleAdapter, keyed by the priced asset.
/// Single-hop assets (e.g. USDC/USD) leave `quote` unset; two-hop assets (e.g. uniBTC priced as
/// uniBTC/BTC x BTC/USD) set both hops.
export interface ISymbioticFeed {
    asset: TEth.Address;
    base: TEth.Address;         // first-hop aggregator (e.g. USDC/USD or uniBTC/BTC)
    baseDecimals: bigint;
    quote?: TEth.Address;       // optional second-hop aggregator (e.g. BTC/USD)
    quoteDecimals?: bigint;
    heartbeat: bigint;          // max round age (seconds) before a price is stale; 0 disables
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
    /// Dedicated safe for manual premium distribution, registered on every market's CDO
    /// (setPremiumRewardSafe). Defaults to SymbioticConfig[network].premiumRewardSafe. Unset = skip.
    premiumRewardSafe?: TEth.Address;
    /// Behaviour when the deployed bytecode differs; mirrors DeploymentsBase.
    deployments?: 'throw' | 'redeploy';
    isTest?: boolean;
}

/// @notice Deploys the single, shared Symbiotic NetworkMiddleware (+ the shared OracleAdapter) and
///         registers the Strata markets that share its AppAdapter.
/// @dev The middleware is NOT per-CDO: one instance is shared across all markets, so this is a
///      standalone deployment (not a per-CDO DeploymentsBase). The AppAdapter is deployed on the
///      Symbiotic side and passed in.
export class SymbioticNMDeployments {

    ds: Deployments;
    owner: TEth.IAccount;

    constructor(public params: ISymbioticNMParams) {
        this.owner = params.owner ?? params.deployer;
        this.ds = new Deployments(params.client, params.deployer, {
            directory: `./deployments/${params.isTest ? 'test/' : ''}`,
            whenBytecodeChanged: params.deployments ?? null,
        });
    }

    /// Deploys the shared, upgradeable OracleAdapter (project-wide, per-asset feed registry).
    async ensureOracle(): Promise<OracleAdapter> {
        const { contract } = await this.ds.ensureWithProxy(OracleAdapter, {
            id: 'SymbioticOracleAdapter',
            arguments: [],
            initialize: [this.owner.address],
        });
        return contract;
    }

    /// Resolves the AppAdapter address from params, falling back to the network config.
    appAdapter(): TEth.Address {
        const network = this.ds.client.network;
        const address = this.params.appAdapter ?? SymbioticConfig[network]?.appAdapter;
        return $require.Address(address, `No AppAdapter configured for network '${network}'`);
    }

    /// Deploys the shared NetworkMiddleware behind a proxy, initialized with the AppAdapter and oracle.
    async ensureMiddleware(oracle: OracleAdapter): Promise<NetworkMiddleware> {
        const appAdapter = this.appAdapter();
        const { contract } = await this.ds.ensureWithProxy(NetworkMiddleware, {
            id: 'SymbioticNetworkMiddleware',
            arguments: [],
            initialize: [
                this.owner.address,
                appAdapter,
                oracle.address,
            ],
        });
        return contract;
    }

    /// Builds the feed set for the current network from src/constants.ts (Addresses + ChainlinkFeeds):
    /// USDe/USDC price single-hop against USD; uniBTC prices two-hop as uniBTC/BTC x BTC/USD.
    defaultFeeds(): ISymbioticFeed[] {
        const network = this.ds.client.network;
        const A = Addresses[network];
        const F = ChainlinkFeeds[network];
        $require.notNull(F, `No Chainlink feeds configured for network '${network}'`);

        const feeds: ISymbioticFeed[] = [];
        if (A?.USDe && F['USDe/USD']) {
            feeds.push({ asset: A.USDe, base: F['USDe/USD'].address, baseDecimals: BigInt(F['USDe/USD'].decimals), heartbeat: DEFAULT_HEARTBEAT });
        }
        if (A?.USDC && F['USDC/USD']) {
            feeds.push({ asset: A.USDC, base: F['USDC/USD'].address, baseDecimals: BigInt(F['USDC/USD'].decimals), heartbeat: DEFAULT_HEARTBEAT });
        }
        if (A?.uniBTC && F['uniBTC/BTC'] && F['BTC/USD']) {
            feeds.push({
                asset: A.uniBTC,
                base: F['uniBTC/BTC'].address, baseDecimals: BigInt(F['uniBTC/BTC'].decimals),
                quote: F['BTC/USD'].address, quoteDecimals: BigInt(F['BTC/USD'].decimals),
                heartbeat: DEFAULT_HEARTBEAT,
            });
        }
        return feeds;
    }

    /// Builds the market set for the current network from src/platforms/symbiotic/SymbioticConfig.ts,
    /// resolving each market's base-asset symbol to an address via Addresses[network].
    defaultMarkets(): ISymbioticMarket[] {
        const network = this.ds.client.network;
        const cfg = SymbioticConfig[network];
        $require.notNull(cfg, `No Symbiotic markets configured for network '${network}'`);
        const A = Addresses[network];

        return cfg.markets.map(m => {
            const baseAsset = A?.[m.baseAsset as keyof typeof A] as TEth.Address | undefined;
            $require.Address(baseAsset, `No address for base asset '${m.baseAsset}' (market ${m.name}) on '${network}'`);
            return {
                cdo: m.cdo,
                accounting: m.accounting,
                baseAsset: baseAsset!,
                bufferBps: m.bufferBps,
                enabled: m.enabled,
            };
        });
    }

    /// Full deployment: oracle + feeds + middleware, then register the configured markets.
    async ensureDeployment(): Promise<{ middleware: NetworkMiddleware; oracle: OracleAdapter }> {
        const oracle = await this.ensureOracle();

        // Explicit feeds/markets override the config-derived defaults for the current network.
        const feeds = this.params.feeds ?? this.defaultFeeds();
        for (const feed of feeds) {
            await this.configureFeed(oracle, feed);
        }

        const middleware = await this.ensureMiddleware(oracle);

        const markets = this.params.markets ?? this.defaultMarkets();
        for (const market of markets) {
            await this.configureMarket(middleware, market);
        }

        // Pre-provision the manual-distribution premium safe on each CDO (does not switch to manual mode).
        const network = this.ds.client.network;
        const premiumSafe = this.params.premiumRewardSafe ?? SymbioticConfig[network]?.premiumRewardSafe;
        if (premiumSafe != null) {
            for (const market of markets) {
                await this.configurePremiumRewardSafe(market.cdo, premiumSafe);
            }
        }
        return { middleware, oracle };
    }

    /// Registers the manual-distribution premium safe on a market's CDO, idempotently.
    /// @dev setPremiumRewardSafe is owner-gated on the CDO, so `this.owner` must be the CDO owner.
    async configurePremiumRewardSafe(cdo: TEth.Address, safe: TEth.Address): Promise<void> {
        const contract = new StrataCDO(cdo, this.ds.client);
        const current = await contract.premiumRewardSafe();
        if (current.toLowerCase() === safe.toLowerCase()) {
            return;
        }
        await contract.$receipt().setPremiumRewardSafe(this.owner, safe);
    }

    /// Registers or updates a single asset feed in the shared OracleAdapter, idempotently.
    async configureFeed(oracle: OracleAdapter, feed: ISymbioticFeed): Promise<void> {
        const quote = feed.quote ?? ZERO_ADDRESS;
        const quoteDecimals = feed.quoteDecimals ?? 0n;
        const current = await oracle.feeds(feed.asset);
        const needsUpdate =
            current.base?.toLowerCase() !== feed.base.toLowerCase() ||
            current.baseDecimals !== feed.baseDecimals ||
            current.quote?.toLowerCase() !== quote.toLowerCase() ||
            current.quoteDecimals !== quoteDecimals ||
            current.heartbeat !== feed.heartbeat;

        await this.ds.configure(oracle, {
            shouldUpdate: () => needsUpdate,
            updater: async () => {
                await oracle.$receipt().setFeed(
                    this.owner,
                    feed.asset,
                    feed.base,
                    feed.baseDecimals,
                    quote,
                    quoteDecimals,
                    feed.heartbeat,
                );
            },
        });
    }

    /// Registers or updates a single market, idempotently.
    async configureMarket(middleware: NetworkMiddleware, market: ISymbioticMarket): Promise<void> {
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
