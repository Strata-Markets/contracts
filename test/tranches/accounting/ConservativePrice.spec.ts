import { UTest } from 'atma-utest';
import { $hh } from '../utils/$hh';
import { $erc4626 } from '../utils/$erc4626';
import { $require } from 'dequanto/utils/$require';
import { $test } from '../utils/$test';
import { $apr } from '@s/utils/$apr';
import { $bigint } from 'dequanto/utils/$bigint';

const test = await $hh.deploy('mhyper', {
    cdoInfo: {
        fees: {
            performanceFee: 0,
        },
        minimumJrtSrtRatio: 0,
        minimumJrtSrtRatioBuffer: 0.00001,
        jrt: {
            sharesCooldown: [
                { covPct: 0, feeBps: 0, lock: 0 },
            ],
        } as any,
        srt: {
            sharesCooldown: [
                { covPct: 0, feeBps: 0, lock: 0 },
            ],
        } as any,
        riskPremium: {
            x: 0.5,
            y: 0,
            k: 1
        },
        ContractVersions: {
            accounting: 'dys',
            accountingOptions: {
                useConservativePrice: true
            },
            unstakeImpl: 'MockInstant'
        }
    },
});

const { deployer, client} = test;
const { feed, srtVault, jrtVault, cdo, accounting } = test.tranches;
const { oracle } = await test.factory.ensureUnderlying();

UTest.create({
    async $before () {
        await feed.$receipt().updateRoundData(
            deployer,
            0,
            .1e12,
            (await client.getBlock('latest')).timestamp
        );
        await $erc4626.deposit(jrtVault, deployer, 1000);
        await $erc4626.deposit(srtVault, deployer, 1000);
        await test.snapshot('conservative-redemption');
    },
    async $teardown () {
        await test.reset('conservative-redemption');
    },
    async $after() {
        await test.wipe();
    },
    async 'price per share: projected vs unprojected' () {
        await client.debug.mine('1year');

        // BaseAPR = 10%; RiskPremium = 50%;
        $test.compare(
            await cdo.pricePerShare(srtVault.address),
            1.05,
        );
        $require.eq(
            await cdo.pricePerShareUnprojected(srtVault.address),
            BigInt(1e18)
        );
        $test.compare(
            await cdo.pricePerShare(jrtVault.address),
            1.15,
        );
        $require.eq(
            await cdo.pricePerShareUnprojected(jrtVault.address),
            BigInt(1e18)
        );

        const oraclePrice = $apr.calcPrice({
            price: 1,
            decimals: 8,
            dt: '1year',
            apr: 0.1
        });
        await oracle.$receipt().setRoundData(deployer, oraclePrice);
        await $erc4626.deposit(jrtVault, deployer, 1n);

        // After reconciliation
        $test.compare(
            await cdo.pricePerShare(srtVault.address),
            1.05,
        );
        $test.compare(
            await cdo.pricePerShareUnprojected(srtVault.address),
            1.05,
        );
        $test.compare(
            await cdo.pricePerShare(jrtVault.address),
            1.15,
        );
        $test.compare(
            await cdo.pricePerShareUnprojected(jrtVault.address),
            1.15,
        );
    },
    async 'erc4626: preview functions' () {
        await client.debug.mine('1year');

        const [
            srtShares,
            jrtShares
        ] = await Promise.all([
            srtVault.balanceOf(deployer.address),
            jrtVault.balanceOf(deployer.address),
        ]);
        $test.compare(
            await srtVault.maxWithdraw(deployer.address),
            1000,
            6
        );
        $test.compare(
            await jrtVault.maxWithdraw(deployer.address),
            1000,
            6
        );
        $test.compare(
            await srtVault.previewRedeem(srtShares),
            1000,
            6
        );
        $test.compare(
            await jrtVault.previewRedeem(jrtShares),
            1000,
            6
        );
        $test.compare(
            await srtVault.previewWithdraw(BigInt(1000e6)),
            srtShares,
        );
        $test.compare(
            await jrtVault.previewWithdraw(BigInt(1000e6)),
            jrtShares,
        );

        const oraclePrice = $apr.calcPrice({
            price: 1,
            decimals: 8,
            dt: '1year',
            apr: 0.1
        });
        await oracle.$receipt().setRoundData(deployer, oraclePrice);
        await $erc4626.deposit(jrtVault, deployer, 1n);

        $test.compare(
            await srtVault.maxWithdraw(deployer.address),
            1000 * 1.05,
            6
        );
        $test.compare(
            await jrtVault.maxWithdraw(deployer.address),
            1000 * 1.15,
            6
        );
        $test.compare(
            await srtVault.previewRedeem(srtShares),
            1000 * 1.05,
            6
        );
        $test.compare(
            await jrtVault.previewRedeem(jrtShares),
            1000 * 1.15,
            6
        );
        $test.compare(
            await srtVault.previewWithdraw($bigint.toWei(1000 * 1.05, 6)),
            srtShares,
        );
        $test.compare(
            await jrtVault.previewWithdraw($bigint.toWei(1000 * 1.15, 6)),
            jrtShares,
        );
    },
    async 'redeem' () {
        await client.debug.mine('0.5year');
        const [
            srtShares,
            jrtShares
        ] = await Promise.all([
            srtVault.balanceOf(deployer.address),
            jrtVault.balanceOf(deployer.address),
        ]);

        $test.compare(
            await cdo.pricePerShare(srtVault.address),
            1.025,
        );
        $test.compare(
            await $erc4626.redeem(srtVault, deployer, srtShares / 2n),
            500,
            6,
            `Redemption should exclude projection`
        );

        $test.compare(
            await cdo.pricePerShare(srtVault.address),
            1.025,
            18,
            `The projected portion should be unwound to Junior.`
        );
        $test.compare(
            await cdo.pricePerShareUnprojected(srtVault.address),
            1,
        );
        await client.debug.mine('0.5year');
        const oraclePrice = $apr.calcPrice({
            price: 1,
            decimals: 8,
            dt: '1year',
            apr: 0.1
        });

        await oracle.$receipt().setRoundData(deployer, oraclePrice);
        await $erc4626.deposit(jrtVault, deployer, 1n);

        // PnL = 150
        // srtFactor = 0.5
        // srtNavTimeNet_ / navTimeNet_ = 236520025 / 551880095 = 0.4285714
        // srtPnLRealized = 150 * 0.5 * 0.4285714 = 32.142855
        // SRT NAV = 500 + 32.142855 = 532.142855
        // SRT price = 532.142855 / 500 = 1.06428571
        // JRT NAV = 1000 + (150 - 32.142855) = 1117.857145
        // JRT price = 1117.857145 / 1000 = 1.11785714
        $test.compare(
            await cdo.pricePerShare(srtVault.address),
            1.064,
        );
        $test.compare(
            await cdo.pricePerShare(jrtVault.address),
            1.11785714,
        );

        $test.compare(
            await $erc4626.redeem(srtVault, deployer, srtShares / 4n),
            250 * 1.06428571,
            6,
            `Redemption should include reconciled rewards`
        );
    }
});
