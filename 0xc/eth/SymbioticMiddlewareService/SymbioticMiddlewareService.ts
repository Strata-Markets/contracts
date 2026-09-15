/**
 *  AUTO-Generated Class: 2026-09-22 13:04
 *  Implementation: https://etherscan.io/address/0xD7dC9B366c027743D90761F71858BCa83C6899Ad#code
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

export namespace SymbioticMiddlewareServiceErrors {
    export interface AlreadySet {
        type: 'AlreadySet'
        params: {
        }
    }
    export interface NotNetwork {
        type: 'NotNetwork'
        params: {
        }
    }
    export type Error = AlreadySet | NotNetwork
}

export class SymbioticMiddlewareService extends ContractBase {
    constructor(
        public address: TEth.Address = '0xD7dC9B366c027743D90761F71858BCa83C6899Ad',
        public client: Web3Client = di.resolve(EvmWeb3Client, { platform: 'eth' }),
        public explorer: IBlockchainExplorer = di.resolve(Evmscan, { platform: 'eth' }),
    ) {
        super(address, client, explorer)

        this.storage = new SymbioticMiddlewareServiceStorageReader(this.address, this.client, this.explorer);
    }

    Types: TSymbioticMiddlewareServiceTypes;

    $meta = {
        "class": "./0xc/eth/SymbioticMiddlewareService/SymbioticMiddlewareService.ts"
    }

    async $constructor (deployer: TSender, networkRegistry: TAddress): Promise<TxWriter> {
        throw new Error('Not implemented. Typing purpose. Use the ContractDeployer class to deploy the contract');
    }

    // 0xc0cd7c3e
    async NETWORK_REGISTRY (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'NETWORK_REGISTRY'));
    }

    // 0xbb5ed032
    async middleware (network: TAddress): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'middleware'), network);
    }

    // 0xb7d8e1a9
    async setMiddleware (sender: TSender, middleware_: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'setMiddleware'), sender, middleware_);
    }

    $call () {
        return super.$call() as ISymbioticMiddlewareServiceTxCaller;
    }
    $signed (): TOverrideReturns<ISymbioticMiddlewareServiceTxCaller, Promise<{ signed: TEth.Hex, error?: Error & { data?: { type: string, params } } }>> {
        return super.$signed() as any;
    }
    $data (): ISymbioticMiddlewareServiceTxData {
        return super.$data() as ISymbioticMiddlewareServiceTxData;
    }
    $gas (): TOverrideReturns<ISymbioticMiddlewareServiceTxCaller, Promise<{ gas?: bigint, price?: bigint, error?: Error & { data?: { type: string, params } } }>> {
        return super.$gas() as any;
    }

    onTransaction <TMethod extends keyof TSymbioticMiddlewareServiceTypes['Methods']> (method: TMethod, options: Parameters<ContractBase['$onTransaction']>[0]): SubjectStream<{
        tx: TEth.Tx
        block: TEth.Block<TEth.Hex>
        calldata: {
            method: TMethod
            arguments: TSymbioticMiddlewareServiceTypes['Methods'][TMethod]['arguments']
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

    onSetMiddleware (fn?: (event: TClientEventsStreamData<TEventArguments<'SetMiddleware'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetMiddleware'>>> {
        return this.$onLog('SetMiddleware', fn);
    }

    extractLogsSetMiddleware (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetMiddleware'>>[] {
        let abi = this.$getAbiItem('event', 'SetMiddleware');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetMiddleware'>>[];
    }

    async getPastLogsSetMiddleware (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { network?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'SetMiddleware'>>[]> {
        return await this.$getPastLogsParsed('SetMiddleware', options) as any;
    }

    abi: TAbiItem[] = [{"inputs":[{"internalType":"address","name":"networkRegistry","type":"address"}],"stateMutability":"nonpayable","type":"constructor"},{"inputs":[],"name":"AlreadySet","type":"error"},{"inputs":[],"name":"NotNetwork","type":"error"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"network","type":"address"},{"indexed":false,"internalType":"address","name":"middleware","type":"address"}],"name":"SetMiddleware","type":"event"},{"inputs":[],"name":"NETWORK_REGISTRY","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"network","type":"address"}],"name":"middleware","outputs":[{"internalType":"address","name":"value","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"middleware_","type":"address"}],"name":"setMiddleware","outputs":[],"stateMutability":"nonpayable","type":"function"}]

    declare storage: SymbioticMiddlewareServiceStorageReader
}

type TSender = TAccount & {
    value?: string | number | bigint
}

type TEventLogOptions<TParams> = {
    fromBlock?: number | Date
    toBlock?: number | Date
    params?: TParams
}

export type TSymbioticMiddlewareServiceTypes = {
    Events: {
        SetMiddleware: {
            outputParams: { network: TAddress, middleware: TAddress },
            outputArgs:   [ network: TAddress, middleware: TAddress ],
        }
    },
    Methods: {
        NETWORK_REGISTRY: {
          method: "NETWORK_REGISTRY"
          arguments: [  ]
        }
        middleware: {
          method: "middleware"
          arguments: [ network: TAddress ]
        }
        setMiddleware: {
          method: "setMiddleware"
          arguments: [ middleware_: TAddress ]
        }
    }
}



class SymbioticMiddlewareServiceStorageReader extends ContractStorageReaderBase {
    constructor(
        public address: TAddress,
        public client: Web3Client,
        public explorer: IBlockchainExplorer,
    ) {
        super(address, client, explorer);

        this.$createHandler(this.$slots);
    }

    async middleware(key: TAddress): Promise<TAddress> {
        return this.$storage.get(['middleware', key]);
    }

    $slots = [
    {
        "slot": 0,
        "position": 0,
        "name": "middleware",
        "size": null,
        "type": "mapping(address => address)"
    }
]

}


interface ISymbioticMiddlewareServiceTxCaller {
    setMiddleware (sender: TSender, middleware_: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
}


interface ISymbioticMiddlewareServiceTxData {
    setMiddleware (sender: TSender, middleware_: TAddress): Promise<TEth.TxLike>
}


type TEvents = TSymbioticMiddlewareServiceTypes['Events'];
type TEventParams<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputParams']>;
type TEventArguments<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputArgs']>;
