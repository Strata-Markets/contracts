/**
 *  AUTO-Generated Class: 2026-09-22 13:04
 *  Implementation: https://etherscan.io/address/0xC773b1011461e7314CF05f97d95aa8e92C1Fd8aA#code
 */
import di from 'a-di';
import { TAddress } from 'dequanto/models/TAddress';
import { TAccount } from 'dequanto/models/TAccount';
import { TBufferLike } from 'dequanto/models/TBufferLike';
import { ClientEventsStream, TClientEventsStreamData } from 'dequanto/clients/ClientEventsStream';
import { ContractBase } from 'dequanto/contracts/ContractBase';
import { ContractBaseUtils } from 'dequanto/contracts/utils/ContractBaseUtils';
import { ContractStorageReaderBase } from 'dequanto/contracts/ContractStorageReaderBase';
import { TxWriter } from 'dequanto/txs/TxWriter';
import { ITxLogItem } from 'dequanto/txs/receipt/ITxLogItem';
import { Web3Client } from 'dequanto/clients/Web3Client';
import { IBlockchainExplorer } from 'dequanto/explorer/IBlockchainExplorer';
import { SubjectStream } from 'dequanto/class/SubjectStream';


import type { ContractWriter } from 'dequanto/contracts/ContractWriter';
import type { TAbiItem } from 'dequanto/types/TAbi';
import type { TEth } from 'dequanto/models/TEth';
import type { TOverrideReturns } from 'dequanto/utils/types';


import { Evmscan } from 'dequanto/explorer/Evmscan';
import { EvmWeb3Client } from 'dequanto/clients/EvmWeb3Client';

export namespace SymbioticNetworkRegistryErrors {
    export interface EntityNotExist {
        type: 'EntityNotExist'
        params: {
        }
    }
    export interface NetworkAlreadyRegistered {
        type: 'NetworkAlreadyRegistered'
        params: {
        }
    }
    export type Error = EntityNotExist | NetworkAlreadyRegistered
}

export class SymbioticNetworkRegistry extends ContractBase {
    constructor(
        public address: TEth.Address = '0xC773b1011461e7314CF05f97d95aa8e92C1Fd8aA',
        public client: Web3Client = di.resolve(EvmWeb3Client, { platform: 'eth' }),
        public explorer: IBlockchainExplorer = di.resolve(Evmscan, { platform: 'eth' }),
    ) {
        super(address, client, explorer)

        this.storage = new SymbioticNetworkRegistryStorageReader(this.address, this.client, this.explorer);
    }

    Types: TSymbioticNetworkRegistryTypes;

    $meta = {
        "class": "./0xc/eth/SymbioticNetworkRegistry/SymbioticNetworkRegistry.ts"
    }

    // 0xb42ba2a2
    async entity (index: bigint): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'entity'), index);
    }

    // 0x14887c58
    async isEntity (entity_: TAddress): Promise<boolean> {
        return this.$read(this.$getAbiItem('function', 'isEntity'), entity_);
    }

    // 0x87140b5b
    async registerNetwork (sender: TSender, ): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'registerNetwork'), sender);
    }

    // 0x5cd8b15e
    async totalEntities (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'totalEntities'));
    }

    $call () {
        return super.$call() as ISymbioticNetworkRegistryTxCaller;
    }
    $signed (): TOverrideReturns<ISymbioticNetworkRegistryTxCaller, Promise<{ signed: TEth.Hex, error?: Error & { data?: { type: string, params } } }>> {
        return super.$signed() as any;
    }
    $data (): ISymbioticNetworkRegistryTxData {
        return super.$data() as ISymbioticNetworkRegistryTxData;
    }
    $gas (): TOverrideReturns<ISymbioticNetworkRegistryTxCaller, Promise<{ gas?: bigint, price?: bigint, error?: Error & { data?: { type: string, params } } }>> {
        return super.$gas() as any;
    }

    onTransaction <TMethod extends keyof TSymbioticNetworkRegistryTypes['Methods']> (method: TMethod, options: Parameters<ContractBase['$onTransaction']>[0]): SubjectStream<{
        tx: TEth.Tx
        block: TEth.Block<TEth.Hex>
        calldata: {
            method: TMethod
            arguments: TSymbioticNetworkRegistryTypes['Methods'][TMethod]['arguments']
        }
    }> {
        options ??= {};
        options.filter ??= {};
        options.filter.method = method;
        return <any> this.$onTransaction(options);
    }

    onLog (event: keyof TEvents, cb?: (event: TClientEventsStreamData) => void): ClientEventsStream<TClientEventsStreamData> {
        return this.$onLog(event, cb);
    }

    async getPastLogs <TEventName extends keyof TEvents> (
        events: TEventName[]
        , options?: TEventLogOptions<TEventParams<TEventName>>
    ): Promise<ITxLogItem<TEventParams<TEventName>, TEventName>[]>
    async getPastLogs <TEventName extends keyof TEvents> (
        event: TEventName
        , options?: TEventLogOptions<TEventParams<TEventName>>
    ): Promise<ITxLogItem<TEventParams<TEventName>, TEventName>[]>
    async getPastLogs (mix: any, options?): Promise<any> {
        return await super.getPastLogs(mix, options) as any;
    }

    onAddEntity (fn?: (event: TClientEventsStreamData<TEventArguments<'AddEntity'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'AddEntity'>>> {
        return this.$onLog('AddEntity', fn);
    }

    extractLogsAddEntity (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'AddEntity'>>[] {
        let abi = this.$getAbiItem('event', 'AddEntity');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'AddEntity'>>[];
    }

    async getPastLogsAddEntity (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { entity?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'AddEntity'>>[]> {
        return await this.$getPastLogsParsed('AddEntity', options) as any;
    }

    abi: TAbiItem[] = [{"inputs":[],"name":"EntityNotExist","type":"error"},{"inputs":[],"name":"NetworkAlreadyRegistered","type":"error"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"entity","type":"address"}],"name":"AddEntity","type":"event"},{"inputs":[{"internalType":"uint256","name":"index","type":"uint256"}],"name":"entity","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"entity_","type":"address"}],"name":"isEntity","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"registerNetwork","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"totalEntities","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"}]

    declare storage: SymbioticNetworkRegistryStorageReader
}

type TSender = TAccount & {
    value?: string | number | bigint
}

type TEventLogOptions<TParams> = {
    fromBlock?: number | Date
    toBlock?: number | Date
    params?: TParams
}

export type TSymbioticNetworkRegistryTypes = {
    Events: {
        AddEntity: {
            outputParams: { entity: TAddress },
            outputArgs:   [ entity: TAddress ],
        }
    },
    Methods: {
        entity: {
          method: "entity"
          arguments: [ index: bigint ]
        }
        isEntity: {
          method: "isEntity"
          arguments: [ entity_: TAddress ]
        }
        registerNetwork: {
          method: "registerNetwork"
          arguments: [  ]
        }
        totalEntities: {
          method: "totalEntities"
          arguments: [  ]
        }
    }
}



class SymbioticNetworkRegistryStorageReader extends ContractStorageReaderBase {
    constructor(
        public address: TAddress,
        public client: Web3Client,
        public explorer: IBlockchainExplorer,
    ) {
        super(address, client, explorer);

        this.$createHandler(this.$slots);
    }

    async _entities(): Promise<{ _inner: { _values: TEth.Hex[], _positions: Record<string | number, bigint> } }> {
        return this.$storage.get(['_entities', ]);
    }

    $slots = [
    {
        "slot": 0,
        "position": 0,
        "name": "_entities",
        "size": 512,
        "type": "((bytes32[] _values, mapping(bytes32 => uint256) _positions) _inner)"
    }
]

}


interface ISymbioticNetworkRegistryTxCaller {
    registerNetwork (sender: TSender, ): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
}


interface ISymbioticNetworkRegistryTxData {
    registerNetwork (sender: TSender, ): Promise<TEth.TxLike>
}


type TEvents = TSymbioticNetworkRegistryTypes['Events'];
type TEventParams<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputParams']>;
type TEventArguments<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputArgs']>;
