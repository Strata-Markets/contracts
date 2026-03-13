import memd from 'memd';
import { AccessControlManager } from '@0xc/hardhat/AccessControlManager/AccessControlManager'
import { Web3Client } from 'dequanto/clients/Web3Client'
import { TEth } from 'dequanto/models/TEth'
import { IPlatformAccounts } from '../platforms/IPlatform'
import { $require } from 'dequanto/utils/$require'
import { SNUSDStrategy } from '@0xc/hardhat/sNUSDStrategy/sNUSDStrategy'
import { StrataCDO } from '@0xc/hardhat/StrataCDO/StrataCDO'
import { ERC20Cooldown } from '@0xc/hardhat/ERC20Cooldown/ERC20Cooldown'
import { UnstakeCooldown } from '@0xc/hardhat/UnstakeCooldown/UnstakeCooldown'
import { $address } from 'dequanto/utils/$address'
import { SNUSDCooldownRequestImpl } from '@0xc/hardhat/sNUSDCooldownRequestImpl/sNUSDCooldownRequestImpl';
import { $date } from 'dequanto/utils/$date';
import { SNUSDAprPairProvider } from '@0xc/hardhat/sNUSDAprPairProvider/sNUSDAprPairProvider';
import { Constructor } from 'dequanto/utils/types';
import { Addresses } from '@s/constants';
import { MockNUSD } from '@0xc/hardhat/MockNUSD/MockNUSD';
import { MockStakedNUSD } from '@0xc/hardhat/MockStakedNUSD/MockStakedNUSD';
import { MockStakedUSDe } from '@0xc/hardhat/MockStakedUSDe/MockStakedUSDe';
import { MockUSDe } from '@0xc/hardhat/MockUSDe/MockUSDe';
import { TrancheDepositor } from '@0xc/hardhat/TrancheDepositor/TrancheDepositor';
import { SNUSDSwapAdapter } from '@0xc/hardhat/sNUSDSwapAdapter/sNUSDSwapAdapter';
import { DeploymentsBase, IDeploymentsBaseParams } from './DeploymentsBase';
import { LensPriceFeed } from '@0xc/hardhat/LensPriceFeed/LensPriceFeed';
import { IStrategy } from '@0xc/hardhat/IStrategy/IStrategy';
import { SUSDeAprPairProvider } from '@0xc/hardhat/sUSDeAprPairProvider/sUSDeAprPairProvider';
import { IBeaconProxy } from 'dequanto/contracts/deploy/proxy/ProxyDeployment';


type TUnderlyingTokens = {
    NUSD: MockNUSD
    sNUSD: MockStakedNUSD
    sUSDe: MockStakedUSDe
    USDe: MockUSDe
}

export class NeutrlDeployments extends DeploymentsBase<{
    Tokens: TUnderlyingTokens
    Strategy: SNUSDStrategy
}> {

    constructor(params: IDeploymentsBaseParams) {
        super({
            cdo: 'neutrl',
            ...params
        })
    }

    async ensureFeedProvider() {
        let { sUSDe, sNUSD } = await this.ensureUnderlying()
        const { contract: sNUSDAprPairProvider } = await this.ds.ensure(SNUSDAprPairProvider, {
            arguments: [
                sUSDe.address,
                sNUSD.address,
            ]
        });
        return {
            provider: sNUSDAprPairProvider as any as InstanceType<typeof SUSDeAprPairProvider>
        };
    }

    @memd.deco.memoize({ perInstance: true })
    async ensureUnderlying(): Promise<{
        base: MockUSDe
        NUSD: MockNUSD
        sNUSD: MockStakedNUSD
        sUSDe: MockStakedUSDe
        USDe: MockUSDe
    }> {
        let network = this.ds.client.network;
        if (network === 'hardhat') {
            let NUSD = await this.ds.ensureContract(MockNUSD);
            let sNUSD = await this.ds.ensureContract(MockStakedNUSD, {
                arguments: [
                    NUSD.address,
                    this.owner.address,
                ]
            });

            let USDe = await this.ds.ensureContract(MockUSDe);
            let sUSDe = await this.ds.ensureContract(MockStakedUSDe, {
                arguments: [
                    USDe.address,
                    this.owner.address,
                    this.owner.address,
                ]
            });

            await sNUSD.$receipt().setCooldownDuration(this.owner, $date.parseTimespan('1week', { get: 's' }));
            return {
                base: NUSD,
                NUSD,
                sNUSD,
                USDe,
                sUSDe,
            };
        }

        const create = <T>(Ctor: Constructor<T>, symbol: string): T => {
            let address = $require.Address(this.platform.Tokens[symbol].address);
            let contract = new Ctor(address, this.ds.client);
            return contract;
        };

        return {
            base: create(MockNUSD, 'NUSD'),
            NUSD: create(MockNUSD, 'NUSD'),
            sNUSD: create(MockStakedNUSD, 'sNUSD'),
            USDe: create(MockUSDe, 'USDe'),
            sUSDe: create(MockStakedUSDe, 'sUSDe'),
        };

    }

    async ensureUnstakeImplemenetations(): Promise<{ token: TEth.Address; impl: IBeaconProxy }[]> {
        let { sNUSD } = await this.ensureUnderlying();
        const { contractBeaconProxy: sNUSDCooldownRequestImpl } = await this.ds.ensureWithBeacon(SNUSDCooldownRequestImpl, {
            id: this.getContractId('SNUSDCooldownRequestBeacon'),
            arguments: [sNUSD.address],
            initialize: [$address.ZERO, $address.ZERO]
        });

        return [
            { token: sNUSD.address, impl: sNUSDCooldownRequestImpl }
        ]
    }
    protected async ensureStrategy(
        cdo: StrataCDO,
        acm: AccessControlManager,
        erc20Cooldown: ERC20Cooldown,
        unstakeCooldown: UnstakeCooldown,
    ): Promise<{ strategy: SNUSDStrategy; }> {
        const { sNUSD } = await this.ensureUnderlying();
        const { contract: strategy } = await this.ds.ensureWithProxy(SNUSDStrategy, {
            id: this.getContractId('SNUSDStrategy'),
            arguments: [
                sNUSD.address
            ],
            initialize: [
                this.owner.address,
                acm.address,
                cdo.address,
                erc20Cooldown.address,
                unstakeCooldown.address
            ]
        });
        return { strategy }
    }
    async configureCooldowns(strategy: IStrategy): Promise<void> {

    }
    async configureDepositor(depositor: TrancheDepositor) {
        let { NUSD } = await this.ensureUnderlying();
        let { cdo, jrtVault } = await this.ensureCDO();

        let status = await depositor.tranches(jrtVault.address, NUSD.address);
        if (status == false) {
            await depositor.$receipt().addCdo(this.owner, cdo.address);
        }

        const NUSD_ROUTER = '0xa052883ebEe7354FC2Aa0f9c727E657FdeCa744a';
        let { contract: swapAdapter } = await this.ds.ensure(SNUSDSwapAdapter, {
            id: this.getContractId('SNUSDSwapAdapter'),
            arguments: [
                Addresses.eth.NUSD,
                NUSD_ROUTER
            ]
        });

        const TOKENS = [
            Addresses.eth.USDC,
            Addresses.eth.USDT,
            Addresses.eth.USDe,
        ];

        await this.ds.configure(swapAdapter, {
            shouldUpdate: async () => {
                let result = await depositor.trancheAutoSwaps(jrtVault.address, TOKENS[0]);
                return $address.isEmpty(result.router);
            },
            updater: async () => {
                for (let token of TOKENS) {
                    await depositor.$receipt().addCdoAutoSwap(this.owner, cdo.address, token, {
                        router: swapAdapter.address,
                        minimumReturnPercentage: 0,
                        fee: 0,
                    });
                }
            }
        });

        return depositor;
    }

    async ensureLenses() {
        const { lens } = await super.ensureLenses();
        const { NUSD } = await this.ensureUnderlying();

        const { contract: nusdPriceFeed } = await this.ds.ensure(LensPriceFeed, {
            id: this.getContractId(`LensPriceFeed`),
            arguments: [this.owner.address],
        });

        await this.ds.configure(lens, {
            title: 'Price Feed for NUSD',
            shouldUpdate: async () => false === $address.eq(nusdPriceFeed.address, await lens.priceFeeds(NUSD.address)),
            updater: async () => {
                const owner = await this.getAccountOwner(lens.address);
                await lens.$receipt().setPriceFeed(owner, NUSD.address, nusdPriceFeed.address);
            }
        });

        return { lens };
    }
}
