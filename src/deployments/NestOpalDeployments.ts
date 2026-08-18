import memd from 'memd';
import { AccessControlManager } from '@0xc/hardhat/AccessControlManager/AccessControlManager'
import { Web3Client } from 'dequanto/clients/Web3Client'
import { TEth } from 'dequanto/models/TEth'
import { IPlatformAccounts } from '../platforms/IPlatform'
import { $require } from 'dequanto/utils/$require'
import { StrataCDO } from '@0xc/hardhat/StrataCDO/StrataCDO'
import { ERC20Cooldown } from '@0xc/hardhat/ERC20Cooldown/ERC20Cooldown'
import { UnstakeCooldown } from '@0xc/hardhat/UnstakeCooldown/UnstakeCooldown'
import { $address } from 'dequanto/utils/$address'
import { Constructor } from 'dequanto/utils/types';
import { TrancheDepositor } from '@0xc/hardhat/TrancheDepositor/TrancheDepositor';
import { DeploymentsBase } from './DeploymentsBase';
import { IStrategy } from '@0xc/hardhat/IStrategy/IStrategy';
import { IBeaconProxy } from 'dequanto/contracts/deploy/proxy/ProxyDeployment';
import { MockERC20 } from '@0xc/hardhat/MockERC20/MockERC20';
import { MockUSDe } from '@0xc/hardhat/MockUSDe/MockUSDe';
import { AprPairFeed } from '@0xc/hardhat/AprPairFeed/AprPairFeed';
import { NestOpalStrategy } from '@0xc/hardhat/NestOpalStrategy/NestOpalStrategy';
import { NestAccountantAprProvider } from '@0xc/hardhat/NestAccountantAprProvider/NestAccountantAprProvider';
import { $boringVault } from '@s/utils/$boringVault';
import { $date } from 'dequanto/utils/$date';
import { l } from 'dequanto/utils/$logger';
import { NestOpalDepositAdapter } from '@0xc/hardhat/NestOpalDepositAdapter/NestOpalDepositAdapter';
import { Eth } from '@s/platforms/Eth';
import { ERC20 } from 'dequanto/prebuilt/openzeppelin/ERC20';


type TUnderlyingContracts = {
    USDC: MockERC20
    nOPAL: MockERC20
}

export class NestOpalDeployments extends DeploymentsBase<{
    Tokens: TUnderlyingContracts
    Strategy: NestOpalStrategy
}> {

    constructor(params: {
        client: Web3Client
        deployer: TEth.EoAccount
        owner?: TEth.IAccount
        accounts?: IPlatformAccounts
        deployments?: 'throw' | 'redeploy'
    }) {
        super({
            cdo: 'nestopal',
            ...params
        })
    }

    async ensureFeedProvider() {
        let network = this.ds.client.network;
        if (network === 'hardhat') {
            // In hardhat tests the accountant mock is deployed by the test harness
            return { provider: $address.ZERO };
        }

        $require.notNull(this.platform.nestopal, `nestopal platform config required`);
        const accountantAddress = this.platform.nestopal.accountant;
        const ROUNDS = 10;
        const toBlock = await this.client.getBlockNumber();
        const rounds = await $boringVault.fetchLatestRounds(accountantAddress, ROUNDS, { toBlock });
        const { contract: provider } = await this.ds.ensure(NestAccountantAprProvider, {
            arguments: [
                accountantAddress,
                rounds
            ]
        });

        l`Rounds ${
            $date.format($date.fromUnixTimestamp(rounds[0].updatedAt), 'yyyy-MM-dd HH:mm')
        } - ${
            $date.format($date.fromUnixTimestamp(rounds[ROUNDS - 1].updatedAt), 'yyyy-MM-dd HH:mm')
        } APR yellow<${await provider.getAprPair()}>`;


        return { provider };
    }

    @memd.deco.memoize({ perInstance: true })
    async ensureUnderlying(): Promise<{
        base: MockUSDe
    } & TUnderlyingContracts> {
        let network = this.ds.client.network;
        if (network === 'hardhat') {
            const USDC = await this.ds.ensureContract(MockERC20, {
                id: 'USDC',
                arguments: ['USDC', 6]
            });
            const nOPAL = await this.ds.ensureContract(MockERC20, {
                id: 'nOPAL',
                arguments: ['Nest BlackOpal LiquidStone II Vault', 6]
            });
            return {
                base: USDC as any,
                USDC,
                nOPAL,
            };
        }

        const { Tokens, nestopal } = this.platform;
        $require.notNull(nestopal, `nestopal platform config is required for mainnet`);

        const create = <T>(Ctor: Constructor<T>, symbolOrAddress: string | TEth.Address): T => {
            let address = $require.Address(Tokens[symbolOrAddress]?.address ?? symbolOrAddress);
            let contract = new Ctor(address, this.ds.client);
            return contract;
        };

        return {
            base: create(MockERC20, 'USDC') as any,
            USDC: create(MockERC20, 'USDC'),
            nOPAL: create(MockERC20, nestopal.nOPAL),
        };
    }

    async ensureUnstakeImplemenetations(): Promise<{ token: TEth.Address; impl: IBeaconProxy }[]> {
        // nOPAL strategy uses erc20Cooldown only — no unstake cooldown mechanism.
        // Users withdraw nOPAL from the strategy and redeem nOPAL→USDC through
        // the Nest vault independently.
        return [];
    }

    protected async ensureStrategy(
        cdo: StrataCDO,
        acm: AccessControlManager,
        erc20Cooldown: ERC20Cooldown,
        unstakeCooldown: UnstakeCooldown,
    ): Promise<{ strategy: NestOpalStrategy; }> {
        const { USDC, nOPAL } = await this.ensureUnderlying();
        let network = this.ds.client.network;
        let accountantAddress: TEth.Address;

        if (network === 'hardhat') {
            accountantAddress = $address.ZERO;
        } else {
            $require.notNull(this.platform.nestopal, `nestopal platform config required`);
            accountantAddress = this.platform.nestopal.accountant;
        }

        const { contract: strategy } = await this.ds.ensureWithProxy(NestOpalStrategy, {
            id: `${this.pfx}NestOpalStrategy`,
            arguments: [
                nOPAL.address,
                USDC.address,
                accountantAddress,
            ],
            initialize: [
                this.owner.address,
                acm.address,
                cdo.address,
                erc20Cooldown.address,
            ]
        });
        return { strategy }
    }

    async configureCooldowns(strategy: IStrategy): Promise<void> {
        // Cooldown periods are set via setCooldowns() on the strategy.
    }

    async configureDepositor(depositor: TrancheDepositor) {
        let { USDC } = await this.ensureUnderlying();
        let { cdo, jrtVault } = await this.ensureCDO();

        let config = await depositor.trancheAdapterSwaps(jrtVault.address, USDC.address);
        if (config.adapter == $address.ZERO) {
            const depositorProxy = await this.ds.ensureContract(NestOpalDepositAdapter, {
                arguments: [
                    Eth.nestopal.predicateProxy,
                    Eth.nestopal.nestVault,
                    Eth.nestopal.nOPAL,
                ]
            });
            await depositor.$receipt().addCdoAdapterSwap(this.owner, cdo.address, USDC.address, {
                adapter: depositorProxy.address,
                minimumReturnPercentage: 900,
                tokenOut: Eth.nestopal.nOPAL
            });
        }

        return depositor;
    }

    protected override async configureAprFeed(feed: AprPairFeed) {
        let { provider, strategy } = await this.ensureCDO();
        await this.ds.configure(strategy, {
            shouldUpdate: async () => {
                return $address.eq(provider.address, await strategy.aprProvider()) === false
            },
            updater: async () => {
                await strategy.$receipt().setAprProvider(this.owner, provider.address);
            }
        })
    }

    protected async getDepositToken (): Promise<ERC20> {
        let { nOPAL } = await this.ensureUnderlying();
        return nOPAL as any as ERC20;
    }

    protected getDepositAmount (): number {
        return 16;
    }
}
