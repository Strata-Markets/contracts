import alot from 'alot';
import memd from 'memd';
import { AccessControlManager } from '@0xc/hardhat/AccessControlManager/AccessControlManager'
import { MockUSDe } from '@0xc/hardhat/MockUSDe/MockUSDe'
import { Tranche } from '@0xc/hardhat/Tranche/Tranche'
import { Web3Client } from 'dequanto/clients/Web3Client'
import { Deployments } from 'dequanto/contracts/deploy/Deployments'
import { TEth } from 'dequanto/models/TEth'
import { Platforms } from '../platforms/Platforms'
import { IPlatform, IPlatformAccounts } from '../platforms/IPlatform'
import { $require } from 'dequanto/utils/$require'
import { StrataCDO } from '@0xc/hardhat/StrataCDO/StrataCDO'
import { ERC20Cooldown } from '@0xc/hardhat/ERC20Cooldown/ERC20Cooldown'
import { UnstakeCooldown } from '@0xc/hardhat/UnstakeCooldown/UnstakeCooldown'
import { Accounting } from '@0xc/hardhat/Accounting/Accounting'
import { ContractsIDMapping, ContractsPrefixMapping, ICDO, TCDOKey, Tranches } from '../platforms/Tranches'
import { $address } from 'dequanto/utils/$address'
import { IERC4626 } from 'dequanto/prebuilt/openzeppelin/IERC4626'
import { $contract } from 'dequanto/utils/$contract'
import { $date } from 'dequanto/utils/$date';
import { AprPairFeed } from '@0xc/hardhat/AprPairFeed/AprPairFeed';
import { SUSDeAprPairProvider } from '@0xc/hardhat/sUSDeAprPairProvider/sUSDeAprPairProvider';
import { $erc4626 } from '../../test/tranches/utils/$erc4626';
import { TrancheDepositor } from '@0xc/hardhat/TrancheDepositor/TrancheDepositor';
import { SafeTx } from 'dequanto/safe/SafeTx';
import { InMemoryServiceTransport } from 'dequanto/safe/transport/InMemoryServiceTransport';
import { l } from 'dequanto/utils/$logger';
import { CDOLens } from '@0xc/hardhat/CDOLens/CDOLens';
import { TwoStepConfigManager } from '@0xc/hardhat/TwoStepConfigManager/TwoStepConfigManager';
import { ContractBase } from 'dequanto/contracts/ContractBase';
import { Constructor, ParametersFromSecond } from 'dequanto/utils/types';
import { SharesCooldown } from '@0xc/hardhat/SharesCooldown/SharesCooldown';
import { IStrategy } from '@0xc/hardhat/IStrategy/IStrategy';
import { SafeAccount } from 'dequanto/models/TAccount';
import { IBeaconProxy } from 'dequanto/contracts/deploy/proxy/ProxyDeployment';
import { $bigint } from 'dequanto/utils/$bigint';
import { $exitMode } from '@s/utils/$exitMode';
import { SUSDeStrategy } from '@0xc/hardhat/sUSDeStrategy/sUSDeStrategy';
import { $number } from 'dequanto/utils/$number';
import { DiscreteAccounting } from '@0xc/hardhat/DiscreteAccounting/DiscreteAccounting';
import { DYSAccounting } from '@0xc/hardhat/DYSAccounting/DYSAccounting';
import { ERC20 } from 'dequanto/prebuilt/openzeppelin/ERC20';
import { KyberSwapAdapter } from '@0xc/hardhat/KyberSwapAdapter/KyberSwapAdapter';
import { ChainAccountService } from 'dequanto/ChainAccountService';
import { $is } from 'dequanto/utils/$is';
import { AccountablePushOracle } from '@0xc/hardhat/AccountablePushOracle/AccountablePushOracle';
import { $promise } from 'dequanto/utils/$promise';
import { $account } from 'dequanto/utils/$account';
import { Ownable } from 'dequanto/prebuilt/openzeppelin/Ownable';


export interface ICdoDeploymentsBase {
    Tokens
    Strategy
}

export type TDeploymentContracts<T extends ICdoDeploymentsBase = any> = {
    acm: AccessControlManager
    jrtVault: Tranche
    srtVault: Tranche
    cdo: StrataCDO
    strategy: SUSDeStrategy
    accounting: Accounting
    erc20Cooldown: ERC20Cooldown
    unstakeCooldown: UnstakeCooldown
    sharesCooldown: SharesCooldown
    feed: AprPairFeed
    provider: SUSDeAprPairProvider
    depositor: TrancheDepositor
    configManager: TwoStepConfigManager
} & T['Tokens']

export interface ICdoDeploymentsCommon extends ICdoDeploymentsBase {
    Stratagy: Constructor<IStrategy>
    Tokens: {
        base: ERC20
    }
}

export interface IDeploymentsBaseParams {
    cdo?: TCDOKey
    client: Web3Client
    deployer: TEth.EoAccount
    owner?: TEth.IAccount
    accounts?: IPlatformAccounts
    deployments?: 'throw' | 'redeploy'
    whenUpgradeRequired?: 'ignore'
    initialDeposit?: boolean
    cdoInfo?: Partial<ICDO>

    // Relevant for forked tests: when true, all contracts being redeployed, otherwise will reuse existing contracts
    isTest?: boolean
}

export abstract class DeploymentsBase<T extends ICdoDeploymentsBase = any> {

    ds: Deployments
    common: Deployments

    platform: IPlatform
    owner: TEth.IAccount
    deployer: TEth.EoAccount
    client: Web3Client
    cdoInfo: ICDO;

    accounts: IPlatformAccounts

    protected pfx: string;

    constructor(public params: IDeploymentsBaseParams) {
        this.deployer = params.deployer;
        this.owner = params.owner ?? params.deployer;
        this.client = params.client;
        this.platform = Platforms[params.client.network];
        this.accounts = params.accounts;
        this.pfx = $require.notNull(params.cdoInfo?.pfx ?? ContractsPrefixMapping[params.cdo], `No contract prefix for ${params.cdo} found`);
        let directoryPfx = params.cdo + '/';

        this.ds = new Deployments(params.client, params.deployer, {
            directory: `./deployments/${params.isTest ? 'test/' : ''}${directoryPfx}`,
            whenBytecodeChanged: params.deployments ?? (this.isTestnet() ? null : 'throw'),
            fork: params.client.forked?.platform,
            whenUpgradeRequired: params.whenUpgradeRequired,
            owner: this.owner,
        });
        this.common = new Deployments(params.client, params.deployer, {
            directory: `./deployments/${params.isTest ? 'test/' : ''}`,
            whenBytecodeChanged: params.deployments ?? (this.isTestnet() ? null : 'throw'),
            fork: params.client.forked?.platform,
            whenUpgradeRequired: params.whenUpgradeRequired,
            owner: this.owner,
        });

        let info = JSON.parse(JSON.stringify(Tranches[params.cdo])) as ICDO;

        if (this.platform?.Tranches?.ethena) {
            info.jrt = { ...info.jrt, ...(this.platform.Tranches?.[params.cdo]?.jrt ?? {}) } as any;
            info.srt = { ...info.srt, ...(this.platform.Tranches?.[params.cdo]?.srt ?? {}) } as any;
        }
        if (this.params.cdoInfo) {
            // 1-Level extend
            for (let key in this.params.cdoInfo) {
                let values = this.params.cdoInfo[key];
                let current = info[key];
                if (typeof current !== 'object' || (values != null && typeof values !== 'object')) {
                    info[key] = values;
                    continue;
                }
                info[key] = {
                    ...current,
                    ...values
                };
            }
        }
        this.cdoInfo = info;
    }

    abstract ensureFeedProvider(): Promise<{ provider: any }>;
    abstract ensureUnderlying(): Promise<{ base: MockUSDe } & T['Tokens']>
    protected abstract ensureUnstakeImplemenetations(
    ): Promise<{
        token: TEth.Address
        impl: IBeaconProxy
    }[]>

    protected abstract ensureStrategy(
        cdo: StrataCDO,
        acm: AccessControlManager,
        erc20Cooldown: ERC20Cooldown,
        unstakeCooldown: UnstakeCooldown,
    ): Promise<{
        strategy: T['Strategy']
    }>

    abstract configureCooldowns(strategy: IStrategy): Promise<void>

    abstract configureDepositor(depositor: TrancheDepositor);

    protected configureAprFeed<T = any>(feed: AprPairFeed) {}

    protected async getDepositToken (): Promise<ERC20> {
        let { base } = await this.ensureUnderlying();
        return base;
    }

    protected getDepositAmount (): number {
        return 40;
    }


    async get<T extends ContractBase>(Ctor: Constructor<T>, params?: {
        id?: 'jrUSDe' | 'srUSDe' | string,
        cdo?: 'USDe',
        common?: boolean
    }) {
        let { error, contract } = await this.getInner(this.ds, Ctor, params);
        if (contract) {
            return contract;
        }
        if (params?.common !== false) {
            let fromCommon = await this.getInner(this.common, Ctor, params);
            if (fromCommon.contract) {
                return fromCommon.contract;
            }
        }
        let fromSimilar = await this.getInner(this.ds, Ctor, { sfx: true, ...(params ?? {}) });
        if (fromSimilar.contract) {
            return fromSimilar.contract;
        }
        throw new Error(error);
    }
    private async getInner<T extends ContractBase>(ds: Deployments, Ctor: Constructor<T>, params?: { id?, cdo?, sfx? }): Promise<{error?: string, contract?: T }> {
        let all = await ds.store.getDeployments();

        if (params?.id != null) {
            let id = ContractsIDMapping[params.id] ?? ContractsIDMapping[this.pfx + params.id]  ?? params.id;
            let contract = await ds.getIfExists<T>(Ctor, { id })
                ?? await ds.getIfExists<T>(Ctor, { id: `${this.pfx}${id}` });
            if (contract) {
                return { contract };
            }
            let byId = all.filter(d => params?.sfx ? d.id.endsWith(params.id) : d.id === params.id);
            if (byId.length === 1) {
                let contract = await ds.getIfExists<T>(Ctor, { id: byId[0].id });
                return { contract };
            }
            return { error: `No ${Ctor.name} found for id ${id} and ${this.pfx} in deployments` };
        }
        let byName = all.filter(d => params?.sfx ? d.name.endsWith(Ctor.name) : d.name === Ctor.name);
        if (byName.length === 0) {
            return { error: `${Ctor.name} not found in deployments` }
        }

        if (byName.length === 1) {
            return { contract: await ds.get(Ctor, { id: byName[0].id }) };
        }
        let cdo = params?.cdo ?? this.pfx;
        let byCdo = byName.filter(x => x.id.toLowerCase().includes(cdo.toLowerCase()));
        if (byCdo.length === 1) {
            return { contract: await ds.get(Ctor, { id: byCdo[0].id }) };
        }

        if (byCdo.length === 0) {
            return { error: `No ${Ctor.name} found for CDO ${cdo} in deployments` };
        }
        if (byCdo.length > 1) {
            return { error: `Multiple ${Ctor.name} found for CDO ${cdo}: ${byCdo.map(x => x.id).join(', ')}` };
        }
    }

    async getDeploymentInfo (q: { address: TEth.Address }) {
        try {
            const info = await this.ds.store.getDeploymentInfo(q.address);
            return info;
        } catch (error) {
            const info = await this.common.store.getDeploymentInfo(q.address);
            return info;
        }
        throw new Error(`No deployment info found for ${q.address}`);
    }

    @memd.deco.memoize({ perInstance: true })
    async ensureACM() {
        const owner = this.owner!;
        const acm = await this.ds.ensureContract(AccessControlManager, {
            id: this.getContractId('AccessControlManager'),
            arguments: [owner.address]
        });

        if (this.isTestnet() === false) {
            let ownerIsAdmin = await acm.hasRole('0x', owner.address);
            let deployer = this.deployer;
            await this.ds.configure(acm, {
                title: `Grant Owner the AccessControlManager Admin Role`,
                shouldUpdate: ownerIsAdmin === false,
                async updater() {
                    await acm.$receipt().grantRole(deployer, '0x', owner.address);
                    await acm.$receipt().revokeRole(owner, '0x', deployer.address);
                }
            });
            let deployerIsAdmin = await acm.hasRole('0x', deployer.address);
            await this.ds.configure(acm, {
                title: `Revoke Deployer the AccessControlManager Admin Role`,
                shouldUpdate: deployerIsAdmin && $address.eq(deployer.address, owner.address) === false,
                async updater() {
                    await acm.$receipt().revokeRole(owner, '0x', deployer.address);
                }
            });
        }
        return acm;
    }

    async ensureRole(roleOrName: TEth.Hex | keyof typeof this.ROLES, account: TEth.Address) {
         const role = roleOrName === '0x' || $is.Hex(roleOrName)
            ? roleOrName
            : this.ROLES[roleOrName];
        $require.Hex(role, 'Role is undefined');
        $require.AddressNotEmpty(account, 'Account is empty');
        let acm = await this.ensureACM();
        let acmAdmin = await this.getAccountByRole('0x');
        let has = await acm.hasRole(role, account);
        if (has === false) {
            await acm.$receipt().grantRole(acmAdmin, role, account);
        }
    }
    async ensureRoles(roles: Record<string, Record<TEth.Address, boolean>>) {
        const acm = await this.ensureACM();
        const admin = this.owner;
        for (let role in roles) {
            for (let address in roles[role]) {
                await ensure(role, address as TEth.Address, roles[role][address]);
            }
        }

        async function ensure(role: string, address: TEth.Address, has: boolean) {
            let roleHash = role.startsWith('0x')
                ? role as TEth.Hex
                : $contract.keccak256(role);
            let hasCurrent = await acm.hasRole(roleHash, address);
            if (hasCurrent !== has) {
                l`gray<EnsureRole>: cyan<${role}> ${has ? '🟢' : '🔴'} cyan<${address}> ⌛`;
                if (has) {
                    await acm.$receipt().grantRole(admin, roleHash, address)
                } else {
                    await acm.$receipt().revokeRole(admin, roleHash, address)
                }
            }
        }
    }

    async addRoles(roles?: Record<TEth.Address, string[]>) {
        roles ??= {
            [this.owner.address]: [
                $contract.keccak256('PAUSER_ROLE'),
                $contract.keccak256('UPDATER_STRAT_CONFIG_ROLE'),
                $contract.keccak256('UPDATER_FEED_ROLE'),
                $contract.keccak256('RESERVE_MANAGER_ROLE'),
            ]
        };
        for (let account in roles) {
            for (let role of roles[account]) {
                await this.ensureRole(role, account as TEth.Address);
            }
        }
    }


    async ensureTranches(cdo: StrataCDO) {
        const { base } = await this.ensureUnderlying();

        const acm = await this.ensureACM();
        const info = this.cdoInfo;
        const useConservativeRedemptionPrice = info.ContractVersions?.accountingOptions?.useConservativeRedemptionPrice ?? false;
        let { contract: jrtVault } = await this.ds.ensureWithProxy(Tranche, {
            id: `${this.pfx}Jrt`,
            arguments: [useConservativeRedemptionPrice],
            initialize: [
                this.owner.address,
                acm.address,
                info.jrt.name,
                info.jrt.symbol,
                base.address,
                cdo.address,
            ]
        });
        let { contract: srtVault } = await this.ds.ensureWithProxy(Tranche, {
            id: `${this.pfx}Srt`,
            arguments: [useConservativeRedemptionPrice],
            initialize: [
                this.owner.address,
                acm.address,
                info.srt.name,
                info.srt.symbol,
                base.address,
                cdo.address,
            ]
        });

        return {
            jrtVault: jrtVault as Tranche & IERC4626,
            srtVault: srtVault as Tranche & IERC4626,
        };
    }

    async ensureConfigManager() {
        let { cdo, sharesCooldown } = await this.ensureCDO();
        let owner = this.accounts.timelock.admin;
        let { contract: configManager } = await this.ds.ensureWithProxy(TwoStepConfigManager, {
            id: `${this.pfx}ConfigManager`,
            arguments: [cdo.address],
            initialize: []
        });

        await this.ds.configure(cdo, {
            title: `Set CDO Two-Step Config Manager`,
            async shouldUpdate() {
                return $address.eq(await cdo.twoStepConfigManager(), configManager.address) === false
            },
            async updater() {
                await cdo.$receipt().setTwoStepConfigManager(owner, configManager.address);
            }
        });

        await this.ds.configure(sharesCooldown, {
            title: `Set SharesCooldown Two-Step Config Manager`,
            async shouldUpdate() {
                return $address.eq(await sharesCooldown.twoStepConfigManager(), configManager.address) === false
            },
            async updater() {
                await sharesCooldown.$receipt().setTwoStepConfigManager(owner, configManager.address);
            }
        });

        await this.ensureRoles({
            'PROPOSER_CONFIG_ROLE': {
                [this.accounts.safe.admin.address]: true
            },
            'UPDATER_STRAT_CONFIG_ROLE': {
                [this.accounts.timelock.config.address]: true
            }
        });

        return { configManager };
    }

    @memd.deco.memoize({ perInstance: true })
    async ensureCooldowns(cdo?: StrataCDO) {
        const acm = await this.ensureACM();
        const { contract: erc20Cooldown } = await this.ds.ensureWithProxy(ERC20Cooldown, {
            id: this.getContractId('ERC20Cooldown'),
            initialize: [
                this.owner.address,
                acm.address
            ]
        });
        const { contract: unstakeCooldown } = await this.ds.ensureWithProxy(UnstakeCooldown, {
            id: this.getContractId('UnstakeCooldown'),
            initialize: [
                this.owner.address,
                acm.address
            ]
        });
        const { contract: sharesCooldown } = await this.ds.ensureWithProxy(SharesCooldown, {
            id: this.getContractId('SharesCooldown'),
            initialize: [
                this.owner.address,
                acm.address
            ]
        });

        let unstakeCooldownsArr = await this.ensureUnstakeImplemenetations();
        let unstakeCooldownsFiltered = await alot(unstakeCooldownsArr)
            .filterAsync(async x => $address.eq(await unstakeCooldown.implementations(x.token), x.impl.address) === false)
            .toArrayAsync();

        await this.ds.configure(unstakeCooldown, {
            shouldUpdate: unstakeCooldownsFiltered.length > 0,
            updater: async () => {
                let tokens = unstakeCooldownsFiltered.map(x => x.token);
                let impls = unstakeCooldownsFiltered.map(x => x.impl.address);
                await unstakeCooldown.$receipt().setImplementations(this.owner, tokens, impls);
            }
        });

        if (cdo != null) {
            await this.ds.configure(cdo, {
                shouldUpdate: $address.eq(await cdo.sharesCooldown(), sharesCooldown.address) === false,
                updater: async () => {
                    await cdo.$receipt().setSharesCooldown(this.owner, sharesCooldown.address);
                }
            });
        }

        return {
            erc20Cooldown,
            unstakeCooldown,
            sharesCooldown,
            acm,
        };
    }



    async ensureFeeds() {
        const acm = await this.ensureACM();

        const { provider } = await this.ensureFeedProvider();

        const CURRENT_PROVIDER = provider?.address ?? $address.ZERO;
        const stalePeriodAfter = $date.parseTimespan(this.platform.Feed.stalePeriodAfter, { get: 's' });
        const { contract: feed } = await this.ds.ensureWithProxy(AprPairFeed, {
            id: `${this.pfx}AprFeeds`,
            initialize: [
                this.owner.address,
                acm.address,
                CURRENT_PROVIDER,
                BigInt(stalePeriodAfter),
                this.cdoInfo.Feed.name ?? "Ethena CDO APR Pair"
            ]
        });

        await this.ds.configure(feed, {
            title: 'Update AprPair Feed Provider',
            shouldUpdate: async () => {
                let providerAddress = await feed.provider();
                return !$address.eq(providerAddress, CURRENT_PROVIDER);
            },
            updater: async () => {
                await feed.$receipt().setProvider(this.owner, CURRENT_PROVIDER)
            }
        });

        return {
            feed,
            provider,
        };
    }

    async ensureStrataCdo() {
        const acm = await this.ensureACM();
         const { base } = await this.ensureUnderlying();
        const { contract: cdo } = await this.ds.ensureWithProxy(StrataCDO, {
            id: `${this.pfx}CDO`,
            arguments: [ $require.Address(base.address) ],
            initialize: [
                this.owner.address,
                acm.address,
            ]
        });
        await this.ensureRole(this.ROLES.COOLDOWN_WORKER_ROLE, cdo.address);
        return cdo;
    }

    @memd.deco.memoize({ perInstance: true })
    async ensureCDO() {
        const { base, ...tokens } = await this.ensureUnderlying();

        const acm = await this.ensureACM();
        const cdo = await this.ensureStrataCdo();

        const { erc20Cooldown, unstakeCooldown, sharesCooldown } = await this.ensureCooldowns(cdo);
        const { strategy } = await this.ensureStrategy(cdo, acm, erc20Cooldown, unstakeCooldown);
        await this.ensureRole(this.ROLES.COOLDOWN_WORKER_ROLE, strategy.address);


        // Accounting
        const accounting = await this.ensureAccounting(cdo.address);

        // Oracle
        const { feed, provider } = await this.ensureFeeds();


        const { jrtVault, srtVault } = await this.ensureTranches(cdo);

        await this.ds.configure(cdo, {
            shouldUpdate: async () => $address.eq(await cdo.strategy(), $address.ZERO),
            updater: async (x, value) => {
                await cdo.$receipt().configure(
                    this.owner,
                    accounting.address,
                    strategy.address,
                    jrtVault.address,
                    srtVault.address
                );
            },
        });

        const output = {
            acm,
            jrtVault,
            srtVault,
            cdo,
            strategy,
            accounting,
            erc20Cooldown,
            unstakeCooldown,
            sharesCooldown,
            feed,
            provider,
            ...tokens,
        };


        await this.setupCdo(output);
        return output;
    }

    async ensureAccounting(cdo: TEth.Address) {
        const acm = await this.ensureACM();
        const { feed } = await this.ensureFeeds();
        const { base } = await this.ensureUnderlying();
        const decimals:bigint = await base.decimals();
        const accountingType = this.cdoInfo.ContractVersions?.accounting;
        const Contract = accountingType === 'continuous'
            ? Accounting
            : accountingType === 'dys'
                ? DYSAccounting
                : DiscreteAccounting;
        const args = accountingType === 'continuous'
            ? [ decimals ] as [ bigint ]
            : accountingType === 'dys'
                ? [ decimals, false, false ] as [ bigint, boolean, boolean ]
                : accountingType === 'isolated'
                    ? [ decimals, true ] as [ bigint, boolean ]
                    : [ decimals, false ] as [ bigint, boolean ];

        const accountingOptions = this.cdoInfo.ContractVersions?.accountingOptions;

        const useBenchmark = accountingOptions?.useBenchmark ?? false;
        const useRatesForReconciliation = accountingOptions?.useRatesForReconciliation ?? false;
        const useNavAtReconciliation = accountingOptions?.useNavAtReconciliation ?? false;
        const useJuniorCoversPaidSrtProjection = accountingOptions?.useJuniorCoversPaidSrtProjection ?? true;
        const useConservativeRedemptionPrice = accountingOptions?.useConservativeRedemptionPrice ?? false;

        const dysAccounting = [
            decimals,
            useBenchmark,
            useNavAtReconciliation,
            useRatesForReconciliation,
            useJuniorCoversPaidSrtProjection,
            useConservativeRedemptionPrice
        ] as ParametersFromSecond<DYSAccounting['$constructor']>

        const { contract: accounting } = await this.ds.ensureWithProxy(Contract as typeof Accounting, {
            id: `${this.pfx}Accounting`,
            initialize: [ this.owner.address, acm.address, cdo, feed.address ],
            arguments: (accountingType === 'dys'
                ? dysAccounting
                : args) as [ bigint ],
        });
        return accounting;
    }

    private async setupCdo(contracts: {
        acm: AccessControlManager,
        jrtVault: Tranche,
        srtVault: Tranche,
        cdo: StrataCDO,
        strategy: IStrategy,
        accounting: Accounting,
        feed: AprPairFeed,
        sharesCooldown: SharesCooldown
    }) {

        let {
            acm,
            jrtVault,
            srtVault,
            cdo,
            strategy,
            accounting,
            feed,
            sharesCooldown,
        } = contracts;

        await this.addRoles();
        await this.ensureRole($contract.keccak256('UPDATER_CDO_APR_ROLE'), feed.address);
        await this.configureCooldowns(strategy);

        await this.ds.configure(accounting, {
            title: `Update Performance (Accounting Reserve BPS) Fee`,
            value: $bigint.toWei(this.cdoInfo.fees?.performanceFee ?? 0, 18),
            current: accounting.reserveBps(),
            updater: async (accounting, value) => {
                await accounting.$receipt().setReserveBps(this.owner, value)
            }
        });

        if (this.params?.initialDeposit !== false && await jrtVault.totalSupply() === 0n) {
            if (this.client.platform === 'eth') {
                await this.initialDepositAtomic({ jrtVault, srtVault, cdo });
            } else if (this.client.network === 'eth') {
                await this.initialDeposit({ jrtVault, srtVault, cdo });
            }
        }


    }

    public async configure(contracts: {
        acm: AccessControlManager,
        jrtVault: Tranche,
        srtVault: Tranche,
        cdo: StrataCDO,
        strategy: IStrategy,
        accounting: Accounting,
        feed: AprPairFeed,
        sharesCooldown: SharesCooldown,
        configManager: TwoStepConfigManager,
        depositor: TrancheDepositor,
    }) {
        let {
            acm,
            jrtVault,
            srtVault,
            cdo,
            strategy,
            accounting,
            feed,
            sharesCooldown,
        } = contracts;

        let info = this.cdoInfo;

        await this._configureFeeRetention(contracts);
        await this._configureExitBounds(contracts);
        await this._configureRiskPremium(contracts);
        await this._configureMinumumJrtSrtRatios(contracts);

        await this.configureAprFeed(feed)


        await this.setTrancheActions(cdo, jrtVault, info, 'jrt');
        await this.setTrancheActions(cdo, srtVault, info, 'srt');

        return contracts;
    }

    async setTrancheActions(cdo: StrataCDO, tranche: Tranche, info: ICDO, type: 'srt' | 'jrt') {
        let actions = type === 'jrt'
            ? await cdo.actionsJrt()
            : await cdo.actionsSrt();

        let current = type === 'jrt'
            ? info.jrt
            : info.srt;

        if (actions.isDepositEnabled !== current.depositsEnabled || actions.isWithdrawEnabled !== current.withdrawalsEnabled) {
            await cdo.$receipt().setActionStates(
                this.owner,
                tranche.address,
                current.depositsEnabled,
                current.withdrawalsEnabled,
            );
        }
    }

    private async initialDeposit(tranches: { jrtVault: Tranche, srtVault: Tranche, cdo: StrataCDO }) {
        let erc20 = await this.getDepositToken();
        let { jrtVault, srtVault, cdo } = tranches;

        if (this.owner.type === 'safe') {
            throw new Error(`Mainnet deployment not ready`);
        }
        const AMOUNT = $bigint.toWei(this.getDepositAmount(), await erc20.decimals());
        let balance = await erc20.balanceOf(this.owner.address);
        if (balance < AMOUNT) {
            if (this.client.network === 'hardhat' || this.client.network === 'hoodi') {
                await (erc20.$receipt() as any).mint(this.owner, this.owner.address, AMOUNT * 100n);
            } else {
                throw new Error(`Not enough balance (${erc20.address}) for initial deposit. ${this.owner.address}`);
            }
        }

        await cdo.$receipt().setActionStates(
            this.owner,
            $address.ZERO,
            true,
            false,
        );
        await $erc4626.depositMeta(jrtVault as any, erc20, this.owner, AMOUNT / 2n);
        await $erc4626.depositMeta(srtVault as any, erc20, this.owner, AMOUNT / 2n);
        await cdo.$receipt().setActionStates(
            this.owner,
            $address.ZERO,
            false,
            false,
        );
    }
    private async initialDepositAtomic(tranches: { jrtVault: Tranche, srtVault: Tranche, cdo: StrataCDO }) {
        let erc20 = await this.getDepositToken();
        let { jrtVault, srtVault, cdo } = tranches;

        const AMOUNT = $bigint.toWei(this.getDepositAmount(), await erc20.decimals());
        let balance = await erc20.balanceOf(this.owner.address);
        if (balance < AMOUNT) {
            throw new Error(`Not enough balance for initial deposit.`);
        }

        const AMOUNT_SRT = AMOUNT / 2n;
        const AMOUNT_JRT = AMOUNT / 2n;

        let actions = [
            await cdo.$data().setActionStates(this.owner, $address.ZERO, true, false),

            await erc20.$data().approve(this.owner, jrtVault.address, AMOUNT_JRT),
            await jrtVault.$data().deposit(this.owner, erc20.address, AMOUNT_JRT, this.owner.address),

            await erc20.$data().approve(this.owner, srtVault.address, AMOUNT_SRT),
            await srtVault.$data().deposit(this.owner, erc20.address, AMOUNT_SRT, this.owner.address),

            await cdo.$data().setActionStates(this.owner, $address.ZERO, false, false),
        ];

        $require.match(/safe/i, this.owner.name);
        let safeTx = new SafeTx(this.owner as SafeAccount, this.client, {
            safeTransport: new InMemoryServiceTransport(this.client, this.deployer)
        });

        l`yellow<Execute batch>`
        let tx = await safeTx.executeBatch(
            ...actions
        );
        await tx.wait();
    }

    async ensureDepositor() {
        let acm = await this.ensureACM();
        let { base } = await this.ensureUnderlying();
        let { cdo, jrtVault } = await this.ensureCDO();

        let v = this.cdoInfo.ContractVersions?.depositor ?? 'V3';
        let { contract: depositor } = await this.common.ensureWithProxy(TrancheDepositor, {
            id: this.isTestnet()
                ? `${this.pfx}TrancheDepositor`
                : `TrancheDepositor${v}`,
            initialize: [
                this.owner.address,
                acm.address
            ],
            latest: false,
        });

        await this.ensureRole($contract.keccak256('DEPOSITOR_CONFIG_ROLE'), this.owner.address);
        let depositToken = await this.getDepositToken();
        let status = await depositor.tranches(jrtVault.address, depositToken.address);
        if (status == false) {
            await depositor.$receipt().addCdo(this.owner, cdo.address);
        }

        await this.configureDepositor(depositor);
        return depositor;
    }

    async ensureValuationOracles() {
        const { valuationKeeper, valuationKeeperOptions } = this.cdoInfo.ContractVersions;
        if (valuationKeeper == null) {
            return;
        }

        let { cdo, accounting } = await this.ensureCDO();
        let gracePeriod = $date.parseTimespan(valuationKeeperOptions?.gracePeriod ?? '0s', { get: 's' });
        $require.True(this.client.platform === 'hardhat' || gracePeriod > 0, `GracePeriod MUST be set on Live`);

        await this.ds.configure(accounting, {
            title: `Update GracePeriod`,
            value: gracePeriod,
            current: async () => {
                const { result, error } = await $promise.caught(accounting.valuationGracePeriod());
                return error == null ? result : 0;
            },
            updater: async (accounting, value) => {
                await accounting.$receipt().setValuationGracePeriod(this.owner, value)
            }
        });

        let observer = await this.getAccount('observer');
        let { contract: accountable } = await this.common.ensure(AccountablePushOracle, {
            arguments: [
                this.owner.address,
                observer.address,
            ]
        });
        await this.ensureRole('PAUSER_ROLE', accountable.address);

        if (valuationKeeper === 'Accountable') {
            await this.ds.configure(cdo, {
                title: `Update the ValuationKeeper`,
                value: accountable.address,
                current: async () => {
                    const { result, error } = await $promise.caught(cdo.valuationKeeper());
                    return error == null ? result : $address.ZERO;
                },
                updater: async (cdo, value) => {
                    await cdo.$receipt().setValuationKeeper(this.owner, value);
                },
            });
        }

        return {
            accountable
        };
    }



    public isTestnet() {
        return this.client.platform !== 'eth';
    }

    async ensureLenses() {
        let { contract: cdoLens } = await this.common.ensureWithProxy(CDOLens, {
            initialize: [
                this.deployer.address
            ],
            latest: false,
        });
        return { lens: cdoLens }
    }
    async configureLenses(): Promise<{ lens: CDOLens } | void> {}

    protected getContractId(name: keyof ICDO['Contracts'][''] | string) {
        if (this.pfx) {
            return `${this.pfx}${name}`;
        }
        const Contracts = this.cdoInfo.Contracts;
        const id = Contracts?.[this.client.network]?.[name]
            ?? Contracts?.['*']?.[name]
            ?? `${name}`;
        return id;
    }

    private async _configureFeeRetention(contracts: {
        accounting: Accounting
    }) {
        const { accounting } = contracts;
        const FeeRetentionBps = {
            jrt: $bigint.toWei(this.cdoInfo.fees?.retention?.jrt ?? 0, 18),
            srt: $bigint.toWei(this.cdoInfo.fees?.retention?.srt ?? 0, 18),
        }
        await this.ds.configure(accounting, {
            title: `Update Fee Retention Ratios`,
            shouldUpdate: async () => {
                let jrtCurrent = await accounting.feeJrtRetentionBps();
                let srtCurrent = await accounting.feeSrtRetentionBps();
                return jrtCurrent !== FeeRetentionBps.jrt || srtCurrent !== FeeRetentionBps.srt;
            },
            updater: async (accounting, value) => {
                await accounting.$receipt().setFeeRetentionBps(this.owner, FeeRetentionBps.jrt, FeeRetentionBps.srt);
            }
        });
    }

    private async _configureRiskPremium(contracts: {
        accounting: Accounting
    }) {
        const risk = this.cdoInfo.riskPremium;
        if (risk == null) {
            return null;
        }
        const { accounting } = contracts;
        const x = $bigint.toWei(risk.x ?? 0.2, 18);
        const y = $bigint.toWei(risk.y ?? 0.2, 18);
        const k = $bigint.toWei(risk.k ?? 0.3, 18);

        await this.ds.configure(accounting, {
            title: `Update Accounting Risk Premium Parameters`,
            shouldUpdate: async () => {
                let [_x, _y, _k] = await accounting.$executeBatch([
                    accounting.$req().riskX(),
                    accounting.$req().riskY(),
                    accounting.$req().riskK(),
                ]);
                return _x !== x || _y !== y || _k !== k;
            },
            updater: async (accounting, value) => {
                await accounting.$receipt().setRiskParameters(this.owner, x, y, k);
            }
        });
    }

    private async _configureMinumumJrtSrtRatios(contracts: {
        srtVault: Tranche,
        accounting: Accounting
    }) {

        if (this.cdoInfo.minimumJrtSrtRatio == null || this.cdoInfo.minimumJrtSrtRatioBuffer == null) {
            return;
        }

        $require.notNull(this.cdoInfo.minimumJrtSrtRatioBuffer, `MINIMUM_JRT_SRT_RATIO_BUFFER`);
        $require.notNull(this.cdoInfo.minimumJrtSrtRatio, `MINIMUM_JRT_SRT_RATIO`);

        const MINIMUM_JRT_SRT_RATIO_BUFFER = $bigint.toWei(this.cdoInfo.minimumJrtSrtRatioBuffer, 18);
        const MINIMUM_JRT_SRT_RATIO = $bigint.toWei(this.cdoInfo.minimumJrtSrtRatio, 18);

        const { accounting, srtVault } = contracts;
        const [curMinimumJrtSrtRatio, curMinimumJrtSrtRatioBuffer] = await accounting.$executeBatch([
            accounting.$req().minimumJrtSrtRatio(),
            accounting.$req().minimumJrtSrtRatioBuffer(),
        ]);
        const owner = this.owner;
        await this.ds.configure(accounting, {
            title: `Update Minimum Jrt/Srt Parameters`,
            shouldUpdate: async () => {
                return MINIMUM_JRT_SRT_RATIO_BUFFER !== curMinimumJrtSrtRatioBuffer
                    || MINIMUM_JRT_SRT_RATIO !== curMinimumJrtSrtRatio;
            },
            updater: async (accounting, value) => {
                const maxDeposit = await srtVault.maxDeposit($address.ZERO);
                const decimals = await new ERC20(await srtVault.asset(), srtVault.client).decimals();
                l`MaxDeposit (Additional) cyan<${$number.humanize($bigint.toEther(maxDeposit, decimals))}>`;

                // MUST: RATIO <= RATIO_BUFFER; so we check what parameter should be updated as first to keep this invariant.
                if (MINIMUM_JRT_SRT_RATIO_BUFFER >= curMinimumJrtSrtRatio) {
                    await accounting.$receipt().setMinimumJrtSrtRatioBuffer(owner, MINIMUM_JRT_SRT_RATIO_BUFFER);
                    await accounting.$receipt().setMinimumJrtSrtRatio(owner, MINIMUM_JRT_SRT_RATIO);
                } else {
                    await accounting.$receipt().setMinimumJrtSrtRatio(owner, MINIMUM_JRT_SRT_RATIO);
                    await accounting.$receipt().setMinimumJrtSrtRatioBuffer(owner, MINIMUM_JRT_SRT_RATIO_BUFFER);
                }

                const maxDepositAfter = await srtVault.maxDeposit($address.ZERO);
                l`MaxDeposit (Additional) cyan<${$number.humanize($bigint.toEther(maxDepositAfter, decimals))}>`;
            }
        });
    }

    private async _configureExitBounds(contracts: {
        sharesCooldown: SharesCooldown,
        configManager: TwoStepConfigManager,
        jrtVault: Tranche,
        srtVault: Tranche,
        depositor: TrancheDepositor,
    }) {
        let {
            sharesCooldown,
            configManager,
            jrtVault,
            srtVault,
        } = contracts;

        const { sharesCooldown: jrtExitBounds } = this.cdoInfo.jrt;
        const { sharesCooldown: srtExitBounds } = this.cdoInfo.srt;
        if (jrtExitBounds == null || srtExitBounds == null) {
            l`No exit bounds defined for JRT AND SRT. Skipping...`;
            return;
        }

        const ExitBounds = {
            jrt: $exitMode.map(jrtExitBounds ?? []),
            srt: $exitMode.map(srtExitBounds ?? []),
        };
        await this.ds.configure(sharesCooldown, {
            title: `Update Exit Bounds`,
            shouldUpdate: async () => {
                let jrtCurrent = await sharesCooldown.vaultExitBounds(jrtVault.address);
                let srtCurrent = await sharesCooldown.vaultExitBounds(srtVault.address);
                return $exitMode.eq(jrtCurrent, ExitBounds.jrt) === false
                    || $exitMode.eq(srtCurrent, ExitBounds.srt) === false
            },
            updater: async (sharesCooldown) => {

                const owner = await sharesCooldown.owner();
                const isTest = this.client.platform === 'hardhat';
                if (!isTest) {
                    if ($address.eq(owner, this.owner.address) === false) {
                        l`Unknown owner. Can't configure at this stage`;
                        return;
                    }
                    let isInternal = /(safe\/eth\/owner)|(deployer)/.test(this.owner.name);
                    if (isInternal === false) {
                        l`Settled owner. Can't configure at this stage`;
                        return;
                    }
                }
                const prevTwoStepConfigManager = await sharesCooldown.twoStepConfigManager();
                const shouldSwitchManager = $address.eq(prevTwoStepConfigManager, this.owner.address) === false;
                if (shouldSwitchManager) {
                    await sharesCooldown.$receipt().setTwoStepConfigManager(this.owner, this.owner.address);
                }
                await sharesCooldown.$receipt().setVaultExitBounds(this.owner, jrtVault.address, ExitBounds.jrt);
                await sharesCooldown.$receipt().setVaultExitBounds(this.owner, srtVault.address, ExitBounds.srt);
                if (shouldSwitchManager) {
                    l`Return shares cooldown back`;
                    await sharesCooldown.$receipt().setTwoStepConfigManager(this.owner, prevTwoStepConfigManager);
                }
            }
        });
    }

    public async ensureDeployment(opts: { initialDeposit?: boolean }): Promise<TDeploymentContracts<T>> {
        const contracts = await this.ensureCDO();
        const depositor = await this.ensureDepositor();
        const { configManager } = await this.ensureConfigManager();
        const contractsAll = {
            ...contracts,
            depositor,
            configManager,
        };

        await this.ensureValuationOracles();
        await this.configure(contractsAll);
        return contractsAll;
    }

    public ROLES = {
        PAUSER_ROLE: $contract.keccak256("PAUSER_ROLE"),
        UPDATER_CDO_APR_ROLE: $contract.keccak256("UPDATER_CDO_APR_ROLE"),
        UPDATER_FEED_ROLE: $contract.keccak256("UPDATER_FEED_ROLE"),
        UPDATER_STRAT_CONFIG_ROLE: $contract.keccak256("UPDATER_STRAT_CONFIG_ROLE"),
        RESERVE_MANAGER_ROLE: $contract.keccak256("RESERVE_MANAGER_ROLE"),
        COOLDOWN_WORKER_ROLE: $contract.keccak256("COOLDOWN_WORKER_ROLE"),
        PROPOSER_CONFIG_ROLE: $contract.keccak256("PROPOSER_CONFIG_ROLE"),
    };

    public async ensureKyberSwapAdapter () {
        let { contract: swapper } = await this.common.ensure(KyberSwapAdapter);
        return swapper;
    }

    public async getAccount(mix: TEth.Address | string): Promise<TEth.IAccount> {
        let arr = [
            this.accounts.deployer,
            this.accounts.observer,
            ...Object.values(this.accounts.safe),
            ...Object.values(this.accounts.timelock),
        ];
        let account = arr.find(x => $address.eq(x?.address, mix) || x?.name === mix);
        if (account) {
            if (this.client.platform === 'hardhat' && /(safe|timelock)/.test(account.name)) {
                // Add the :hh suffix to prevent dequanto from detecting the accounts as Safe or Timelock agents.
                return {
                    ...account,
                    name: account.name.replace(/(safe|timelock)/, '$1:hh')
                };
            }
            return account;
        }
        return $require.notNull(await ChainAccountService.get(mix), `Account ${mix} not found`);
    }
    public async getAccountOwner(contract: TEth.Address): Promise<TEth.IAccount> {
        let ownabled = new Ownable(contract, this.client);
        let owner = await ownabled.owner();
        return this.getAccount(owner);
    }

    public async getAccountByRole(roleOrName: TEth.Hex | keyof typeof this.ROLES): Promise<TEth.IAccount> {
        if (this.client.network === 'hardhat') {
            // In the raw Hardhat network (not forked) the acm admin is the deployer
            return this.owner;
        }
        const role = roleOrName === '0x' || $is.Hex(roleOrName)
            ? roleOrName
            : $contract.keccak256(roleOrName, 'hex');
        const arr = [
            this.accounts.timelock.config,
            this.accounts.timelock.admin,
            this.accounts.safe.admin,
            this.accounts.safe.operator,
            this.accounts.deployer,
        ] as TEth.IAccount[];
        const acm = await this.get(AccessControlManager);
        return alot(arr).findAsync(account => acm.hasRole(role, account.address));
    }
}
