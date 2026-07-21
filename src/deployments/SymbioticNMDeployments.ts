import { Deployments } from 'dequanto/contracts/deploy/Deployments';
import { Web3Client } from 'dequanto/clients/Web3Client';
import { TEth } from 'dequanto/models/TEth';
import { $require } from 'dequanto/utils/$require';
import { NetworkMiddleware } from '@0xc/hardhat/NetworkMiddleware/NetworkMiddleware';
import { OracleAdapter } from '@0xc/hardhat/OracleAdapter/OracleAdapter';

/// A market entry to register in the middleware's coverage registry.
export interface ISymbioticMarket {
    cdo: TEth.Address;
    accounting: TEth.Address;
    baseAsset: TEth.Address;
    oracle?: TEth.Address;   // defaults to the shared 1:1 OracleAdapter when omitted
    bufferBps: bigint;
    enabled: boolean;
}

export interface ISymbioticNMParams {
    client: Web3Client;
    deployer: TEth.EoAccount;
    /// Owner of the middleware (governance / timelock multisig). Defaults to the deployer.
    owner?: TEth.IAccount;
    /// The Symbiotic AppAdapter this middleware drives (deployed on the Symbiotic side).
    appAdapter: TEth.Address;
    /// Markets sharing this middleware's AppAdapter.
    markets?: ISymbioticMarket[];
    /// Behaviour when the deployed bytecode differs; mirrors DeploymentsBase.
    deployments?: 'throw' | 'redeploy';
    isTest?: boolean;
}

/// @notice Deploys the single, shared Symbiotic NetworkMiddleware (+ the 1:1 OracleAdapter) and
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

    /// Deploys the 1:1 OracleAdapter (base stablecoins <-> vault asset priced at $1).
    async ensureOracle(): Promise<OracleAdapter> {
        return await this.ds.ensureContract(OracleAdapter, {
            id: 'SymbioticOracleAdapter',
        });
    }

    /// Deploys the shared NetworkMiddleware behind a proxy, initialized with the AppAdapter.
    async ensureMiddleware(): Promise<NetworkMiddleware> {
        const appAdapter = $require.Address(this.params.appAdapter);
        const { contract } = await this.ds.ensureWithProxy(NetworkMiddleware, {
            id: 'SymbioticNetworkMiddleware',
            arguments: [],
            initialize: [
                this.owner.address,
                appAdapter,
            ],
        });
        return contract;
    }

    /// Full deployment: oracle + middleware, then register the configured markets.
    async ensureDeployment(): Promise<{ middleware: NetworkMiddleware; oracle: OracleAdapter }> {
        const oracle = await this.ensureOracle();
        const middleware = await this.ensureMiddleware();

        for (const market of this.params.markets ?? []) {
            await this.configureMarket(middleware, oracle, market);
        }
        return { middleware, oracle };
    }

    /// Registers or updates a single market, idempotently.
    async configureMarket(middleware: NetworkMiddleware, oracle: OracleAdapter, market: ISymbioticMarket): Promise<void> {
        const oracleAddress = market.oracle ?? oracle.address;
        const current = await middleware.markets(market.cdo);
        const needsUpdate =
            current.accounting?.toLowerCase() !== market.accounting.toLowerCase() ||
            current.baseAsset?.toLowerCase() !== market.baseAsset.toLowerCase() ||
            current.oracle?.toLowerCase() !== oracleAddress.toLowerCase() ||
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
                    oracleAddress,
                    market.bufferBps,
                    market.enabled,
                );
            },
        });
    }
}
