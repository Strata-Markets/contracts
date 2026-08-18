import { ITestHelper } from '../interfaces/ITestHelper';
import { $date } from 'dequanto/utils/$date';
import { $bigint } from 'dequanto/utils/$bigint';
import { TEth } from 'dequanto/models/TEth';
import { type $hh } from 'test/tranches/utils/$hh';
import { NestOpalDeployments } from '@s/deployments/NestOpalDeployments';
import { MockNestAccountant } from '@0xc/hardhat/MockNestAccountant/MockNestAccountant';
import { Eth } from '@s/platforms/Eth';

const SECONDS_PER_YEAR = 365 * 24 * 60 * 60;

export class NestOpalTestHelper implements ITestHelper {
    constructor (public test: $hh.Test<NestOpalDeployments>) {

    }
    async getStrategyTokensMain() {
        const { base, nOPAL } = await this.test.factory.ensureUnderlying();
        return {
            base: base.address,
            receipt: nOPAL.address,
        };
    }


    async getStrategyTokensIn() {
        const { nOPAL } = await this.test.factory.ensureUnderlying();
        return [
            // base,
            nOPAL
        ];
    }
    async getStrategyTokensOut() {
        const { nOPAL } = await this.test.factory.ensureUnderlying();
        return [
            // {
            //     ...base,
            //     cooldown: 'unstake' as const
            // },
            nOPAL
        ];
    }

    async distributeRewards (params: {
        assetsBefore?: bigint
        dt: number | string
        amount?: number
        apr?: number | bigint
    }) {
        let { nOPAL } = await this.test.factory.ensureUnderlying();
        let { strategy } = await this.test.factory.ensureCDO();
        let shares = await nOPAL.balanceOf(strategy.address);
        let accountant = new MockNestAccountant(Eth.nestopal.accountant, this.test.client);

        let dt = typeof params.dt === 'number'
            ? params.dt
            : $date.parseTimespan(params.dt, { get:'s' });

        let { exchangeRate: price } = await accountant.accountantState();

        if (params.apr != null) {
            let apr = typeof params.apr === 'bigint' ? params.apr : $bigint.toWei(params.apr, 12);
            let delta = price * apr * BigInt(dt) / BigInt(1e12 * SECONDS_PER_YEAR);
            let nextPrice = price + delta;

            // e.g. https://etherscan.io/tx/0x1329a75912bcb9481f7b2259cea0e6d1319acfee12635aae8b9dac4995001fa8
            let updater = {
                address: `0x450545F4cC7425DDe582091a7fe9E63471Af1045`,
                type: 'impersonated'
            } as TEth.IAccount;

            await accountant.$receipt().updateExchangeRate(
                updater,
                nextPrice
            );
            const totalAssetsAfter = shares * nextPrice / BigInt(1e6);
            return {
                navGainExpect: totalAssetsAfter - params.assetsBefore
            };
        }
    }

    async getUnderlyingExitFee (tokenOut: TEth.Address) {
        return 0;
    }

    async getUnderlyingUnstakePeriod () {
        return '3days';
    }

    async finalizeUnderlyingUnstake () {

    }

    getSanityAprTarget() {
        return [0, 0.1] as [number, number];
    }
    getSanityAprBase() {
        return [0, 0.1] as [number, number];
    }
}
