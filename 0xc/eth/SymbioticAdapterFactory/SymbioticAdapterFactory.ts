/**
 *  AUTO-Generated Class: 2026-09-17 13:20
 *  Implementation: https://etherscan.io/address/0x161954842B7EA47CBd050cAb4875DAa4D6599476#code
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

export namespace SymbioticAdapterFactoryErrors {
    export interface AlreadyBlacklisted {
        type: 'AlreadyBlacklisted'
        params: {
        }
    }
    export interface AlreadyWhitelisted {
        type: 'AlreadyWhitelisted'
        params: {
        }
    }
    export interface EntityNotExist {
        type: 'EntityNotExist'
        params: {
        }
    }
    export interface InvalidImplementation {
        type: 'InvalidImplementation'
        params: {
        }
    }
    export interface InvalidVersion {
        type: 'InvalidVersion'
        params: {
        }
    }
    export interface NotOwner {
        type: 'NotOwner'
        params: {
        }
    }
    export interface OldVersion {
        type: 'OldVersion'
        params: {
        }
    }
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
    export type Error = AlreadyBlacklisted | AlreadyWhitelisted | EntityNotExist | InvalidImplementation | InvalidVersion | NotOwner | OldVersion | OwnableInvalidOwner | OwnableUnauthorizedAccount
}

export class SymbioticAdapterFactory extends ContractBase {
    constructor(
        public address: TEth.Address = '0x161954842B7EA47CBd050cAb4875DAa4D6599476',
        public client: Web3Client = di.resolve(EvmWeb3Client, { platform: 'eth' }),
        public explorer: IBlockchainExplorer = di.resolve(Evmscan, { platform: 'eth' }),
    ) {
        super(address, client, explorer)

        this.storage = new SymbioticAdapterFactoryStorageReader(this.address, this.client, this.explorer);
    }

    Types: TSymbioticAdapterFactoryTypes;

    $meta = {
        "class": "./0xc/eth/SymbioticAdapterFactory/SymbioticAdapterFactory.ts"
    }

    async $constructor (deployer: TSender, newOwner: TAddress): Promise<TxWriter> {
        throw new Error('Not implemented. Typing purpose. Use the ContractDeployer class to deploy the contract');
    }

    // 0xb572a966
    async blacklist (sender: TSender, version: number): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'blacklist'), sender, version);
    }

    // 0xb6caa119
    async blacklisted (version: number): Promise<boolean> {
        return this.$read(this.$getAbiItem('function', 'blacklisted'), version);
    }

    // 0x3ac04911
    async create (sender: TSender, version: number, owner_: TAddress, data: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'create'), sender, version, owner_, data);
    }

    // 0xb42ba2a2
    async entity (index: bigint): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'entity'), index);
    }

    // 0xf9661602
    async implementation (version: number): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'implementation'), version);
    }

    // 0x14887c58
    async isEntity (entity_: TAddress): Promise<boolean> {
        return this.$read(this.$getAbiItem('function', 'isEntity'), entity_);
    }

    // 0x64dfea06
    async lastVersion (): Promise<number> {
        return this.$read(this.$getAbiItem('function', 'lastVersion'));
    }

    // 0x58336662
    async migrate (sender: TSender, entity_: TAddress, newVersion: number, data: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'migrate'), sender, entity_, newVersion, data);
    }

    // 0x8da5cb5b
    async owner (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'owner'));
    }

    // 0x715018a6
    async renounceOwnership (sender: TSender, ): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'renounceOwnership'), sender);
    }

    // 0x5cd8b15e
    async totalEntities (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'totalEntities'));
    }

    // 0xf2fde38b
    async transferOwnership (sender: TSender, newOwner: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'transferOwnership'), sender, newOwner);
    }

    // 0x9b19251a
    async whitelist (sender: TSender, implementation_: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'whitelist'), sender, implementation_);
    }

    $call () {
        return super.$call() as ISymbioticAdapterFactoryTxCaller;
    }
    $signed (): TOverrideReturns<ISymbioticAdapterFactoryTxCaller, Promise<{ signed: TEth.Hex, error?: Error & { data?: { type: string, params } } }>> {
        return super.$signed() as any;
    }
    $data (): ISymbioticAdapterFactoryTxData {
        return super.$data() as ISymbioticAdapterFactoryTxData;
    }
    $gas (): TOverrideReturns<ISymbioticAdapterFactoryTxCaller, Promise<{ gas?: bigint, price?: bigint, error?: Error & { data?: { type: string, params } } }>> {
        return super.$gas() as any;
    }

    onTransaction <TMethod extends keyof TSymbioticAdapterFactoryTypes['Methods']> (method: TMethod, options: Parameters<ContractBase['$onTransaction']>[0]): SubjectStream<{
        tx: TEth.Tx
        block: TEth.Block<TEth.Hex>
        calldata: {
            method: TMethod
            arguments: TSymbioticAdapterFactoryTypes['Methods'][TMethod]['arguments']
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

    onBlacklist (fn?: (event: TClientEventsStreamData<TEventArguments<'Blacklist'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Blacklist'>>> {
        return this.$onLog('Blacklist', fn);
    }

    onMigrate (fn?: (event: TClientEventsStreamData<TEventArguments<'Migrate'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Migrate'>>> {
        return this.$onLog('Migrate', fn);
    }

    onOwnershipTransferred (fn?: (event: TClientEventsStreamData<TEventArguments<'OwnershipTransferred'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'OwnershipTransferred'>>> {
        return this.$onLog('OwnershipTransferred', fn);
    }

    onWhitelist (fn?: (event: TClientEventsStreamData<TEventArguments<'Whitelist'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Whitelist'>>> {
        return this.$onLog('Whitelist', fn);
    }

    extractLogsAddEntity (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'AddEntity'>>[] {
        let abi = this.$getAbiItem('event', 'AddEntity');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'AddEntity'>>[];
    }

    extractLogsBlacklist (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Blacklist'>>[] {
        let abi = this.$getAbiItem('event', 'Blacklist');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Blacklist'>>[];
    }

    extractLogsMigrate (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Migrate'>>[] {
        let abi = this.$getAbiItem('event', 'Migrate');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Migrate'>>[];
    }

    extractLogsOwnershipTransferred (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'OwnershipTransferred'>>[] {
        let abi = this.$getAbiItem('event', 'OwnershipTransferred');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'OwnershipTransferred'>>[];
    }

    extractLogsWhitelist (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Whitelist'>>[] {
        let abi = this.$getAbiItem('event', 'Whitelist');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Whitelist'>>[];
    }

    async getPastLogsAddEntity (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { entity?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'AddEntity'>>[]> {
        return await this.$getPastLogsParsed('AddEntity', options) as any;
    }

    async getPastLogsBlacklist (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { version?: number }
    }): Promise<ITxLogItem<TEventParams<'Blacklist'>>[]> {
        return await this.$getPastLogsParsed('Blacklist', options) as any;
    }

    async getPastLogsMigrate (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { entity?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'Migrate'>>[]> {
        return await this.$getPastLogsParsed('Migrate', options) as any;
    }

    async getPastLogsOwnershipTransferred (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { previousOwner?: TAddress,newOwner?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'OwnershipTransferred'>>[]> {
        return await this.$getPastLogsParsed('OwnershipTransferred', options) as any;
    }

    async getPastLogsWhitelist (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { implementation?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'Whitelist'>>[]> {
        return await this.$getPastLogsParsed('Whitelist', options) as any;
    }

    abi: TAbiItem[] = [{"inputs":[{"internalType":"address","name":"newOwner","type":"address"}],"stateMutability":"nonpayable","type":"constructor"},{"inputs":[],"name":"AlreadyBlacklisted","type":"error"},{"inputs":[],"name":"AlreadyWhitelisted","type":"error"},{"inputs":[],"name":"EntityNotExist","type":"error"},{"inputs":[],"name":"InvalidImplementation","type":"error"},{"inputs":[],"name":"InvalidVersion","type":"error"},{"inputs":[],"name":"NotOwner","type":"error"},{"inputs":[],"name":"OldVersion","type":"error"},{"inputs":[{"internalType":"address","name":"owner","type":"address"}],"name":"OwnableInvalidOwner","type":"error"},{"inputs":[{"internalType":"address","name":"account","type":"address"}],"name":"OwnableUnauthorizedAccount","type":"error"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"entity","type":"address"}],"name":"AddEntity","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"uint64","name":"version","type":"uint64"}],"name":"Blacklist","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"entity","type":"address"},{"indexed":false,"internalType":"uint64","name":"newVersion","type":"uint64"}],"name":"Migrate","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"previousOwner","type":"address"},{"indexed":true,"internalType":"address","name":"newOwner","type":"address"}],"name":"OwnershipTransferred","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"implementation","type":"address"}],"name":"Whitelist","type":"event"},{"inputs":[{"internalType":"uint64","name":"version","type":"uint64"}],"name":"blacklist","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint64","name":"version","type":"uint64"}],"name":"blacklisted","outputs":[{"internalType":"bool","name":"value","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint64","name":"version","type":"uint64"},{"internalType":"address","name":"owner_","type":"address"},{"internalType":"bytes","name":"data","type":"bytes"}],"name":"create","outputs":[{"internalType":"address","name":"entity_","type":"address"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"index","type":"uint256"}],"name":"entity","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint64","name":"version","type":"uint64"}],"name":"implementation","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"entity_","type":"address"}],"name":"isEntity","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"lastVersion","outputs":[{"internalType":"uint64","name":"","type":"uint64"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"entity_","type":"address"},{"internalType":"uint64","name":"newVersion","type":"uint64"},{"internalType":"bytes","name":"data","type":"bytes"}],"name":"migrate","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"owner","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"renounceOwnership","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"totalEntities","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"newOwner","type":"address"}],"name":"transferOwnership","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"implementation_","type":"address"}],"name":"whitelist","outputs":[],"stateMutability":"nonpayable","type":"function"}]

    declare storage: SymbioticAdapterFactoryStorageReader
}

type TSender = TAccount & {
    value?: string | number | bigint
}

type TEventLogOptions<TParams> = {
    fromBlock?: number | Date
    toBlock?: number | Date
    params?: TParams
}

export type TSymbioticAdapterFactoryTypes = {
    Events: {
        AddEntity: {
            outputParams: { entity: TAddress },
            outputArgs:   [ entity: TAddress ],
        }
        Blacklist: {
            outputParams: { version: number },
            outputArgs:   [ version: number ],
        }
        Migrate: {
            outputParams: { entity: TAddress, newVersion: number },
            outputArgs:   [ entity: TAddress, newVersion: number ],
        }
        OwnershipTransferred: {
            outputParams: { previousOwner: TAddress, newOwner: TAddress },
            outputArgs:   [ previousOwner: TAddress, newOwner: TAddress ],
        }
        Whitelist: {
            outputParams: { implementation: TAddress },
            outputArgs:   [ implementation: TAddress ],
        }
    },
    Methods: {
        blacklist: {
          method: "blacklist"
          arguments: [ version: number ]
        }
        blacklisted: {
          method: "blacklisted"
          arguments: [ version: number ]
        }
        create: {
          method: "create"
          arguments: [ version: number, owner_: TAddress, data: TEth.Hex ]
        }
        entity: {
          method: "entity"
          arguments: [ index: bigint ]
        }
        implementation: {
          method: "implementation"
          arguments: [ version: number ]
        }
        isEntity: {
          method: "isEntity"
          arguments: [ entity_: TAddress ]
        }
        lastVersion: {
          method: "lastVersion"
          arguments: [  ]
        }
        migrate: {
          method: "migrate"
          arguments: [ entity_: TAddress, newVersion: number, data: TEth.Hex ]
        }
        owner: {
          method: "owner"
          arguments: [  ]
        }
        renounceOwnership: {
          method: "renounceOwnership"
          arguments: [  ]
        }
        totalEntities: {
          method: "totalEntities"
          arguments: [  ]
        }
        transferOwnership: {
          method: "transferOwnership"
          arguments: [ newOwner: TAddress ]
        }
        whitelist: {
          method: "whitelist"
          arguments: [ implementation_: TAddress ]
        }
    }
}



class SymbioticAdapterFactoryStorageReader extends ContractStorageReaderBase {
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

    async _owner(): Promise<TAddress> {
        return this.$storage.get(['_owner', ]);
    }

    async blacklisted(key: number): Promise<boolean> {
        return this.$storage.get(['blacklisted', key]);
    }

    async _whitelistedImplementations(): Promise<{ _inner: { _values: TEth.Hex[], _positions: Record<string | number, bigint> } }> {
        return this.$storage.get(['_whitelistedImplementations', ]);
    }

    $slots = [
    {
        "slot": 0,
        "position": 0,
        "name": "_entities",
        "size": 512,
        "type": "((bytes32[] _values, mapping(bytes32 => uint256) _positions) _inner)"
    },
    {
        "slot": 2,
        "position": 0,
        "name": "_owner",
        "size": 160,
        "type": "address"
    },
    {
        "slot": 3,
        "position": 0,
        "name": "blacklisted",
        "size": null,
        "type": "mapping(uint64 => bool)"
    },
    {
        "slot": 4,
        "position": 0,
        "name": "_whitelistedImplementations",
        "size": 512,
        "type": "((bytes32[] _values, mapping(bytes32 => uint256) _positions) _inner)"
    }
]

}


interface ISymbioticAdapterFactoryTxCaller {
    blacklist (sender: TSender, version: number): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    create (sender: TSender, version: number, owner_: TAddress, data: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    migrate (sender: TSender, entity_: TAddress, newVersion: number, data: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    renounceOwnership (sender: TSender, ): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    transferOwnership (sender: TSender, newOwner: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    whitelist (sender: TSender, implementation_: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
}


interface ISymbioticAdapterFactoryTxData {
    blacklist (sender: TSender, version: number): Promise<TEth.TxLike>
    create (sender: TSender, version: number, owner_: TAddress, data: TEth.Hex): Promise<TEth.TxLike>
    migrate (sender: TSender, entity_: TAddress, newVersion: number, data: TEth.Hex): Promise<TEth.TxLike>
    renounceOwnership (sender: TSender, ): Promise<TEth.TxLike>
    transferOwnership (sender: TSender, newOwner: TAddress): Promise<TEth.TxLike>
    whitelist (sender: TSender, implementation_: TAddress): Promise<TEth.TxLike>
}


type TEvents = TSymbioticAdapterFactoryTypes['Events'];
type TEventParams<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputParams']>;
type TEventArguments<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputArgs']>;
