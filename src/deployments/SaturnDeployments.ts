import memd from 'memd';
import { AccessControlManager } from '@0xc/hardhat/AccessControlManager/AccessControlManager'
import { Web3Client } from 'dequanto/clients/Web3Client'
import { TEth } from 'dequanto/models/TEth'
import { IPlatformAccounts } from '../platforms/IPlatform'
import { $require } from 'dequanto/utils/$require'
import { SaturnStrategy } from '@0xc/hardhat/SaturnStrategy/SaturnStrategy'
import { StrataCDO } from '@0xc/hardhat/StrataCDO/StrataCDO'
import { ERC20Cooldown } from '@0xc/hardhat/ERC20Cooldown/ERC20Cooldown'
import { UnstakeCooldown } from '@0xc/hardhat/UnstakeCooldown/UnstakeCooldown'
import { $address } from 'dequanto/utils/$address'
import { SaturnCooldownRequestImpl } from '@0xc/hardhat/SaturnCooldownRequestImpl/SaturnCooldownRequestImpl';
import { SaturnAprPairProvider } from '@0xc/hardhat/SaturnAprPairProvider/SaturnAprPairProvider';
import { $date } from 'dequanto/utils/$date';
import { Constructor } from 'dequanto/utils/types';
import { MockUSDe } from '@0xc/hardhat/MockUSDe/MockUSDe';
import { MockStakedUSDat } from '@0xc/hardhat/MockStakedUSDat/MockStakedUSDat';
import { TrancheDepositor } from '@0xc/hardhat/TrancheDepositor/TrancheDepositor';
import { DeploymentsBase } from './DeploymentsBase';
import { IStrategy } from '@0xc/hardhat/IStrategy/IStrategy';
import { SUSDeAprPairProvider } from '@0xc/hardhat/sUSDeAprPairProvider/sUSDeAprPairProvider';
import { IBeaconProxy } from 'dequanto/contracts/deploy/proxy/ProxyDeployment';
import { MockERC20 } from '@0xc/hardhat/MockERC20/MockERC20';
import { LensPriceFeed } from '@0xc/hardhat/LensPriceFeed/LensPriceFeed';
import { CDOLens } from '@0xc/hardhat/CDOLens/CDOLens';


type TUnderlyingTokens = {
    sUSDat: MockStakedUSDat
}

export class SaturnDeployments extends DeploymentsBase<{
    Tokens: TUnderlyingTokens
    Strategy: SaturnStrategy
}> {

    constructor(params: {
        client: Web3Client
        deployer: TEth.EoAccount
        owner?: TEth.IAccount
        accounts?: IPlatformAccounts
        deployments?: 'throw' | 'redeploy'
    }) {
        super({
            cdo: 'saturn',
            ...params
        })
    }

    async ensureFeedProvider() {
        const acm = await this.ensureACM();
        const { sUSDat } = await this.ensureUnderlying();

        const { contract: provider } = await this.ds.ensure(SaturnAprPairProvider, {
            arguments: [
                acm.address,
                sUSDat.address,
                .075e12
            ]
        });

        if (this.accounts.safe.worker) {
            await this.ensureRole(
                this.ROLES.UPDATER_FEED_ROLE,
                this.accounts.safe.worker.address
            );
        }
        return {
            provider: provider as any as InstanceType<typeof SUSDeAprPairProvider>
        };
    }

    @memd.deco.memoize({ perInstance: true })
    async ensureUnderlying(): Promise<{
        base: MockUSDe
        sUSDat: MockStakedUSDat
    }> {
        let network = this.ds.client.network;
        if (network === 'hardhat') {
            // MockUSDat (6 decimals, mintable)
            let USDat = await this.ds.ensureContract(MockERC20, {
                id: 'MockUSDat',
                arguments: [
                    'MockUSDat',
                    6
                ],
            });
            let sUSDat = await this.ds.ensureContract(MockStakedUSDat, {
                arguments: [
                    USDat.address,
                    this.owner.address,
                ]
            });
            return {
                base: USDat as any as MockUSDe,
                sUSDat,
            };
        }

        const create = <T>(Ctor: Constructor<T>, symbol: string): T => {
            let address = $require.Address(this.platform.Tokens[symbol].address);
            let contract = new Ctor(address, this.ds.client);
            return contract;
        };

        return {
            base: create(MockUSDe, 'USDat'),
            sUSDat: create(MockStakedUSDat, 'sUSDat'),
        };
    }

    async ensureUnstakeImplemenetations(): Promise<{ token: TEth.Address; impl: IBeaconProxy }[]> {
        let { sUSDat } = await this.ensureUnderlying();
        const { contractBeaconProxy: saturnCooldownRequestImpl } = await this.ds.ensureWithBeacon(
            SaturnCooldownRequestImpl,
            {
                id: this.getContractId('SaturnCooldownRequestBeacon'),
                arguments: [sUSDat.address],
                initialize: [$address.ZERO, $address.ZERO],
            }
        );

        return [
            { token: sUSDat.address, impl: saturnCooldownRequestImpl },
        ];
    }

    protected async ensureStrategy(
        cdo: StrataCDO,
        acm: AccessControlManager,
        erc20Cooldown: ERC20Cooldown,
        unstakeCooldown: UnstakeCooldown,
    ): Promise<{ strategy: SaturnStrategy; }> {
        const { sUSDat } = await this.ensureUnderlying();
        const { contract: strategy } = await this.ds.ensureWithProxy(SaturnStrategy, {
            id: this.getContractId('SaturnStrategy'),
            arguments: [
                sUSDat.address,
            ],
            initialize: [
                this.owner.address,
                acm.address,
                cdo.address,
                erc20Cooldown.address,
                unstakeCooldown.address,
            ],
        });
        return { strategy };
    }

    async configureCooldowns(strategy: IStrategy): Promise<void> {
        const saturnStrategy = strategy as any as SaturnStrategy;
        const cdoInfo = this.cdoInfo;

        const jrtCooldown = typeof cdoInfo.jrt['sUSDatCooldown'] === 'string'
            ? $date.parseTimespan(cdoInfo.jrt['sUSDatCooldown'], { get: 's' })
            : cdoInfo.jrt['sUSDatCooldown'] ?? 0;
        const srtCooldown = typeof cdoInfo.srt['sUSDatCooldown'] === 'string'
            ? $date.parseTimespan(cdoInfo.srt['sUSDatCooldown'], { get: 's' })
            : cdoInfo.srt['sUSDatCooldown'] ?? 0;

        const [currentJrt, currentSrt] = await Promise.all([
            saturnStrategy.sUSDatCooldownJrt(),
            saturnStrategy.sUSDatCooldownSrt(),
        ]);

        if (currentJrt !== BigInt(jrtCooldown) || currentSrt !== BigInt(srtCooldown)) {
            await saturnStrategy.$receipt().setCooldowns(
                this.owner,
                BigInt(jrtCooldown),
                BigInt(srtCooldown)
            );
        }
    }

    async configureDepositor(depositor: TrancheDepositor) {
        let { base } = await this.ensureUnderlying();
        let { cdo, jrtVault } = await this.ensureCDO();

        let status = await depositor.tranches(jrtVault.address, base.address);
        if (status == false) {
            await depositor.$receipt().addCdo(this.owner, cdo.address);
        }

        return depositor;
    }


    async configureLenses() {
        const lens = await this.get(CDOLens);
        const { base } = await this.ensureUnderlying();

        const { contract: USDatPriceFeed } = await this.ds.ensure(LensPriceFeed, {
            id: this.getContractId(`LensPriceFeed`),
            arguments: [this.owner.address],
        });

        await this.ds.configure(lens, {
            title: 'Price Feed for USDat',
            shouldUpdate: async () => false === $address.eq(USDatPriceFeed.address, await lens.priceFeeds(base.address)),
            updater: async () => {
                const owner = await this.getAccountOwner(lens.address);
                await lens.$receipt().setPriceFeed(owner, base.address, USDatPriceFeed.address);
            }
        });

        return { lens };
    }
}
