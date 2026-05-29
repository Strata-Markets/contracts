import { UTest } from 'atma-utest';
import { $require } from 'dequanto/utils/$require';
import { $bigint } from 'dequanto/utils/$bigint';
import { $date } from 'dequanto/utils/$date';
import { l } from 'dequanto/utils/$logger';
import { $hh } from '../utils/$hh';
import { $tranche } from '../utils/$tranche';
import { $erc20 } from '../utils/$erc20';
import { $exitMode } from '@s/utils/$exitMode';
import { IsolatedStrategy } from '@0xc/hardhat/IsolatedStrategy/IsolatedStrategy';
import { SparkUSDCStrategy } from '@0xc/hardhat/SparkUSDCStrategy/SparkUSDCStrategy';
import { MidasStrategy } from '@0xc/hardhat/MidasStrategy/MidasStrategy';
import { Rebalancer } from '@0xc/hardhat/Rebalancer/Rebalancer';

const test = $hh.create('spkMhyperIso');

const {
    USDC,
    oracle,
    redemptionVault,
    jrtVault,
    srtVault,
    feed,
    accounting,
    strategy: _strategy,
} = await test.deploy();

const { deployer, client } = test;
const strategy = _strategy as any as IsolatedStrategy;

const juniorStrat = new SparkUSDCStrategy(await strategy.juniorStrat(), client);
const seniorStrat = new MidasStrategy(await strategy.seniorStrat(), client);
const rebalancer = new Rebalancer(await strategy.rebalancer(), client);

UTest.create({
    async $before() {
        await feed.$receipt().setRoundStaleAfter(deployer, BigInt($date.parseTimespan('5years', { get: 's' })));
        // Use a far-future timestamp so MidasStrategy never treats oracle as stale
        // when updateAccounting fires during withdrawal (block.timestamp advances past the snapshot).
        await oracle.$receipt().setRoundData(deployer, 1n, BigInt(1e8), BigInt(9_999_999_999));
        await setAPRs(0, 0);
        await accounting.$receipt().setReserveBps(deployer, 0n);
        // Clear JRT SharesCooldown lock so withdrawal tests aren't blocked by the 3-day tier lock.
        await $exitMode.set(test.tranches.sharesCooldown, test.configManager, jrtVault.address, [{ covPct: 0, feeBps: 0, lock: 0 }]);
        await test.snapshot('isolated');
    },
    async $after() {
        await test.wipe();
    },
    async $teardown() {
        await test.reset('isolated');
    },

    async 'JRT deposits route to Spark (juniorStrat)' () {
        await $erc20.mint(USDC, deployer, deployer, 100);

        const sparkBefore = await juniorStrat.totalAssets();
        await $tranche.deposit(jrtVault, deployer, USDC, 100);
        const sparkAfter = await juniorStrat.totalAssets();

        $require.gt(sparkAfter, sparkBefore, 'Spark should receive JRT deposits');
        $require.eq(await seniorStrat.totalAssets(), 0n, 'Midas should be empty after JRT-only deposit');
        l`Spark totalAssets after JRT deposit: cyan<${$bigint.toEther(sparkAfter, 6)}> USDC`;
    },

    async 'SRT deposits route to Midas (seniorStrat)' () {
        await $erc20.mint(USDC, deployer, deployer, 100);
        await $tranche.deposit(jrtVault, deployer, USDC, 80);

        const midasBefore = await seniorStrat.totalAssets();
        await $tranche.deposit(srtVault, deployer, USDC, 20);
        const midasAfter = await seniorStrat.totalAssets();

        $require.gt(midasAfter, midasBefore, 'Midas should receive SRT deposits');
        l`Midas totalAssets after SRT deposit: cyan<${$bigint.toEther(midasAfter, 6)}> USDC`;
    },

    async 'totalAssets aggregates both sub-strats' () {
        await $erc20.mint(USDC, deployer, deployer, 100);
        await $tranche.deposit(jrtVault, deployer, USDC, 80);
        await $tranche.deposit(srtVault, deployer, USDC, 20);

        const juniorAssets = await juniorStrat.totalAssets();
        const seniorAssets = await seniorStrat.totalAssets();
        const total = await strategy.totalAssets();

        $require.eq(total, juniorAssets + seniorAssets, 'totalAssets must equal sum of sub-strats');
        l`Total: cyan<${$bigint.toEther(total, 6)}> = Spark cyan<${$bigint.toEther(juniorAssets, 6)}> + Midas cyan<${$bigint.toEther(seniorAssets, 6)}>`;
    },

    async 'totalAssetsByTranche splits JRT/SRT assets' () {
        await $erc20.mint(USDC, deployer, deployer, 100);
        await $tranche.deposit(jrtVault, deployer, USDC, 80);
        await $tranche.deposit(srtVault, deployer, USDC, 20);

        const { jrtAssets, srtAssets } = await strategy.totalAssetsByTranche();

        $require.eq($bigint.toEther(jrtAssets, 6), 80, 'JRT assets = Spark holdings');
        $require.eq($bigint.toEther(srtAssets, 6), 20, 'SRT assets = Midas holdings');
        l`JRT: cyan<${$bigint.toEther(jrtAssets, 6)}> SRT: cyan<${$bigint.toEther(srtAssets, 6)}>`;
    },

    async 'SRT withdrawal borrows from Spark first (records toJunior debt)' () {
        await $erc20.mint(USDC, deployer, deployer, 200);
        await $tranche.deposit(jrtVault, deployer, USDC, 150);
        await $tranche.deposit(srtVault, deployer, USDC, 50);

        $require.eq((await strategy.debts()).toJunior, 0n, 'No debt before withdrawal');

        await $tranche.withdraw(srtVault, deployer, USDC, 30);

        const { toJunior: debt } = await strategy.debts();
        $require.gt(debt, 0n, 'SRT should owe JRT after borrowing from Spark');
        l`toJunior debt after SRT withdrawal: cyan<${$bigint.toEther(debt, 6)}> USDC`;
    },

    async 'JRT withdrawal borrows from Midas first (records toSenior debt)' () {
        await $erc20.mint(USDC, deployer, deployer, 200);
        await $tranche.deposit(jrtVault, deployer, USDC, 100);
        await $tranche.deposit(srtVault, deployer, USDC, 100);

        $require.eq((await strategy.debts()).toSenior, 0n, 'No debt before withdrawal');

        // JRT borrows from Midas (cross-strat, skip cooldown) → instant
        await $tranche.withdraw(jrtVault, deployer, USDC, 50);

        const { toSenior: debt } = await strategy.debts();
        $require.gt(debt, 0n, 'JRT should owe SRT after borrowing from Midas');
        l`toSenior debt after JRT withdrawal: cyan<${$bigint.toEther(debt, 6)}> USDC`;
    },

    async 'Rebalance Spark→Midas: instant, clears toSenior debt' () {
        await $erc20.mint(USDC, deployer, deployer, 200);
        await $tranche.deposit(jrtVault, deployer, USDC, 100);
        await $tranche.deposit(srtVault, deployer, USDC, 100);

        await $tranche.withdraw(jrtVault, deployer, USDC, 50);
        const { toSenior: debtBefore } = await strategy.debts();
        $require.gt(debtBefore, 0n, 'Debt must exist before rebalance');

        // Spark (0) → Midas (1): Spark is liquid so the whole rebalance completes in one tx
        await rebalancer.$receipt().initiateRebalance(
            deployer,
            0n, 1n,
            USDC.address, USDC.address,
            debtBefore
        );

        $require.eq((await strategy.debts()).toSenior, 0n, 'toSenior debt cleared after Spark→Midas rebalance');
        l`Rebalance complete: debt cyan<${$bigint.toEther(debtBefore, 6)}> → 0`;
    },

    async 'Rebalance Midas→Spark: async, clears toJunior debt after completeRebalance' () {
        await $erc20.mint(USDC, deployer, deployer, 200);
        await $tranche.deposit(jrtVault, deployer, USDC, 150);
        await $tranche.deposit(srtVault, deployer, USDC, 50);

        await $tranche.withdraw(srtVault, deployer, USDC, 30);
        const { toJunior: debtBefore } = await strategy.debts();
        $require.gt(debtBefore, 0n, 'Debt must exist before rebalance');

        // Midas (1) → Spark (0): withdraw as USDC (baseAsset path) to avoid MidasStrategy
        // calling cdo.isJrt — IsolatedStrategy is the cdo here and doesn't implement isJrt.
        await rebalancer.$receipt().initiateRebalance(
            deployer,
            1n, 0n,
            USDC.address, USDC.address,
            debtBefore
        );

        // Debt zeroed immediately: in-flight assets are credited to JR via pendingToStrat
        $require.eq((await strategy.debts()).toJunior, 0n, 'Debt zeroed once rebalance is in-flight');
        $require.eq(await rebalancer.pendingCount(), 1n, '1 pending rebalance');

        // Advance time and fulfill the Midas redemption
        await test.mine('3days');
        const requestId = await redemptionVault.nextRequestId();
        await redemptionVault.$receipt().fulfillRequest(deployer, requestId - 1n);

        // Complete rebalance: Rebalancer finalizes unstakeCooldown and deposits to Spark
        await rebalancer.$receipt().completeRebalance(deployer, 0n);

        $require.eq((await strategy.debts()).toJunior, 0n, 'toJunior debt cleared after Midas→Spark rebalance completes');
        $require.eq(await rebalancer.pendingCount(), 0n, 'No pending rebalances');
        l`Async rebalance complete: debt cyan<${$bigint.toEther(debtBefore, 6)}> → 0`;
    },
});


async function setAPRs(aprTarget: number, aprBase: number) {
    const block = await client.getBlock('latest');
    await feed.$receipt().updateRoundData(deployer, aprTarget * 10 ** 12, aprBase * 10 ** 12, block.timestamp);
    await (accounting as any).$receipt().onAprChanged(deployer);
}
