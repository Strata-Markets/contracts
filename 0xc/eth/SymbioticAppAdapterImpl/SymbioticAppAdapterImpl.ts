/**
 *  AUTO-Generated Class: 2026-09-21 19:40
 *  Implementation: https://etherscan.io/address/0xfe8cFC5Dbb9c77A32a5Eb77C17F0317593f2c133#code
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

export namespace SymbioticAppAdapterImplErrors {
    export interface AlreadyInitialized {
        type: 'AlreadyInitialized'
        params: {
        }
    }
    export interface AlreadyReservedOrder {
        type: 'AlreadyReservedOrder'
        params: {
        }
    }
    export interface CheckpointUnorderedInsertion {
        type: 'CheckpointUnorderedInsertion'
        params: {
        }
    }
    export interface ExecutionDelayNotElapsed {
        type: 'ExecutionDelayNotElapsed'
        params: {
        }
    }
    export interface ExpiredOrder {
        type: 'ExpiredOrder'
        params: {
        }
    }
    export interface InsufficientBurnerGas {
        type: 'InsufficientBurnerGas'
        params: {
        }
    }
    export interface InsufficientSlash {
        type: 'InsufficientSlash'
        params: {
        }
    }
    export interface InvalidAccountNonce {
        type: 'InvalidAccountNonce'
        params: {
            account: TAddress
            currentNonce: bigint
        }
    }
    export interface InvalidBuyAmount {
        type: 'InvalidBuyAmount'
        params: {
        }
    }
    export interface InvalidCaller {
        type: 'InvalidCaller'
        params: {
        }
    }
    export interface InvalidDuration {
        type: 'InvalidDuration'
        params: {
        }
    }
    export interface InvalidInitialization {
        type: 'InvalidInitialization'
        params: {
        }
    }
    export interface InvalidNetOrOp {
        type: 'InvalidNetOrOp'
        params: {
        }
    }
    export interface InvalidSellAmount {
        type: 'InvalidSellAmount'
        params: {
        }
    }
    export interface InvalidTokenIn {
        type: 'InvalidTokenIn'
        params: {
        }
    }
    export interface InvalidTokenOut {
        type: 'InvalidTokenOut'
        params: {
        }
    }
    export interface InvalidVault {
        type: 'InvalidVault'
        params: {
        }
    }
    export interface NoBurner {
        type: 'NoBurner'
        params: {
        }
    }
    export interface NotFactory {
        type: 'NotFactory'
        params: {
        }
    }
    export interface NotInitializing {
        type: 'NotInitializing'
        params: {
        }
    }
    export interface NotNetworkMiddleware {
        type: 'NotNetworkMiddleware'
        params: {
        }
    }
    export interface NotNetworkOrMiddleware {
        type: 'NotNetworkOrMiddleware'
        params: {
        }
    }
    export interface NotVault {
        type: 'NotVault'
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
    export interface ReentrancyGuardReentrantCall {
        type: 'ReentrancyGuardReentrantCall'
        params: {
        }
    }
    export interface SafeERC20FailedOperation {
        type: 'SafeERC20FailedOperation'
        params: {
            token: TAddress
        }
    }
    export interface TooFarValidTo {
        type: 'TooFarValidTo'
        params: {
        }
    }
    export type Error = AlreadyInitialized | AlreadyReservedOrder | CheckpointUnorderedInsertion | ExecutionDelayNotElapsed | ExpiredOrder | InsufficientBurnerGas | InsufficientSlash | InvalidAccountNonce | InvalidBuyAmount | InvalidCaller | InvalidDuration | InvalidInitialization | InvalidNetOrOp | InvalidSellAmount | InvalidTokenIn | InvalidTokenOut | InvalidVault | NoBurner | NotFactory | NotInitializing | NotNetworkMiddleware | NotNetworkOrMiddleware | NotVault | OwnableInvalidOwner | OwnableUnauthorizedAccount | ReentrancyGuardReentrantCall | SafeERC20FailedOperation | TooFarValidTo
}

export class SymbioticAppAdapterImpl extends ContractBase {
    constructor(
        public address: TEth.Address = '0xfe8cFC5Dbb9c77A32a5Eb77C17F0317593f2c133',
        public client: Web3Client = di.resolve(EvmWeb3Client, { platform: 'eth' }),
        public explorer: IBlockchainExplorer = di.resolve(Evmscan, { platform: 'eth' }),
    ) {
        super(address, client, explorer)

        this.storage = new SymbioticAppAdapterImplStorageReader(this.address, this.client, this.explorer);
    }

    Types: TSymbioticAppAdapterImplTypes;

    $meta = {
        "class": "./0xc/eth/SymbioticAppAdapterImpl/SymbioticAppAdapterImpl.ts"
    }

    async $constructor (deployer: TSender, vaultFactory: TAddress, adapterFactory: TAddress, cowSwapSettlement: TAddress, networkMiddlewareService: TAddress): Promise<TxWriter> {
        throw new Error('Not implemented. Typing purpose. Use the ContractDeployer class to deploy the contract');
    }

    // 0xefd7c5b4
    async COW_SWAP_SETTLEMENT (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'COW_SWAP_SETTLEMENT'));
    }

    // 0x7c4a610b
    async COW_SWAP_VAULT_RELAYER (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'COW_SWAP_VAULT_RELAYER'));
    }

    // 0x2dd31000
    async FACTORY (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'FACTORY'));
    }

    // 0x1d3b809a
    async allocatable (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'allocatable'));
    }

    // 0x90ca796b
    async allocate (sender: TSender, amount: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'allocate'), sender, amount);
    }

    // 0x38d52e0f
    async asset (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'asset'));
    }

    // 0x27810b6e
    async burner (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'burner'));
    }

    // 0x75e30d72
    async convert (sender: TSender, tokenIn: TAddress, amountIn: bigint, tokenOut: TAddress, data: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'convert'), sender, tokenIn, amountIn, tokenOut, data);
    }

    // 0x60a6e23a
    async converters (index: bigint): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'converters'), index);
    }

    // 0x6f6c441f
    async deallocate (sender: TSender, amount: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'deallocate'), sender, amount);
    }

    // 0x0fb5a6b4
    async duration (): Promise<number> {
        return this.$read(this.$getAbiItem('function', 'duration'));
    }

    // 0x50c7c021
    async executableAt (nonce: bigint, requestHash: TEth.Hex): Promise<number> {
        return this.$read(this.$getAbiItem('function', 'executableAt'), nonce, requestHash);
    }

    // 0x11f240ac
    async freeAssets (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'freeAssets'));
    }

    // 0x57ec83cc
    async initialize (sender: TSender, initialVersion: number, owner_: TAddress, data: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'initialize'), sender, initialVersion, owner_, data);
    }

    // 0xc0bf3f00
    async invalidateConvert (sender: TSender, orderUid: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'invalidateConvert'), sender, orderUid);
    }

    // 0x6361f99f
    async invalidateConverts (sender: TSender, tokenIn: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'invalidateConverts'), sender, tokenIn);
    }

    // 0x2abe3048
    async migrate (sender: TSender, newVersion: number, data: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'migrate'), sender, newVersion, data);
    }

    // 0xac9650d8
    async multicall (sender: TSender, data: TEth.Hex[]): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'multicall'), sender, data);
    }

    // 0x7ecebe00
    async nonces (owner: TAddress): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'nonces'), owner);
    }

    // 0x570ca735
    async operator (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'operator'));
    }

    // 0x8da5cb5b
    async owner (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'owner'));
    }

    // 0xc6ef72e2
    async prepareConvert (sender: TSender, tokenIn: TAddress, amountIn: bigint, tokenOut: TAddress, data: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'prepareConvert'), sender, tokenIn, amountIn, tokenOut, data);
    }

    // 0x37bdc99b
    async release (sender: TSender, amount: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'release'), sender, amount);
    }

    // 0x715018a6
    async renounceOwnership (sender: TSender, ): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'renounceOwnership'), sender);
    }

    // 0xf79f679d
    async requestDeallocate (sender: TSender, amount: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'requestDeallocate'), sender, amount);
    }

    // 0x21670f22
    async reward (sender: TSender, token: TAddress, amount: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'reward'), sender, token, amount);
    }

    // 0xc43ef599
    async setConverters (sender: TSender, newConverters: TAddress[]): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'setConverters'), sender, newConverters);
    }

    // 0x45bc4d10
    async slash (sender: TSender, amount: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'slash'), sender, amount);
    }

    // 0xe351399a
    async slashable (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'slashable'));
    }

    // 0x3a4b66f1
    async stake (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'stake'));
    }

    // 0x58d3947d
    async stakeAt (timestamp: number): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'stakeAt'), timestamp);
    }

    // 0x9f86fd85
    async staticDelegateCall (sender: TSender, target: TAddress, data: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'staticDelegateCall'), sender, target, data);
    }

    // 0xceebb69a
    async subnetwork (): Promise<TEth.Hex> {
        return this.$read(this.$getAbiItem('function', 'subnetwork'));
    }

    // 0x01e1d114
    async totalAssets (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'totalAssets'));
    }

    // 0xf2fde38b
    async transferOwnership (sender: TSender, newOwner: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'transferOwnership'), sender, newOwner);
    }

    // 0xfbfa77cf
    async vault (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'vault'));
    }

    // 0x54fd4d50
    async version (): Promise<number> {
        return this.$read(this.$getAbiItem('function', 'version'));
    }

    $call () {
        return super.$call() as ISymbioticAppAdapterImplTxCaller;
    }
    $signed (): TOverrideReturns<ISymbioticAppAdapterImplTxCaller, Promise<{ signed: TEth.Hex, error?: Error & { data?: { type: string, params } } }>> {
        return super.$signed() as any;
    }
    $data (): ISymbioticAppAdapterImplTxData {
        return super.$data() as ISymbioticAppAdapterImplTxData;
    }
    $gas (): TOverrideReturns<ISymbioticAppAdapterImplTxCaller, Promise<{ gas?: bigint, price?: bigint, error?: Error & { data?: { type: string, params } } }>> {
        return super.$gas() as any;
    }

    onTransaction <TMethod extends keyof TSymbioticAppAdapterImplTypes['Methods']> (method: TMethod, options: Parameters<ContractBase['$onTransaction']>[0]): SubjectStream<{
        tx: TEth.Tx
        block: TEth.Block<TEth.Hex>
        calldata: {
            method: TMethod
            arguments: TSymbioticAppAdapterImplTypes['Methods'][TMethod]['arguments']
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

    onConvert (fn?: (event: TClientEventsStreamData<TEventArguments<'Convert'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Convert'>>> {
        return this.$onLog('Convert', fn);
    }

    onInitialize (fn?: (event: TClientEventsStreamData<TEventArguments<'Initialize'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Initialize'>>> {
        return this.$onLog('Initialize', fn);
    }

    onInitialized (fn?: (event: TClientEventsStreamData<TEventArguments<'Initialized'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Initialized'>>> {
        return this.$onLog('Initialized', fn);
    }

    onInvalidateConvert (fn?: (event: TClientEventsStreamData<TEventArguments<'InvalidateConvert'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'InvalidateConvert'>>> {
        return this.$onLog('InvalidateConvert', fn);
    }

    onInvalidateConverts (fn?: (event: TClientEventsStreamData<TEventArguments<'InvalidateConverts'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'InvalidateConverts'>>> {
        return this.$onLog('InvalidateConverts', fn);
    }

    onOwnershipTransferred (fn?: (event: TClientEventsStreamData<TEventArguments<'OwnershipTransferred'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'OwnershipTransferred'>>> {
        return this.$onLog('OwnershipTransferred', fn);
    }

    onPrepareConvert (fn?: (event: TClientEventsStreamData<TEventArguments<'PrepareConvert'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'PrepareConvert'>>> {
        return this.$onLog('PrepareConvert', fn);
    }

    onRelease (fn?: (event: TClientEventsStreamData<TEventArguments<'Release'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Release'>>> {
        return this.$onLog('Release', fn);
    }

    onSetConverters (fn?: (event: TClientEventsStreamData<TEventArguments<'SetConverters'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetConverters'>>> {
        return this.$onLog('SetConverters', fn);
    }

    onSetVault (fn?: (event: TClientEventsStreamData<TEventArguments<'SetVault'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetVault'>>> {
        return this.$onLog('SetVault', fn);
    }

    onSlash (fn?: (event: TClientEventsStreamData<TEventArguments<'Slash'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Slash'>>> {
        return this.$onLog('Slash', fn);
    }

    extractLogsConvert (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Convert'>>[] {
        let abi = this.$getAbiItem('event', 'Convert');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Convert'>>[];
    }

    extractLogsInitialize (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Initialize'>>[] {
        let abi = this.$getAbiItem('event', 'Initialize');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Initialize'>>[];
    }

    extractLogsInitialized (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Initialized'>>[] {
        let abi = this.$getAbiItem('event', 'Initialized');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Initialized'>>[];
    }

    extractLogsInvalidateConvert (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'InvalidateConvert'>>[] {
        let abi = this.$getAbiItem('event', 'InvalidateConvert');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'InvalidateConvert'>>[];
    }

    extractLogsInvalidateConverts (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'InvalidateConverts'>>[] {
        let abi = this.$getAbiItem('event', 'InvalidateConverts');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'InvalidateConverts'>>[];
    }

    extractLogsOwnershipTransferred (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'OwnershipTransferred'>>[] {
        let abi = this.$getAbiItem('event', 'OwnershipTransferred');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'OwnershipTransferred'>>[];
    }

    extractLogsPrepareConvert (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'PrepareConvert'>>[] {
        let abi = this.$getAbiItem('event', 'PrepareConvert');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'PrepareConvert'>>[];
    }

    extractLogsRelease (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Release'>>[] {
        let abi = this.$getAbiItem('event', 'Release');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Release'>>[];
    }

    extractLogsSetConverters (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetConverters'>>[] {
        let abi = this.$getAbiItem('event', 'SetConverters');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetConverters'>>[];
    }

    extractLogsSetVault (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetVault'>>[] {
        let abi = this.$getAbiItem('event', 'SetVault');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetVault'>>[];
    }

    extractLogsSlash (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Slash'>>[] {
        let abi = this.$getAbiItem('event', 'Slash');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Slash'>>[];
    }

    async getPastLogsConvert (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'Convert'>>[]> {
        return await this.$getPastLogsParsed('Convert', options) as any;
    }

    async getPastLogsInitialize (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'Initialize'>>[]> {
        return await this.$getPastLogsParsed('Initialize', options) as any;
    }

    async getPastLogsInitialized (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'Initialized'>>[]> {
        return await this.$getPastLogsParsed('Initialized', options) as any;
    }

    async getPastLogsInvalidateConvert (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'InvalidateConvert'>>[]> {
        return await this.$getPastLogsParsed('InvalidateConvert', options) as any;
    }

    async getPastLogsInvalidateConverts (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { tokenIn?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'InvalidateConverts'>>[]> {
        return await this.$getPastLogsParsed('InvalidateConverts', options) as any;
    }

    async getPastLogsOwnershipTransferred (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { previousOwner?: TAddress,newOwner?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'OwnershipTransferred'>>[]> {
        return await this.$getPastLogsParsed('OwnershipTransferred', options) as any;
    }

    async getPastLogsPrepareConvert (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { tokenIn?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'PrepareConvert'>>[]> {
        return await this.$getPastLogsParsed('PrepareConvert', options) as any;
    }

    async getPastLogsRelease (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'Release'>>[]> {
        return await this.$getPastLogsParsed('Release', options) as any;
    }

    async getPastLogsSetConverters (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'SetConverters'>>[]> {
        return await this.$getPastLogsParsed('SetConverters', options) as any;
    }

    async getPastLogsSetVault (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { vault?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'SetVault'>>[]> {
        return await this.$getPastLogsParsed('SetVault', options) as any;
    }

    async getPastLogsSlash (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'Slash'>>[]> {
        return await this.$getPastLogsParsed('Slash', options) as any;
    }

    abi: TAbiItem[] = [{"inputs":[{"internalType":"address","name":"vaultFactory","type":"address"},{"internalType":"address","name":"adapterFactory","type":"address"},{"internalType":"address","name":"cowSwapSettlement","type":"address"},{"internalType":"address","name":"networkMiddlewareService","type":"address"}],"stateMutability":"nonpayable","type":"constructor"},{"inputs":[],"name":"AlreadyInitialized","type":"error"},{"inputs":[],"name":"AlreadyReservedOrder","type":"error"},{"inputs":[],"name":"CheckpointUnorderedInsertion","type":"error"},{"inputs":[],"name":"ExecutionDelayNotElapsed","type":"error"},{"inputs":[],"name":"ExpiredOrder","type":"error"},{"inputs":[],"name":"InsufficientBurnerGas","type":"error"},{"inputs":[],"name":"InsufficientSlash","type":"error"},{"inputs":[{"internalType":"address","name":"account","type":"address"},{"internalType":"uint256","name":"currentNonce","type":"uint256"}],"name":"InvalidAccountNonce","type":"error"},{"inputs":[],"name":"InvalidBuyAmount","type":"error"},{"inputs":[],"name":"InvalidCaller","type":"error"},{"inputs":[],"name":"InvalidDuration","type":"error"},{"inputs":[],"name":"InvalidInitialization","type":"error"},{"inputs":[],"name":"InvalidNetOrOp","type":"error"},{"inputs":[],"name":"InvalidSellAmount","type":"error"},{"inputs":[],"name":"InvalidTokenIn","type":"error"},{"inputs":[],"name":"InvalidTokenOut","type":"error"},{"inputs":[],"name":"InvalidVault","type":"error"},{"inputs":[],"name":"NoBurner","type":"error"},{"inputs":[],"name":"NotFactory","type":"error"},{"inputs":[],"name":"NotInitializing","type":"error"},{"inputs":[],"name":"NotNetworkMiddleware","type":"error"},{"inputs":[],"name":"NotNetworkOrMiddleware","type":"error"},{"inputs":[],"name":"NotVault","type":"error"},{"inputs":[{"internalType":"address","name":"owner","type":"address"}],"name":"OwnableInvalidOwner","type":"error"},{"inputs":[{"internalType":"address","name":"account","type":"address"}],"name":"OwnableUnauthorizedAccount","type":"error"},{"inputs":[],"name":"ReentrancyGuardReentrantCall","type":"error"},{"inputs":[{"internalType":"address","name":"token","type":"address"}],"name":"SafeERC20FailedOperation","type":"error"},{"inputs":[],"name":"TooFarValidTo","type":"error"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"bytes","name":"orderUid","type":"bytes"},{"indexed":true,"internalType":"address","name":"tokenIn","type":"address"},{"indexed":false,"internalType":"uint256","name":"amountIn","type":"uint256"},{"indexed":true,"internalType":"address","name":"tokenOut","type":"address"},{"components":[{"internalType":"uint256","name":"buyAmount","type":"uint256"},{"internalType":"uint32","name":"validTo","type":"uint32"},{"internalType":"bytes32","name":"appData","type":"bytes32"}],"indexed":false,"internalType":"struct ICoWSwapConverter.OrderParams","name":"params","type":"tuple"}],"name":"Convert","type":"event"},{"anonymous":false,"inputs":[{"components":[{"internalType":"address","name":"burner","type":"address"},{"internalType":"uint48","name":"duration","type":"uint48"},{"internalType":"address","name":"operator","type":"address"},{"internalType":"bytes32","name":"subnetwork","type":"bytes32"},{"internalType":"address[]","name":"converters","type":"address[]"}],"indexed":false,"internalType":"struct IAppAdapter.InitParams","name":"params","type":"tuple"}],"name":"Initialize","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint64","name":"version","type":"uint64"}],"name":"Initialized","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"bytes","name":"orderUid","type":"bytes"}],"name":"InvalidateConvert","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"tokenIn","type":"address"}],"name":"InvalidateConverts","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"previousOwner","type":"address"},{"indexed":true,"internalType":"address","name":"newOwner","type":"address"}],"name":"OwnershipTransferred","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"tokenIn","type":"address"},{"indexed":false,"internalType":"uint256","name":"amountIn","type":"uint256"},{"indexed":true,"internalType":"address","name":"tokenOut","type":"address"},{"indexed":false,"internalType":"bytes","name":"data","type":"bytes"}],"name":"PrepareConvert","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint256","name":"amount","type":"uint256"}],"name":"Release","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"address[]","name":"converters","type":"address[]"}],"name":"SetConverters","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"vault","type":"address"}],"name":"SetVault","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint256","name":"amount","type":"uint256"}],"name":"Slash","type":"event"},{"inputs":[],"name":"COW_SWAP_SETTLEMENT","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"COW_SWAP_VAULT_RELAYER","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"FACTORY","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"allocatable","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"allocate","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"asset","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"burner","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"tokenIn","type":"address"},{"internalType":"uint256","name":"amountIn","type":"uint256"},{"internalType":"address","name":"tokenOut","type":"address"},{"internalType":"bytes","name":"data","type":"bytes"}],"name":"convert","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"index","type":"uint256"}],"name":"converters","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"deallocate","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"duration","outputs":[{"internalType":"uint48","name":"","type":"uint48"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"nonce","type":"uint256"},{"internalType":"bytes32","name":"requestHash","type":"bytes32"}],"name":"executableAt","outputs":[{"internalType":"uint48","name":"","type":"uint48"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"freeAssets","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint64","name":"initialVersion","type":"uint64"},{"internalType":"address","name":"owner_","type":"address"},{"internalType":"bytes","name":"data","type":"bytes"}],"name":"initialize","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes","name":"orderUid","type":"bytes"}],"name":"invalidateConvert","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"tokenIn","type":"address"}],"name":"invalidateConverts","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint64","name":"newVersion","type":"uint64"},{"internalType":"bytes","name":"data","type":"bytes"}],"name":"migrate","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes[]","name":"data","type":"bytes[]"}],"name":"multicall","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"owner","type":"address"}],"name":"nonces","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"operator","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"owner","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"tokenIn","type":"address"},{"internalType":"uint256","name":"amountIn","type":"uint256"},{"internalType":"address","name":"tokenOut","type":"address"},{"internalType":"bytes","name":"data","type":"bytes"}],"name":"prepareConvert","outputs":[{"internalType":"bytes32","name":"requestHash","type":"bytes32"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"release","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"renounceOwnership","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"requestDeallocate","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"token","type":"address"},{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"reward","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address[]","name":"newConverters","type":"address[]"}],"name":"setConverters","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"slash","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"slashable","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"stake","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint48","name":"timestamp","type":"uint48"}],"name":"stakeAt","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"target","type":"address"},{"internalType":"bytes","name":"data","type":"bytes"}],"name":"staticDelegateCall","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"subnetwork","outputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"totalAssets","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"newOwner","type":"address"}],"name":"transferOwnership","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"vault","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"version","outputs":[{"internalType":"uint64","name":"","type":"uint64"}],"stateMutability":"view","type":"function"}]

    declare storage: SymbioticAppAdapterImplStorageReader
}

type TSender = TAccount & {
    value?: string | number | bigint
}

type TEventLogOptions<TParams> = {
    fromBlock?: number | Date
    toBlock?: number | Date
    params?: TParams
}

export type TSymbioticAppAdapterImplTypes = {
    Events: {
        Convert: {
            outputParams: { orderUid: TEth.Hex, tokenIn: TAddress, amountIn: bigint, tokenOut: TAddress, params: { buyAmount: bigint, validTo: number, appData: TEth.Hex } },
            outputArgs:   [ orderUid: TEth.Hex, tokenIn: TAddress, amountIn: bigint, tokenOut: TAddress, params: { buyAmount: bigint, validTo: number, appData: TEth.Hex } ],
        }
        Initialize: {
            outputParams: { params: { burner: TAddress, duration: number, operator: TAddress, subnetwork: TEth.Hex, converters: TAddress[] } },
            outputArgs:   [ params: { burner: TAddress, duration: number, operator: TAddress, subnetwork: TEth.Hex, converters: TAddress[] } ],
        }
        Initialized: {
            outputParams: { version: number },
            outputArgs:   [ version: number ],
        }
        InvalidateConvert: {
            outputParams: { orderUid: TEth.Hex },
            outputArgs:   [ orderUid: TEth.Hex ],
        }
        InvalidateConverts: {
            outputParams: { tokenIn: TAddress },
            outputArgs:   [ tokenIn: TAddress ],
        }
        OwnershipTransferred: {
            outputParams: { previousOwner: TAddress, newOwner: TAddress },
            outputArgs:   [ previousOwner: TAddress, newOwner: TAddress ],
        }
        PrepareConvert: {
            outputParams: { tokenIn: TAddress, amountIn: bigint, tokenOut: TAddress, data: TEth.Hex },
            outputArgs:   [ tokenIn: TAddress, amountIn: bigint, tokenOut: TAddress, data: TEth.Hex ],
        }
        Release: {
            outputParams: { amount: bigint },
            outputArgs:   [ amount: bigint ],
        }
        SetConverters: {
            outputParams: { converters: TAddress[] },
            outputArgs:   [ converters: TAddress[] ],
        }
        SetVault: {
            outputParams: { vault: TAddress },
            outputArgs:   [ vault: TAddress ],
        }
        Slash: {
            outputParams: { amount: bigint },
            outputArgs:   [ amount: bigint ],
        }
    },
    Methods: {
        COW_SWAP_SETTLEMENT: {
          method: "COW_SWAP_SETTLEMENT"
          arguments: [  ]
        }
        COW_SWAP_VAULT_RELAYER: {
          method: "COW_SWAP_VAULT_RELAYER"
          arguments: [  ]
        }
        FACTORY: {
          method: "FACTORY"
          arguments: [  ]
        }
        allocatable: {
          method: "allocatable"
          arguments: [  ]
        }
        allocate: {
          method: "allocate"
          arguments: [ amount: bigint ]
        }
        asset: {
          method: "asset"
          arguments: [  ]
        }
        burner: {
          method: "burner"
          arguments: [  ]
        }
        convert: {
          method: "convert"
          arguments: [ tokenIn: TAddress, amountIn: bigint, tokenOut: TAddress, data: TEth.Hex ]
        }
        converters: {
          method: "converters"
          arguments: [ index: bigint ]
        }
        deallocate: {
          method: "deallocate"
          arguments: [ amount: bigint ]
        }
        duration: {
          method: "duration"
          arguments: [  ]
        }
        executableAt: {
          method: "executableAt"
          arguments: [ nonce: bigint, requestHash: TEth.Hex ]
        }
        freeAssets: {
          method: "freeAssets"
          arguments: [  ]
        }
        initialize: {
          method: "initialize"
          arguments: [ initialVersion: number, owner_: TAddress, data: TEth.Hex ]
        }
        invalidateConvert: {
          method: "invalidateConvert"
          arguments: [ orderUid: TEth.Hex ]
        }
        invalidateConverts: {
          method: "invalidateConverts"
          arguments: [ tokenIn: TAddress ]
        }
        migrate: {
          method: "migrate"
          arguments: [ newVersion: number, data: TEth.Hex ]
        }
        multicall: {
          method: "multicall"
          arguments: [ data: TEth.Hex[] ]
        }
        nonces: {
          method: "nonces"
          arguments: [ owner: TAddress ]
        }
        operator: {
          method: "operator"
          arguments: [  ]
        }
        owner: {
          method: "owner"
          arguments: [  ]
        }
        prepareConvert: {
          method: "prepareConvert"
          arguments: [ tokenIn: TAddress, amountIn: bigint, tokenOut: TAddress, data: TEth.Hex ]
        }
        release: {
          method: "release"
          arguments: [ amount: bigint ]
        }
        renounceOwnership: {
          method: "renounceOwnership"
          arguments: [  ]
        }
        requestDeallocate: {
          method: "requestDeallocate"
          arguments: [ amount: bigint ]
        }
        reward: {
          method: "reward"
          arguments: [ token: TAddress, amount: bigint ]
        }
        setConverters: {
          method: "setConverters"
          arguments: [ newConverters: TAddress[] ]
        }
        slash: {
          method: "slash"
          arguments: [ amount: bigint ]
        }
        slashable: {
          method: "slashable"
          arguments: [  ]
        }
        stake: {
          method: "stake"
          arguments: [  ]
        }
        stakeAt: {
          method: "stakeAt"
          arguments: [ timestamp: number ]
        }
        staticDelegateCall: {
          method: "staticDelegateCall"
          arguments: [ target: TAddress, data: TEth.Hex ]
        }
        subnetwork: {
          method: "subnetwork"
          arguments: [  ]
        }
        totalAssets: {
          method: "totalAssets"
          arguments: [  ]
        }
        transferOwnership: {
          method: "transferOwnership"
          arguments: [ newOwner: TAddress ]
        }
        vault: {
          method: "vault"
          arguments: [  ]
        }
        version: {
          method: "version"
          arguments: [  ]
        }
    }
}



class SymbioticAppAdapterImplStorageReader extends ContractStorageReaderBase {
    constructor(
        public address: TAddress,
        public client: Web3Client,
        public explorer: IBlockchainExplorer,
    ) {
        super(address, client, explorer);

        this.$createHandler(this.$slots);
    }

    async __gap$(): Promise<bigint[10]> {
        return this.$storage.get(['__gap$', ]);
    }

    async vault(): Promise<TAddress> {
        return this.$storage.get(['vault', ]);
    }

    async __gap(): Promise<bigint[50]> {
        return this.$storage.get(['__gap', ]);
    }

    async burner(): Promise<TAddress> {
        return this.$storage.get(['burner', ]);
    }

    async duration(): Promise<number> {
        return this.$storage.get(['duration', ]);
    }

    async operator(): Promise<TAddress> {
        return this.$storage.get(['operator', ]);
    }

    async subnetwork(): Promise<TEth.Hex> {
        return this.$storage.get(['subnetwork', ]);
    }

    async asset(): Promise<TAddress> {
        return this.$storage.get(['asset', ]);
    }

    async _stakes(): Promise<{ initialStake: bigint, debt: { _checkpoints: { _key: bigint, _value: bigint }[] }, slashed: { _checkpoints: { _key: bigint, _value: bigint }[] } }[]> {
        return this.$storage.get(['_stakes', ]);
    }

    async _stakePos(): Promise<{ _checkpoints: { _key: number, _value: bigint }[] }> {
        return this.$storage.get(['_stakePos', ]);
    }

    $slots = [
    {
        "slot": 0,
        "position": 0,
        "name": "__gap$",
        "size": 2560,
        "type": "uint256[10]"
    },
    {
        "slot": 10,
        "position": 0,
        "name": "vault",
        "size": 160,
        "type": "address"
    },
    {
        "slot": 11,
        "position": 0,
        "name": "__gap",
        "size": 12800,
        "type": "uint256[50]"
    },
    {
        "slot": 61,
        "position": 0,
        "name": "burner",
        "size": 160,
        "type": "address"
    },
    {
        "slot": 61,
        "position": 160,
        "name": "duration",
        "size": 48,
        "type": "uint48"
    },
    {
        "slot": 62,
        "position": 0,
        "name": "operator",
        "size": 160,
        "type": "address"
    },
    {
        "slot": 63,
        "position": 0,
        "name": "subnetwork",
        "size": 256,
        "type": "bytes32"
    },
    {
        "slot": 64,
        "position": 0,
        "name": "asset",
        "size": 160,
        "type": "address"
    },
    {
        "slot": 65,
        "position": 0,
        "name": "_stakes",
        "size": null,
        "type": "(uint256 initialStake, ((uint256 _key, uint256 _value)[] _checkpoints) debt, ((uint256 _key, uint256 _value)[] _checkpoints) slashed)[]"
    },
    {
        "slot": 66,
        "position": 0,
        "name": "_stakePos",
        "size": 256,
        "type": "((uint48 _key, uint208 _value)[] _checkpoints)"
    }
]

}


interface ISymbioticAppAdapterImplTxCaller {
    allocate (sender: TSender, amount: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    convert (sender: TSender, tokenIn: TAddress, amountIn: bigint, tokenOut: TAddress, data: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    deallocate (sender: TSender, amount: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    initialize (sender: TSender, initialVersion: number, owner_: TAddress, data: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    invalidateConvert (sender: TSender, orderUid: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    invalidateConverts (sender: TSender, tokenIn: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    migrate (sender: TSender, newVersion: number, data: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    multicall (sender: TSender, data: TEth.Hex[]): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    prepareConvert (sender: TSender, tokenIn: TAddress, amountIn: bigint, tokenOut: TAddress, data: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    release (sender: TSender, amount: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    renounceOwnership (sender: TSender, ): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    requestDeallocate (sender: TSender, amount: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    reward (sender: TSender, token: TAddress, amount: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    setConverters (sender: TSender, newConverters: TAddress[]): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    slash (sender: TSender, amount: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    staticDelegateCall (sender: TSender, target: TAddress, data: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    transferOwnership (sender: TSender, newOwner: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
}


interface ISymbioticAppAdapterImplTxData {
    allocate (sender: TSender, amount: bigint): Promise<TEth.TxLike>
    convert (sender: TSender, tokenIn: TAddress, amountIn: bigint, tokenOut: TAddress, data: TEth.Hex): Promise<TEth.TxLike>
    deallocate (sender: TSender, amount: bigint): Promise<TEth.TxLike>
    initialize (sender: TSender, initialVersion: number, owner_: TAddress, data: TEth.Hex): Promise<TEth.TxLike>
    invalidateConvert (sender: TSender, orderUid: TEth.Hex): Promise<TEth.TxLike>
    invalidateConverts (sender: TSender, tokenIn: TAddress): Promise<TEth.TxLike>
    migrate (sender: TSender, newVersion: number, data: TEth.Hex): Promise<TEth.TxLike>
    multicall (sender: TSender, data: TEth.Hex[]): Promise<TEth.TxLike>
    prepareConvert (sender: TSender, tokenIn: TAddress, amountIn: bigint, tokenOut: TAddress, data: TEth.Hex): Promise<TEth.TxLike>
    release (sender: TSender, amount: bigint): Promise<TEth.TxLike>
    renounceOwnership (sender: TSender, ): Promise<TEth.TxLike>
    requestDeallocate (sender: TSender, amount: bigint): Promise<TEth.TxLike>
    reward (sender: TSender, token: TAddress, amount: bigint): Promise<TEth.TxLike>
    setConverters (sender: TSender, newConverters: TAddress[]): Promise<TEth.TxLike>
    slash (sender: TSender, amount: bigint): Promise<TEth.TxLike>
    staticDelegateCall (sender: TSender, target: TAddress, data: TEth.Hex): Promise<TEth.TxLike>
    transferOwnership (sender: TSender, newOwner: TAddress): Promise<TEth.TxLike>
}


type TEvents = TSymbioticAppAdapterImplTypes['Events'];
type TEventParams<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputParams']>;
type TEventArguments<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputArgs']>;
