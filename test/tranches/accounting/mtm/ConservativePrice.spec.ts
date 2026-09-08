import { UTest } from 'atma-utest';
import { $hh } from '../../utils/$hh';
import { $erc4626 } from '../../utils/$erc4626';
import { $test } from '../../utils/$test';
import { $bigint } from 'dequanto/utils/$bigint';
import { MockMTMStrategy } from '@0xc/hardhat/MockMTMStrategy/MockMTMStrategy';
import { $date } from 'dequanto/utils/$date';
import { MTMAccounting } from '@0xc/hardhat/MTMAccounting/MTMAccounting';

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
            accounting: 'mtm',
            accountingOptions: {
                useConservativePrice: true,
                useMTMProjection: true,
                useNavAtReconciliation: true,
            },
            unstakeImpl: 'MockInstant',
            strategyImpl: 'MockMTMStrategy',
        }
    },
});

const { deployer, client} = test;
const { feed, srtVault, jrtVault, cdo, accounting, strategy } = test.tranches;
const { oracle } = await test.factory.ensureUnderlying();
const mockStrategy = strategy as any as MockMTMStrategy;
const mockAccounting = accounting as any as MTMAccounting;

UTest.create({
    async $before () {
        await feed.$receipt().updateRoundData(
            deployer,
            0,
            0,
            (await client.getBlock('latest')).timestamp
        );
        await $erc4626.deposit(jrtVault, deployer, 1000);
        await $erc4626.deposit(srtVault, deployer, 1000);
        await mockStrategy.$receipt().setEpochDuration(
            deployer,
            BigInt($date.parseTimespan('365days', { get: 's' }))
        );
        await test.snapshot('conservative-redemption');
    },
    async $teardown () {
        await test.reset('conservative-redemption');
    },
    async $after() {
        await test.wipe();
    },
    async 'price per share: projected vs settled' () {
        await client.debug.mine('.5year');

        await mockStrategy.$receipt().setTotalAssets(deployer, BigInt(4000e6));


        // RiskPremium = 50%; MTM Rewards: 100%
        $test.compare(
            await cdo.pricePerShare(srtVault.address),
            1.50,
        );
        $test.compare(
            await cdo.pricePerShareSettled(srtVault.address),
            1.00,
        );
        $test.compare(
            await cdo.pricePerShare(jrtVault.address),
            2.50,
        );
        $test.compare(
            await cdo.pricePerShareSettled(jrtVault.address),
            1.00,
        );

        $test.compare(
            await jrtVault.maxWithdraw(deployer.address),
            1000,
            6,
            'Redemptions at epoch NAV'
        );

        await client.debug.mine('.6year');

        // After reconciliation
        $test.compare(
            await cdo.pricePerShare(srtVault.address),
            1.50,
        );
        $test.compare(
            await cdo.pricePerShareSettled(srtVault.address),
            1.50,
        );
        $test.compare(
            await cdo.pricePerShare(jrtVault.address),
            2.50,
        );
        $test.compare(
            await cdo.pricePerShareSettled(jrtVault.address),
            2.50,
        );

        $test.compare(
            await srtVault.maxWithdraw(deployer.address),
            1500,
            6,
            'SRT redemptions at reconciled NAV'
        );
        $test.compare(
            await jrtVault.maxWithdraw(deployer.address),
            2500,
            6,
            'JRT redemptions at reconciled NAV'
        );
    },

    async 'preview: conservative deposit and withdraw prices' () {
        await client.debug.mine('.5year');
        await mockStrategy.$receipt().setTotalAssets(deployer, BigInt(4000e6));

        // Deposits use max(epoch PPS, MTM PPS).
        $test.compare(
            await srtVault.previewDeposit(BigInt(1000e6)),
            1000 / 1.5,
        );
        $test.compare(
            await jrtVault.previewDeposit(BigInt(1000e6)),
            1000 / 2.5,
        );

        // Redemptions use min(epoch PPS, MTM PPS).
        $test.compare(
            await srtVault.previewWithdraw(BigInt(1000e6)),
            1000,
        );
        $test.compare(
            await jrtVault.previewWithdraw(BigInt(1000e6)),
            1000,
        );

        await client.debug.mine('.6year');

        // Deposits use max(epoch PPS, MTM PPS).
        $test.compare(
            await srtVault.previewDeposit(BigInt(1000e6)),
            1000 / 1.5,
        );
        $test.compare(
            await jrtVault.previewDeposit(BigInt(1000e6)),
            1000 / 2.5,
        );

        // Redemptions use min(epoch PPS, MTM PPS).
        $test.compare(
            await srtVault.previewWithdraw(BigInt(1000e6)),
            1000 / 1.5,
        );
        $test.compare(
            await jrtVault.previewWithdraw(BigInt(1000e6)),
            1000 / 2.5,
        );
    }
});
