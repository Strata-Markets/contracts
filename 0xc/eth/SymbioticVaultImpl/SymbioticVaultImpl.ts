/**
 *  AUTO-Generated Class: 2026-09-21 19:09
 *  Implementation: https://etherscan.io/address/0x41069A712FaCc421fE194cAa59667456863a780e#code
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

export namespace SymbioticVaultImplErrors {
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
    export interface AlreadyInitialized {
        type: 'AlreadyInitialized'
        params: {
        }
    }
    export interface CheckpointUnorderedInsertion {
        type: 'CheckpointUnorderedInsertion'
        params: {
        }
    }
    export interface DelegatorAlreadyInitialized {
        type: 'DelegatorAlreadyInitialized'
        params: {
        }
    }
    export interface ECDSAInvalidSignature {
        type: 'ECDSAInvalidSignature'
        params: {
        }
    }
    export interface ECDSAInvalidSignatureLength {
        type: 'ECDSAInvalidSignatureLength'
        params: {
            length: bigint
        }
    }
    export interface ECDSAInvalidSignatureS {
        type: 'ECDSAInvalidSignatureS'
        params: {
            s: TEth.Hex
        }
    }
    export interface ERC20InsufficientAllowance {
        type: 'ERC20InsufficientAllowance'
        params: {
            spender: TAddress
            allowance: bigint
            needed: bigint
        }
    }
    export interface ERC20InsufficientBalance {
        type: 'ERC20InsufficientBalance'
        params: {
            sender: TAddress
            balance: bigint
            needed: bigint
        }
    }
    export interface ERC20InvalidApprover {
        type: 'ERC20InvalidApprover'
        params: {
            approver: TAddress
        }
    }
    export interface ERC20InvalidReceiver {
        type: 'ERC20InvalidReceiver'
        params: {
            receiver: TAddress
        }
    }
    export interface ERC20InvalidSender {
        type: 'ERC20InvalidSender'
        params: {
            sender: TAddress
        }
    }
    export interface ERC20InvalidSpender {
        type: 'ERC20InvalidSpender'
        params: {
            spender: TAddress
        }
    }
    export interface ERC2612ExpiredSignature {
        type: 'ERC2612ExpiredSignature'
        params: {
            deadline: bigint
        }
    }
    export interface ERC2612InvalidSigner {
        type: 'ERC2612InvalidSigner'
        params: {
            signer: TAddress
            owner: TAddress
        }
    }
    export interface ERC4626ExceededMaxDeposit {
        type: 'ERC4626ExceededMaxDeposit'
        params: {
            receiver: TAddress
            assets: bigint
            max: bigint
        }
    }
    export interface ERC4626ExceededMaxMint {
        type: 'ERC4626ExceededMaxMint'
        params: {
            receiver: TAddress
            shares: bigint
            max: bigint
        }
    }
    export interface ERC4626ExceededMaxRedeem {
        type: 'ERC4626ExceededMaxRedeem'
        params: {
            owner: TAddress
            shares: bigint
            max: bigint
        }
    }
    export interface ERC4626ExceededMaxWithdraw {
        type: 'ERC4626ExceededMaxWithdraw'
        params: {
            owner: TAddress
            assets: bigint
            max: bigint
        }
    }
    export interface FeeTooHigh {
        type: 'FeeTooHigh'
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
    export interface InvalidAddress {
        type: 'InvalidAddress'
        params: {
        }
    }
    export interface InvalidDelegator {
        type: 'InvalidDelegator'
        params: {
        }
    }
    export interface InvalidInitialization {
        type: 'InvalidInitialization'
        params: {
        }
    }
    export interface NotDelegator {
        type: 'NotDelegator'
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
    export interface PendingWithdrawalQueue {
        type: 'PendingWithdrawalQueue'
        params: {
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
    export type Error = AccessControlBadConfirmation | AccessControlUnauthorizedAccount | AlreadyInitialized | CheckpointUnorderedInsertion | DelegatorAlreadyInitialized | ECDSAInvalidSignature | ECDSAInvalidSignatureLength | ECDSAInvalidSignatureS | ERC20InsufficientAllowance | ERC20InsufficientBalance | ERC20InvalidApprover | ERC20InvalidReceiver | ERC20InvalidSender | ERC20InvalidSpender | ERC2612ExpiredSignature | ERC2612InvalidSigner | ERC4626ExceededMaxDeposit | ERC4626ExceededMaxMint | ERC4626ExceededMaxRedeem | ERC4626ExceededMaxWithdraw | FeeTooHigh | InvalidAccountNonce | InvalidAddress | InvalidDelegator | InvalidInitialization | NotDelegator | NotFactory | NotInitializing | OwnableInvalidOwner | OwnableUnauthorizedAccount | PendingWithdrawalQueue | ReentrancyGuardReentrantCall | SafeERC20FailedOperation
}

export class SymbioticVaultImpl extends ContractBase {
    constructor(
        public address: TEth.Address = '0x41069A712FaCc421fE194cAa59667456863a780e',
        public client: Web3Client = di.resolve(EvmWeb3Client, { platform: 'eth' }),
        public explorer: IBlockchainExplorer = di.resolve(Evmscan, { platform: 'eth' }),
    ) {
        super(address, client, explorer)

        this.storage = new SymbioticVaultImplStorageReader(this.address, this.client, this.explorer);
    }

    Types: TSymbioticVaultImplTypes;

    $meta = {
        "class": "./0xc/eth/SymbioticVaultImpl/SymbioticVaultImpl.ts"
    }

    async $constructor (deployer: TSender, vaultFactory: TAddress, delegatorFactory: TAddress, protocolFeeRegistry: TAddress, withdrawalQueueFactory: TAddress): Promise<TxWriter> {
        throw new Error('Not implemented. Typing purpose. Use the ContractDeployer class to deploy the contract');
    }

    // 0xa217fddf
    async DEFAULT_ADMIN_ROLE (): Promise<TEth.Hex> {
        return this.$read(this.$getAbiItem('function', 'DEFAULT_ADMIN_ROLE'));
    }

    // 0x3644e515
    async DOMAIN_SEPARATOR (): Promise<TEth.Hex> {
        return this.$read(this.$getAbiItem('function', 'DOMAIN_SEPARATOR'));
    }

    // 0x2dd31000
    async FACTORY (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'FACTORY'));
    }

    // 0xa6afed95
    async accrueInterest (sender: TSender, ): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'accrueInterest'), sender);
    }

    // 0xdd62ed3e
    async allowance (owner: TAddress, spender: TAddress): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'allowance'), owner, spender);
    }

    // 0x095ea7b3
    async approve (sender: TSender, spender: TAddress, value: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'approve'), sender, spender, value);
    }

    // 0x38d52e0f
    async asset (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'asset'));
    }

    // 0x70a08231
    async balanceOf (account: TAddress): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'balanceOf'), account);
    }

    // 0x95c3a492
    async balanceOfAt (account: TAddress, timestamp: number): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'balanceOfAt'), account, timestamp);
    }

    // 0x07a2d13a
    async convertToAssets (shares: bigint): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'convertToAssets'), shares);
    }

    // 0xc6e6f592
    async convertToShares (assets: bigint): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'convertToShares'), assets);
    }

    // 0x313ce567
    async decimals (): Promise<number> {
        return this.$read(this.$getAbiItem('function', 'decimals'));
    }

    // 0xce9b7930
    async delegator (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'delegator'));
    }

    // 0x6e553f65
    async deposit (sender: TSender, assets: bigint, receiver: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'deposit'), sender, assets, receiver);
    }

    // 0xecf70858
    async depositLimit (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'depositLimit'));
    }

    // 0x48d3b775
    async depositWhitelist (): Promise<boolean> {
        return this.$read(this.$getAbiItem('function', 'depositWhitelist'));
    }

    // 0x84b0196e
    async eip712Domain (): Promise<{ fields: TEth.Hex, name: string, version: string, chainId: bigint, verifyingContract: TAddress, salt: TEth.Hex, extensions: bigint[] }> {
        return this.$read(this.$getAbiItem('function', 'eip712Domain'));
    }

    // 0x11f240ac
    async freeAssets (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'freeAssets'));
    }

    // 0x0445a611
    async getAccrueInterest (): Promise<{ newTotalAssets: bigint, managementFeeShares: bigint, performanceFeeShares: bigint, protocolFeeShares: bigint }> {
        return this.$read(this.$getAbiItem('function', 'getAccrueInterest'));
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

    // 0x57ec83cc
    async initialize (sender: TSender, initialVersion: number, owner_: TAddress, data: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'initialize'), sender, initialVersion, owner_, data);
    }

    // 0xa1b12202
    async isDepositLimit (): Promise<boolean> {
        return this.$read(this.$getAbiItem('function', 'isDepositLimit'));
    }

    // 0x794b15b7
    async isDepositorWhitelisted (account: TAddress): Promise<boolean> {
        return this.$read(this.$getAbiItem('function', 'isDepositorWhitelisted'), account);
    }

    // 0x392e53cd
    async isInitialized (): Promise<boolean> {
        return this.$read(this.$getAbiItem('function', 'isInitialized'));
    }

    // 0xef9c691f
    async lastProtocolFeeReceiver (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'lastProtocolFeeReceiver'));
    }

    // 0x192fb170
    async lastProtocolManagementFee (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'lastProtocolManagementFee'));
    }

    // 0xf56f1926
    async lastProtocolPerformanceFee (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'lastProtocolPerformanceFee'));
    }

    // 0xc0463711
    async lastUpdate (): Promise<number> {
        return this.$read(this.$getAbiItem('function', 'lastUpdate'));
    }

    // 0xa6f7f5d6
    async managementFee (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'managementFee'));
    }

    // 0x43039947
    async managementFeeReceiver (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'managementFeeReceiver'));
    }

    // 0x402d267d
    async maxDeposit (input0: TAddress): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'maxDeposit'), input0);
    }

    // 0xc63d75b6
    async maxMint (receiver: TAddress): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'maxMint'), receiver);
    }

    // 0xd905777e
    async maxRedeem (owner: TAddress): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'maxRedeem'), owner);
    }

    // 0xce96cb77
    async maxWithdraw (owner: TAddress): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'maxWithdraw'), owner);
    }

    // 0x2abe3048
    async migrate (sender: TSender, newVersion: number, data: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'migrate'), sender, newVersion, data);
    }

    // 0x94bf804d
    async mint (sender: TSender, shares: bigint, receiver: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'mint'), sender, shares, receiver);
    }

    // 0xac9650d8
    async multicall (sender: TSender, data: TEth.Hex[]): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'multicall'), sender, data);
    }

    // 0x06fdde03
    async name (): Promise<string> {
        return this.$read(this.$getAbiItem('function', 'name'));
    }

    // 0x7ecebe00
    async nonces (owner: TAddress): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'nonces'), owner);
    }

    // 0x8da5cb5b
    async owner (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'owner'));
    }

    // 0x87788782
    async performanceFee (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'performanceFee'));
    }

    // 0x82cf16df
    async performanceFeeReceiver (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'performanceFeeReceiver'));
    }

    // 0xd505accf
    async permit (sender: TSender, owner: TAddress, spender: TAddress, value: bigint, deadline: bigint, v: number, r: TEth.Hex, s: TEth.Hex): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'permit'), sender, owner, spender, value, deadline, v, r, s);
    }

    // 0xef8b30f7
    async previewDeposit (assets: bigint): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'previewDeposit'), assets);
    }

    // 0xb3d7f6b9
    async previewMint (shares: bigint): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'previewMint'), shares);
    }

    // 0x4cdad506
    async previewRedeem (shares: bigint): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'previewRedeem'), shares);
    }

    // 0x0a28a477
    async previewWithdraw (assets: bigint): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'previewWithdraw'), assets);
    }

    // 0x97b41a12
    async pull (sender: TSender, assets: bigint, receiver: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'pull'), sender, assets, receiver);
    }

    // 0xc80fbe4e
    async push (sender: TSender, assets: bigint, owner: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'push'), sender, assets, owner);
    }

    // 0xba087652
    async redeem (sender: TSender, shares: bigint, receiver: TAddress, owner: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'redeem'), sender, shares, receiver, owner);
    }

    // 0x2d7ecd11
    async redeemable (sender: TSender, ): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'redeemable'), sender);
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

    // 0xbdc8144b
    async setDepositLimit (sender: TSender, newLimit: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'setDepositLimit'), sender, newLimit);
    }

    // 0x4105a7dd
    async setDepositWhitelist (sender: TSender, newStatus: boolean): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'setDepositWhitelist'), sender, newStatus);
    }

    // 0xa2861466
    async setDepositorWhitelistStatus (sender: TSender, account: TAddress, newStatus: boolean): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'setDepositorWhitelistStatus'), sender, account, newStatus);
    }

    // 0x5346e34f
    async setIsDepositLimit (sender: TSender, newStatus: boolean): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'setIsDepositLimit'), sender, newStatus);
    }

    // 0xf5cd33d2
    async setManagementFee (sender: TSender, newManagementFee: bigint, newManagementFeeReceiver: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'setManagementFee'), sender, newManagementFee, newManagementFeeReceiver);
    }

    // 0xc4fef03e
    async setPerformanceFee (sender: TSender, newPerformanceFee: bigint, newPerformanceFeeReceiver: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'setPerformanceFee'), sender, newPerformanceFee, newPerformanceFeeReceiver);
    }

    // 0x01ffc9a7
    async supportsInterface (interfaceId: TEth.Hex): Promise<boolean> {
        return this.$read(this.$getAbiItem('function', 'supportsInterface'), interfaceId);
    }

    // 0x95d89b41
    async symbol (): Promise<string> {
        return this.$read(this.$getAbiItem('function', 'symbol'));
    }

    // 0x01e1d114
    async totalAssets (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'totalAssets'));
    }

    // 0x18160ddd
    async totalSupply (): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'totalSupply'));
    }

    // 0xe9efd4cf
    async totalSupplyAt (timestamp: number): Promise<bigint> {
        return this.$read(this.$getAbiItem('function', 'totalSupplyAt'), timestamp);
    }

    // 0xa9059cbb
    async transfer (sender: TSender, to: TAddress, value: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'transfer'), sender, to, value);
    }

    // 0x23b872dd
    async transferFrom (sender: TSender, from: TAddress, to: TAddress, value: bigint): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'transferFrom'), sender, from, to, value);
    }

    // 0xf2fde38b
    async transferOwnership (sender: TSender, newOwner: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'transferOwnership'), sender, newOwner);
    }

    // 0x54fd4d50
    async version (): Promise<number> {
        return this.$read(this.$getAbiItem('function', 'version'));
    }

    // 0xb460af94
    async withdraw (sender: TSender, assets: bigint, receiver: TAddress, owner: TAddress): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'withdraw'), sender, assets, receiver, owner);
    }

    // 0x50188301
    async withdrawable (sender: TSender, ): Promise<TxWriter> {
        return this.$write(this.$getAbiItem('function', 'withdrawable'), sender);
    }

    // 0x37d5fe99
    async withdrawalQueue (): Promise<TAddress> {
        return this.$read(this.$getAbiItem('function', 'withdrawalQueue'));
    }

    $call () {
        return super.$call() as ISymbioticVaultImplTxCaller;
    }
    $signed (): TOverrideReturns<ISymbioticVaultImplTxCaller, Promise<{ signed: TEth.Hex, error?: Error & { data?: { type: string, params } } }>> {
        return super.$signed() as any;
    }
    $data (): ISymbioticVaultImplTxData {
        return super.$data() as ISymbioticVaultImplTxData;
    }
    $gas (): TOverrideReturns<ISymbioticVaultImplTxCaller, Promise<{ gas?: bigint, price?: bigint, error?: Error & { data?: { type: string, params } } }>> {
        return super.$gas() as any;
    }

    onTransaction <TMethod extends keyof TSymbioticVaultImplTypes['Methods']> (method: TMethod, options: Parameters<ContractBase['$onTransaction']>[0]): SubjectStream<{
        tx: TEth.Tx
        block: TEth.Block<TEth.Hex>
        calldata: {
            method: TMethod
            arguments: TSymbioticVaultImplTypes['Methods'][TMethod]['arguments']
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

    onAccrueInterest (fn?: (event: TClientEventsStreamData<TEventArguments<'AccrueInterest'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'AccrueInterest'>>> {
        return this.$onLog('AccrueInterest', fn);
    }

    onApproval (fn?: (event: TClientEventsStreamData<TEventArguments<'Approval'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Approval'>>> {
        return this.$onLog('Approval', fn);
    }

    onDeposit (fn?: (event: TClientEventsStreamData<TEventArguments<'Deposit'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Deposit'>>> {
        return this.$onLog('Deposit', fn);
    }

    onEIP712DomainChanged (fn?: (event: TClientEventsStreamData<TEventArguments<'EIP712DomainChanged'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'EIP712DomainChanged'>>> {
        return this.$onLog('EIP712DomainChanged', fn);
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

    onPull (fn?: (event: TClientEventsStreamData<TEventArguments<'Pull'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Pull'>>> {
        return this.$onLog('Pull', fn);
    }

    onPush (fn?: (event: TClientEventsStreamData<TEventArguments<'Push'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Push'>>> {
        return this.$onLog('Push', fn);
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

    onSetDelegator (fn?: (event: TClientEventsStreamData<TEventArguments<'SetDelegator'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetDelegator'>>> {
        return this.$onLog('SetDelegator', fn);
    }

    onSetDepositLimit (fn?: (event: TClientEventsStreamData<TEventArguments<'SetDepositLimit'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetDepositLimit'>>> {
        return this.$onLog('SetDepositLimit', fn);
    }

    onSetDepositWhitelist (fn?: (event: TClientEventsStreamData<TEventArguments<'SetDepositWhitelist'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetDepositWhitelist'>>> {
        return this.$onLog('SetDepositWhitelist', fn);
    }

    onSetDepositorWhitelistStatus (fn?: (event: TClientEventsStreamData<TEventArguments<'SetDepositorWhitelistStatus'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetDepositorWhitelistStatus'>>> {
        return this.$onLog('SetDepositorWhitelistStatus', fn);
    }

    onSetIsDepositLimit (fn?: (event: TClientEventsStreamData<TEventArguments<'SetIsDepositLimit'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetIsDepositLimit'>>> {
        return this.$onLog('SetIsDepositLimit', fn);
    }

    onSetManagementFee (fn?: (event: TClientEventsStreamData<TEventArguments<'SetManagementFee'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetManagementFee'>>> {
        return this.$onLog('SetManagementFee', fn);
    }

    onSetPerformanceFee (fn?: (event: TClientEventsStreamData<TEventArguments<'SetPerformanceFee'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetPerformanceFee'>>> {
        return this.$onLog('SetPerformanceFee', fn);
    }

    onSetWithdrawalQueue (fn?: (event: TClientEventsStreamData<TEventArguments<'SetWithdrawalQueue'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'SetWithdrawalQueue'>>> {
        return this.$onLog('SetWithdrawalQueue', fn);
    }

    onTransfer (fn?: (event: TClientEventsStreamData<TEventArguments<'Transfer'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Transfer'>>> {
        return this.$onLog('Transfer', fn);
    }

    onUpdateProtocolFee (fn?: (event: TClientEventsStreamData<TEventArguments<'UpdateProtocolFee'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'UpdateProtocolFee'>>> {
        return this.$onLog('UpdateProtocolFee', fn);
    }

    onWithdraw (fn?: (event: TClientEventsStreamData<TEventArguments<'Withdraw'>>) => void): ClientEventsStream<TClientEventsStreamData<TEventArguments<'Withdraw'>>> {
        return this.$onLog('Withdraw', fn);
    }

    extractLogsAccrueInterest (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'AccrueInterest'>>[] {
        let abi = this.$getAbiItem('event', 'AccrueInterest');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'AccrueInterest'>>[];
    }

    extractLogsApproval (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Approval'>>[] {
        let abi = this.$getAbiItem('event', 'Approval');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Approval'>>[];
    }

    extractLogsDeposit (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Deposit'>>[] {
        let abi = this.$getAbiItem('event', 'Deposit');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Deposit'>>[];
    }

    extractLogsEIP712DomainChanged (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'EIP712DomainChanged'>>[] {
        let abi = this.$getAbiItem('event', 'EIP712DomainChanged');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'EIP712DomainChanged'>>[];
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

    extractLogsPull (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Pull'>>[] {
        let abi = this.$getAbiItem('event', 'Pull');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Pull'>>[];
    }

    extractLogsPush (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Push'>>[] {
        let abi = this.$getAbiItem('event', 'Push');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Push'>>[];
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

    extractLogsSetDelegator (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetDelegator'>>[] {
        let abi = this.$getAbiItem('event', 'SetDelegator');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetDelegator'>>[];
    }

    extractLogsSetDepositLimit (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetDepositLimit'>>[] {
        let abi = this.$getAbiItem('event', 'SetDepositLimit');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetDepositLimit'>>[];
    }

    extractLogsSetDepositWhitelist (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetDepositWhitelist'>>[] {
        let abi = this.$getAbiItem('event', 'SetDepositWhitelist');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetDepositWhitelist'>>[];
    }

    extractLogsSetDepositorWhitelistStatus (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetDepositorWhitelistStatus'>>[] {
        let abi = this.$getAbiItem('event', 'SetDepositorWhitelistStatus');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetDepositorWhitelistStatus'>>[];
    }

    extractLogsSetIsDepositLimit (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetIsDepositLimit'>>[] {
        let abi = this.$getAbiItem('event', 'SetIsDepositLimit');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetIsDepositLimit'>>[];
    }

    extractLogsSetManagementFee (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetManagementFee'>>[] {
        let abi = this.$getAbiItem('event', 'SetManagementFee');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetManagementFee'>>[];
    }

    extractLogsSetPerformanceFee (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetPerformanceFee'>>[] {
        let abi = this.$getAbiItem('event', 'SetPerformanceFee');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetPerformanceFee'>>[];
    }

    extractLogsSetWithdrawalQueue (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'SetWithdrawalQueue'>>[] {
        let abi = this.$getAbiItem('event', 'SetWithdrawalQueue');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'SetWithdrawalQueue'>>[];
    }

    extractLogsTransfer (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Transfer'>>[] {
        let abi = this.$getAbiItem('event', 'Transfer');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Transfer'>>[];
    }

    extractLogsUpdateProtocolFee (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'UpdateProtocolFee'>>[] {
        let abi = this.$getAbiItem('event', 'UpdateProtocolFee');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'UpdateProtocolFee'>>[];
    }

    extractLogsWithdraw (tx: TEth.TxReceipt): ITxLogItem<TEventParams<'Withdraw'>>[] {
        let abi = this.$getAbiItem('event', 'Withdraw');
        return this.$extractLogs(tx, abi) as any as ITxLogItem<TEventParams<'Withdraw'>>[];
    }

    async getPastLogsAccrueInterest (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'AccrueInterest'>>[]> {
        return await this.$getPastLogsParsed('AccrueInterest', options) as any;
    }

    async getPastLogsApproval (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { owner?: TAddress,spender?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'Approval'>>[]> {
        return await this.$getPastLogsParsed('Approval', options) as any;
    }

    async getPastLogsDeposit (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { sender?: TAddress,owner?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'Deposit'>>[]> {
        return await this.$getPastLogsParsed('Deposit', options) as any;
    }

    async getPastLogsEIP712DomainChanged (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'EIP712DomainChanged'>>[]> {
        return await this.$getPastLogsParsed('EIP712DomainChanged', options) as any;
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

    async getPastLogsPull (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'Pull'>>[]> {
        return await this.$getPastLogsParsed('Pull', options) as any;
    }

    async getPastLogsPush (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'Push'>>[]> {
        return await this.$getPastLogsParsed('Push', options) as any;
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

    async getPastLogsSetDelegator (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { delegator?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'SetDelegator'>>[]> {
        return await this.$getPastLogsParsed('SetDelegator', options) as any;
    }

    async getPastLogsSetDepositLimit (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'SetDepositLimit'>>[]> {
        return await this.$getPastLogsParsed('SetDepositLimit', options) as any;
    }

    async getPastLogsSetDepositWhitelist (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'SetDepositWhitelist'>>[]> {
        return await this.$getPastLogsParsed('SetDepositWhitelist', options) as any;
    }

    async getPastLogsSetDepositorWhitelistStatus (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { account?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'SetDepositorWhitelistStatus'>>[]> {
        return await this.$getPastLogsParsed('SetDepositorWhitelistStatus', options) as any;
    }

    async getPastLogsSetIsDepositLimit (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'SetIsDepositLimit'>>[]> {
        return await this.$getPastLogsParsed('SetIsDepositLimit', options) as any;
    }

    async getPastLogsSetManagementFee (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'SetManagementFee'>>[]> {
        return await this.$getPastLogsParsed('SetManagementFee', options) as any;
    }

    async getPastLogsSetPerformanceFee (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: {  }
    }): Promise<ITxLogItem<TEventParams<'SetPerformanceFee'>>[]> {
        return await this.$getPastLogsParsed('SetPerformanceFee', options) as any;
    }

    async getPastLogsSetWithdrawalQueue (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { withdrawalQueue?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'SetWithdrawalQueue'>>[]> {
        return await this.$getPastLogsParsed('SetWithdrawalQueue', options) as any;
    }

    async getPastLogsTransfer (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { from?: TAddress,to?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'Transfer'>>[]> {
        return await this.$getPastLogsParsed('Transfer', options) as any;
    }

    async getPastLogsUpdateProtocolFee (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { receiver?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'UpdateProtocolFee'>>[]> {
        return await this.$getPastLogsParsed('UpdateProtocolFee', options) as any;
    }

    async getPastLogsWithdraw (options?: {
        fromBlock?: number | Date
        toBlock?: number | Date
        params?: { sender?: TAddress,receiver?: TAddress,owner?: TAddress }
    }): Promise<ITxLogItem<TEventParams<'Withdraw'>>[]> {
        return await this.$getPastLogsParsed('Withdraw', options) as any;
    }

    abi: TAbiItem[] = [{"inputs":[{"internalType":"address","name":"vaultFactory","type":"address"},{"internalType":"address","name":"delegatorFactory","type":"address"},{"internalType":"address","name":"protocolFeeRegistry","type":"address"},{"internalType":"address","name":"withdrawalQueueFactory","type":"address"}],"stateMutability":"nonpayable","type":"constructor"},{"inputs":[],"name":"AccessControlBadConfirmation","type":"error"},{"inputs":[{"internalType":"address","name":"account","type":"address"},{"internalType":"bytes32","name":"neededRole","type":"bytes32"}],"name":"AccessControlUnauthorizedAccount","type":"error"},{"inputs":[],"name":"AlreadyInitialized","type":"error"},{"inputs":[],"name":"CheckpointUnorderedInsertion","type":"error"},{"inputs":[],"name":"DelegatorAlreadyInitialized","type":"error"},{"inputs":[],"name":"ECDSAInvalidSignature","type":"error"},{"inputs":[{"internalType":"uint256","name":"length","type":"uint256"}],"name":"ECDSAInvalidSignatureLength","type":"error"},{"inputs":[{"internalType":"bytes32","name":"s","type":"bytes32"}],"name":"ECDSAInvalidSignatureS","type":"error"},{"inputs":[{"internalType":"address","name":"spender","type":"address"},{"internalType":"uint256","name":"allowance","type":"uint256"},{"internalType":"uint256","name":"needed","type":"uint256"}],"name":"ERC20InsufficientAllowance","type":"error"},{"inputs":[{"internalType":"address","name":"sender","type":"address"},{"internalType":"uint256","name":"balance","type":"uint256"},{"internalType":"uint256","name":"needed","type":"uint256"}],"name":"ERC20InsufficientBalance","type":"error"},{"inputs":[{"internalType":"address","name":"approver","type":"address"}],"name":"ERC20InvalidApprover","type":"error"},{"inputs":[{"internalType":"address","name":"receiver","type":"address"}],"name":"ERC20InvalidReceiver","type":"error"},{"inputs":[{"internalType":"address","name":"sender","type":"address"}],"name":"ERC20InvalidSender","type":"error"},{"inputs":[{"internalType":"address","name":"spender","type":"address"}],"name":"ERC20InvalidSpender","type":"error"},{"inputs":[{"internalType":"uint256","name":"deadline","type":"uint256"}],"name":"ERC2612ExpiredSignature","type":"error"},{"inputs":[{"internalType":"address","name":"signer","type":"address"},{"internalType":"address","name":"owner","type":"address"}],"name":"ERC2612InvalidSigner","type":"error"},{"inputs":[{"internalType":"address","name":"receiver","type":"address"},{"internalType":"uint256","name":"assets","type":"uint256"},{"internalType":"uint256","name":"max","type":"uint256"}],"name":"ERC4626ExceededMaxDeposit","type":"error"},{"inputs":[{"internalType":"address","name":"receiver","type":"address"},{"internalType":"uint256","name":"shares","type":"uint256"},{"internalType":"uint256","name":"max","type":"uint256"}],"name":"ERC4626ExceededMaxMint","type":"error"},{"inputs":[{"internalType":"address","name":"owner","type":"address"},{"internalType":"uint256","name":"shares","type":"uint256"},{"internalType":"uint256","name":"max","type":"uint256"}],"name":"ERC4626ExceededMaxRedeem","type":"error"},{"inputs":[{"internalType":"address","name":"owner","type":"address"},{"internalType":"uint256","name":"assets","type":"uint256"},{"internalType":"uint256","name":"max","type":"uint256"}],"name":"ERC4626ExceededMaxWithdraw","type":"error"},{"inputs":[],"name":"FeeTooHigh","type":"error"},{"inputs":[{"internalType":"address","name":"account","type":"address"},{"internalType":"uint256","name":"currentNonce","type":"uint256"}],"name":"InvalidAccountNonce","type":"error"},{"inputs":[],"name":"InvalidAddress","type":"error"},{"inputs":[],"name":"InvalidDelegator","type":"error"},{"inputs":[],"name":"InvalidInitialization","type":"error"},{"inputs":[],"name":"NotDelegator","type":"error"},{"inputs":[],"name":"NotFactory","type":"error"},{"inputs":[],"name":"NotInitializing","type":"error"},{"inputs":[{"internalType":"address","name":"owner","type":"address"}],"name":"OwnableInvalidOwner","type":"error"},{"inputs":[{"internalType":"address","name":"account","type":"address"}],"name":"OwnableUnauthorizedAccount","type":"error"},{"inputs":[],"name":"PendingWithdrawalQueue","type":"error"},{"inputs":[],"name":"ReentrancyGuardReentrantCall","type":"error"},{"inputs":[{"internalType":"address","name":"token","type":"address"}],"name":"SafeERC20FailedOperation","type":"error"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint256","name":"newTotalAssets","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"managementFeeShares","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"performanceFeeShares","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"protocolFeeShares","type":"uint256"}],"name":"AccrueInterest","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"owner","type":"address"},{"indexed":true,"internalType":"address","name":"spender","type":"address"},{"indexed":false,"internalType":"uint256","name":"value","type":"uint256"}],"name":"Approval","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"sender","type":"address"},{"indexed":true,"internalType":"address","name":"owner","type":"address"},{"indexed":false,"internalType":"uint256","name":"assets","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"shares","type":"uint256"}],"name":"Deposit","type":"event"},{"anonymous":false,"inputs":[],"name":"EIP712DomainChanged","type":"event"},{"anonymous":false,"inputs":[{"components":[{"internalType":"string","name":"name","type":"string"},{"internalType":"string","name":"symbol","type":"string"},{"internalType":"address","name":"asset","type":"address"},{"internalType":"bool","name":"depositWhitelist","type":"bool"},{"internalType":"address","name":"depositorToWhitelist","type":"address"},{"internalType":"uint256","name":"depositLimit","type":"uint256"},{"internalType":"bool","name":"isDepositLimit","type":"bool"},{"internalType":"address","name":"defaultAdminRoleHolder","type":"address"},{"internalType":"address","name":"managementFeeRoleHolder","type":"address"},{"internalType":"address","name":"performanceFeeRoleHolder","type":"address"},{"internalType":"address","name":"depositLimitSetRoleHolder","type":"address"},{"internalType":"address","name":"depositorWhitelistRoleHolder","type":"address"},{"internalType":"address","name":"isDepositLimitSetRoleHolder","type":"address"},{"internalType":"address","name":"depositWhitelistSetRoleHolder","type":"address"},{"internalType":"bytes","name":"delegatorParams","type":"bytes"}],"indexed":false,"internalType":"struct IVaultV2.InitParams","name":"params","type":"tuple"}],"name":"Initialize","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint64","name":"version","type":"uint64"}],"name":"Initialized","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"previousOwner","type":"address"},{"indexed":true,"internalType":"address","name":"newOwner","type":"address"}],"name":"OwnershipTransferred","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint256","name":"assets","type":"uint256"},{"indexed":true,"internalType":"address","name":"receiver","type":"address"}],"name":"Pull","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint256","name":"assets","type":"uint256"},{"indexed":true,"internalType":"address","name":"owner","type":"address"}],"name":"Push","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"role","type":"bytes32"},{"indexed":true,"internalType":"bytes32","name":"previousAdminRole","type":"bytes32"},{"indexed":true,"internalType":"bytes32","name":"newAdminRole","type":"bytes32"}],"name":"RoleAdminChanged","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"role","type":"bytes32"},{"indexed":true,"internalType":"address","name":"account","type":"address"},{"indexed":true,"internalType":"address","name":"sender","type":"address"}],"name":"RoleGranted","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"role","type":"bytes32"},{"indexed":true,"internalType":"address","name":"account","type":"address"},{"indexed":true,"internalType":"address","name":"sender","type":"address"}],"name":"RoleRevoked","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"delegator","type":"address"}],"name":"SetDelegator","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint256","name":"limit","type":"uint256"}],"name":"SetDepositLimit","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"bool","name":"status","type":"bool"}],"name":"SetDepositWhitelist","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"account","type":"address"},{"indexed":false,"internalType":"bool","name":"status","type":"bool"}],"name":"SetDepositorWhitelistStatus","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"bool","name":"status","type":"bool"}],"name":"SetIsDepositLimit","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint256","name":"fee","type":"uint256"},{"indexed":true,"internalType":"address","name":"receiver","type":"address"}],"name":"SetManagementFee","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint256","name":"fee","type":"uint256"},{"indexed":true,"internalType":"address","name":"receiver","type":"address"}],"name":"SetPerformanceFee","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"withdrawalQueue","type":"address"}],"name":"SetWithdrawalQueue","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"from","type":"address"},{"indexed":true,"internalType":"address","name":"to","type":"address"},{"indexed":false,"internalType":"uint256","name":"value","type":"uint256"}],"name":"Transfer","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"receiver","type":"address"},{"indexed":false,"internalType":"uint96","name":"managementFee","type":"uint96"},{"indexed":false,"internalType":"uint96","name":"performanceFee","type":"uint96"}],"name":"UpdateProtocolFee","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"sender","type":"address"},{"indexed":true,"internalType":"address","name":"receiver","type":"address"},{"indexed":true,"internalType":"address","name":"owner","type":"address"},{"indexed":false,"internalType":"uint256","name":"assets","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"shares","type":"uint256"}],"name":"Withdraw","type":"event"},{"inputs":[],"name":"DEFAULT_ADMIN_ROLE","outputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"DOMAIN_SEPARATOR","outputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"FACTORY","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"accrueInterest","outputs":[{"internalType":"uint256","name":"managementFeeShares","type":"uint256"},{"internalType":"uint256","name":"performanceFeeShares","type":"uint256"},{"internalType":"uint256","name":"protocolFeeShares","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"owner","type":"address"},{"internalType":"address","name":"spender","type":"address"}],"name":"allowance","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"spender","type":"address"},{"internalType":"uint256","name":"value","type":"uint256"}],"name":"approve","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"asset","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"account","type":"address"}],"name":"balanceOf","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"account","type":"address"},{"internalType":"uint48","name":"timestamp","type":"uint48"}],"name":"balanceOfAt","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"shares","type":"uint256"}],"name":"convertToAssets","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"assets","type":"uint256"}],"name":"convertToShares","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"decimals","outputs":[{"internalType":"uint8","name":"","type":"uint8"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"delegator","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"assets","type":"uint256"},{"internalType":"address","name":"receiver","type":"address"}],"name":"deposit","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"depositLimit","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"depositWhitelist","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"eip712Domain","outputs":[{"internalType":"bytes1","name":"fields","type":"bytes1"},{"internalType":"string","name":"name","type":"string"},{"internalType":"string","name":"version","type":"string"},{"internalType":"uint256","name":"chainId","type":"uint256"},{"internalType":"address","name":"verifyingContract","type":"address"},{"internalType":"bytes32","name":"salt","type":"bytes32"},{"internalType":"uint256[]","name":"extensions","type":"uint256[]"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"freeAssets","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"getAccrueInterest","outputs":[{"internalType":"uint256","name":"newTotalAssets","type":"uint256"},{"internalType":"uint256","name":"managementFeeShares","type":"uint256"},{"internalType":"uint256","name":"performanceFeeShares","type":"uint256"},{"internalType":"uint256","name":"protocolFeeShares","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"}],"name":"getRoleAdmin","outputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"},{"internalType":"address","name":"account","type":"address"}],"name":"grantRole","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"},{"internalType":"address","name":"account","type":"address"}],"name":"hasRole","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint64","name":"initialVersion","type":"uint64"},{"internalType":"address","name":"owner_","type":"address"},{"internalType":"bytes","name":"data","type":"bytes"}],"name":"initialize","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"isDepositLimit","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"account","type":"address"}],"name":"isDepositorWhitelisted","outputs":[{"internalType":"bool","name":"value","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"isInitialized","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"lastProtocolFeeReceiver","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"lastProtocolManagementFee","outputs":[{"internalType":"uint96","name":"","type":"uint96"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"lastProtocolPerformanceFee","outputs":[{"internalType":"uint96","name":"","type":"uint96"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"lastUpdate","outputs":[{"internalType":"uint48","name":"","type":"uint48"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"managementFee","outputs":[{"internalType":"uint96","name":"","type":"uint96"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"managementFeeReceiver","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"","type":"address"}],"name":"maxDeposit","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"receiver","type":"address"}],"name":"maxMint","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"owner","type":"address"}],"name":"maxRedeem","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"owner","type":"address"}],"name":"maxWithdraw","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint64","name":"newVersion","type":"uint64"},{"internalType":"bytes","name":"data","type":"bytes"}],"name":"migrate","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"shares","type":"uint256"},{"internalType":"address","name":"receiver","type":"address"}],"name":"mint","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes[]","name":"data","type":"bytes[]"}],"name":"multicall","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"name","outputs":[{"internalType":"string","name":"","type":"string"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"owner","type":"address"}],"name":"nonces","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"owner","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"performanceFee","outputs":[{"internalType":"uint96","name":"","type":"uint96"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"performanceFeeReceiver","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"owner","type":"address"},{"internalType":"address","name":"spender","type":"address"},{"internalType":"uint256","name":"value","type":"uint256"},{"internalType":"uint256","name":"deadline","type":"uint256"},{"internalType":"uint8","name":"v","type":"uint8"},{"internalType":"bytes32","name":"r","type":"bytes32"},{"internalType":"bytes32","name":"s","type":"bytes32"}],"name":"permit","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"assets","type":"uint256"}],"name":"previewDeposit","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"shares","type":"uint256"}],"name":"previewMint","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"shares","type":"uint256"}],"name":"previewRedeem","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"assets","type":"uint256"}],"name":"previewWithdraw","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"assets","type":"uint256"},{"internalType":"address","name":"receiver","type":"address"}],"name":"pull","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"assets","type":"uint256"},{"internalType":"address","name":"owner","type":"address"}],"name":"push","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"shares","type":"uint256"},{"internalType":"address","name":"receiver","type":"address"},{"internalType":"address","name":"owner","type":"address"}],"name":"redeem","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"redeemable","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"renounceOwnership","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"},{"internalType":"address","name":"callerConfirmation","type":"address"}],"name":"renounceRole","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"},{"internalType":"address","name":"account","type":"address"}],"name":"revokeRole","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"newLimit","type":"uint256"}],"name":"setDepositLimit","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bool","name":"newStatus","type":"bool"}],"name":"setDepositWhitelist","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"account","type":"address"},{"internalType":"bool","name":"newStatus","type":"bool"}],"name":"setDepositorWhitelistStatus","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bool","name":"newStatus","type":"bool"}],"name":"setIsDepositLimit","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint96","name":"newManagementFee","type":"uint96"},{"internalType":"address","name":"newManagementFeeReceiver","type":"address"}],"name":"setManagementFee","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint96","name":"newPerformanceFee","type":"uint96"},{"internalType":"address","name":"newPerformanceFeeReceiver","type":"address"}],"name":"setPerformanceFee","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes4","name":"interfaceId","type":"bytes4"}],"name":"supportsInterface","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"symbol","outputs":[{"internalType":"string","name":"","type":"string"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"totalAssets","outputs":[{"internalType":"uint256","name":"assets","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"totalSupply","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint48","name":"timestamp","type":"uint48"}],"name":"totalSupplyAt","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"to","type":"address"},{"internalType":"uint256","name":"value","type":"uint256"}],"name":"transfer","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"from","type":"address"},{"internalType":"address","name":"to","type":"address"},{"internalType":"uint256","name":"value","type":"uint256"}],"name":"transferFrom","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"newOwner","type":"address"}],"name":"transferOwnership","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"version","outputs":[{"internalType":"uint64","name":"","type":"uint64"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"uint256","name":"assets","type":"uint256"},{"internalType":"address","name":"receiver","type":"address"},{"internalType":"address","name":"owner","type":"address"}],"name":"withdraw","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"withdrawable","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"withdrawalQueue","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"}]

    declare storage: SymbioticVaultImplStorageReader
}

type TSender = TAccount & {
    value?: string | number | bigint
}

type TEventLogOptions<TParams> = {
    fromBlock?: number | Date
    toBlock?: number | Date
    params?: TParams
}

export type TSymbioticVaultImplTypes = {
    Events: {
        AccrueInterest: {
            outputParams: { newTotalAssets: bigint, managementFeeShares: bigint, performanceFeeShares: bigint, protocolFeeShares: bigint },
            outputArgs:   [ newTotalAssets: bigint, managementFeeShares: bigint, performanceFeeShares: bigint, protocolFeeShares: bigint ],
        }
        Approval: {
            outputParams: { owner: TAddress, spender: TAddress, value: bigint },
            outputArgs:   [ owner: TAddress, spender: TAddress, value: bigint ],
        }
        Deposit: {
            outputParams: { _sender: TAddress, owner: TAddress, assets: bigint, shares: bigint },
            outputArgs:   [ _sender: TAddress, owner: TAddress, assets: bigint, shares: bigint ],
        }
        EIP712DomainChanged: {
            outputParams: {  },
            outputArgs:   [  ],
        }
        Initialize: {
            outputParams: { params: { name: string, symbol: string, asset: TAddress, depositWhitelist: boolean, depositorToWhitelist: TAddress, depositLimit: bigint, isDepositLimit: boolean, defaultAdminRoleHolder: TAddress, managementFeeRoleHolder: TAddress, performanceFeeRoleHolder: TAddress, depositLimitSetRoleHolder: TAddress, depositorWhitelistRoleHolder: TAddress, isDepositLimitSetRoleHolder: TAddress, depositWhitelistSetRoleHolder: TAddress, delegatorParams: TEth.Hex } },
            outputArgs:   [ params: { name: string, symbol: string, asset: TAddress, depositWhitelist: boolean, depositorToWhitelist: TAddress, depositLimit: bigint, isDepositLimit: boolean, defaultAdminRoleHolder: TAddress, managementFeeRoleHolder: TAddress, performanceFeeRoleHolder: TAddress, depositLimitSetRoleHolder: TAddress, depositorWhitelistRoleHolder: TAddress, isDepositLimitSetRoleHolder: TAddress, depositWhitelistSetRoleHolder: TAddress, delegatorParams: TEth.Hex } ],
        }
        Initialized: {
            outputParams: { version: number },
            outputArgs:   [ version: number ],
        }
        OwnershipTransferred: {
            outputParams: { previousOwner: TAddress, newOwner: TAddress },
            outputArgs:   [ previousOwner: TAddress, newOwner: TAddress ],
        }
        Pull: {
            outputParams: { assets: bigint, receiver: TAddress },
            outputArgs:   [ assets: bigint, receiver: TAddress ],
        }
        Push: {
            outputParams: { assets: bigint, owner: TAddress },
            outputArgs:   [ assets: bigint, owner: TAddress ],
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
        SetDelegator: {
            outputParams: { delegator: TAddress },
            outputArgs:   [ delegator: TAddress ],
        }
        SetDepositLimit: {
            outputParams: { limit: bigint },
            outputArgs:   [ limit: bigint ],
        }
        SetDepositWhitelist: {
            outputParams: { status: boolean },
            outputArgs:   [ status: boolean ],
        }
        SetDepositorWhitelistStatus: {
            outputParams: { account: TAddress, status: boolean },
            outputArgs:   [ account: TAddress, status: boolean ],
        }
        SetIsDepositLimit: {
            outputParams: { status: boolean },
            outputArgs:   [ status: boolean ],
        }
        SetManagementFee: {
            outputParams: { fee: bigint, receiver: TAddress },
            outputArgs:   [ fee: bigint, receiver: TAddress ],
        }
        SetPerformanceFee: {
            outputParams: { fee: bigint, receiver: TAddress },
            outputArgs:   [ fee: bigint, receiver: TAddress ],
        }
        SetWithdrawalQueue: {
            outputParams: { withdrawalQueue: TAddress },
            outputArgs:   [ withdrawalQueue: TAddress ],
        }
        Transfer: {
            outputParams: { from: TAddress, to: TAddress, value: bigint },
            outputArgs:   [ from: TAddress, to: TAddress, value: bigint ],
        }
        UpdateProtocolFee: {
            outputParams: { receiver: TAddress, managementFee: bigint, performanceFee: bigint },
            outputArgs:   [ receiver: TAddress, managementFee: bigint, performanceFee: bigint ],
        }
        Withdraw: {
            outputParams: { _sender: TAddress, receiver: TAddress, owner: TAddress, assets: bigint, shares: bigint },
            outputArgs:   [ _sender: TAddress, receiver: TAddress, owner: TAddress, assets: bigint, shares: bigint ],
        }
    },
    Methods: {
        DEFAULT_ADMIN_ROLE: {
          method: "DEFAULT_ADMIN_ROLE"
          arguments: [  ]
        }
        DOMAIN_SEPARATOR: {
          method: "DOMAIN_SEPARATOR"
          arguments: [  ]
        }
        FACTORY: {
          method: "FACTORY"
          arguments: [  ]
        }
        accrueInterest: {
          method: "accrueInterest"
          arguments: [  ]
        }
        allowance: {
          method: "allowance"
          arguments: [ owner: TAddress, spender: TAddress ]
        }
        approve: {
          method: "approve"
          arguments: [ spender: TAddress, value: bigint ]
        }
        asset: {
          method: "asset"
          arguments: [  ]
        }
        balanceOf: {
          method: "balanceOf"
          arguments: [ account: TAddress ]
        }
        balanceOfAt: {
          method: "balanceOfAt"
          arguments: [ account: TAddress, timestamp: number ]
        }
        convertToAssets: {
          method: "convertToAssets"
          arguments: [ shares: bigint ]
        }
        convertToShares: {
          method: "convertToShares"
          arguments: [ assets: bigint ]
        }
        decimals: {
          method: "decimals"
          arguments: [  ]
        }
        delegator: {
          method: "delegator"
          arguments: [  ]
        }
        deposit: {
          method: "deposit"
          arguments: [ assets: bigint, receiver: TAddress ]
        }
        depositLimit: {
          method: "depositLimit"
          arguments: [  ]
        }
        depositWhitelist: {
          method: "depositWhitelist"
          arguments: [  ]
        }
        eip712Domain: {
          method: "eip712Domain"
          arguments: [  ]
        }
        freeAssets: {
          method: "freeAssets"
          arguments: [  ]
        }
        getAccrueInterest: {
          method: "getAccrueInterest"
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
        initialize: {
          method: "initialize"
          arguments: [ initialVersion: number, owner_: TAddress, data: TEth.Hex ]
        }
        isDepositLimit: {
          method: "isDepositLimit"
          arguments: [  ]
        }
        isDepositorWhitelisted: {
          method: "isDepositorWhitelisted"
          arguments: [ account: TAddress ]
        }
        isInitialized: {
          method: "isInitialized"
          arguments: [  ]
        }
        lastProtocolFeeReceiver: {
          method: "lastProtocolFeeReceiver"
          arguments: [  ]
        }
        lastProtocolManagementFee: {
          method: "lastProtocolManagementFee"
          arguments: [  ]
        }
        lastProtocolPerformanceFee: {
          method: "lastProtocolPerformanceFee"
          arguments: [  ]
        }
        lastUpdate: {
          method: "lastUpdate"
          arguments: [  ]
        }
        managementFee: {
          method: "managementFee"
          arguments: [  ]
        }
        managementFeeReceiver: {
          method: "managementFeeReceiver"
          arguments: [  ]
        }
        maxDeposit: {
          method: "maxDeposit"
          arguments: [ input0: TAddress ]
        }
        maxMint: {
          method: "maxMint"
          arguments: [ receiver: TAddress ]
        }
        maxRedeem: {
          method: "maxRedeem"
          arguments: [ owner: TAddress ]
        }
        maxWithdraw: {
          method: "maxWithdraw"
          arguments: [ owner: TAddress ]
        }
        migrate: {
          method: "migrate"
          arguments: [ newVersion: number, data: TEth.Hex ]
        }
        mint: {
          method: "mint"
          arguments: [ shares: bigint, receiver: TAddress ]
        }
        multicall: {
          method: "multicall"
          arguments: [ data: TEth.Hex[] ]
        }
        name: {
          method: "name"
          arguments: [  ]
        }
        nonces: {
          method: "nonces"
          arguments: [ owner: TAddress ]
        }
        owner: {
          method: "owner"
          arguments: [  ]
        }
        performanceFee: {
          method: "performanceFee"
          arguments: [  ]
        }
        performanceFeeReceiver: {
          method: "performanceFeeReceiver"
          arguments: [  ]
        }
        permit: {
          method: "permit"
          arguments: [ owner: TAddress, spender: TAddress, value: bigint, deadline: bigint, v: number, r: TEth.Hex, s: TEth.Hex ]
        }
        previewDeposit: {
          method: "previewDeposit"
          arguments: [ assets: bigint ]
        }
        previewMint: {
          method: "previewMint"
          arguments: [ shares: bigint ]
        }
        previewRedeem: {
          method: "previewRedeem"
          arguments: [ shares: bigint ]
        }
        previewWithdraw: {
          method: "previewWithdraw"
          arguments: [ assets: bigint ]
        }
        pull: {
          method: "pull"
          arguments: [ assets: bigint, receiver: TAddress ]
        }
        push: {
          method: "push"
          arguments: [ assets: bigint, owner: TAddress ]
        }
        redeem: {
          method: "redeem"
          arguments: [ shares: bigint, receiver: TAddress, owner: TAddress ]
        }
        redeemable: {
          method: "redeemable"
          arguments: [  ]
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
        setDepositLimit: {
          method: "setDepositLimit"
          arguments: [ newLimit: bigint ]
        }
        setDepositWhitelist: {
          method: "setDepositWhitelist"
          arguments: [ newStatus: boolean ]
        }
        setDepositorWhitelistStatus: {
          method: "setDepositorWhitelistStatus"
          arguments: [ account: TAddress, newStatus: boolean ]
        }
        setIsDepositLimit: {
          method: "setIsDepositLimit"
          arguments: [ newStatus: boolean ]
        }
        setManagementFee: {
          method: "setManagementFee"
          arguments: [ newManagementFee: bigint, newManagementFeeReceiver: TAddress ]
        }
        setPerformanceFee: {
          method: "setPerformanceFee"
          arguments: [ newPerformanceFee: bigint, newPerformanceFeeReceiver: TAddress ]
        }
        supportsInterface: {
          method: "supportsInterface"
          arguments: [ interfaceId: TEth.Hex ]
        }
        symbol: {
          method: "symbol"
          arguments: [  ]
        }
        totalAssets: {
          method: "totalAssets"
          arguments: [  ]
        }
        totalSupply: {
          method: "totalSupply"
          arguments: [  ]
        }
        totalSupplyAt: {
          method: "totalSupplyAt"
          arguments: [ timestamp: number ]
        }
        transfer: {
          method: "transfer"
          arguments: [ to: TAddress, value: bigint ]
        }
        transferFrom: {
          method: "transferFrom"
          arguments: [ from: TAddress, to: TAddress, value: bigint ]
        }
        transferOwnership: {
          method: "transferOwnership"
          arguments: [ newOwner: TAddress ]
        }
        version: {
          method: "version"
          arguments: [  ]
        }
        withdraw: {
          method: "withdraw"
          arguments: [ assets: bigint, receiver: TAddress, owner: TAddress ]
        }
        withdrawable: {
          method: "withdrawable"
          arguments: [  ]
        }
        withdrawalQueue: {
          method: "withdrawalQueue"
          arguments: [  ]
        }
    }
}



class SymbioticVaultImplStorageReader extends ContractStorageReaderBase {
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

    async withdrawalQueue(): Promise<TAddress> {
        return this.$storage.get(['withdrawalQueue', ]);
    }

    async delegator(): Promise<TAddress> {
        return this.$storage.get(['delegator', ]);
    }

    async __decimalsOffset(): Promise<number> {
        return this.$storage.get(['__decimalsOffset', ]);
    }

    async lastUpdate(): Promise<number> {
        return this.$storage.get(['lastUpdate', ]);
    }

    async isDepositLimit(): Promise<boolean> {
        return this.$storage.get(['isDepositLimit', ]);
    }

    async depositWhitelist(): Promise<boolean> {
        return this.$storage.get(['depositWhitelist', ]);
    }

    async depositLimit(): Promise<bigint> {
        return this.$storage.get(['depositLimit', ]);
    }

    async isDepositorWhitelisted(key: TAddress): Promise<boolean> {
        return this.$storage.get(['isDepositorWhitelisted', key]);
    }

    async managementFee(): Promise<bigint> {
        return this.$storage.get(['managementFee', ]);
    }

    async managementFeeReceiver(): Promise<TAddress> {
        return this.$storage.get(['managementFeeReceiver', ]);
    }

    async performanceFee(): Promise<bigint> {
        return this.$storage.get(['performanceFee', ]);
    }

    async performanceFeeReceiver(): Promise<TAddress> {
        return this.$storage.get(['performanceFeeReceiver', ]);
    }

    async lastProtocolManagementFee(): Promise<bigint> {
        return this.$storage.get(['lastProtocolManagementFee', ]);
    }

    async lastProtocolFeeReceiver(): Promise<TAddress> {
        return this.$storage.get(['lastProtocolFeeReceiver', ]);
    }

    async lastProtocolPerformanceFee(): Promise<bigint> {
        return this.$storage.get(['lastProtocolPerformanceFee', ]);
    }

    async _totalAssets(): Promise<bigint> {
        return this.$storage.get(['_totalAssets', ]);
    }

    async _totalSupply(): Promise<{ _checkpoints: { _key: bigint, _value: bigint }[] }> {
        return this.$storage.get(['_totalSupply', ]);
    }

    async _balances(key: TAddress): Promise<{ _checkpoints: { _key: bigint, _value: bigint }[] }> {
        return this.$storage.get(['_balances', key]);
    }

    async __gap(): Promise<bigint[50]> {
        return this.$storage.get(['__gap', ]);
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
        "name": "withdrawalQueue",
        "size": 160,
        "type": "address"
    },
    {
        "slot": 11,
        "position": 0,
        "name": "delegator",
        "size": 160,
        "type": "address"
    },
    {
        "slot": 11,
        "position": 160,
        "name": "__decimalsOffset",
        "size": 8,
        "type": "uint8"
    },
    {
        "slot": 11,
        "position": 168,
        "name": "lastUpdate",
        "size": 48,
        "type": "uint48"
    },
    {
        "slot": 11,
        "position": 216,
        "name": "isDepositLimit",
        "size": 8,
        "type": "bool"
    },
    {
        "slot": 11,
        "position": 224,
        "name": "depositWhitelist",
        "size": 8,
        "type": "bool"
    },
    {
        "slot": 12,
        "position": 0,
        "name": "depositLimit",
        "size": 256,
        "type": "uint256"
    },
    {
        "slot": 13,
        "position": 0,
        "name": "isDepositorWhitelisted",
        "size": null,
        "type": "mapping(address => bool)"
    },
    {
        "slot": 14,
        "position": 0,
        "name": "managementFee",
        "size": 96,
        "type": "uint96"
    },
    {
        "slot": 14,
        "position": 96,
        "name": "managementFeeReceiver",
        "size": 160,
        "type": "address"
    },
    {
        "slot": 15,
        "position": 0,
        "name": "performanceFee",
        "size": 96,
        "type": "uint96"
    },
    {
        "slot": 15,
        "position": 96,
        "name": "performanceFeeReceiver",
        "size": 160,
        "type": "address"
    },
    {
        "slot": 16,
        "position": 0,
        "name": "lastProtocolManagementFee",
        "size": 96,
        "type": "uint96"
    },
    {
        "slot": 16,
        "position": 96,
        "name": "lastProtocolFeeReceiver",
        "size": 160,
        "type": "address"
    },
    {
        "slot": 17,
        "position": 0,
        "name": "lastProtocolPerformanceFee",
        "size": 96,
        "type": "uint96"
    },
    {
        "slot": 18,
        "position": 0,
        "name": "_totalAssets",
        "size": 256,
        "type": "uint256"
    },
    {
        "slot": 19,
        "position": 0,
        "name": "_totalSupply",
        "size": 256,
        "type": "((uint256 _key, uint256 _value)[] _checkpoints)"
    },
    {
        "slot": 20,
        "position": 0,
        "name": "_balances",
        "size": null,
        "type": "mapping(address => ((uint256 _key, uint256 _value)[] _checkpoints))"
    },
    {
        "slot": 21,
        "position": 0,
        "name": "__gap",
        "size": 12800,
        "type": "uint256[50]"
    }
]

}


interface ISymbioticVaultImplTxCaller {
    accrueInterest (sender: TSender, ): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    approve (sender: TSender, spender: TAddress, value: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    deposit (sender: TSender, assets: bigint, receiver: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    grantRole (sender: TSender, role: TEth.Hex, account: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    initialize (sender: TSender, initialVersion: number, owner_: TAddress, data: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    migrate (sender: TSender, newVersion: number, data: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    mint (sender: TSender, shares: bigint, receiver: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    multicall (sender: TSender, data: TEth.Hex[]): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    permit (sender: TSender, owner: TAddress, spender: TAddress, value: bigint, deadline: bigint, v: number, r: TEth.Hex, s: TEth.Hex): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    pull (sender: TSender, assets: bigint, receiver: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    push (sender: TSender, assets: bigint, owner: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    redeem (sender: TSender, shares: bigint, receiver: TAddress, owner: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    redeemable (sender: TSender, ): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    renounceOwnership (sender: TSender, ): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    renounceRole (sender: TSender, role: TEth.Hex, callerConfirmation: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    revokeRole (sender: TSender, role: TEth.Hex, account: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    setDepositLimit (sender: TSender, newLimit: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    setDepositWhitelist (sender: TSender, newStatus: boolean): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    setDepositorWhitelistStatus (sender: TSender, account: TAddress, newStatus: boolean): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    setIsDepositLimit (sender: TSender, newStatus: boolean): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    setManagementFee (sender: TSender, newManagementFee: bigint, newManagementFeeReceiver: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    setPerformanceFee (sender: TSender, newPerformanceFee: bigint, newPerformanceFeeReceiver: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    transfer (sender: TSender, to: TAddress, value: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    transferFrom (sender: TSender, from: TAddress, to: TAddress, value: bigint): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    transferOwnership (sender: TSender, newOwner: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    withdraw (sender: TSender, assets: bigint, receiver: TAddress, owner: TAddress): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
    withdrawable (sender: TSender, ): Promise<{ error?: Error & { data?: { type: string, params } }, result? }>
}


interface ISymbioticVaultImplTxData {
    accrueInterest (sender: TSender, ): Promise<TEth.TxLike>
    approve (sender: TSender, spender: TAddress, value: bigint): Promise<TEth.TxLike>
    deposit (sender: TSender, assets: bigint, receiver: TAddress): Promise<TEth.TxLike>
    grantRole (sender: TSender, role: TEth.Hex, account: TAddress): Promise<TEth.TxLike>
    initialize (sender: TSender, initialVersion: number, owner_: TAddress, data: TEth.Hex): Promise<TEth.TxLike>
    migrate (sender: TSender, newVersion: number, data: TEth.Hex): Promise<TEth.TxLike>
    mint (sender: TSender, shares: bigint, receiver: TAddress): Promise<TEth.TxLike>
    multicall (sender: TSender, data: TEth.Hex[]): Promise<TEth.TxLike>
    permit (sender: TSender, owner: TAddress, spender: TAddress, value: bigint, deadline: bigint, v: number, r: TEth.Hex, s: TEth.Hex): Promise<TEth.TxLike>
    pull (sender: TSender, assets: bigint, receiver: TAddress): Promise<TEth.TxLike>
    push (sender: TSender, assets: bigint, owner: TAddress): Promise<TEth.TxLike>
    redeem (sender: TSender, shares: bigint, receiver: TAddress, owner: TAddress): Promise<TEth.TxLike>
    redeemable (sender: TSender, ): Promise<TEth.TxLike>
    renounceOwnership (sender: TSender, ): Promise<TEth.TxLike>
    renounceRole (sender: TSender, role: TEth.Hex, callerConfirmation: TAddress): Promise<TEth.TxLike>
    revokeRole (sender: TSender, role: TEth.Hex, account: TAddress): Promise<TEth.TxLike>
    setDepositLimit (sender: TSender, newLimit: bigint): Promise<TEth.TxLike>
    setDepositWhitelist (sender: TSender, newStatus: boolean): Promise<TEth.TxLike>
    setDepositorWhitelistStatus (sender: TSender, account: TAddress, newStatus: boolean): Promise<TEth.TxLike>
    setIsDepositLimit (sender: TSender, newStatus: boolean): Promise<TEth.TxLike>
    setManagementFee (sender: TSender, newManagementFee: bigint, newManagementFeeReceiver: TAddress): Promise<TEth.TxLike>
    setPerformanceFee (sender: TSender, newPerformanceFee: bigint, newPerformanceFeeReceiver: TAddress): Promise<TEth.TxLike>
    transfer (sender: TSender, to: TAddress, value: bigint): Promise<TEth.TxLike>
    transferFrom (sender: TSender, from: TAddress, to: TAddress, value: bigint): Promise<TEth.TxLike>
    transferOwnership (sender: TSender, newOwner: TAddress): Promise<TEth.TxLike>
    withdraw (sender: TSender, assets: bigint, receiver: TAddress, owner: TAddress): Promise<TEth.TxLike>
    withdrawable (sender: TSender, ): Promise<TEth.TxLike>
}


type TEvents = TSymbioticVaultImplTypes['Events'];
type TEventParams<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputParams']>;
type TEventArguments<TEventName extends keyof TEvents> = Partial<TEvents[TEventName]['outputArgs']>;
