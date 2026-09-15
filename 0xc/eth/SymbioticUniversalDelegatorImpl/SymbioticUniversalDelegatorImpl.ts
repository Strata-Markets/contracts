/**
 *  AUTO-Generated Class: 2026-09-22 00:25
 *  Implementation: https://etherscan.io/address/0xa74F3107c29D514084bA37BC0E7650cc55fc39E4#code
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

export namespace SymbioticUniversalDelegatorImplErrors {
    export interface AccessControlBadConfirmation {
        type: 'AccessControlBadConfirmation'
        params: {
        }
    }
    export interface AccessControlUnauthorizedAccount {
        type: 'AccessControlUnauthorizedAccount'
        params: {
            account: TAddress
            neededRole: TEth.Hex
        }
    }
    export interface AdapterHasAssets {
        type: 'AdapterHasAssets'
        params: {
        }
    }
    export interface AlreadyAdded {
        type: 'AlreadyAdded'
        params: {
        }
    }
    export interface AlreadyInitialized {
        type: 'AlreadyInitialized'
        params: {
        }
    }
    export interface InvalidAdapter {
        type: 'InvalidAdapter'
        params: {
        }
    }
    export interface InvalidInitialization {
        type: 'InvalidInitialization'
        params: {
        }
    }
    export interface InvalidRole {
        type: 'InvalidRole'
        params: {
        }
    }
    export interface InvalidShareLimit {
        type: 'InvalidShareLimit'
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
    export interface NotSelf {
        type: 'NotSelf'
        params: {
        }
    }
    export interface NotVault {
        type: 'NotVault'
        params: {
        }
    }
    export interface OldVault {
        type: 'OldVault'
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
    export interface TooManyAdapters {
        type: 'TooManyAdapters'
        params: {
        }
    }
    export type Error = AccessControlBadConfirmation | AccessControlUnauthorizedAccount | AdapterHasAssets | AlreadyAdded | AlreadyInitialized | InvalidAdapter | InvalidInitialization | InvalidRole | InvalidShareLimit | NotFactory | NotInitializing | NotSelf | NotVault | OldVault | OwnableInvalidOwner | OwnableUnauthorizedAccount | ReentrancyGuardReentrantCall | TooManyAdapters
}

export class SymbioticUniversalDelegatorImpl extends ContractBase {
    constructor(
        public address: TEth.Address = '0xa74F3107c29D514084bA37BC0E7650cc55fc39E4',
        public client: Web3Client = di.resolve(EvmWeb3Client, { platform: 'eth' }),
        public explorer: IBlockchainExplorer = di.resolve(Evmscan, { platform: 'eth' }),
    ) {
        super(address, client, explorer)

        this.storage = new SymbioticUniversalDelegatorImplStorageReader(this.address, this.client, this.explorer);
    }

    Types: TSymbioticUniversalDelegatorImplTypes;

    $meta = {
        "class": "./0xc/eth/SymbioticUniversalDelegatorImpl/SymbioticUniversalDelegatorImpl.ts"
    }

    async $constructor (deployer: TSender, adapterRegistry: TAddress, delegatorFactory: TAddress): Promise<TxWriter> {
        throw new Error('Not implemented. Typing purpose. Use the ContractDeployer class to deploy the contract');
    }

    // 0xa217fddf
    async DEFAULT_ADMIN_ROLE (): Promise<TEth.Hex> {
        return this.$read(this.$getAbiItem('function', 'DEFAULT_ADMIN_ROLE'));
    }

    // 0x2dd31000
    async FACTORY (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'FACTORY'));
    }

    // 0x4b312205
    async __deallocateAll (sender: TSender, ): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', '__deallocateAll'), sender);
    }

    // 0x38539bb7
    async absoluteLimitOf (adapter: TAddress): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'absoluteLimitOf'), adapter);
    }

    // 0xa4378cf0
    async adapterToIndex (adapter: TAddress): Promise<number> {
        return this.$read(this.$getAbiItem('function', 'adapterToIndex'), adapter);
    }

    // 0x4ef501ac
    async adapters (input0: bigint): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'adapters'), input0);
    }

    // 0x867fd0dd
    async adaptersWithPending (input0: bigint): Promise<number> {
        return this.$read(this.$getAbiItem('function', 'adaptersWithPending'), input0);
    }

    // 0x60d54d41
    async addAdapter (sender: TSender, adapter: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'addAdapter'), sender, adapter);
    }

    // 0xb78b52df
    async allocate (sender: TSender, adapter: TAddress, assets: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'allocate'), sender, adapter, assets);
    }

    // 0xb362a86c
    async allocateAll (sender: TSender, assets: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'allocateAll'), sender, assets);
    }

    // 0x2f62f70c
    async allocateExact (sender: TSender, adapter: TAddress, assets: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'allocateExact'), sender, adapter, assets);
    }

    // 0x13d16101
    async autoAllocateAdapters (input0: bigint): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'autoAllocateAdapters'), input0);
    }

    // 0x2a86c173
    async deallocatable (sender: TSender, ): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'deallocatable'), sender);
    }

    // 0x59db9eb0
    async deallocate (sender: TSender, adapter: TAddress, assets: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'deallocate'), sender, adapter, assets);
    }

    // 0x0a391711
    async deallocateAll (sender: TSender, assets: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'deallocateAll'), sender, assets);
    }

    // 0x535d8b5b
    async deallocateExact (sender: TSender, assets: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'deallocateExact'), sender, assets);
    }

    // 0x4036df80
    async decreaseLimits (sender: TSender, assets: bigint, share: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'decreaseLimits'), sender, assets, share);
    }

    // 0xd35ba3c9
    async forceDeallocate (sender: TSender, adapter: TAddress, assets: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'forceDeallocate'), sender, adapter, assets);
    }

    // 0x90700304
    async getAdaptersLength (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'getAdaptersLength'));
    }

    // 0x248a9ca3
    async getRoleAdmin (role: TEth.Hex): Promise<TEth.Hex> {
        return this.$read(this.$getAbiItem('function', 'getRoleAdmin'), role);
    }

    // 0x2f2ff15d
    async grantRole (sender: TSender, role: TEth.Hex, account: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'grantRole'), sender, role, account);
    }

    // 0x91d14854
    async hasRole (role: TEth.Hex, account: TAddress): Promise<boolean> {
        return this.$read(this.$getAbiItem('function', 'hasRole'), role, account);
    }

    // 0x3cc4eb38
    async indexToAdapter (index: number): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'indexToAdapter'), index);
    }

    // 0x57ec83cc
    async initialize (sender: TSender, initialVersion: number, owner_: TAddress, data: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'initialize'), sender, initialVersion, owner_, data);
    }

    // 0x546a2ca4
    async limitOf (adapter: TAddress): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'limitOf'), adapter);
    }

    // 0x2abe3048
    async migrate (sender: TSender, newVersion: number, data: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'migrate'), sender, newVersion, data);
    }

    // 0xac9650d8
    async multicall (sender: TSender, data: TEth.Hex[]): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'multicall'), sender, data);
    }

    // 0x12c93f59
    async onDeposit (sender: TSender, ): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'onDeposit'), sender);
    }

    // 0x4b6d39f5
    async onWithdraw (sender: TSender, assets: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'onWithdraw'), sender, assets);
    }

    // 0x8da5cb5b
    async owner (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'owner'));
    }

    // 0x585cd34b
    async removeAdapter (sender: TSender, adapter: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'removeAdapter'), sender, adapter);
    }

    // 0x715018a6
    async renounceOwnership (sender: TSender, ): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'renounceOwnership'), sender);
    }

    // 0x36568abe
    async renounceRole (sender: TSender, role: TEth.Hex, callerConfirmation: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'renounceRole'), sender, role, callerConfirmation);
    }

    // 0xd547741f
    async revokeRole (sender: TSender, role: TEth.Hex, account: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'revokeRole'), sender, role, account);
    }

    // 0xc4e68d93
    async setAutoAllocateAdapters (sender: TSender, newAutoAllocateAdapters: TAddress[]): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'setAutoAllocateAdapters'), sender, newAutoAllocateAdapters);
    }

    // 0xa08d5654
    async setLimits (sender: TSender, adapter: TAddress, assets: bigint, share: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'setLimits'), sender, adapter, assets, share);
    }

    // 0x701b3624
    async shareLimitOf (adapter: TAddress): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'shareLimitOf'), adapter);
    }

    // 0x9f86fd85
    async staticDelegateCall (sender: TSender, target: TAddress, data: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'staticDelegateCall'), sender, target, data);
    }

    // 0x01ffc9a7
    async supportsInterface (interfaceId: TEth.Hex): Promise<boolean> {
        return this.$read(this.$getAbiItem('function', 'supportsInterface'), interfaceId);
    }

    // 0x8ef5792a
    async swapAdapters (sender: TSender, adapter1: TAddress, adapter2: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'swapAdapters'), sender, adapter1, adapter2);
    }

    // 0xde54984c
    async sweepPending (sender: TSender, ): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'sweepPending'), sender);
    }

    // 0xa1b39b7f
    async totalAdapters (): Promise<number> {
        return this.$read(this.$getAbiItem('function', 'totalAdapters'));
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
        return super.$call() as ISymbioticUniversalDelegatorImplTxCaller;
    }
    $signed (): TOverrideReturns<ISymbioticUniversalDelegatorImplTxCaller, Promise<{ signed: TEth.Hex, error?: Error & { data?: { type: string, params } } }>> {
        return super.$signed() as any;
    }
    $data (): ISymbioticUniversalDelegatorImplTxData {
        return super.$data() as ISymbioticUniversalDelegatorImplTxData;
    }
    $gas (): TOverrideReturns<ISymbioticUniversalDelegatorImplTxCaller, Promise<{ gas?: bigint, price?: bigint, error?: Error & { data?: { type: string, params } } }>> {
        return super.$gas() as any;
    }

    onTransaction <TMethod extends keyof TSymbioticUniversalDelegatorImplTypes['Methods']> (method: TMethod, options: Parameters<ContractBase['$onTransaction']>[0]): SubjectStream<{
        tx: TEth.Tx
        block: TEth.Block<TEth.Hex>
        calldata: {
            method: TMethod
            arguments: TSymbioticUniversalDelegatorImplTypes['Methods'][TMethod]['arguments']
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

    onAddAdapter (fn?: (event: TClientEventsStreamData<TEventArguments<'AddAdapter'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'AddAdapter'>>> {
        return this.$onLog('AddAdapter', fn);
    }

    onAllocate (fn?: (event: TClientEventsStreamData<TEventArguments<'Allocate'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Allocate'>>> {
        return this.$onLog('Allocate', fn);
    }

    onDeallocate (fn?: (event: TClientEventsStreamData<TEventArguments<'Deallocate'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Deallocate'>>> {
        return this.$onLog('Deallocate', fn);
    }

    onDecreaseLimits (fn?: (event: TClientEventsStreamData<TEventArguments<'DecreaseLimits'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'DecreaseLimits'>>> {
        return this.$onLog('DecreaseLimits', fn);
    }

    onInitialize (fn?: (event: TClientEventsStreamData<TEventArguments<'Initialize'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Initialize'>>> {
        return this.$onLog('Initialize', fn);
    }

    onInitialized (fn?: (event: TClientEventsStreamData<TEventArguments<'Initialized'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Initialized'>>> {
        return this.$onLog('Initialized', fn);
    }

    onOwnershipTransferred (fn?: (event: TClientEventsStreamData<TEventArguments<'OwnershipTransferred'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'OwnershipTransferred'>>> {
        return this.$onLog('OwnershipTransferred', fn);
    }

    onRemoveAdapter (fn?: (event: TClientEventsStreamData<TEventArguments<'RemoveAdapter'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'RemoveAdapter'>>> {
        return this.$onLog('RemoveAdapter', fn);
    }

    onRequestDeallocate (fn?: (event: TClientEventsStreamData<TEventArguments<'RequestDeallocate'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'RequestDeallocate'>>> {
        return this.$onLog('RequestDeallocate', fn);
    }

    onRoleAdminChanged (fn?: (event: TClientEventsStreamData<TEventArguments<'RoleAdminChanged'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'RoleAdminChanged'>>> {
        return this.$onLog('RoleAdminChanged', fn);
    }

    onRoleGranted (fn?: (event: TClientEventsStreamData<TEventArguments<'RoleGranted'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'RoleGranted'>>> {
        return this.$onLog('RoleGranted', fn);
    }

    onRoleRevoked (fn?: (event: TClientEventsStreamData<TEventArguments<'RoleRevoked'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'RoleRevoked'>>> {
        return this.$onLog('RoleRevoked', fn);
    }

    onSetAutoAllocateAdapters (fn?: (event: TClientEventsStreamData<TEventArguments<'SetAutoAllocateAdapters'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetAutoAllocateAdapters'>>> {
        return this.$onLog('SetAutoAllocateAdapters', fn);
    }

    onSetLimits (fn?: (event: TClientEventsStreamData<TEventArguments<'SetLimits'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetLimits'>>> {
        return this.$onLog('SetLimits', fn);
    }

    onSwapAdapters (fn?: (event: TClientEventsStreamData<TEventArguments<'SwapAdapters'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SwapAdapters'>>> {
        return this.$onLog('SwapAdapters', fn);
    }

    extractLogsAddAdapter (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'AddAdapter'>>[] {
        let abi = this.$getAbiItem('event', 'AddAdapter');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'AddAdapter'>>[];
    }

    extractLogsAllocate (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Allocate'>>[] {
        let abi = this.$getAbiItem('event', 'Allocate');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Allocate'>>[];
    }

    extractLogsDeallocate (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Deallocate'>>[] {
        let abi = this.$getAbiItem('event', 'Deallocate');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Deallocate'>>[];
    }

    extractLogsDecreaseLimits (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'DecreaseLimits'>>[] {
        let abi = this.$getAbiItem('event', 'DecreaseLimits');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'DecreaseLimits'>>[];
    }

    extractLogsInitialize (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Initialize'>>[] {
        let abi = this.$getAbiItem('event', 'Initialize');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Initialize'>>[];
    }

    extractLogsInitialized (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Initialized'>>[] {
        let abi = this.$getAbiItem('event', 'Initialized');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Initialized'>>[];
    }

    extractLogsOwnershipTransferred (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'OwnershipTransferred'>>[] {
        let abi = this.$getAbiItem('event', 'OwnershipTransferred');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'OwnershipTransferred'>>[];
    }

    extractLogsRemoveAdapter (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'RemoveAdapter'>>[] {
        let abi = this.$getAbiItem('event', 'RemoveAdapter');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'RemoveAdapter'>>[];
    }

    extractLogsRequestDeallocate (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'RequestDeallocate'>>[] {
        let abi = this.$getAbiItem('event', 'RequestDeallocate');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'RequestDeallocate'>>[];
    }

    extractLogsRoleAdminChanged (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'RoleAdminChanged'>>[] {
        let abi = this.$getAbiItem('event', 'RoleAdminChanged');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'RoleAdminChanged'>>[];
    }

    extractLogsRoleGranted (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'RoleGranted'>>[] {
        let abi = this.$getAbiItem('event', 'RoleGranted');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'RoleGranted'>>[];
    }

    extractLogsRoleRevoked (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'RoleRevoked'>>[] {
        let abi = this.$getAbiItem('event', 'RoleRevoked');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'RoleRevoked'>>[];
    }

    extractLogsSetAutoAllocateAdapters (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetAutoAllocateAdapters'>>[] {
        let abi = this.$getAbiItem('event', 'SetAutoAllocateAdapters');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetAutoAllocateAdapters'>>[];
    }

    extractLogsSetLimits (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetLimits'>>[] {
        let abi = this.$getAbiItem('event', 'SetLimits');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetLimits'>>[];
    }

    extractLogsSwapAdapters (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SwapAdapters'>>[] {
        let abi = this.$getAbiItem('event', 'SwapAdapters');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SwapAdapters'>>[];
    }

    async getPastLogsAddAdapter (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { adapter?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'AddAdapter'>>[]> {
        return await this.$getPastLogsParsed('AddAdapter', options) as any;
    }

    async getPastLogsAllocate (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { adapter?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'Allocate'>>[]> {
        return await this.$getPastLogsParsed('Allocate', options) as any;
    }

    async getPastLogsDeallocate (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { adapter?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'Deallocate'>>[]> {
        return await this.$getPastLogsParsed('Deallocate', options) as any;
    }

    async getPastLogsDecreaseLimits (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'DecreaseLimits'>>[]> {
        return await this.$getPastLogsParsed('DecreaseLimits', options) as any;
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

    async getPastLogsOwnershipTransferred (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { previousOwner?: TAddress,newOwner?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'OwnershipTransferred'>>[]> {
        return await this.$getPastLogsParsed('OwnershipTransferred', options) as any;
    }

    async getPastLogsRemoveAdapter (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { adapter?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'RemoveAdapter'>>[]> {
        return await this.$getPastLogsParsed('RemoveAdapter', options) as any;
    }

    async getPastLogsRequestDeallocate (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { adapter?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'RequestDeallocate'>>[]> {
        return await this.$getPastLogsParsed('RequestDeallocate', options) as any;
    }

    async getPastLogsRoleAdminChanged (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { role?: TEth.Hex,previousAdminRole?: TEth.Hex,newAdminRole?: TEth.Hex }
    }): Promise<ITxLogItem<TEventParams<'RoleAdminChanged'>>[]> {
        return await this.$getPastLogsParsed('RoleAdminChanged', options) as any;
    }

    async getPastLogsRoleGranted (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { role?: TEth.Hex,account?: TAddress,sender?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'RoleGranted'>>[]> {
        return await this.$getPastLogsParsed('RoleGranted', options) as any;
    }

    async getPastLogsRoleRevoked (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { role?: TEth.Hex,account?: TAddress,sender?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'RoleRevoked'>>[]> {
        return await this.$getPastLogsParsed('RoleRevoked', options) as any;
    }

    async getPastLogsSetAutoAllocateAdapters (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'SetAutoAllocateAdapters'>>[]> {
        return await this.$getPastLogsParsed('SetAutoAllocateAdapters', options) as any;
    }

    async getPastLogsSetLimits (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { adapter?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'SetLimits'>>[]> {
        return await this.$getPastLogsParsed('SetLimits', options) as any;
    }

    async getPastLogsSwapAdapters (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { adapter1?: TAddress,adapter2?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'SwapAdapters'>>[]> {
        return await this.$getPastLogsParsed('SwapAdapters', options) as any;
    }

    abi: TAbiItem[] = [{"inputs":[{"internalType":"address","name":"adapterRegistry","type":"address"},{"internalType":"address","name":"delegatorFactory","type":"address"}],"stateMutability":"nonpayable","type":"constructor"},{"inputs":[],"name":"AccessControlBadConfirmation","type":"error"},{"inputs":[{"internalType":"address","name":"account","type":"address"},{"internalType":"bytes32","name":"neededRole","type":"bytes32"}],"name":"AccessControlUnauthorizedAccount","type":"error"},{"inputs":[],"name":"AdapterHasAssets","type":"error"},{"inputs":[],"name":"AlreadyAdded","type":"error"},{"inputs":[],"name":"AlreadyInitialized","type":"error"},{"inputs":[],"name":"InvalidAdapter","type":"error"},{"inputs":[],"name":"InvalidInitialization","type":"error"},{"inputs":[],"name":"InvalidRole","type":"error"},{"inputs":[],"name":"InvalidShareLimit","type":"error"},{"inputs":[],"name":"NotFactory","type":"error"},{"inputs":[],"name":"NotInitializing","type":"error"},{"inputs":[],"name":"NotSelf","type":"error"},{"inputs":[],"name":"NotVault","type":"error"},{"inputs":[],"name":"OldVault","type":"error"},{"inputs":[{"internalType":"address","name":"owner","type":"address"}],"name":"OwnableInvalidOwner","type":"error"},{"inputs":[{"internalType":"address","name":"account","type":"address"}],"name":"OwnableUnauthorizedAccount","type":"error"},{"inputs":[],"name":"ReentrancyGuardReentrantCall","type":"error"},{"inputs":[],"name":"TooManyAdapters","type":"error"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"adapter","type":"address"},{"indexed":false,"internalType":"uint256","name":"index","type":"uint256"}],"name":"AddAdapter","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"adapter","type":"address"},{"indexed":false,"internalType":"uint256","name":"assets","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"totalAssets","type":"uint256"}],"name":"Allocate","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"adapter","type":"address"},{"indexed":false,"internalType":"uint256","name":"assets","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"totalAssets","type":"uint256"}],"name":"Deallocate","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint256","name":"assets","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"share","type":"uint256"}],"name":"DecreaseLimits","type":"event"},{"anonymous":false,"inputs":[{"components":[{"internalType":"address","name":"allocateRoleHolder","type":"address"},{"internalType":"address","name":"deallocateRoleHolder","type":"address"},{"internalType":"address","name":"addAdapterRoleHolder","type":"address"},{"internalType":"address","name":"swapAdaptersRoleHolder","type":"address"},{"internalType":"address","name":"defaultAdminRoleHolder","type":"address"},{"internalType":"address","name":"removeAdapterRoleHolder","type":"address"},{"internalType":"address","name":"forceDeallocateRoleHolder","type":"address"},{"internalType":"address","name":"setAdapterLimitsRoleHolder","type":"address"},{"internalType":"address","name":"setAutoAllocateAdaptersRoleHolder","type":"address"}],"indexed":false,"internalType":"struct IUniversalDelegator.InitParams","name":"params","type":"tuple"}],"name":"Initialize","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint64","name":"version","type":"uint64"}],"name":"Initialized","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"previousOwner","type":"address"},{"indexed":true,"internalType":"address","name":"newOwner","type":"address"}],"name":"OwnershipTransferred","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"adapter","type":"address"},{"indexed":false,"internalType":"uint256","name":"index","type":"uint256"}],"name":"RemoveAdapter","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"adapter","type":"address"},{"indexed":false,"internalType":"uint256","name":"assets","type":"uint256"}],"name":"RequestDeallocate","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"role","type":"bytes32"},{"indexed":true,"internalType":"bytes32","name":"previousAdminRole","type":"bytes32"},{"indexed":true,"internalType":"bytes32","name":"newAdminRole","type":"bytes32"}],"name":"RoleAdminChanged","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"role","type":"bytes32"},{"indexed":true,"internalType":"address","name":"account","type":"address"},{"indexed":true,"internalType":"address","name":"sender","type":"address"}],"name":"RoleGranted","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"role","type":"bytes32"},{"indexed":true,"internalType":"address","name":"account","type":"address"},{"indexed":true,"internalType":"address","name":"sender","type":"address"}],"name":"RoleRevoked","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"address[]","name":"adapters","type":"address[]"}],"name":"SetAutoAllocateAdapters","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"adapter","type":"address"},{"indexed":false,"internalType":"uint256","name":"absoluteLimit","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"shareLimit","type":"uint256"}],"name":"SetLimits","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"adapter1","type":"address"},{"indexed":true,"internalType":"address","name":"adapter2","type":"address"}],"name":"SwapAdapters","type":"event"},{"inputs":[],"name":"DEFAULT_ADMIN_ROLE","outputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"FACTORY","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"__deallocateAll","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"adapter","type":"address"}],"name":"absoluteLimitOf","outputs":[{"internalType":"uint256","name":"assets","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"adapter","type":"address"}],"name":"adapterToIndex","outputs":[{"internalType":"uint16","name":"index","type":"uint16"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"","type":"uint256"}],"name":"adapters","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"","type":"uint256"}],"name":"adaptersWithPending","outputs":[{"internalType":"uint16","name":"","type":"uint16"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"adapter","type":"address"}],"name":"addAdapter","outputs":[{"internalType":"uint16","name":"index","type":"uint16"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"adapter","type":"address"},{"internalType":"uint256","name":"assets","type":"uint256"}],"name":"allocate","outputs":[{"internalType":"uint256","name":"allocated","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"assets","type":"uint256"}],"name":"allocateAll","outputs":[{"internalType":"uint256","name":"allocated","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"adapter","type":"address"},{"internalType":"uint256","name":"assets","type":"uint256"}],"name":"allocateExact","outputs":[{"internalType":"uint256","name":"allocated","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"","type":"uint256"}],"name":"autoAllocateAdapters","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"deallocatable","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"adapter","type":"address"},{"internalType":"uint256","name":"assets","type":"uint256"}],"name":"deallocate","outputs":[{"internalType":"uint256","name":"deallocated","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"assets","type":"uint256"}],"name":"deallocateAll","outputs":[{"internalType":"uint256","name":"deallocated","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"assets","type":"uint256"}],"name":"deallocateExact","outputs":[{"internalType":"uint256","name":"deallocated","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"assets","type":"uint256"},{"internalType":"uint256","name":"share","type":"uint256"}],"name":"decreaseLimits","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"adapter","type":"address"},{"internalType":"uint256","name":"assets","type":"uint256"}],"name":"forceDeallocate","outputs":[{"internalType":"uint256","name":"deallocated","type":"uint256"},{"internalType":"uint256","name":"pending","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"getAdaptersLength","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"}],"name":"getRoleAdmin","outputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"},{"internalType":"address","name":"account","type":"address"}],"name":"grantRole","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"},{"internalType":"address","name":"account","type":"address"}],"name":"hasRole","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint16","name":"index","type":"uint16"}],"name":"indexToAdapter","outputs":[{"internalType":"address","name":"adapter","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint64","name":"initialVersion","type":"uint64"},{"internalType":"address","name":"owner_","type":"address"},{"internalType":"bytes","name":"data","type":"bytes"}],"name":"initialize","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"adapter","type":"address"}],"name":"limitOf","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint64","name":"newVersion","type":"uint64"},{"internalType":"bytes","name":"data","type":"bytes"}],"name":"migrate","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes[]","name":"data","type":"bytes[]"}],"name":"multicall","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"onDeposit","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"assets","type":"uint256"}],"name":"onWithdraw","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"owner","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"adapter","type":"address"}],"name":"removeAdapter","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"renounceOwnership","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"},{"internalType":"address","name":"callerConfirmation","type":"address"}],"name":"renounceRole","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"},{"internalType":"address","name":"account","type":"address"}],"name":"revokeRole","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address[]","name":"newAutoAllocateAdapters","type":"address[]"}],"name":"setAutoAllocateAdapters","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"adapter","type":"address"},{"internalType":"uint256","name":"assets","type":"uint256"},{"internalType":"uint256","name":"share","type":"uint256"}],"name":"setLimits","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"adapter","type":"address"}],"name":"shareLimitOf","outputs":[{"internalType":"uint256","name":"share","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"target","type":"address"},{"internalType":"bytes","name":"data","type":"bytes"}],"name":"staticDelegateCall","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes4","name":"interfaceId","type":"bytes4"}],"name":"supportsInterface","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"adapter1","type":"address"},{"internalType":"address","name":"adapter2","type":"address"}],"name":"swapAdapters","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"sweepPending","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"totalAdapters","outputs":[{"internalType":"uint16","name":"","type":"uint16"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"totalAssets","outputs":[{"internalType":"uint256","name":"assets","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"newOwner","type":"address"}],"name":"transferOwnership","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"vault","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"version","outputs":[{"internalType":"uint64","name":"","type":"uint64"}],"stateMutability":"view","type":"function"}]

    declare storage: SymbioticUniversalDelegatorImplStorageReader
}

type TSender = TAccount & {
    value?: string | number | bigint
}

type TEventLogOptions<TParams> = {
    fromBlock?: number | Date
    toBlock?: number | Date
    params?: TParams
}

export type TSymbioticUniversalDelegatorImplTypes = {
    Events: {
        AddAdapter: {
            outputParams: { adapter: TAddress, index: bigint },
            outputArgs:   [ adapter: TAddress, index: bigint ],
        }
        Allocate: {
            outputParams: { adapter: TAddress, assets: bigint, totalAssets: bigint },
            outputArgs:   [ adapter: TAddress, assets: bigint, totalAssets: bigint ],
        }
        Deallocate: {
            outputParams: { adapter: TAddress, assets: bigint, totalAssets: bigint },
            outputArgs:   [ adapter: TAddress, assets: bigint, totalAssets: bigint ],
        }
        DecreaseLimits: {
            outputParams: { assets: bigint, share: bigint },
            outputArgs:   [ assets: bigint, share: bigint ],
        }
        Initialize: {
            outputParams: { params: { allocateRoleHolder: TAddress, deallocateRoleHolder: TAddress, addAdapterRoleHolder: TAddress, swapAdaptersRoleHolder: TAddress, defaultAdminRoleHolder: TAddress, removeAdapterRoleHolder: TAddress, forceDeallocateRoleHolder: TAddress, setAdapterLimitsRoleHolder: TAddress, setAutoAllocateAdaptersRoleHolder: TAddress } },
            outputArgs:   [ params: { allocateRoleHolder: TAddress, deallocateRoleHolder: TAddress, addAdapterRoleHolder: TAddress, swapAdaptersRoleHolder: TAddress, defaultAdminRoleHolder: TAddress, removeAdapterRoleHolder: TAddress, forceDeallocateRoleHolder: TAddress, setAdapterLimitsRoleHolder: TAddress, setAutoAllocateAdaptersRoleHolder: TAddress } ],
        }
        Initialized: {
            outputParams: { version: number },
            outputArgs:   [ version: number ],
        }
        OwnershipTransferred: {
            outputParams: { previousOwner: TAddress, newOwner: TAddress },
            outputArgs:   [ previousOwner: TAddress, newOwner: TAddress ],
        }
        RemoveAdapter: {
            outputParams: { adapter: TAddress, index: bigint },
            outputArgs:   [ adapter: TAddress, index: bigint ],
        }
        RequestDeallocate: {
            outputParams: { adapter: TAddress, assets: bigint },
            outputArgs:   [ adapter: TAddress, assets: bigint ],
        }
        RoleAdminChanged: {
            outputParams: { role: TEth.Hex, previousAdminRole: TEth.Hex, newAdminRole: TEth.Hex },
            outputArgs:   [ role: TEth.Hex, previousAdminRole: TEth.Hex, newAdminRole: TEth.Hex ],
        }
        RoleGranted: {
            outputParams: { role: TEth.Hex, account: TAddress, _sender: TAddress },
            outputArgs:   [ role: TEth.Hex, account: TAddress, _sender: TAddress ],
        }
        RoleRevoked: {
            outputParams: { role: TEth.Hex, account: TAddress, _sender: TAddress },
            outputArgs:   [ role: TEth.Hex, account: TAddress, _sender: TAddress ],
        }
        SetAutoAllocateAdapters: {
            outputParams: { adapters: TAddress[] },
            outputArgs:   [ adapters: TAddress[] ],
        }
        SetLimits: {
            outputParams: { adapter: TAddress, absoluteLimit: bigint, shareLimit: bigint },
            outputArgs:   [ adapter: TAddress, absoluteLimit: bigint, shareLimit: bigint ],
        }
        SwapAdapters: {
            outputParams: { adapter1: TAddress, adapter2: TAddress },
            outputArgs:   [ adapter1: TAddress, adapter2: TAddress ],
        }
    },
    Methods: {
        DEFAULT_ADMIN_ROLE: {
          method: "DEFAULT_ADMIN_ROLE"
          arguments: [  ]
        }
        FACTORY: {
          method: "FACTORY"
          arguments: [  ]
        }
        __deallocateAll: {
          method: "__deallocateAll"
          arguments: [  ]
        }
        absoluteLimitOf: {
          method: "absoluteLimitOf"
          arguments: [ adapter: TAddress ]
        }
        adapterToIndex: {
          method: "adapterToIndex"
          arguments: [ adapter: TAddress ]
        }
        adapters: {
          method: "adapters"
          arguments: [ input0: bigint ]
        }
        adaptersWithPending: {
          method: "adaptersWithPending"
          arguments: [ input0: bigint ]
        }
        addAdapter: {
          method: "addAdapter"
          arguments: [ adapter: TAddress ]
        }
        allocate: {
          method: "allocate"
          arguments: [ adapter: TAddress, assets: bigint ]
        }
        allocateAll: {
          method: "allocateAll"
          arguments: [ assets: bigint ]
        }
        allocateExact: {
          method: "allocateExact"
          arguments: [ adapter: TAddress, assets: bigint ]
        }
        autoAllocateAdapters: {
          method: "autoAllocateAdapters"
          arguments: [ input0: bigint ]
        }
        deallocatable: {
          method: "deallocatable"
          arguments: [  ]
        }
        deallocate: {
          method: "deallocate"
          arguments: [ adapter: TAddress, assets: bigint ]
        }
        deallocateAll: {
          method: "deallocateAll"
          arguments: [ assets: bigint ]
        }
        deallocateExact: {
          method: "deallocateExact"
          arguments: [ assets: bigint ]
        }
        decreaseLimits: {
          method: "decreaseLimits"
          arguments: [ assets: bigint, share: bigint ]
        }
        forceDeallocate: {
          method: "forceDeallocate"
          arguments: [ adapter: TAddress, assets: bigint ]
        }
        getAdaptersLength: {
          method: "getAdaptersLength"
          arguments: [  ]
        }
        getRoleAdmin: {
          method: "getRoleAdmin"
          arguments: [ role: TEth.Hex ]
        }
        grantRole: {
          method: "grantRole"
          arguments: [ role: TEth.Hex, account: TAddress ]
        }
        hasRole: {
          method: "hasRole"
          arguments: [ role: TEth.Hex, account: TAddress ]
        }
        indexToAdapter: {
          method: "indexToAdapter"
          arguments: [ index: number ]
        }
        initialize: {
          method: "initialize"
          arguments: [ initialVersion: number, owner_: TAddress, data: TEth.Hex ]
        }
        limitOf: {
          method: "limitOf"
          arguments: [ adapter: TAddress ]
        }
        migrate: {
          method: "migrate"
          arguments: [ newVersion: number, data: TEth.Hex ]
        }
        multicall: {
          method: "multicall"
          arguments: [ data: TEth.Hex[] ]
        }
        onDeposit: {
          method: "onDeposit"
          arguments: [  ]
        }
        onWithdraw: {
          method: "onWithdraw"
          arguments: [ assets: bigint ]
        }
        owner: {
          method: "owner"
          arguments: [  ]
        }
        removeAdapter: {
          method: "removeAdapter"
          arguments: [ adapter: TAddress ]
        }
        renounceOwnership: {
          method: "renounceOwnership"
          arguments: [  ]
        }
        renounceRole: {
          method: "renounceRole"
          arguments: [ role: TEth.Hex, callerConfirmation: TAddress ]
        }
        revokeRole: {
          method: "revokeRole"
          arguments: [ role: TEth.Hex, account: TAddress ]
        }
        setAutoAllocateAdapters: {
          method: "setAutoAllocateAdapters"
          arguments: [ newAutoAllocateAdapters: TAddress[] ]
        }
        setLimits: {
          method: "setLimits"
          arguments: [ adapter: TAddress, assets: bigint, share: bigint ]
        }
        shareLimitOf: {
          method: "shareLimitOf"
          arguments: [ adapter: TAddress ]
        }
        staticDelegateCall: {
          method: "staticDelegateCall"
          arguments: [ target: TAddress, data: TEth.Hex ]
        }
        supportsInterface: {
          method: "supportsInterface"
          arguments: [ interfaceId: TEth.Hex ]
        }
        swapAdapters: {
          method: "swapAdapters"
          arguments: [ adapter1: TAddress, adapter2: TAddress ]
        }
        sweepPending: {
          method: "sweepPending"
          arguments: [  ]
        }
        totalAdapters: {
          method: "totalAdapters"
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



class SymbioticUniversalDelegatorImplStorageReader extends ContractStorageReaderBase {
    constructor(
        public address: TAddress,
        public client: Web3Client,
        public explorer: IBlockchainExplorer,
    ) {
        super(address, client, explorer);

        this.$createHandler(this.$slots);
    }

    async __gap(): Promise<bigint[10]> {
        return this.$storage.get(['__gap', ]);
    }

    async vault(): Promise<TAddress> {
        return this.$storage.get(['vault', ]);
    }

    async totalAdapters(): Promise<number> {
        return this.$storage.get(['totalAdapters', ]);
    }

    async adapters(): Promise<TAddress[]> {
        return this.$storage.get(['adapters', ]);
    }

    async adaptersWithPending(): Promise<number[]> {
        return this.$storage.get(['adaptersWithPending', ]);
    }

    async autoAllocateAdapters(): Promise<TAddress[]> {
        return this.$storage.get(['autoAllocateAdapters', ]);
    }

    async indexToAdapter(key: number): Promise<TAddress> {
        return this.$storage.get(['indexToAdapter', key]);
    }

    async adapterToIndex(key: TAddress): Promise<number> {
        return this.$storage.get(['adapterToIndex', key]);
    }

    async shareLimitOf(key: TAddress): Promise<bigint> {
        return this.$storage.get(['shareLimitOf', key]);
    }

    async absoluteLimitOf(key: TAddress): Promise<bigint> {
        return this.$storage.get(['absoluteLimitOf', key]);
    }

    async _isAdapterAdded(key: TAddress): Promise<boolean> {
        return this.$storage.get(['_isAdapterAdded', key]);
    }

    $slots = [
    {
        "slot": 0,
        "position": 0,
        "name": "__gap",
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
        "slot": 10,
        "position": 160,
        "name": "totalAdapters",
        "size": 16,
        "type": "uint16"
    },
    {
        "slot": 11,
        "position": 0,
        "name": "adapters",
        "size": null,
        "type": "address[]"
    },
    {
        "slot": 12,
        "position": 0,
        "name": "adaptersWithPending",
        "size": null,
        "type": "uint16[]"
    },
    {
        "slot": 13,
        "position": 0,
        "name": "autoAllocateAdapters",
        "size": null,
        "type": "address[]"
    },
    {
        "slot": 14,
        "position": 0,
        "name": "indexToAdapter",
        "size": null,
        "type": "mapping(uint16 => address)"
    },
    {
        "slot": 15,
        "position": 0,
        "name": "adapterToIndex",
        "size": null,
        "type": "mapping(address => uint16)"
    },
    {
        "slot": 16,
        "position": 0,
        "name": "shareLimitOf",
        "size": null,
        "type": "mapping(address => uint256)"
    },
    {
        "slot": 17,
        "position": 0,
        "name": "absoluteLimitOf",
        "size": null,
        "type": "mapping(address => uint256)"
    },
    {
        "slot": 18,
        "position": 0,
        "name": "_isAdapterAdded",
        "size": null,
        "type": "mapping(address => bool)"
    }
]

}


interface ISymbioticUniversalDelegatorImplTxCaller {
    __deallocateAll (sender: TSender, ): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    addAdapter (sender: TSender, adapter: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    allocate (sender: TSender, adapter: TAddress, assets: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    allocateAll (sender: TSender, assets: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    allocateExact (sender: TSender, adapter: TAddress, assets: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    deallocatable (sender: TSender, ): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    deallocate (sender: TSender, adapter: TAddress, assets: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    deallocateAll (sender: TSender, assets: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    deallocateExact (sender: TSender, assets: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    decreaseLimits (sender: TSender, assets: bigint, share: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    forceDeallocate (sender: TSender, adapter: TAddress, assets: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    grantRole (sender: TSender, role: TEth.Hex, account: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    initialize (sender: TSender, initialVersion: number, owner_: TAddress, data: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    migrate (sender: TSender, newVersion: number, data: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    multicall (sender: TSender, data: TEth.Hex[]): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    onDeposit (sender: TSender, ): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    onWithdraw (sender: TSender, assets: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    removeAdapter (sender: TSender, adapter: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    renounceOwnership (sender: TSender, ): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    renounceRole (sender: TSender, role: TEth.Hex, callerConfirmation: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    revokeRole (sender: TSender, role: TEth.Hex, account: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    setAutoAllocateAdapters (sender: TSender, newAutoAllocateAdapters: TAddress[]): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    setLimits (sender: TSender, adapter: TAddress, assets: bigint, share: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    staticDelegateCall (sender: TSender, target: TAddress, data: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    swapAdapters (sender: TSender, adapter1: TAddress, adapter2: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    sweepPending (sender: TSender, ): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    transferOwnership (sender: TSender, newOwner: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
}


interface ISymbioticUniversalDelegatorImplTxData {
    __deallocateAll (sender: TSender, ): Promise<TEth.TxLike>
    addAdapter (sender: TSender, adapter: TAddress): Promise<TEth.TxLike>
    allocate (sender: TSender, adapter: TAddress, assets: bigint): Promise<TEth.TxLike>
    allocateAll (sender: TSender, assets: bigint): Promise<TEth.TxLike>
    allocateExact (sender: TSender, adapter: TAddress, assets: bigint): Promise<TEth.TxLike>
    deallocatable (sender: TSender, ): Promise<TEth.TxLike>
    deallocate (sender: TSender, adapter: TAddress, assets: bigint): Promise<TEth.TxLike>
    deallocateAll (sender: TSender, assets: bigint): Promise<TEth.TxLike>
    deallocateExact (sender: TSender, assets: bigint): Promise<TEth.TxLike>
    decreaseLimits (sender: TSender, assets: bigint, share: bigint): Promise<TEth.TxLike>
    forceDeallocate (sender: TSender, adapter: TAddress, assets: bigint): Promise<TEth.TxLike>
    grantRole (sender: TSender, role: TEth.Hex, account: TAddress): Promise<TEth.TxLike>
    initialize (sender: TSender, initialVersion: number, owner_: TAddress, data: TEth.Hex): Promise<TEth.TxLike>
    migrate (sender: TSender, newVersion: number, data: TEth.Hex): Promise<TEth.TxLike>
    multicall (sender: TSender, data: TEth.Hex[]): Promise<TEth.TxLike>
    onDeposit (sender: TSender, ): Promise<TEth.TxLike>
    onWithdraw (sender: TSender, assets: bigint): Promise<TEth.TxLike>
    removeAdapter (sender: TSender, adapter: TAddress): Promise<TEth.TxLike>
    renounceOwnership (sender: TSender, ): Promise<TEth.TxLike>
    renounceRole (sender: TSender, role: TEth.Hex, callerConfirmation: TAddress): Promise<TEth.TxLike>
    revokeRole (sender: TSender, role: TEth.Hex, account: TAddress): Promise<TEth.TxLike>
    setAutoAllocateAdapters (sender: TSender, newAutoAllocateAdapters: TAddress[]): Promise<TEth.TxLike>
    setLimits (sender: TSender, adapter: TAddress, assets: bigint, share: bigint): Promise<TEth.TxLike>
    staticDelegateCall (sender: TSender, target: TAddress, data: TEth.Hex): Promise<TEth.TxLike>
    swapAdapters (sender: TSender, adapter1: TAddress, adapter2: TAddress): Promise<TEth.TxLike>
    sweepPending (sender: TSender, ): Promise<TEth.TxLike>
    transferOwnership (sender: TSender, newOwner: TAddress): Promise<TEth.TxLike>
}


type TEvents = TSymbioticUniversalDelegatorImplTypes['Events'];
type TEventParams<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputParams']>;
type TEventArguments<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputArgs']>;
