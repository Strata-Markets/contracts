import { UTest } from 'atma-utest';
import { $require } from 'dequanto/utils/$require';
import { $bigint } from 'dequanto/utils/$bigint';
import { l } from 'dequanto/utils/$logger';
import { $hh } from '../utils/$hh';
import { $tranche } from '../utils/$tranche';
import { $erc20 } from '../utils/$erc20';
import { DiscreteAccounting } from '@0xc/hardhat/DiscreteAccounting/DiscreteAccounting';

const test = $hh.create('spkMhyperIso');

const {
    USDC,
    oracle,
    jrtVault,
    srtVault,
    feed,
    accounting,
    strategy,
} = await test.deploy();

const { deployer, client } = test;
const acc = accounting as any as DiscreteAccounting;

UTest.create({
    async $before() {
        await feed.$receipt().setRoundStaleAfter(deployer, BigInt(5 * 365 * 24 * 3600));
        await oracle.$receipt().setRoundData(deployer, 1n, BigInt(1e8), BigInt(9_999_999_999));
        await setAPRs(0, 0);
        await acc.$receipt().setReserveBps(deployer, 0n);
        await test.snapshot('deposits');
    },
    async $after() {
        await test.wipe();
    },
    async $teardown() {
        await test.reset('deposits');
    },

    async 'should deposit USDC to JRT vault' () {
        await $erc20.mint(USDC, deployer, deployer, 100);

        await $tranche.deposit(jrtVault, deployer, USDC, 100);

        const shares = await jrtVault.balanceOf(deployer.address);
        $require.gt(shares, 0n, 'JRT shares minted');

        const totalAssets = await jrtVault.totalAssets();
        $require.eq(totalAssets, BigInt(100e6), 'JRT totalAssets = 100 USDC');

        const totalSupply = await jrtVault.totalSupply();
        $require.eq(totalSupply, BigInt(100e18), '1:1 shares at init');
        l`JRT: assets cyan<${$bigint.toEther(totalAssets, 6)}> shares cyan<${$bigint.toEther(totalSupply)}>`;
    },

    async 'should deposit USDC to SRT vault' () {
        await $erc20.mint(USDC, deployer, deployer, 100);
        await $tranche.deposit(jrtVault, deployer, USDC, 80);

        await $tranche.deposit(srtVault, deployer, USDC, 20);

        const shares = await srtVault.balanceOf(deployer.address);
        $require.gt(shares, 0n, 'SRT shares minted');

        const totalAssets = await srtVault.totalAssets();
        $require.eq(totalAssets, BigInt(20e6), 'SRT totalAssets = 20 USDC');
        l`SRT: assets cyan<${$bigint.toEther(totalAssets, 6)}> shares cyan<${$bigint.toEther(await srtVault.totalSupply())}>`;
    },

    async 'strategy totalAssets = JRT + SRT TVL' () {
        await $erc20.mint(USDC, deployer, deployer, 100);
        await $tranche.deposit(jrtVault, deployer, USDC, 80);
        await $tranche.deposit(srtVault, deployer, USDC, 20);

        const stratTotal = await strategy.totalAssets();
        $require.eq(stratTotal, BigInt(100e6), 'Strategy holds full 100 USDC');
    },

    async 'APR flow: yield distributes between JRT and SRT' () {
        await $erc20.mint(USDC, deployer, deployer, 400);

        let jrtTVL = 200;
        let srtTVL = 200;
        await $tranche.deposit(jrtVault, deployer, USDC, jrtTVL);
        await $tranche.deposit(srtVault, deployer, USDC, srtTVL);

        // aprBase=2% (what Spark earns), aprTarget=1% (SRT target floor)
        await setAPRs(0.01, 0.02);
        await test.mine('1year');

        // Trigger accounting update
        await setAPRs(0.01, 0.02);

        const srtAssets = await srtVault.totalAssets();
        const jrtAssets = await jrtVault.totalAssets();

        // Total projected yield = aprBase * totalTVL = 2% * 400 = 8 USDC (reserve=0)
        $require.eq(srtAssets + jrtAssets, BigInt(408e6), 'Total yield = aprBase * TVL (conservation)');
        // SRT earns above its 1% target floor (risk-adjusted aprSrt > aprTarget given these params)
        $require.gte(srtAssets, $bigint.toWei(srtTVL * 1.01, 6), 'SRT earns ≥ aprTarget floor (1%)');
        // JRT absorbs the excess: always earns more than SRT
        $require.gt(jrtAssets, srtAssets, 'JRT earns more than SRT');
        l`After 1yr: JRT cyan<${$bigint.toEther(jrtAssets, 6)}> SRT cyan<${$bigint.toEther(srtAssets, 6)}>`;
    },

    async 'maxDeposit for SRT is bounded by JRT coverage ratio' () {
        await $erc20.mint(USDC, deployer, deployer, 200);
        await $tranche.deposit(jrtVault, deployer, USDC, 100);

        const jrtSrtBuffer = $bigint.toEther(await acc.minimumJrtSrtRatioBuffer());
        const maxSrt = $bigint.multWithFloat(await jrtVault.totalAssets(), 1 / jrtSrtBuffer);
        const maxSrtFact = await acc.maxDeposit(false);

        $require.eq(maxSrt, maxSrtFact, 'maxDeposit(SRT) matches JRT-coverage ratio');
        l`JRT=100 → maxSRT=cyan<${$bigint.toEther(maxSrtFact, 6)}> (buffer cyan<${jrtSrtBuffer}>)`;
    },
});


async function setAPRs(aprTarget: number, aprBase: number) {
    const block = await client.getBlock('latest');
    await feed.$receipt().updateRoundData(deployer, aprTarget * 10 ** 12, aprBase * 10 ** 12, block.timestamp);
    await acc.$receipt().onAprChanged(deployer);
}
