import { DeploymentsBase } from '@s/deployments/DeploymentsBase';
import { TEth } from 'dequanto/models/TEth';
import { $hh } from 'test/tranches/utils/$hh';


export interface ITestHelperConstructor {
    new (test: $hh.Test<DeploymentsBase>): ITestHelper;
}

export interface ITestHelper {

    // Perform any necessary setup for the strategy
    setup? (): Promise<void>

    // Distribute rewards to simulate underlying strategy behavior, such as total asset or price increases.
    distributeRewards (params: {
        assetsBefore?: bigint
        dt: number | string
        amount?: number
        apr?: bigint | number
    }): Promise<void | {
        navGainExpect?: bigint
    }>

    // Returns all tokens accepted by the strategy.
    getStrategyTokensIn (): Promise<{
        address: TEth.Address
    }[]>

    // Returns all redeemable tokens, including cooldown information when relevant.
    getStrategyTokensOut (): Promise<{
        address: TEth.Address,
        cooldown?: 'unstake' | 'erc20' | 'shares' | undefined
    }[]>

    // Returns the strategy's main tokens:
    // base: the primary accounting asset.
    // receipt: the token received by the strategy.
    getStrategyTokensMain (): Promise<{ base: TEth.Address, receipt: TEth.Address }>

    // Returns the exit fee for the underlying token, if any.
    getUnderlyingExitFee (tokenOut: TEth.Address): Promise<number>

    // Returns the unstake period for tokens that require unstaking.
    getUnderlyingUnstakePeriod(): Promise<string>

    // Finalizes an unstake request when the underlying protocol requires a prior step.
    // Example: Midas must approve the request first.
    finalizeUnderlyingUnstake(account: TEth.Address): Promise<void>


    getSanityAprTarget?(): [min: number, max: number]
    getSanityAprBase?(): [min: number, max: number]
}

