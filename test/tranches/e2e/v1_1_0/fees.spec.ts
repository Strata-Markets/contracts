import { UTest } from 'atma-utest'
import { $hh } from '../../utils/$hh';
import { EthenaDeployments } from '@s/deployments/EthenaDeployments';
import { TimelockService } from 'dequanto/services/TimelockService/TimelockService';
import { StrataMasterChef } from '@0xc/hardhat/StrataMasterChef/StrataMasterChef';
import { TEth } from 'dequanto/models/TEth';
import { TwoStepConfigManager } from '@0xc/hardhat/TwoStepConfigManager/TwoStepConfigManager';
import { StrataCDO } from '@0xc/hardhat/StrataCDO/StrataCDO';
import { $require } from 'dequanto/utils/$require';
import { Accounting } from '@0xc/hardhat/Accounting/Accounting';
import { $bigint } from 'dequanto/utils/$bigint';
import { $date } from 'dequanto/utils/$date';
import { SUSDeStrategy } from '@0xc/hardhat/sUSDeStrategy/sUSDeStrategy';
import { Tranche } from '@0xc/hardhat/Tranche/Tranche';
import { $number } from 'dequanto/utils/$number';
import { ERC20 } from 'dequanto/prebuilt/openzeppelin/ERC20';
import { Addresses } from '@s/constants';
import { l } from 'dequanto/utils/$logger';
import { AprPairFeed } from '@0xc/hardhat/AprPairFeed/AprPairFeed';
import { $strata } from '../../utils/$strata';


let test = $hh.create('ethena', {
    forked: 23946200,
    cdoInfo: { ContractVersions: { accounting: 'continuous' }}
});

let { factory: forked } = await test.init();

let TVLs_v110_fees = {
    jrtBefore: 0n,
    jrtAfter: 0n,
    jrtFees: 0n,
    jrtWithdrawnNet: 0n,
    jrtWithdrawnGross: 0n,

    srtBefore: 0n,
    srtAfter: 0n,
    srtFees: 0n,
    srtWithdrawnNet: 0n,
    srtWithdrawnGross: 0n,
};
let TVLs_v110_noFee = {
    jrtBefore: 0n,
    jrtAfter: 0n,
    jrtFees: 0n,
    jrtWithdrawnNet: 0n,
    jrtWithdrawnGross: 0n,

    srtBefore: 0n,
    srtAfter: 0n,
    srtFees: 0n,
    srtWithdrawnNet: 0n,
    srtWithdrawnGross: 0n,
};
let TVLs_v100_noFee = {
    jrtBefore: 0n,
    jrtAfter: 0n,
    jrtFees: 0n,
    jrtWithdrawnNet: 0n,
    jrtWithdrawnGross: 0n,

    srtBefore: 0n,
    srtAfter: 0n,
    srtFees: 0n,
    srtWithdrawnNet: 0n,
    srtWithdrawnGross: 0n,
};

const ROUND_STALE = $date.parseTimespan('1month', { get: 's' });

UTest.create({

    $config: {
        timeout: 60_000
    },

    async $before () {
        // forked = await $hh.forked({
        //     block: 23946200,
        //     cdo: 'ethena',
        //     cdoInfo: { ContractVersions: { accounting: 'continuous' }}
        // });

        const { client } = forked;
        await client.debug.mine('10days');
        await $strata.disableAPRs(forked);

        await test.snapshot('v_1_1_0');
    },

    async $teardown () {
        await test.reset('v_1_1_0');
    },
    async $after () {
        await $hh.reset(forked.client);
    },


    async '!v1.1.0: upgrade + enable fee' () {
        // https://github.com/Strata-Money/contracts-tranches-release-reports/tree/master/v1.1.0
        const timelockConfig = {
            name: 'impersonated',
            type: 'impersonated',
            address: '0x4f2682b78F37910704fB1AFF29358A1da07E022d'
        };
        const timelockAdmin = forked.accounts.timelock.admin;
        const safeAdmin = forked.accounts.safe.admin;
        const deployer = forked.accounts.deployer;
        const client = forked.client;

        let twoStepConfigManager = await forked.get(TwoStepConfigManager);
        let cdo = await forked.get(StrataCDO);
        let accounting = await forked.get(Accounting);
        let strategy = await forked.get(SUSDeStrategy);
        let jrUSDe = await forked.get(Tranche, { id: 'jrUSDe' });
        let srUSDe = await forked.get(Tranche, { id: 'srUSDe' });
        let sUSDe = new ERC20(Addresses.eth.sUSDe, client);

        let timelock = new StrataMasterChef(timelockAdmin.address, client);
        let service = new TimelockService(timelock, {
            execute: false,
            simulate: false,
        });

        const { schedule } = await service.getPendingFromTx(`0x926a688f612b92b2b7ebfd5cba6858bf6e2b4696ac4e2d75c929ae9415b13d29`);

        const txExec = await timelock.$receipt().executeBatch(
            deployer,
            schedule.to as TEth.Address[],
            schedule.value as any as bigint[],
            schedule.data as TEth.Address[],
            schedule.predecessor,
            schedule.salt
        );

        $require.eq(await cdo.twoStepConfigManager(), twoStepConfigManager.address);

        const jrtFee = $bigint.toWei(10 / 10000, 18);
        const srtFee = $bigint.toWei(2.5 / 10000, 18);
        const delay = $date.parseTimespan('1day', { get: 's' });
        await twoStepConfigManager
            .$receipt()
            .scheduleExitFeeChange(safeAdmin, jrtFee, srtFee, BigInt(delay));

        await accounting
            .$receipt()
            .setFeeRetentionBps(timelockAdmin, BigInt(1e18), BigInt(1e18));

        await accounting
            .$receipt()
            .setFeeRetentionBps(timelockAdmin, BigInt(1e18), BigInt(1e18));

        await client.debug.mine('2days');

        await twoStepConfigManager
            .$receipt()
            .executeExitFeeChange(timelockConfig);

        await strategy
            .$receipt()
            .setCooldowns(timelockConfig, 0n, 0n);


        $require.eq(await cdo.exitFeeJrt(), jrtFee);
        $require.eq(await cdo.exitFeeSrt(), srtFee);

        srUSDe: {
            l`green<Test withdraw srUSDe>`;
            const holder = '0xC69c87351Bf66cAB8E5676D6f2D4b63299Ad0835';
            await client.debug.setBalance(holder, BigInt(1e18));
            const shares = await srUSDe.balanceOf(holder);

            const usdeGross  = await srUSDe.convertToAssets(shares);
            const usdeNet = await srUSDe.previewRedeem(shares);
            const sUSDeNet = await strategy.convertToTokens(sUSDe.address, usdeNet, 0);
            const tvlBefore = await accounting.srtNav();
            const ppsBefore = $bigint.toEther(await cdo.pricePerShare(srUSDe.address));
            const feeAmout = usdeGross - usdeNet;

            const block = await client.getBlock('latest');
            l`(upgrade + enable fee srUSDe) block ${block.number} Time: ${block.timestamp}`;
            l`(upgrade + enable fee srUSDe) TVL before ${tvlBefore}`;
            l`(upgrade + enable fee srUSDe) shares ${shares}`;
            l`(upgrade + enable fee srUSDe) usdeGross ${usdeGross}`;
            l`(upgrade + enable fee srUSDe) usdeNet ${usdeNet}`;
            l`(upgrade + enable fee srUSDe) fee ${feeAmout}`;

            l`TVL before cyan<${ $number.humanize($bigint.toEther(tvlBefore)) }>`;
            l`PPS before cyan<${ ppsBefore }>`;
            l`Withdraw yellow<${ $number.humanize($bigint.toEther(usdeGross)) }>`;


            l`Fee cyan<${ $number.humanize($bigint.toEther(feeAmout)) }>`;
            const feePct = $bigint.divToFloat(feeAmout, usdeGross, 1000000n);
            $require.eq(0.025, $number.round(feePct * 100, 3));

            let sUSDeBalanceBefore = await sUSDe.balanceOf(holder);
            await srUSDe.$receipt().redeem({
                type: 'impersonated',
                address: holder
            }, sUSDe.address, shares, holder, holder);
            let sUSDeBalanceAfter = await sUSDe.balanceOf(holder);


            let userSUSDeDiff = (sUSDeBalanceAfter - sUSDeBalanceBefore) - sUSDeNet
            $require.lte(userSUSDeDiff, 1n);

            const tvlAfter = await accounting.srtNav();
            l`(upgrade + enable fee) TVL srUSDe after ${tvlAfter}`;
            l`TVL after cyan<${ $number.humanize($bigint.toEther(tvlAfter)) }>`;

            let tvlDiff = tvlBefore - usdeGross + feeAmout - tvlAfter;
            $require.lte(tvlDiff, 1n);

            const ppsAfter = $bigint.toEther(await cdo.pricePerShare(srUSDe.address));
            l`PPS after cyan<${ ppsAfter }>`;

            TVLs_v110_fees.srtAfter = tvlAfter;
            TVLs_v110_fees.srtBefore = tvlBefore;
            TVLs_v110_fees.srtFees = feeAmout;
            TVLs_v110_fees.srtWithdrawnNet = usdeNet;
            TVLs_v110_fees.srtWithdrawnGross = usdeGross;
        }

        jrUSDe: {
            l`green<Test withdraw jrUSDe>`;
            const holder = '0x5071479276AD65a5D7E04230C226c25e2522891a';
            await client.debug.setBalance(holder, BigInt(1e18));

            const shares = await jrUSDe.balanceOf(holder);

            const usdeGross  = await jrUSDe.convertToAssets(shares);
            const usdeNet = await jrUSDe.previewRedeem(shares);
            const sUSDeNet = await strategy.convertToTokens(sUSDe.address, usdeNet, 0);

            const tvlBefore = await accounting.jrtNav();
            const ppsBefore = $bigint.toEther(await cdo.pricePerShare(jrUSDe.address));
            l`TVL before cyan<${ $number.humanize($bigint.toEther(tvlBefore)) }>`;
            l`PPS before cyan<${ ppsBefore }>`;
            l`Withdraw yellow<${ $number.humanize($bigint.toEther(usdeGross)) }>`;

            const feeAmout = usdeGross - usdeNet;
            l`Fee cyan<${ $number.humanize($bigint.toEther(feeAmout)) }>`;

            const block = await client.getBlock('latest');
            l`(upgrade + enable fee srUSDe) block ${block.number} Time: ${block.timestamp}`;
            l`(upgrade + enable fee jrUSDe) TVL before ${tvlBefore}`;
            l`(upgrade + enable fee jrUSDe) shares ${shares}`;
            l`(upgrade + enable fee jrUSDe) usdeGross ${usdeGross}`;
            l`(upgrade + enable fee jrUSDe) usdeNet ${usdeNet}`;
            l`(upgrade + enable fee jrUSDe) fee ${feeAmout}`;

            const feePct = $bigint.divToFloat(feeAmout, usdeGross, 1000000n);
            $require.eq(0.1, $number.round(feePct * 100, 2));


            let sUSDeBalanceBefore = await sUSDe.balanceOf(holder);
            await jrUSDe.$receipt().redeem({
                type: 'impersonated',
                address: holder
            }, sUSDe.address, shares, holder, holder);
            let sUSDeBalanceAfter = await sUSDe.balanceOf(holder);


            let diff = (sUSDeBalanceAfter - sUSDeBalanceBefore) - sUSDeNet;
            $require.lte(diff, 1n);

            const tvlAfter = await accounting.jrtNav();

            l`TVL after  cyan<${ $number.humanize($bigint.toEther(tvlAfter)) }>`;
            l`TVL before cyan<${ $number.humanize($bigint.toEther(tvlBefore)) }>`;
            l`Fee cyan<${ $bigint.toEther(feeAmout) }>`;
            l`USDe NET cyan<${ $bigint.toEther(usdeNet) }>`;
            l`USDe GRO cyan<${ $bigint.toEther(usdeGross) }>`;

            l`TVL drop cyan<${ $bigint.toEther(tvlBefore - tvlAfter) }>`;

            // 1wei rounding on fees
            let tvlDiff = tvlBefore - usdeGross + feeAmout - tvlAfter;
            $require.lte(tvlDiff, 1n);

            const ppsAfter = $bigint.toEther(await cdo.pricePerShare(srUSDe.address));
            l`PPS after cyan<${ ppsAfter }>`;

            TVLs_v110_fees.jrtAfter = tvlAfter;
            TVLs_v110_fees.jrtBefore = tvlBefore;
            TVLs_v110_fees.jrtFees = feeAmout;
            TVLs_v110_fees.jrtWithdrawnNet = usdeNet;
            TVLs_v110_fees.jrtWithdrawnGross = usdeGross;
        }
    },

    async 'v1.1.0: upgrade only' () {
        // https://github.com/Strata-Money/contracts-tranches-release-reports/tree/master/v1.1.0
        const timelockAdmin = forked.accounts.timelock.admin;
        const timelockConfig = forked.accounts.timelock.config;
        const safeAdmin = forked.accounts.safe.admin;
        const safeOperator = forked.accounts.safe.operator;
        const deployer = forked.accounts.deployer;
        const client = forked.client;

        let twoStepConfigManager = await forked.get(TwoStepConfigManager);
        let cdo = await forked.get(StrataCDO);
        let accounting = await forked.get(Accounting);
        let strategy = await forked.get(SUSDeStrategy);
        let jrUSDe = await forked.get(Tranche, { id: 'jrUSDe' });
        let srUSDe = await forked.get(Tranche, { id: 'srUSDe' });
        let sUSDe = new ERC20(Addresses.eth.sUSDe, client);
        let feed = await forked.get(AprPairFeed);


        let timelock = new StrataMasterChef(timelockAdmin.address, client);
        let service = new TimelockService(timelock, {
            execute: false,
            simulate: false,
        });

        const { schedule } = await service.getPendingFromTx(`0x926a688f612b92b2b7ebfd5cba6858bf6e2b4696ac4e2d75c929ae9415b13d29`);

        const txExec = await timelock.$receipt().executeBatch(
            deployer,
            schedule.to as TEth.Address[],
            schedule.value as any as bigint[],
            schedule.data as TEth.Address[],
            schedule.predecessor,
            schedule.salt
        );

        $require.eq(await cdo.twoStepConfigManager(), twoStepConfigManager.address);


        await accounting
            .$receipt()
            .setFeeRetentionBps(timelockAdmin, BigInt(1e18), BigInt(1e18));

        await client.debug.mine('2days');

        await strategy
            .$receipt()
            .setCooldowns(timelockConfig, 0n, 0n);


        $require.eq(await cdo.exitFeeJrt(), 0n);
        $require.eq(await cdo.exitFeeSrt(), 0n);

        srUSDe: {
            l`green<Test withdraw srUSDe>`;
            const holder = '0xC69c87351Bf66cAB8E5676D6f2D4b63299Ad0835';
            await client.debug.setBalance(holder, BigInt(1e18));
            const shares = await srUSDe.balanceOf(holder);

            const usdeGross  = await srUSDe.convertToAssets(shares);
            const usdeNet = await srUSDe.previewRedeem(shares);
            const sUSDeNet = await strategy.convertToTokens(sUSDe.address, usdeNet, 0);
            const tvlBefore = await accounting.srtNav();
            const ppsBefore = $bigint.toEther(await cdo.pricePerShare(srUSDe.address));
            const feeAmout = usdeGross - usdeNet;

            l`(upgrade only srUSDe) TVL before ${tvlBefore}`;
            l`(upgrade only srUSDe) shares ${shares}`;
            l`(upgrade only srUSDe) usdeGross ${usdeGross}`;
            l`(upgrade only srUSDe) usdeNet ${usdeNet}`;
            l`(upgrade only srUSDe) fee ${feeAmout}`;



            l`TVL before cyan<${ $number.humanize($bigint.toEther(tvlBefore)) }>`;
            l`PPS before cyan<${ ppsBefore }>`;
            l`Withdraw yellow<${ $number.humanize($bigint.toEther(usdeGross)) }>`;



            l`Fee cyan<${ $number.humanize($bigint.toEther(feeAmout)) }>`;
            const feePct = $bigint.divToFloat(feeAmout, usdeGross, 1000000n);
            $require.eq(0, $number.round(feePct * 100, 3));

            let sUSDeBalanceBefore = await sUSDe.balanceOf(holder);
            await srUSDe.$receipt().redeem({
                type: 'impersonated',
                address: holder
            }, sUSDe.address, shares, holder, holder);
            let sUSDeBalanceAfter = await sUSDe.balanceOf(holder);


            let diff = (sUSDeBalanceAfter - sUSDeBalanceBefore) - sUSDeNet
            $require.lte(diff, 1n);

            const tvlAfter = await accounting.srtNav();
            l`(upgrade only srUSDe) TVL after ${tvlAfter}`;
            l`TVL after cyan<${ $number.humanize($bigint.toEther(tvlAfter)) }>`;

            let tvlDiff = tvlBefore - usdeGross + feeAmout - tvlAfter;
            $require.lte(tvlDiff, 1n);

            const ppsAfter = $bigint.toEther(await cdo.pricePerShare(srUSDe.address));
            l`PPS after cyan<${ ppsAfter }>`;

            TVLs_v110_noFee.srtAfter = tvlAfter;
            TVLs_v110_noFee.srtBefore = tvlBefore;
            TVLs_v110_noFee.srtFees = feeAmout;
            TVLs_v110_noFee.srtWithdrawnNet = usdeNet;
            TVLs_v110_noFee.srtWithdrawnGross = usdeGross;
        }

        jrUSDe: {
            l`green<Test withdraw jrUSDe>`;
            const holder = '0x5071479276AD65a5D7E04230C226c25e2522891a';
            await client.debug.setBalance(holder, BigInt(1e18));

            const shares = await jrUSDe.balanceOf(holder);

            const usdeGross  = await jrUSDe.convertToAssets(shares);
            const usdeNet = await jrUSDe.previewRedeem(shares);
            const sUSDeNet = await strategy.convertToTokens(sUSDe.address, usdeNet, 0);
            const tvlBefore = await accounting.jrtNav();
            const ppsBefore = $bigint.toEther(await cdo.pricePerShare(jrUSDe.address));
            const feeAmout = usdeGross - usdeNet;

            l`(upgrade only jrUSDe) TVL before ${tvlBefore}`;
            l`(upgrade only jrUSDe) shares ${shares}`;
            l`(upgrade only jrUSDe) usdeGross ${usdeGross}`;
            l`(upgrade only jrUSDe) usdeNet ${usdeNet}`;
            l`(upgrade only jrUSDe) fee ${feeAmout}`;

            l`TVL before cyan<${ $number.humanize($bigint.toEther(tvlBefore)) }>`;
            l`PPS before cyan<${ ppsBefore }>`;
            l`Withdraw yellow<${ $number.humanize($bigint.toEther(usdeGross)) }>`;


            l`Fee cyan<${ $number.humanize($bigint.toEther(feeAmout)) }>`;

            const feePct = $bigint.divToFloat(feeAmout, usdeGross, 1000000n);
            $require.eq(0, $number.round(feePct * 100, 2));


            let sUSDeBalanceBefore = await sUSDe.balanceOf(holder);
            await jrUSDe.$receipt().redeem({
                type: 'impersonated',
                address: holder
            }, sUSDe.address, shares, holder, holder);
            let sUSDeBalanceAfter = await sUSDe.balanceOf(holder);


            let diff = (sUSDeBalanceAfter - sUSDeBalanceBefore) - sUSDeNet;
            $require.lte(diff, 1n);

            const tvlAfter = await accounting.jrtNav();
            l`(upgrade only jrUSDe) TVL after ${tvlAfter}`;

            l`TVL after  cyan<${ $number.humanize($bigint.toEther(tvlAfter)) }>`;
            l`TVL before cyan<${ $number.humanize($bigint.toEther(tvlBefore)) }>`;
            l`Fee cyan<${ $bigint.toEther(feeAmout) }>`;
            l`USDe NET cyan<${ $bigint.toEther(usdeNet) }>`;
            l`USDe GRO cyan<${ $bigint.toEther(usdeGross) }>`;

            l`TVL drop cyan<${ $bigint.toEther(tvlBefore - tvlAfter) }>`;


            let tvlDiff = tvlBefore - usdeGross + feeAmout - tvlAfter;
            $require.lte(tvlDiff, 1n);

            const ppsAfter = $bigint.toEther(await cdo.pricePerShare(srUSDe.address));
            l`PPS after cyan<${ ppsAfter }>`;

            TVLs_v110_noFee.jrtAfter = tvlAfter;
            TVLs_v110_noFee.jrtBefore = tvlBefore;
            TVLs_v110_noFee.jrtFees = feeAmout;
            TVLs_v110_noFee.jrtWithdrawnNet = usdeNet;
            TVLs_v110_noFee.jrtWithdrawnGross = usdeGross;
        }
    },

    async 'v1.0.0: withdraw without fees' () {
        // https://github.com/Strata-Money/contracts-tranches-release-reports/tree/master/v1.1.0
        const timelockConfig = forked.accounts.timelock.config;
        const client = forked.client;

        let cdo = await forked.get(StrataCDO);
        let accounting = await forked.get(Accounting);
        let strategy = await forked.get(SUSDeStrategy);
        let jrUSDe = await forked.get(Tranche, { id: 'jrUSDe' });
        let srUSDe = await forked.get(Tranche, { id: 'srUSDe' });
        let sUSDe = new ERC20(Addresses.eth.sUSDe, client);


        await client.debug.mine('2days');
        await strategy.$receipt().setCooldowns(timelockConfig, 0n, 0n);

        srUSDe: {
            l`Test withdraw srUSDe`;
            const holder = '0xC69c87351Bf66cAB8E5676D6f2D4b63299Ad0835';
            await client.debug.setBalance(holder, BigInt(1e18));
            const shares = await srUSDe.balanceOf(holder);

            const usdeGross  = await srUSDe.convertToAssets(shares);
            const usdeNet = await srUSDe.previewRedeem(shares);
            const sUSDeNet = await strategy.convertToTokens(sUSDe.address, usdeNet, 0);
            const tvlBefore = await accounting.srtNav();
            const ppsBefore = $bigint.toEther(await cdo.pricePerShare(srUSDe.address));
            const feeAmout = usdeGross - usdeNet;

            l`(withdraw without fees srUSDe) TVL before ${tvlBefore}`;
            l`(withdraw without fees srUSDe) shares ${shares}`;
            l`(withdraw without fees srUSDe) usdeGross ${usdeGross}`;
            l`(withdraw without fees srUSDe) usdeNet ${usdeNet}`;
            l`(withdraw without fees srUSDe) fee ${feeAmout}`;


            l`TVL before cyan<${ $number.humanize($bigint.toEther(tvlBefore)) }>`;
            l`PPS before cyan<${ ppsBefore }>`;
            l`Withdraw yellow<${ $number.humanize($bigint.toEther(usdeGross)) }>`;

            $require.eq(feeAmout, 0n);

            let sUSDeBalanceBefore = await sUSDe.balanceOf(holder);
            await srUSDe.$receipt().redeem({
                type: 'impersonated',
                address: holder
            }, sUSDe.address, shares, holder, holder);
            let sUSDeBalanceAfter = await sUSDe.balanceOf(holder);


            let diff = (sUSDeBalanceAfter - sUSDeBalanceBefore) - sUSDeNet
            $require.lte(diff, 1n);

            const tvlAfter = await accounting.srtNav();
            l`(withdraw without fees srUSDe) TVL after ${tvlAfter}`;
            let tvlDiff = tvlBefore - usdeGross + feeAmout - tvlAfter;
            $require.lte(tvlDiff, 1n);

            const ppsAfter = $bigint.toEther(await cdo.pricePerShare(srUSDe.address));

            l`Fee cyan<${ $number.humanize($bigint.toEther(feeAmout)) }>`;
            l`TVL after cyan<${ $number.humanize($bigint.toEther(tvlAfter)) }>`;
            l`PPS after cyan<${ ppsAfter }>`;

            TVLs_v100_noFee.srtAfter = tvlAfter;
            TVLs_v100_noFee.srtBefore = tvlBefore;
            TVLs_v100_noFee.srtFees = feeAmout;
            TVLs_v100_noFee.srtWithdrawnNet = usdeNet;
            TVLs_v100_noFee.srtWithdrawnGross = usdeGross;
        }

        jrUSDe: {
            l`Test withdraw jrUSDe`;
            const holder = '0x5071479276AD65a5D7E04230C226c25e2522891a';
            await client.debug.setBalance(holder, BigInt(1e18));

            const shares = await jrUSDe.balanceOf(holder);

            const usdeGross  = await jrUSDe.convertToAssets(shares);
            const usdeNet = await jrUSDe.previewRedeem(shares);
            const sUSDeNet = await strategy.convertToTokens(sUSDe.address, usdeNet, 0);

            const tvlBefore = await accounting.jrtNav();
            const ppsBefore = $bigint.toEther(await cdo.pricePerShare(jrUSDe.address));
            const feeAmout = usdeGross - usdeNet;

            l`(withdraw without fees jrUSDe) TVL before ${tvlBefore}`;
            l`(withdraw without fees jrUSDe) shares ${shares}`;
            l`(withdraw without fees jrUSDe) usdeGross ${usdeGross}`;
            l`(withdraw without fees jrUSDe) usdeNet ${usdeNet}`;
            l`(withdraw without fees jrUSDe) fee ${feeAmout}`;

            l`TVL before cyan<${ $number.humanize($bigint.toEther(tvlBefore)) }>`;
            l`PPS before cyan<${ ppsBefore }>`;
            l`Withdraw yellow<${ $number.humanize($bigint.toEther(usdeGross)) }>`;

            l`USR MaxWithdraw yellow<${ $number.humanize($bigint.toEther( await jrUSDe.maxWithdraw(holder) )) }>`
            l`CDO MaxWithdraw yellow<${ $number.humanize($bigint.toEther( await cdo.maxWithdraw(jrUSDe.address) )) }>`
            l`USR Preview yellow<${ $number.humanize($bigint.toEther( await jrUSDe.previewRedeem(shares) )) }>`

            l`maxRedeem yellow<${ await jrUSDe.maxRedeem(holder) }>`;
            l`Balance   yellow<${ shares }>`;
            l`Balance   yellow<${ await jrUSDe.balanceOf(holder) }>`;


            $require.eq(feeAmout, 0n);


            let sUSDeBalanceBefore = await sUSDe.balanceOf(holder);
            await jrUSDe.$receipt().redeem({
                type: 'impersonated',
                address: holder
            }, sUSDe.address, shares, holder, holder);
            let sUSDeBalanceAfter = await sUSDe.balanceOf(holder);


            let diff = (sUSDeBalanceAfter - sUSDeBalanceBefore) - sUSDeNet;
            $require.lte(diff, 1n);

            const tvlAfter = await accounting.jrtNav();
            l`(withdraw without fees jrUSDe) TVL after ${tvlAfter}`;
            let tvlDiff = tvlBefore - usdeGross + feeAmout - tvlAfter;
            $require.lte(tvlDiff, 1n);

            const ppsAfter = $bigint.toEther(await cdo.pricePerShare(srUSDe.address));
            l`Fee cyan<${ $number.humanize($bigint.toEther(feeAmout)) }>`;
            l`TVL after cyan<${ $number.humanize($bigint.toEther(tvlAfter)) }>`;
            l`PPS after cyan<${ ppsAfter }>`;

            TVLs_v100_noFee.jrtAfter = tvlAfter;
            TVLs_v100_noFee.jrtBefore = tvlBefore;
            TVLs_v100_noFee.jrtFees = feeAmout;
            TVLs_v100_noFee.jrtWithdrawnNet = usdeNet;
            TVLs_v100_noFee.jrtWithdrawnGross = usdeGross;
        }
    },
    async 'final TVLs should be equal' () {

        function eqRounded(a: bigint, b: bigint, hint: string) {
            $require.lte($bigint.abs(a - b), 1n, hint);
        }

        eqRounded(TVLs_v110_fees.jrtBefore, TVLs_v100_noFee.jrtBefore, '(before) JRT TVLs should be same');
        eqRounded(TVLs_v110_fees.srtBefore, TVLs_v100_noFee.srtBefore, '(before) SRT TVLs should be same');

        eqRounded(TVLs_v110_noFee.srtBefore, TVLs_v100_noFee.srtBefore, 'v110 vs v100 - (before) SRT TVLs should be same');

        eqRounded(TVLs_v110_fees.jrtWithdrawnGross, TVLs_v100_noFee.jrtWithdrawnGross, 'JRT Withdrawn Gross final TVLs should be same');
        eqRounded(TVLs_v110_fees.srtWithdrawnGross, TVLs_v100_noFee.srtWithdrawnGross, 'SRT Withdrawn Gross final TVLs should be same');

        eqRounded(TVLs_v110_noFee.jrtWithdrawnGross, TVLs_v100_noFee.jrtWithdrawnGross, 'JRT Withdrawn Gross final TVLs should be same');
        eqRounded(TVLs_v110_noFee.srtWithdrawnGross, TVLs_v100_noFee.srtWithdrawnGross, 'SRT Withdrawn Gross final TVLs should be same');

        eqRounded(TVLs_v110_fees.srtAfter - TVLs_v110_fees.srtFees, TVLs_v100_noFee.srtAfter, '(after) SRT TVLs should be same');
        eqRounded(TVLs_v110_fees.jrtAfter - TVLs_v110_fees.jrtFees, TVLs_v100_noFee.jrtAfter, '(after) JRT TVLs should be same');

        eqRounded(TVLs_v110_noFee.srtAfter, TVLs_v100_noFee.srtAfter, '(after) SRT TVLs should be same');
        eqRounded(TVLs_v110_noFee.jrtAfter, TVLs_v100_noFee.jrtAfter, '(after) JRT TVLs should be same');


        eqRounded(TVLs_v110_fees.jrtWithdrawnNet + TVLs_v110_fees.jrtFees, TVLs_v100_noFee.jrtWithdrawnGross, 'JRT');
        eqRounded(TVLs_v110_fees.srtWithdrawnNet + TVLs_v110_fees.srtFees, TVLs_v100_noFee.srtWithdrawnGross, 'SRT');
    }
})
