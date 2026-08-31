import { ITestHelper } from '../interfaces/ITestHelper';
import { $date } from 'dequanto/utils/$date';
import { $bigint } from 'dequanto/utils/$bigint';
import { TEth } from 'dequanto/models/TEth';
import { type $hh } from 'test/tranches/utils/$hh';
import { SaturnDeployments } from '@s/deployments/SaturnDeployments';
import { ERC20 } from 'dequanto/prebuilt/openzeppelin/ERC20';
import { $erc20 } from '@test/tranches/utils/$erc20';
import { $bigfloat } from 'dequanto/utils/$bigfloat';
import { IWithdrawalQueueERC721 } from '@0xc/hardhat/IWithdrawalQueueERC721/IWithdrawalQueueERC721';
import { SaturnCooldownRequestImpl } from '@0xc/hardhat/SaturnCooldownRequestImpl/SaturnCooldownRequestImpl';

const SECONDS_PER_YEAR = 365 * 24 * 60 * 60;

export class SaturnTestHelper implements ITestHelper {

    static forked = 24925000;

    static cdoInfo = {
        jrt: {
            sharesCooldown: [
                { covPct: 15, feeBps: 0, lock: '28days' },
                { covPct: 30, feeBps: 10, lock: '14days' },
                // No default shares lock in test env
                { covPct: 0, feeBps: 20, lock: 0 },
            ]
        },
    }

    constructor (public test: $hh.Test<SaturnDeployments>) {}

    async getStrategyTokensMain() {
        const { base, sUSDat } = await this.test.factory.ensureUnderlying();
        return {
            base: base.address,
            receipt: sUSDat.address,
        };
    }


    async getStrategyTokensIn() {
        const { strategy } = this.test.tranches;
        const tokens = await strategy.getSupportedTokens();
        return tokens.map(address => ({ address }))
    }
    async getStrategyTokensOut() {
        const { base, sUSDat } = await this.test.factory.ensureUnderlying();
        return [
            sUSDat,
            {
                ...base,
                cooldown: 'unstake' as const
            },
        ];
    }

    async distributeRewards (params: {
        assetsBefore?: bigint
        dt: number | string
        amount?: number
        apr?: number | bigint
    }) {
        let { strategy, sUSDat } = await this.test.tranches;

        let dt = typeof params.dt === 'number'
            ? params.dt
            : $date.parseTimespan(params.dt, { get:'s' });

        let assets = params.assetsBefore;

        if (params.apr != null) {

            let apr = typeof params.apr === 'bigint' ? params.apr : $bigint.toWei(params.apr, 12);

            const weiPerDt = $bigfloat
                .from(assets)
                .mul(apr)
                .mul(dt)
                .div(SECONDS_PER_YEAR)
                .div(10**12)
                .toBigInt();

            const nextAssets = assets + weiPerDt;
            const shares = await strategy.convertToTokens(sUSDat.address, nextAssets, 1);

            await $erc20.setBalanceAny(sUSDat as any as ERC20, strategy.address, shares);
            return;
        }
    }

    async getUnderlyingExitFee (tokenOut: TEth.Address) {
        return 0;
        // sUSDat has no exit fee for withdrawals (only deposit fee).
        // The 0.1% deposit fee is handled in SaturnStrategy.deposit().
    }

    async getUnderlyingUnstakePeriod () {
        // finalize by saturn earlier (otherwise strc oracle is stale after 7days)
        return '1h';
    }

    getSanityAprBase (): [number, number] {
        // V2: getAPRbase() returns 0 — STRCon yield is continuous mark-to-market
        return [0, 0.30];
    }

    async finalizeUnderlyingUnstake (acc: TEth.Address) {
        // V2: WithdrawalQueueERC721 requires off-chain operator processing.
        // processRequests is simplified in V2 — just tokenIds, vault handles pricing.
        const { sUSDat } = await this.test.factory.ensureUnderlying();
        const SaturnWithdrawProcessor = {
            address: `0x09D6E34cE24D54890fF0BC6a090b5f880F8C729f`,
            type: 'impersonated'
        } as TEth.IAccount;

        const { unstakeCooldown } = this.test.tranches;
        const req = await unstakeCooldown.activeRequests(sUSDat.address, acc, 0n);
        const proxy = new SaturnCooldownRequestImpl(req.proxy, this.test.client);
        const id = await proxy.requestId();

        // V2: get the separate WithdrawalQueueERC721 contract address
        const queueAddr = await sUSDat.getWithdrawalQueue();
        const queue = new IWithdrawalQueueERC721(queueAddr, this.test.client);

        // V2: processRequests just takes tokenIds — vault handles pricing internally
        await queue.$receipt().processRequests(SaturnWithdrawProcessor, [
            id
        ]);

        // Move forward 7 days to finalize our unstake request
        await this.test.mine('7days');

    }

}
