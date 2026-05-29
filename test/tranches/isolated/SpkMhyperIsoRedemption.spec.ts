import { UTest } from 'atma-utest';
import { $require } from 'dequanto/utils/$require';
import { $bigint } from 'dequanto/utils/$bigint';
import { $date } from 'dequanto/utils/$date';
import { l } from 'dequanto/utils/$logger';
import { $hh } from '../utils/$hh';
import { $tranche } from '../utils/$tranche';
import { $erc20 } from '../utils/$erc20';
import { IsolatedStrategy } from '@0xc/hardhat/IsolatedStrategy/IsolatedStrategy';

const test = $hh.create('spkMhyperIso', { cdoInfo: { pfx: 'HhSpkMhyperIso' } });

const {
    USDC,
    oracle,
    mHYPER,
    redemptionVault,
    jrtVault,
    srtVault,
    feed,
    accounting,
    strategy: _strategy,
} = await test.deploy({ initialDeposit: false });

const { deployer, client } = test;
const strategy = _strategy as any as IsolatedStrategy;

UTest.create({
    async $before() {
        await feed.$receipt().setRoundStaleAfter(deployer, BigInt($date.parseTimespan('5years', { get: 's' })));
        await oracle.$receipt().setRoundData(deployer, 1n, BigInt(1e8), BigInt(9_999_999_999));
        await setAPRs(0, 0);
        await (accounting as any).$receipt().setReserveBps(deployer, 0n);
        await test.snapshot('redemption');
    },
    async $after() {
        await test.wipe();
    },
    async $teardown() {
        await test.reset('redemption');
    },

    // SRT borrows from Spark (JRT's strat) — always instant since Spark is liquid.
    async 'SRT redeems instantly via Spark' () {
        await $erc20.mint(USDC, deployer, deployer, 110);
        await $tranche.deposit(jrtVault, deployer, USDC, 100);
        await $tranche.deposit(srtVault, deployer, USDC, 10);

        const usdcBefore = await USDC.balanceOf(deployer.address);
        await $tranche.withdraw(srtVault, deployer, USDC, 5);
        const usdcAfter = await USDC.balanceOf(deployer.address);

        $require.gt(usdcAfter, usdcBefore, 'SRT redeem delivers USDC immediately');
        $require.gt((await strategy.debts()).toJunior, 0n, 'Debt recorded: SRT borrowed from Spark');
        l`SRT redeemed: USDC received cyan<${$bigint.toEther(usdcAfter - usdcBefore, 6)}>`;
    },

    // JRT borrows from Midas (SRT's strat) — cross-strat borrow skips the Midas cooldown.
    // JRT borrows from Midas (SRT's strat) via cross-strat borrow.
    // shouldSkipCooldown=true skips the erc20Cooldown (mToken path) but Midas's USDC
    // withdrawal always goes through unstakeCooldown, which is inherently async.
    async 'JRT redeems via Midas cross-strat (async, debt recorded)' () {
        await $erc20.mint(USDC, deployer, deployer, 200);
        await $tranche.deposit(jrtVault, deployer, USDC, 100);
        await $tranche.deposit(srtVault, deployer, USDC, 100);

        const usdcBefore = await USDC.balanceOf(deployer.address);
        await $tranche.withdraw(jrtVault, deployer, USDC, 50);
        const usdcAfter = await USDC.balanceOf(deployer.address);

        $require.eq(usdcAfter, usdcBefore, 'No USDC arrives immediately — Midas is always async');
        $require.gt((await strategy.debts()).toSenior, 0n, 'Debt recorded: JRT borrowed from Midas');

        const { pending } = await test.tranches.unstakeCooldown.balanceOf(mHYPER.address, deployer.address);
        $require.gt(pending, 0n, 'USDC queued in unstakeCooldown');
        l`Pending in cooldown: cyan<${$bigint.toEther(pending, 6)}> USDC`;

        // Complete the async portion
        await test.mine('3days');
        const requestId = await redemptionVault.nextRequestId();
        await redemptionVault.$receipt().fulfillRequest(deployer, requestId - 1n);
        await test.tranches.unstakeCooldown.$receipt().finalize(deployer, mHYPER.address, deployer.address);

        const usdcFinal = await USDC.balanceOf(deployer.address);
        $require.gte(usdcFinal - usdcBefore, BigInt(49e6), 'Full ~50 USDC received after cooldown');
        l`JRT redeemed after cooldown: cyan<${$bigint.toEther(usdcFinal - usdcBefore, 6)}> USDC`;
    },

    // When SRT needs more than Spark holds, it falls back to Midas (its own strat, no skip) — async.
    async 'SRT falls back to Midas when Spark is insufficient (async cooldown)' () {
        await $erc20.mint(USDC, deployer, deployer, 110);
        // Small JRT deposit → only 10 USDC in Spark
        await $tranche.deposit(jrtVault, deployer, USDC, 10);
        await $tranche.deposit(srtVault, deployer, USDC, 100);

        const usdcBefore = await USDC.balanceOf(deployer.address);
        // SRT redeems 60: Spark covers 10 instantly; remaining 50 queued in Midas cooldown
        await $tranche.withdraw(srtVault, deployer, USDC, 60);
        const usdcAfter = await USDC.balanceOf(deployer.address);

        // Only the Spark portion arrives immediately
        $require.lt(usdcAfter - usdcBefore, BigInt(60e6), 'Only partial USDC received instantly');

        // Remaining is pending in unstakeCooldown
        const { pending } = await test.tranches.unstakeCooldown.balanceOf(mHYPER.address, deployer.address);
        $require.gt(pending, 0n, 'Remainder queued as Midas cooldown');
        l`Instant: cyan<${$bigint.toEther(usdcAfter - usdcBefore, 6)}> Pending: cyan<${$bigint.toEther(pending, 6)}>`;

        // Complete the async portion
        await test.mine('3days');
        const requestId = await redemptionVault.nextRequestId();
        await redemptionVault.$receipt().fulfillRequest(deployer, requestId - 1n);
        await test.tranches.unstakeCooldown.$receipt().finalize(deployer, mHYPER.address, deployer.address);

        const usdcFinal = await USDC.balanceOf(deployer.address);
        $require.gte(usdcFinal - usdcBefore, BigInt(59e6), 'Full ~60 USDC received after cooldown');
        l`Total USDC received: cyan<${$bigint.toEther(usdcFinal - usdcBefore, 6)}>`;
    },

    async 'SRT can redeem full balance if Spark has enough liquidity' () {
        await $erc20.mint(USDC, deployer, deployer, 110);
        await $tranche.deposit(jrtVault, deployer, USDC, 100);
        await $tranche.deposit(srtVault, deployer, USDC, 10);

        const usdcBefore = await USDC.balanceOf(deployer.address);

        // Withdraw via USDC amount rather than full share redemption to stay above MIN_SHARES
        await $tranche.withdraw(srtVault, deployer, USDC, 9);

        const usdcAfter = await USDC.balanceOf(deployer.address);
        $require.gt(usdcAfter, usdcBefore, 'SRT redemption returns USDC immediately');
        // No cooldown queued — SRT exits via Spark, which is always liquid
        const { pending } = await test.tranches.unstakeCooldown.balanceOf(mHYPER.address, deployer.address);
        $require.eq(pending, 0n, 'No cooldown pending: Spark is liquid');
        l`SRT redeem: cyan<${$bigint.toEther(usdcAfter - usdcBefore, 6)}> USDC`;
    },
});


async function setAPRs(aprTarget: number, aprBase: number) {
    const block = await client.getBlock('latest');
    await feed.$receipt().updateRoundData(deployer, aprTarget * 10 ** 12, aprBase * 10 ** 12, block.timestamp);
    await (accounting as any).$receipt().onAprChanged(deployer);
}
