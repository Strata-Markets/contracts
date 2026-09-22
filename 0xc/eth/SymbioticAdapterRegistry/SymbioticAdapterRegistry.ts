/**
 *  AUTO-Generated Class: 2026-09-22 00:33
 *  Implementation: https://etherscan.io/address/0x788823C9579A049D986eB76718bC758C0998594a#code
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

export namespace SymbioticAdapterRegistryErrors {
    export interface OwnableInvalidOwner {
        type: 'OwnableInvalidOwner'
        params: {
            owner: TAddress
        }
    }
    export interface OwnableUnauthorizedAccount {
        type: 'OwnableUnauthorizedAccount'
        params: {
            account: TAddress
        }
    }
    export type Error = OwnableInvalidOwner | OwnableUnauthorizedAccount
}

export class SymbioticAdapterRegistry extends ContractBase {
    constructor(
        public address: TEth.Address = '0x788823C9579A049D986eB76718bC758C0998594a',
        public client: Web3Client = di.resolve(EvmWeb3Client, { platform: 'eth' }),
        public explorer: IBlockchainExplorer = di.resolve(Evmscan, { platform: 'eth' }),
    ) {
        super(address, client, explorer)

        this.storage = new SymbioticAdapterRegistryStorageReader(this.address, this.client, this.explorer);
    }

    Types: TSymbioticAdapterRegistryTypes;

    $meta = {
        "class": "./0xc/eth/SymbioticAdapterRegistry/SymbioticAdapterRegistry.ts"
    }

    async $constructor (deployer: TSender, newOwner: TAddress): Promise<TxWriter> {
        throw new Error('Not implemented. Typing purpose. Use the ContractDeployer class to deploy the contract');
    }

    // 0xb6b35272
    async isWhitelisted (vault: TAddress, adapter: TAddress): Promise<boolean> {
        return this.$read(this.$getAbiItem('function', 'isWhitelisted'), vault, adapter);
    }

    // 0x8da5cb5b
    async owner (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'owner'));
    }

    // 0x715018a6
    async renounceOwnership (sender: TSender, ): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'renounceOwnership'), sender);
    }

    // 0x5a38d3bc
    async setWhitelistedStatus (sender: TSender, vault: TAddress, adapter: TAddress, status: boolean): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'setWhitelistedStatus'), sender, vault, adapter, status);
    }

    // 0xf2fde38b
    async transferOwnership (sender: TSender, newOwner: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'transferOwnership'), sender, newOwner);
    }

    $call () {
        return super.$call() as ISymbioticAdapterRegistryTxCaller;
    }
    $signed (): TOverrideReturns<ISymbioticAdapterRegistryTxCaller, Promise<{ signed: TEth.Hex, error?: Error & { data?: { type: string, params } } }>> {
        return super.$signed() as any;
    }
    $data (): ISymbioticAdapterRegistryTxData {
        return super.$data() as ISymbioticAdapterRegistryTxData;
    }
    $gas (): TOverrideReturns<ISymbioticAdapterRegistryTxCaller, Promise<{ gas?: bigint, price?: bigint, error?: Error & { data?: { type: string, params } } }>> {
        return super.$gas() as any;
    }

    onTransaction <TMethod extends keyof TSymbioticAdapterRegistryTypes['Methods']> (method: TMethod, options: Parameters<ContractBase['$onTransaction']>[0]): SubjectStream<{
        tx: TEth.Tx
        block: TEth.Block<TEth.Hex>
        calldata: {
            method: TMethod
            arguments: TSymbioticAdapterRegistryTypes['Methods'][TMethod]['arguments']
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

    onOwnershipTransferred (fn?: (event: TClientEventsStreamData<TEventArguments<'OwnershipTransferred'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'OwnershipTransferred'>>> {
        return this.$onLog('OwnershipTransferred', fn);
    }

    onSetWhitelistedStatus (fn?: (event: TClientEventsStreamData<TEventArguments<'SetWhitelistedStatus'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetWhitelistedStatus'>>> {
        return this.$onLog('SetWhitelistedStatus', fn);
    }

    extractLogsOwnershipTransferred (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'OwnershipTransferred'>>[] {
        let abi = this.$getAbiItem('event', 'OwnershipTransferred');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'OwnershipTransferred'>>[];
    }

    extractLogsSetWhitelistedStatus (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetWhitelistedStatus'>>[] {
        let abi = this.$getAbiItem('event', 'SetWhitelistedStatus');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetWhitelistedStatus'>>[];
    }

    async getPastLogsOwnershipTransferred (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { previousOwner?: TAddress,newOwner?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'OwnershipTransferred'>>[]> {
        return await this.$getPastLogsParsed('OwnershipTransferred', options) as any;
    }

    async getPastLogsSetWhitelistedStatus (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { vault?: TAddress,adapter?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'SetWhitelistedStatus'>>[]> {
        return await this.$getPastLogsParsed('SetWhitelistedStatus', options) as any;
    }

    abi: TAbiItem[] = [{"inputs":[{"internalType":"address","name":"newOwner","type":"address"}],"stateMutability":"nonpayable","type":"constructor"},{"inputs":[{"internalType":"address","name":"owner","type":"address"}],"name":"OwnableInvalidOwner","type":"error"},{"inputs":[{"internalType":"address","name":"account","type":"address"}],"name":"OwnableUnauthorizedAccount","type":"error"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"previousOwner","type":"address"},{"indexed":true,"internalType":"address","name":"newOwner","type":"address"}],"name":"OwnershipTransferred","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"vault","type":"address"},{"indexed":true,"internalType":"address","name":"adapter","type":"address"},{"indexed":false,"internalType":"bool","name":"status","type":"bool"}],"name":"SetWhitelistedStatus","type":"event"},{"inputs":[{"internalType":"address","name":"vault","type":"address"},{"internalType":"address","name":"adapter","type":"address"}],"name":"isWhitelisted","outputs":[{"internalType":"bool","name":"status","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"owner","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"renounceOwnership","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"vault","type":"address"},{"internalType":"address","name":"adapter","type":"address"},{"internalType":"bool","name":"status","type":"bool"}],"name":"setWhitelistedStatus","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"newOwner","type":"address"}],"name":"transferOwnership","outputs":[],"stateMutability":"nonpayable","type":"function"}]

    declare storage: SymbioticAdapterRegistryStorageReader
}

type TSender = TAccount & {
    value?: string | number | bigint
}

type TEventLogOptions<TParams> = {
    fromBlock?: number | Date
    toBlock?: number | Date
    params?: TParams
}

export type TSymbioticAdapterRegistryTypes = {
    Events: {
        OwnershipTransferred: {
            outputParams: { previousOwner: TAddress, newOwner: TAddress },
            outputArgs:   [ previousOwner: TAddress, newOwner: TAddress ],
        }
        SetWhitelistedStatus: {
            outputParams: { vault: TAddress, adapter: TAddress, status: boolean },
            outputArgs:   [ vault: TAddress, adapter: TAddress, status: boolean ],
        }
    },
    Methods: {
        isWhitelisted: {
          method: "isWhitelisted"
          arguments: [ vault: TAddress, adapter: TAddress ]
        }
        owner: {
          method: "owner"
          arguments: [  ]
        }
        renounceOwnership: {
          method: "renounceOwnership"
          arguments: [  ]
        }
        setWhitelistedStatus: {
          method: "setWhitelistedStatus"
          arguments: [ vault: TAddress, adapter: TAddress, status: boolean ]
        }
        transferOwnership: {
          method: "transferOwnership"
          arguments: [ newOwner: TAddress ]
        }
    }
}



class SymbioticAdapterRegistryStorageReader extends ContractStorageReaderBase {
    constructor(
        public address: TAddress,
        public client: Web3Client,
        public explorer: IBlockchainExplorer,
    ) {
        super(address, client, explorer);

        this.$createHandler(this.$slots);
    }

    async _owner(): Promise<TAddress> {
        return this.$storage.get(['_owner', ]);
    }

    async isWhitelisted(key: TAddress): Promise<Record<string | number, boolean>> {
        return this.$storage.get(['isWhitelisted', key]);
    }

    $slots = [
    {
        "slot": 0,
        "position": 0,
        "name": "_owner",
        "size": 160,
        "type": "address"
    },
    {
        "slot": 1,
        "position": 0,
        "name": "isWhitelisted",
        "size": null,
        "type": "mapping(address => mapping(address => bool))"
    }
]

}


interface ISymbioticAdapterRegistryTxCaller {
    renounceOwnership (sender: TSender, ): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    setWhitelistedStatus (sender: TSender, vault: TAddress, adapter: TAddress, status: boolean): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    transferOwnership (sender: TSender, newOwner: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
}


interface ISymbioticAdapterRegistryTxData {
    renounceOwnership (sender: TSender, ): Promise<TEth.TxLike>
    setWhitelistedStatus (sender: TSender, vault: TAddress, adapter: TAddress, status: boolean): Promise<TEth.TxLike>
    transferOwnership (sender: TSender, newOwner: TAddress): Promise<TEth.TxLike>
}


type TEvents = TSymbioticAdapterRegistryTypes['Events'];
type TEventParams<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputParams']>;
type TEventArguments<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputArgs']>;
