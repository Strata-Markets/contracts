import memd from 'memd';
import { AccessControlManager } from '@0xc/hardhat/AccessControlManager/AccessControlManager';
import { Web3Client } from 'dequanto/clients/Web3Client';
import { TEth } from 'dequanto/models/TEth';
import { IPlatformAccounts } from '../platforms/IPlatform';
import { $require } from 'dequanto/utils/$require';
import { StrataCDO } from '@0xc/hardhat/StrataCDO/StrataCDO';
import { ERC20Cooldown } from '@0xc/hardhat/ERC20Cooldown/ERC20Cooldown';
import { UnstakeCooldown } from '@0xc/hardhat/UnstakeCooldown/UnstakeCooldown';
import { $address } from 'dequanto/utils/$address';
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
import { ConstantOracleAprPairProvider } from '@0xc/hardhat/ConstantOracleAprPairProvider/ConstantOracleAprPairProvider';
import { ERC20 } from 'dequanto/prebuilt/openzeppelin/ERC20';

type TUnderlyingContracts = {
    mM1USD: MockMToken;
    oracle: MockOracle;
    depositVault: MockDepositVault;
    redemptionVault: MockRedemptionVault;

    USDC: MockERC20;
};

export class MM1UsdDeployments extends DeploymentsBase<{
    Tokens: TUnderlyingContracts;
    Strategy: MidasStrategy;
}> {
    constructor(params: IDeploymentsBaseParams) {
        super({
            cdo: 'mm1usd',
            ...params,
        });
    }

    async ensureFeedProvider() {
        let { oracle } = await this.ensureUnderlying();
        let acm = await this.ensureACM();
        let network = this.ds.client.network;
        let aavePool = Addresses[network]?.AavePool;
        if (aavePool == null) {
            // Not found Aave Pool, remove NULL for manual update (@TODO create a mock one if needed)
            return { provider: null };
        }

        const { contract: provider } = await this.ds.ensure(ConstantOracleAprPairProvider, {
            id: this.getContractId(`ConstantOracleAprPairProvider`),
            arguments: [
                oracle.address,
            ],
        });
        return {
            provider,
        };
    }

    @memd.deco.memoize({ perInstance: true })
    async ensureUnderlying(): Promise<
        {
            base: MockUSDe;
        } & TUnderlyingContracts
    > {
        let network = this.ds.client.network;
        if (network === 'hardhat') {
            const USDC = await this.ds.ensureContract(MockERC20, {
                id: 'USDC',
                arguments: ['USDC', 6],
            });

            const mM1USD = await this.ds.ensureContract(MockMToken, {
                id: 'MockMM1USD',
                arguments: [],
            });
            const oracle = await this.ds.ensureContract(MockOracle, {
                id: 'MockMM1USDOracle',
                arguments: [],
            });
            const midasDepositVault = await this.ds.ensureContract(MockDepositVault, {
                id: 'MockMM1USDDepositVault',
                arguments: [mM1USD.address, oracle.address],
            });
            const midasRedemptionVault = await this.ds.ensureContract(MockRedemptionVault, {
                id: 'MockMM1USDRedemptionVault',
                arguments: [mM1USD.address, USDC.address, $address.ZERO],
            });


            return {
                base: USDC as any,
                USDC,
                mM1USD,
                oracle,
                depositVault: midasDepositVault,
                redemptionVault: midasRedemptionVault,
            };
        }

        const { Tokens, mm1usd } = this.platform;

        const create = <T>(Ctor: Constructor<T>, symbolOrAddress: string | TEth.Address): T => {
            let address = $require.Address(Tokens[symbolOrAddress]?.address ?? symbolOrAddress);
            let contract = new Ctor(address, this.ds.client);
            return contract;
        };

        return {
            base: create(MockERC20, 'USDC') as any,
            mM1USD: create(MockMToken, 'mM1USD'),
            USDC: create(MockERC20, 'USDC'),
            oracle: create(MockOracle, mm1usd.oracle),
            depositVault: create(MockDepositVault, mm1usd.depositVault),
            redemptionVault: create(MockRedemptionVault, mm1usd.redemptionVault),
        };
    }

    async ensureUnstakeImplemenetations(): Promise<{ token: TEth.Address; impl: IBeaconProxy }[]> {
        let { USDC, mM1USD, redemptionVault } = await this.ensureUnderlying();
        const { contractBeaconProxy: midasCooldownRequestImpl } = await this.ds.ensureWithBeacon(
            MidasCooldownRequestImpl,
            {
                id: 'MM1UsdCooldownRequestBeacon',
                arguments: [USDC.address, mM1USD.address, redemptionVault.address],
                initialize: [$address.ZERO, $address.ZERO],
            }
        );

        return [{ token: mM1USD.address, impl: midasCooldownRequestImpl }];
    }
    protected async ensureStrategy(
        cdo: StrataCDO,
        acm: AccessControlManager,
        erc20Cooldown: ERC20Cooldown,
        unstakeCooldown: UnstakeCooldown
    ): Promise<{ strategy: MidasStrategy }> {
        const { USDC, mM1USD, depositVault, redemptionVault, oracle } = await this.ensureUnderlying();
        const { contract: strategy } = await this.ds.ensureWithProxy(MidasStrategy, {
            arguments: [USDC.address, mM1USD.address, depositVault.address, redemptionVault.address, oracle.address],
            initialize: [
                this.owner.address,
                acm.address,
                cdo.address,
                erc20Cooldown.address,
                unstakeCooldown.address,
                [],
            ],
        });
        return { strategy };
    }
    async configureCooldowns(strategy: IStrategy): Promise<void> {}
    async configureDepositor(depositor: TrancheDepositor) {
        let { USDC } = await this.ensureUnderlying();
        let { cdo, jrtVault } = await this.ensureCDO();

        let status = await depositor.tranches(jrtVault.address, USDC.address);
        if (status == false) {
            // If JRT and USDC are not supported, add CDO
            await depositor.$receipt().addCdo(this.owner, cdo.address);
        }

        return depositor;
    }

    async getDepositToken (): Promise<ERC20> {
        let { mM1USD } = await this.ensureUnderlying();
        return mM1USD as any as ERC20;
    }
}
