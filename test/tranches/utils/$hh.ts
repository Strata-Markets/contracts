import memd from 'memd';
import { HardhatProvider } from 'dequanto/hardhat/HardhatProvider';
import { $require } from 'dequanto/utils/$require';
import { Web3Client } from 'dequanto/clients/Web3Client';
import { TEth } from 'dequanto/models/TEth';
import { $sig } from 'dequanto/utils/$sig';
import { HardhatWeb3Client } from 'dequanto/hardhat/HardhatWeb3Client';
import { TwoStepConfigManager } from '@0xc/hardhat/TwoStepConfigManager/TwoStepConfigManager';
import { PlatformFactory } from '../../../tasks/PlatformFactory';
import { $cli } from 'dequanto/utils/$cli';
import { ICDO, TCDOKey } from '@s/platforms/Tranches';
import { DeploymentsBase } from '@s/deployments/DeploymentsBase';
import { DeploymentsTypes } from '@s/deployments/DeploymentsTypes';
import { TrancheDepositor } from '@0xc/hardhat/TrancheDepositor/TrancheDepositor';
import { Web3ClientFactory } from 'dequanto/clients/Web3ClientFactory';


export namespace $hh {

    export function isCoverage () {
        const coverage = Boolean($cli.getParamValue('coverage'));
        return coverage as boolean;
    }

    export function getClient () {
        const hh = new HardhatProvider();
        return hh.client('hardhat');
    }

    export async function forked<TKey extends TCDOKey> (opts?: {
        block?: number,
        cdo: TKey,
        cdoInfo?: Partial<ICDO>,
    }) {
        const config = await PlatformFactory.ConfigLoader.fetch();
        const hh = new HardhatProvider();
        const client = await hh.forked({ platform: 'eth', block: opts?.block ?? void 0 });
        client.configureFork('eth');

        const { tranches } = await PlatformFactory.init<TKey>({
            client,
            cdo: opts?.cdo ?? 'ethena' as TKey,
            cdoInfo: opts?.cdoInfo
        });
        return tranches;
    }

    export function create<T extends TCDOKey>(cdo: T, params?: {
        forked?: number | 'latest'
        cdoInfo?: Partial<ICDO>
        accounts?: TCDOKey | 'operator' | 'deployer'
        // Relevant for forked tests: when true, all contracts being redeployed, otherwise will reuse existing contracts
        fresh?: boolean
    }) {
        return new Test<DeploymentsTypes.CDOs[T]>(cdo, params)
    }

    export async function init<T extends TCDOKey>(...args: Parameters<typeof create<T>>) {
        const test = create(...args);
        return await test.init();
    }

    export async function deploy<T extends TCDOKey>(...args: Parameters<typeof create<T>>) {
        const test = create(...args);
        const ds = await test.init();
        await ds.deploy();
        return ds;
    }

    export async function reset (client: Web3Client) {
        await client.debug.reset({});
        if (test.factory) {
            memd.fn.clearMemoized(test.factory.ensureCDO);
            memd.fn.clearMemoized(test.factory.ensureUnderlying);
            memd.fn.clearMemoized(test.factory.ensureACM);
            memd.fn.clearMemoized(test.factory.ensureCooldowns);
        }
        memd.fn.clearMemoized(test.deploy);
        memd.fn.clearMemoized(test.init);
        (client as HardhatWeb3Client).configureFork(null);
    }

    export class Test<TDeployments extends DeploymentsBase> {
        snapshots: Record<string, any> = {};
        client: Web3Client;
        factory: TDeployments;
        tranches: Awaited<ReturnType<TDeployments['ensureCDO']>>;
        underlying: Awaited<ReturnType<TDeployments['ensureUnderlying']>>;
        deployer: TEth.EoAccount
        depositor: TrancheDepositor
        configManager: TwoStepConfigManager;

        constructor (private cdoKey: TCDOKey, private params?: {
            forked?: number | 'latest'
            cdoInfo?: Partial<ICDO>
            accounts?: TCDOKey | 'operator' | 'deployer'
            fresh?: boolean
        }) {
            // Override default CDO infos for tests
            this.params ??= {};
        }

        @memd.deco.memoize({ perInstance: true })
        async init (opts?: { initialDeposit?: boolean }) {
            const config = await PlatformFactory.ConfigLoader.fetch();
            const hh = new HardhatProvider();

            if (this.params?.forked === 'latest') {
                let eth = await Web3ClientFactory.getAsync('eth');
                let block = await eth.getBlockNumber();
                this.params.forked = block - 50;
            }

            const client = this.params?.forked == null
                ? await getClient()
                : await hh.forked({ platform: 'eth', block: this.params.forked });

            if (this.params?.forked != null) {
                client.configureFork('eth');
            }

            const deployer = await hh.deployer(0);

            const { tranches: factory } = await PlatformFactory.init({
                client,
                cdo: this.cdoKey,
                cdoInfo: this.params?.cdoInfo,
                accounts: this.params?.accounts,
                initialDeposit: opts?.initialDeposit,
                isTest: this.params?.fresh,
                ...(opts ?? {}),
            });

            this.client = client;
            this.factory = factory as any as TDeployments;
            this.deployer = deployer;
            return this;
        }

        async createAccount (name: string, client?: Web3Client) {
            let account = $sig.$account.generate({ name });
            await (client ?? this.client).debug.setBalance(account.address, 10n**20n);
            return account;
        }

        @memd.deco.memoize({ perInstance: true })
        async deploy (opts?: { initialDeposit?: boolean }) {
            await this.init(opts);

            this.underlying = await this.factory.ensureUnderlying();

            let contracts = await this.factory.ensureDeployment(opts);

            this.tranches = contracts;
            this.depositor = contracts.depositor;
            let { configManager } = await this.factory.ensureConfigManager();
            this.configManager = configManager;

            await this.snapshot();
            return {
                ...this.tranches,
                ...this.underlying,
            };
        }

        async snapshot (snapshotName: string = 'root') {
            if (this.client == null) {
                return;
            }
            this.snapshots[snapshotName] = await this.client.debug.snapshot();
        }

        async reset (snapshotName: string = 'root') {
            if (this.client == null) {
                return;
            }
            let snap = $require.notNull(this.snapshots[snapshotName], snapshotName);
            let result = await this.client.debug.revert(snap);
            if (result == false) {
                const message = `🚫🚫🚫 Failed to revert to snapshot ${snapshotName}: ${snap}`
                console.error(message)
                //throw new Error(message);
            }

            let newSnapshotId = await this.client.debug.snapshot();
            this.snapshots[snapshotName] = newSnapshotId;
        }

        async wipe () {
            const { client, factory } = this;
            if ('root' in this.snapshots) {
                await this.reset('root');
            }
            await client.debug.reset({});
            if (factory) {
                memd.fn.clearMemoized(factory.ensureCDO);
                memd.fn.clearMemoized(factory.ensureUnderlying);
                memd.fn.clearMemoized(factory.ensureACM);
                memd.fn.clearMemoized(factory.ensureCooldowns);
            }
            memd.fn.clearMemoized(this.deploy);
            memd.fn.clearMemoized(this.init);
            (client as HardhatWeb3Client).configureFork(null);
        }

        async mine (t: string | '30mins' | '5hours' | '1year') {
            await this.client.debug.mine(t);
        }
    }

    export const test = new Test('ethena')
}
