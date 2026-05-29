import memd from 'memd';
import { AccessControlManager } from '@0xc/hardhat/AccessControlManager/AccessControlManager'
import { TEth } from 'dequanto/models/TEth'
import { $require } from 'dequanto/utils/$require'
import { StrataCDO } from '@0xc/hardhat/StrataCDO/StrataCDO'
import { ERC20Cooldown } from '@0xc/hardhat/ERC20Cooldown/ERC20Cooldown'
import { UnstakeCooldown } from '@0xc/hardhat/UnstakeCooldown/UnstakeCooldown'
import { $address } from 'dequanto/utils/$address'
import { Constructor } from 'dequanto/utils/types';
import { Addresses } from '@s/constants';
import { TrancheDepositor } from '@0xc/hardhat/TrancheDepositor/TrancheDepositor';
import { DeploymentsBase, IDeploymentsBaseParams } from './DeploymentsBase';
import { IStrategy } from '@0xc/hardhat/IStrategy/IStrategy';
import { IBeaconProxy } from 'dequanto/contracts/deploy/proxy/ProxyDeployment';
import { MockMToken } from '@0xc/hardhat/MockMToken/MockMToken';
import { MockOracle } from '@0xc/hardhat/MockOracle/MockOracle';
import { MockDepositVault } from '@0xc/hardhat/MockDepositVault/MockDepositVault';
import { MockRedemptionVault } from '@0xc/hardhat/MockRedemptionVault/MockRedemptionVault';
import { MidasStrategy } from '@0xc/hardhat/MidasStrategy/MidasStrategy';
import { AaveOracleAprPairProvider } from '@0xc/hardhat/AaveOracleAprPairProvider/AaveOracleAprPairProvider';
import { MockERC20 } from '@0xc/hardhat/MockERC20/MockERC20';
import { MidasCooldownRequestImpl } from '@0xc/hardhat/MidasCooldownRequestImpl/MidasCooldownRequestImpl';
import { MockUSDe } from '@0xc/hardhat/MockUSDe/MockUSDe';
import { MockERC4626 } from '@0xc/hardhat/MockERC4626/MockERC4626';
import { AprPairFeed } from '@0xc/hardhat/AprPairFeed/AprPairFeed';
// Bindings for these contracts must be generated: run `npx hardhat compile && npx 0xweb generate`
import { IsolatedStrategy } from '@0xc/hardhat/IsolatedStrategy/IsolatedStrategy';
import { SparkUSDCStrategy } from '@0xc/hardhat/SparkUSDCStrategy/SparkUSDCStrategy';
import { Rebalancer } from '@0xc/hardhat/Rebalancer/Rebalancer';


type TIsolatedTokens = {
    USDC: MockERC20
    DAI: MockERC20
    USDS: MockERC20
    spVault: MockERC4626       // ERC4626 Spark USDC savings vault
    mHYPER: MockMToken
    oracle: MockOracle
    depositVault: MockDepositVault
    redemptionVault: MockRedemptionVault
}

export class SpkMhyperIsoDeployments extends DeploymentsBase<{
    Tokens: TIsolatedTokens
    Strategy: IsolatedStrategy
}> {

    constructor(params: IDeploymentsBaseParams) {
        super({
            cdo: 'spkMhyperIso',
            ...params
        })
    }

    async ensureFeedProvider() {
        let { oracle } = await this.ensureUnderlying();
        let acm = await this.ensureACM();
        let network = this.ds.client.network;
        let aavePool = Addresses[network]?.AavePool;
        if (aavePool == null) {
            return { provider: null };
        }

        const { contract: provider } = await this.ds.ensure(AaveOracleAprPairProvider, {
            id: `${this.pfx}AaveOracleAprPairProvider`,
            arguments: [
                acm.address,
                aavePool,
                [
                    $require.Address(Addresses[network].USDC),
                    $require.Address(Addresses[network].USDT),
                ],
                oracle.address,
            ]
        });

        return { provider };
    }

    @memd.deco.memoize({ perInstance: true })
    async ensureUnderlying(): Promise<{ base: MockUSDe } & TIsolatedTokens> {
        let network = this.ds.client.network;

        if (network === 'hardhat') {
            const USDC = await this.ds.ensureContract(MockERC20, {
                id: 'USDC',
                arguments: ['USDC', 6]
            });
            const DAI = await this.ds.ensureContract(MockERC20, {
                id: 'DAI',
                arguments: ['DAI', 18]
            });
            const USDS = await this.ds.ensureContract(MockERC20, {
                id: 'USDS',
                arguments: ['USDS', 18]
            });

            const spVault = await this.ds.ensureContract(MockERC4626, {
                id: 'SparkUSDCVault',
                arguments: [USDC.address]
            });

            const mHYPER = await this.ds.ensureContract(MockMToken);
            const depositVault = await this.ds.ensureContract(MockDepositVault, {
                arguments: [mHYPER.address]
            });
            const redemptionVault = await this.ds.ensureContract(MockRedemptionVault, {
                arguments: [mHYPER.address, USDC.address]
            });
            const oracle = await this.ds.ensureContract(MockOracle);

            return {
                base: USDC as any,
                USDC,
                DAI,
                USDS,
                spVault,
                mHYPER,
                oracle,
                depositVault,
                redemptionVault,
            };
        }

        const { Tokens, mhyper } = this.platform;

        const create = <T>(Ctor: Constructor<T>, symbolOrAddress: string | TEth.Address): T => {
            let address = $require.Address(Tokens[symbolOrAddress]?.address ?? symbolOrAddress);
            return new Ctor(address, this.ds.client);
        };

        return {
            base: create(MockERC20, 'USDC') as any,
            USDC: create(MockERC20, 'USDC'),
            DAI: create(MockERC20, 'DAI'),
            USDS: create(MockERC20, 'USDS'),
            spVault: create(MockERC4626, $require.Address(Addresses[network].SparkUSDCVault, 'SparkUSDCVault not configured')),
            mHYPER: create(MockMToken, 'mHYPER'),
            oracle: create(MockOracle, mhyper.oracle),
            depositVault: create(MockDepositVault, mhyper.depositVault),
            redemptionVault: create(MockRedemptionVault, mhyper.redemptionVault),
        };
    }

    async ensureUnstakeImplemenetations(): Promise<{ token: TEth.Address; impl: IBeaconProxy }[]> {
        let { USDC, mHYPER, redemptionVault } = await this.ensureUnderlying();
        const { contractBeaconProxy: midasCooldownRequestImpl } = await this.ds.ensureWithBeacon(MidasCooldownRequestImpl, {
            id: `${this.pfx}CooldownRequestBeacon`,
            arguments: [USDC.address, mHYPER.address, redemptionVault.address],
            initialize: [$address.ZERO, $address.ZERO]
        });

        return [
            { token: mHYPER.address, impl: midasCooldownRequestImpl }
        ];
    }

    protected async ensureStrategy(
        cdo: StrataCDO,
        acm: AccessControlManager,
        erc20Cooldown: ERC20Cooldown,
        unstakeCooldown: UnstakeCooldown,
    ): Promise<{ strategy: IsolatedStrategy }> {
        const { USDC, DAI, USDS, spVault, mHYPER, depositVault, redemptionVault, oracle } = await this.ensureUnderlying();

        // IsolatedStrategy must exist before sub-strats (they reference it as their parent),
        // but strat addresses aren't known until both sub-strats are deployed.
        // Deploy the proxy without calling initialize by presenting a stripped ABI to the
        // deployment framework (which requires the exact initialize arg count). After bith
        // sub-strats are deployed we call initialize().
        class IsolatedStrategyDeferInit extends IsolatedStrategy {
            constructor(...args: ConstructorParameters<typeof IsolatedStrategy>) {
                super(...args);
                this.abi = this.abi.filter((x: any) => x.name !== 'initialize') as any;
            }
        }

        const { contract: strategyProxy } = await this.ds.ensureWithProxy(IsolatedStrategyDeferInit as any, {
            id: `${this.pfx}IsolatedStrategy`,
            arguments: [],
        });
        // Use the full binding for all subsequent calls so initialize() is available.
        const strategy = new IsolatedStrategy(strategyProxy.address, this.ds.client);

        // Junior strat: SparkUSDCStrategy — liquid Spark USDC vault, instant redemptions.
        // Cooldowns left at 0: no locking needed in the isolated context.
        const { contract: juniorStrat } = await this.ds.ensureWithProxy(SparkUSDCStrategy, {
            id: `${this.pfx}SparkStrategy`,
            arguments: [spVault.address],
            initialize: [
                this.owner.address,
                acm.address,
                strategy.address,
                erc20Cooldown.address,
            ],
        });

        // Senior strat: MidasStrategy — illiquid mHYPER vault, async cooldown redemptions.
        const { contract: seniorStrat } = await this.ds.ensureWithProxy(MidasStrategy, {
            id: `${this.pfx}MidasStrategy`,
            arguments: [
                USDC.address,
                mHYPER.address,
                depositVault.address,
                redemptionVault.address,
                oracle.address,
            ],
            initialize: [
                this.owner.address,
                acm.address,
                strategy.address,
                erc20Cooldown.address,
                unstakeCooldown.address,
                [DAI.address, USDS.address],
            ],
        });
        await this.ensureRole(this.ROLES.COOLDOWN_WORKER_ROLE, juniorStrat.address);
        await this.ensureRole(this.ROLES.COOLDOWN_WORKER_ROLE, seniorStrat.address);

        // Both sub-strats are ready — initialize IsolatedStrategy.
        await this.ds.configure(strategy, {
            title: 'Initialize IsolatedStrategy',
            // cdo() is set during initialize and safe to read before init (no array access).
            shouldUpdate: async () => $address.eq(await strategy.cdo(), $address.ZERO),
            updater: async () => {
                await strategy.$receipt().initialize(
                    this.owner,
                    this.owner.address,
                    acm.address,
                    cdo.address,
                    juniorStrat.address,
                    seniorStrat.address,
                    300000000000000000n, // juniorAllocationFloor: 30% (0.3e18 WAD)
                );
            },
        });

        // Rebalancer: executes cross-strat rebalances (immediate for Spark, deferred for Midas).
        const { contract: rebalancer } = await this.ds.ensureWithProxy(Rebalancer, {
            id: `${this.pfx}Rebalancer`,
            initialize: [
                this.owner.address,
                acm.address,
                strategy.address,
                unstakeCooldown.address,
            ],
        });

        await this.ds.configure(strategy, {
            title: 'Set Rebalancer on IsolatedStrategy',
            shouldUpdate: async () => $address.eq(await strategy.rebalancer(), $address.ZERO),
            updater: async () => {
                await strategy.$receipt().setRebalancer(this.owner, rebalancer.address);
            },
        });

        const accounting = await this.ensureAccounting(cdo.address);
        await this.ds.configure(strategy, {
            title: 'Set Accounting on IsolatedStrategy',
            shouldUpdate: async () => $address.eq(await strategy.accounting(), $address.ZERO),
            updater: async () => {
                await strategy.$receipt().setAccounting(this.owner, accounting.address);
            },
        });

        return { strategy };
    }

    async configureCooldowns(_strategy: IStrategy): Promise<void> {
        // Midas mHYPER cooldowns are disabled by default (instant redemptions).
        // Set non-zero values here if Midas requires a cooldown period in the production deployment.
    }

    async configureDepositor(depositor: TrancheDepositor) {
        let { USDC } = await this.ensureUnderlying();
        let { cdo, jrtVault } = await this.ensureCDO();

        let status = await depositor.tranches(jrtVault.address, USDC.address);
        if (status == false) {
            await depositor.$receipt().addCdo(this.owner, cdo.address);
        }

        return depositor;
    }

    protected override async configureAprFeed(_feed: AprPairFeed) {
        const { provider } = await this.ensureFeedProvider();
        if (provider == null) {
            return;
        }

        const spread = 0.03e12;
        await this.ds.configure(provider, {
            title: 'Update spread',
            value: spread,
            current: provider.spread(),
            updater: async () => {
                await provider.$receipt().setSpread(this.owner, spread);
            }
        });
    }
}
