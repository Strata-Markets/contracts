import memd from 'memd';
import alot from 'alot';
import { IPlatformAccounts } from '@s/platforms/IPlatform';
import { ChainAccountService } from 'dequanto/ChainAccountService';
import { Web3Client } from 'dequanto/clients/Web3Client';
import { Web3ClientFactory } from 'dequanto/clients/Web3ClientFactory';
import { Config } from 'dequanto/config/Config';
import { HardhatProvider } from 'dequanto/hardhat/HardhatProvider';
import { EoAccount } from 'dequanto/models/TAccount';
import { TEth } from 'dequanto/models/TEth';
import { InMemoryServiceTransport } from 'dequanto/safe/transport/InMemoryServiceTransport';
import { TxWriter } from 'dequanto/txs/TxWriter';
import { ICDO, TCDOKey, Tranches } from '@s/platforms/Tranches';
import { DeploymentsTypes } from '@s/deployments/DeploymentsTypes';
import { DeploymentsBase } from '@s/deployments/DeploymentsBase';
import { AccessControlManager } from '@0xc/hardhat/AccessControlManager/AccessControlManager';


export namespace PlatformFactory {

    export class ConfigLoader {
        @memd.deco.memoize()
        static async fetch() {
            return await Config.fetch({
                configGlobal: './config/*.yml'
            });
        }
    }

    export async function init<TKey extends TCDOKey>(params: {
        client?: Web3Client
        platform?: TEth.Platform
        deployments?: 'throw' | 'redeploy',
        whenUpgradeRequired?: 'ignore'
        cdo: TKey
        accounts?: TKey | 'operator' | 'deployer' | Partial<ICDO['accounts']>
        cdoInfo?: Partial<ICDO>
        initialDeposit?: boolean
        isTest?: boolean
    }) {
        const hh = new HardhatProvider();
        const config = await ConfigLoader.fetch();

        const platform = params.platform ?? params?.client?.platform ?? config.$get('chain') ?? 'hardhat';
        const client = params?.client ?? await Web3ClientFactory.getAsync(platform);

        const accounts = await getAccounts(client, params.accounts ?? params.cdo);
        // if (accounts.safe?.admin?.type === 'safe' || client.platform === 'hardhat') {
        //     TxWriter.defaultOptions({
        //         safeTransport: new InMemoryServiceTransport(client, accounts.deployer as EoAccount)
        //     });
        // }

        const CtorDeployments = DeploymentsTypes.Tranches[params.cdo];

        const depl = new CtorDeployments({
            client,
            deployer: accounts.deployer as EoAccount,
            owner: accounts.timelock.admin,
            deployments: params?.deployments,
            whenUpgradeRequired: params?.whenUpgradeRequired,
            accounts,
            initialDeposit: params?.initialDeposit,
            cdoInfo: params?.cdoInfo,
            isTest: params?.isTest,
        });
        return {
            tranches: depl as any as DeploymentsTypes.CDOs[TKey],
            client,
            owner: params.accounts === 'operator' ? accounts.safe.operator : accounts.timelock.admin,
            deployer: accounts.deployer,
        }
    }

    async function getAccounts(client: Web3Client, group: TCDOKey | 'operator' | 'deployer' | Partial<ICDO['accounts']>) {
        const { platform, network } = client;
        const hh = new HardhatProvider();

        let accounts = {
            deployer: `${network}/deployer`,
            timelockAdmin: `timelock/${network}/strata`,
            timelockConfig: `timelock/${network}/config`,
            safeAdmin: `safe/${network}/admin`,
            safeOperator: `safe/${network}/operator`,
            safeWorker: `safe/${network}/worker`,
            observer: `observer`,
        };
        if (typeof group === 'string') {
            accounts = Tranches[group]?.accounts?.[network] ?? accounts;
        } else if (group != null) {
            accounts = {
                ...accounts,
                ...group,
            };
        }

        let deployer = await ChainAccountService.get(accounts.deployer);
        let timelockAdmin = await ChainAccountService.get(accounts.timelockAdmin);
        let timelockConfig = await ChainAccountService.get(accounts.timelockConfig);
        let safeAdmin = await ChainAccountService.get(accounts.safeAdmin);
        let safeOperator = await ChainAccountService.get(accounts.safeOperator);
        let safeWorker = await ChainAccountService.get(accounts.safeWorker);
        let observer = await ChainAccountService.get('observer');

        if (network === 'hardhat' || (platform === 'hardhat' && group === 'deployer')) {
            deployer = {
                ...hh.deployer(0),
                type: 'eoa',
                name: accounts.deployer,
            };
            observer = {
                ...deployer,
                name: accounts.observer
            };
            timelockAdmin = {
                ...deployer,
                name: accounts.timelockAdmin
            };
            timelockConfig = {
                ...deployer,
                name: accounts.timelockConfig
            };
            safeAdmin = {
                ...deployer,
                name: accounts.safeAdmin
            };
            safeOperator = {
                ...deployer,
                name: accounts.safeOperator
            };
        } else if (platform === 'hardhat' && client.forked?.platform) {
            // Impersonate safe and timelock accounts in forked networks
            deployer = {
                name: deployer.name,
                type: 'impersonated',
                address: deployer.address,
            };
            safeAdmin = {
                name: safeAdmin.name,
                type: 'impersonated',
                address: safeAdmin.address,
            };
            safeOperator = {
                name: safeOperator.name,
                type: 'impersonated',
                address: safeOperator.address,
            };
            safeWorker = {
                name: safeWorker.name,
                type: 'impersonated',
                address: safeWorker.address,
            };
            timelockAdmin = {
                name: timelockAdmin.name,
                type: 'impersonated',
                address: timelockAdmin.address,
            };
            timelockConfig = {
                name: timelockConfig.name,
                type: 'impersonated',
                address: timelockConfig.address,
            };
            await client.debug.setBalance(deployer.address,         BigInt(1e18));
            await client.debug.setBalance(timelockAdmin.address,    BigInt(1e18));
            await client.debug.setBalance(timelockConfig.address,   BigInt(1e18));
            await client.debug.setBalance(safeAdmin.address,        BigInt(1e18));
            await client.debug.setBalance(safeOperator.address,     BigInt(1e18));

        } else if (platform !== 'eth' || group === 'operator') {

            safeAdmin = safeOperator;
            safeOperator = safeOperator;
            safeWorker = safeOperator;
            timelockAdmin = safeOperator;
            timelockConfig = safeOperator;
        }

        if (group === 'operator') {
            safeAdmin = safeOperator;
            safeOperator = safeOperator;
            safeWorker = safeOperator;
            timelockAdmin = safeOperator;
            timelockConfig = safeOperator;
        }

        return {
            deployer,
            observer,
            safe: {
                admin: safeAdmin,
                operator: safeOperator,
                worker: safeWorker,
            },
            timelock: {
                admin: timelockAdmin,
                config: timelockConfig,
            },
        } as IPlatformAccounts
    }


    export async function getTranches() {
        const config = await ConfigLoader.fetch();
        const cdoArr = config.$get('cdo')?.split(',') ?? null;
        const platform = config.$get('chain') ?? 'eth';
        const ignore = ['spkMhyperIso', 'mkralpha', 'mrox'];
        return await alot
            .fromObject(Tranches)
            .filter(x => ignore.includes(x.key) === false)
            .filter(x => cdoArr == null ? true : cdoArr.includes(x.key))
            .mapAsync(async x => {
                const factory = await PlatformFactory.init({
                    platform,
                    cdo: x.key as 'ethena',
                    deployments: 'throw',
                });
                return factory;
            })
            .toArrayAsync()
    }

    export async function getAccountByRole(ds: DeploymentsBase, roleOrName: TEth.Hex | keyof typeof ds.ROLES) {
        return ds.getAccountByRole(roleOrName);
    }
}
