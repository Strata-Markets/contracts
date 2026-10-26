import { UTest } from 'atma-utest'
import { $erc4626 } from './utils/$erc4626';
import { $hh } from './utils/$hh';
import { $require } from 'dequanto/utils/$require';
import { $bigint } from 'dequanto/utils/$bigint';
import { $promise } from 'dequanto/utils/$promise';
import { l } from 'dequanto/utils/$logger';
import { $date } from 'dequanto/utils/$date';
import { IPlatformAccounts } from '@s/platforms/IPlatform';
import { TwoStepConfigManager } from '@0xc/hardhat/TwoStepConfigManager/TwoStepConfigManager';
import { StrataCDO } from '@0xc/hardhat/StrataCDO/StrataCDO';

await $hh.test.deploy();

let { deployer } = $hh.test;
let { accounts } = $hh.test.factory;

UTest.create({
    async $before () {
        let { sUSDe, strategy, jrtVault } = $hh.test.tranches;

        // Disable default cooldowns
        await sUSDe.$receipt().setCooldownDuration(deployer, 0);
        await strategy.$receipt().setCooldowns(deployer, 0n, 0n);

        // min shares
        await $erc4626.deposit(jrtVault, deployer, 10);
        await $hh.test.snapshot('test');
    },
    async $teardown () {
        await $hh.test.reset('test');
    },
    async $after () {
        await $hh.test.reset();
    },
    async 'ERC4626::withdrawal fee' () {
        let { jrtVault, cdo, USDe, accounting } = $hh.test.tranches;
        let { configManager } = $hh.test;

        // Deposit initial
        let alice = await $hh.test.createAccount('alice');

        await $erc4626.deposit(jrtVault, alice, 1000);

        let aliceTotalShares = await jrtVault.balanceOf(alice.address);

        l`No fee, max withdraw 1000$`;
        $require.eq(await jrtVault.maxWithdraw(alice.address), $bigint.toWei(1000));
        $require.eq(await jrtVault.maxRedeem(alice.address), aliceTotalShares);

        await ConfigManagerTest.setExitFees(accounts, configManager, cdo, BigInt(0.01e18), BigInt(0.01e18));

        l`::previewRedeem (1%: deposited 1000, redeem 990)`;
        let shares = await jrtVault.balanceOf(alice.address);
        $require.eq(await jrtVault.previewRedeem(shares), $bigint.toWei(990));

        l`::previewWithdraw (990 equals users total shares)`;
        $require.eq(await jrtVault.previewWithdraw(990n * 10n**18n), shares);
        l`::maxWithdraw`;
        $require.eq(await jrtVault.maxWithdraw(alice.address), $bigint.toWei(990));
        l`::maxRedeem (unchanged)`;
        $require.eq(await jrtVault.maxRedeem(alice.address), aliceTotalShares);

        await $hh.test.snapshot('fees-alice');

        return UTest.create({
            async $teardown () {
                await $hh.test.reset('fees-alice');
            },
            async 'conversion check' () {
                for (let i = 0n; i < 9n; i++ ) {
                    const shares1 = 989898989898989898989n + i;
                    const assets = await jrtVault.previewRedeem(shares1);
                    const shares2 = await jrtVault.previewWithdraw(assets);
                    $require.eq(shares2, shares1, 'Share conversion error');
                }
                for (let i = 0n; i < 9n; i++ ) {
                    const assets1 = 989898989898989898989n + i;
                    const shares = await jrtVault.previewWithdraw(assets1);
                    const assets2 = await jrtVault.previewRedeem(shares);
                    $require.eq(assets1, assets2, 'Assets conversion error');
                }
            },
            async 'withdraw 1 step - 1% ~ 10$ fee' () {
                l`Should revert, as assetsNet is passed and assetsGross is not enough`;
                let { error } = await $promise.caught(() => {
                    return $erc4626.withdraw(jrtVault, alice, 1000);
                });
                $require.match(/ERC4626ExceededMaxWithdraw/, error.message);

                let balance = await $erc4626.withdraw(jrtVault, alice, 990);
                $require.eq(await accounting.reserveNav(), $bigint.toWei(10));
                $require.eq(balance, 990n * 10n**18n);
            },
            async 'withdraw 2 step' () {
                console.log('Alice', await jrtVault.balanceOf(alice.address));
                let balance = await $erc4626.withdraw(jrtVault, alice, 10);
                // Gross up the 10$ net withdrawal; the fee rounds up.
                $require.eq(await accounting.reserveNav(), 101_010_101_010_101_011n);
                $require.eq(balance, 10n * 10n**18n);

                let maxWithdraw = await jrtVault.maxWithdraw(alice.address);
                $require.eq(maxWithdraw, 979_999_999_999_999_999_999n, `Rounded fees leave one wei less than 980$`);
                balance = await $erc4626.withdraw(jrtVault, alice, maxWithdraw);
                $require.eq(balance, maxWithdraw);
                $require.eq(await accounting.reserveNav(), 10_000_000_000_000_000_001n);
                $require.eq(await jrtVault.balanceOf(alice.address), 0n, `Withdrawing the remaining maximum burns all Alice's shares`);
            },
            async 'redeem' () {
                let balance = await $erc4626.redeem(jrtVault, alice, '100%');
                $require.eq(await accounting.reserveNav(), $bigint.toWei(10));
                $require.eq(balance, 990n * 10n**18n);
            },
            async 'redeem 2 step' () {
                let balance = await $erc4626.redeem(jrtVault, alice, '30%');
                $require.eq(balance, $bigint.toWei(990 * .3));
                $require.eq(await accounting.reserveNav(), $bigint.toWei(990 * .3 / 99));

                balance = await $erc4626.redeem(jrtVault, alice, '100%');
                $require.eq(balance, $bigint.toWei(990 * .7));
                $require.eq(await jrtVault.balanceOf(alice.address), 0n);
                $require.eq(await USDe.balanceOf(alice.address), 990n * 10n**18n);
            },
            async 'lower the fees in one go' () {
                let jrtFee = await cdo.exitFeeJrt();
                let srtFee = await cdo.exitFeeSrt();
                $require.gt(jrtFee, 0n);
                $require.gt(srtFee, 0n);
                await configManager.$receipt().scheduleExitFeeChange(deployer, 0n, 0n, 0n);

                let jrtFeeAfter = await cdo.exitFeeJrt();
                let srtFeeAfter = await cdo.exitFeeSrt();
                $require.eq(jrtFeeAfter, 0n);
                $require.eq(srtFeeAfter, 0n);
            }
        });
    },
    async 'ERC4626::withdrawal fee with retention' () {

        let { jrtVault, cdo, accounting } = $hh.test.tranches;
        let { configManager } = $hh.test;

        // Deposit initial
        let alice = await $hh.test.createAccount('alice');

        await $erc4626.deposit(jrtVault, alice, 1000);
        await ConfigManagerTest.setExitFees(accounts, configManager, cdo, BigInt(0.01e18), BigInt(0.01e18));

        await $hh.test.snapshot('fees-retention-alice');
        return UTest.create({
            async $teardown () {
                await $hh.test.reset('fees-retention-alice');
            },
            async '100% back to TVL' () {
                await accounting.$receipt().setFeeRetentionBps(deployer, BigInt(1e18), 0n);

                let priceBefore = $bigint.toEther(await cdo.pricePerShare(jrtVault.address));
                let jrtNav = await accounting.jrtNav();
                let balance = await $erc4626.redeem(jrtVault, alice, '100%');
                $require.eq(await accounting.reserveNav(), $bigint.toWei(0), `Reserve should be empty`);
                $require.eq(await accounting.jrtNav(), jrtNav - 990n * 10n**18n, `10$ should be returned to Juniors`);
                $require.eq(balance, 990n * 10n**18n);

                let priceAfter = $bigint.toEther(await cdo.pricePerShare(jrtVault.address));

                let priceIncrease = priceAfter / priceBefore;
                $require.eq(priceIncrease, 2, `Before Alice: 10$; after fee 10$ goes to Juniors: 100% increase`)
            },
            async '25% back to TVL' () {
                await accounting.$receipt().setFeeRetentionBps(deployer, BigInt(0.25e18), 0n);


                let jrtNav = await accounting.jrtNav();
                let balance = await $erc4626.redeem(jrtVault, alice, '100%');
                $require.eq(await accounting.reserveNav(), BigInt(7.5e18), `Reserve should collect 75% of 10$ fee`);
                $require.eq(await accounting.jrtNav(), jrtNav - BigInt(1000e18) + BigInt(2.5e18), `2.5$ should be returned to Juniors`);
                $require.eq(balance, 990n * 10n**18n);
            }
        });
    },
    async 'ERC4626:: reserve distribution' () {
        let { jrtVault, cdo, accounting } = $hh.test.tranches;
        let { configManager } = $hh.test;
        // Deposit initial
        let alice = await $hh.test.createAccount('alice');

        await $erc4626.deposit(jrtVault, alice, 1000);
        await ConfigManagerTest.setExitFees(accounts, configManager, cdo, BigInt(0.01e18), BigInt(0.01e18));

        await $hh.test.snapshot('fees-distribution-alice');
        return UTest.create({
            async $teardown () {
                await $hh.test.reset('fees-distribution-alice');
            },
            async 'distribute' () {

                await $erc4626.redeem(jrtVault, alice, '100%');

                let [jrtNav, srtNav] = await Promise.all([ accounting.jrtNav(), accounting.srtNav() ]);
                $require.eq(await accounting.reserveNav(), $bigint.toWei(10), `Reserve should be 10$`);

                await cdo.$receipt().distributeReserve(deployer, BigInt(8e18), BigInt(2e18));
                $require.eq(await accounting.reserveNav(), 0n, `Reserve should be empty`);

                let [jrtNavT1, srtNavT1] = await Promise.all([ accounting.jrtNav(), accounting.srtNav() ]);

                $require.eq(jrtNavT1 - jrtNav, BigInt(8e18), `Juniors should receive 8$`);
                $require.eq(srtNavT1 - srtNav, BigInt(2e18), `Seniors should receive 2$`);
            }
        });
    },
    async 'should cancel fee' () {
        let { cdo } = $hh.test.tranches;
        let { configManager } = $hh.test;
        await ConfigManagerTest.scheduleExitFees(accounts, configManager, cdo, BigInt(0.005e18), BigInt(0.04e5));
        await ConfigManagerTest.cancelExitFees(accounts, configManager);
    }
})


namespace ConfigManagerTest {

    export async function scheduleExitFees (
        accounts: IPlatformAccounts
        , configManager: TwoStepConfigManager
        , cdo: StrataCDO
        , feeJrt: bigint
        , feeSrt: bigint) {
        const { deployer } = accounts;
        const delay = $date.parseTimespan('1day', { get: 's' });
        const txSchedule = await configManager.$receipt().scheduleExitFeeChange(deployer, feeJrt, feeSrt, BigInt(delay));
        const pendingChange = await configManager.pendingExitFeeChange();
        const scheduleLogs = configManager.extractLogsExitFeeChangeScheduled(txSchedule.receipt);
        $require.eq(scheduleLogs.length, 1);
        $require.eq(scheduleLogs[0].params.feeJrt, feeJrt);
        $require.eq(scheduleLogs[0].params.feeSrt, feeSrt);
        $require.eq(pendingChange.feeJrt, feeJrt);
        $require.eq(pendingChange.feeSrt, feeSrt);
    }

    export async function cancelExitFees (
        accounts: IPlatformAccounts
        , configManager: TwoStepConfigManager) {
        const { deployer } = accounts;
        const txCancel = await configManager.$receipt().cancelExitFeeChange(deployer);
        const cancelLogs = configManager.extractLogsExitFeeChangeCancelled(txCancel.receipt);
        $require.eq(cancelLogs.length, 1);

        const pendingChange = await configManager.pendingExitFeeChange();
        $require.eq(pendingChange.feeJrt, 0n);
        $require.eq(pendingChange.feeSrt, 0n);
        $require.eq(pendingChange.executeAfter, 0);
    }


    export async function setExitFees (
        accounts: IPlatformAccounts
        , configManager: TwoStepConfigManager
        , cdo: StrataCDO
        , feeJrt: bigint
        , feeSrt: bigint) {
        const { deployer } = accounts;

        await scheduleExitFees(accounts, configManager, cdo, feeJrt, feeSrt);

        await configManager.client.debug.mine('2days');
        const txExec = await configManager.$receipt().executeExitFeeChange(deployer);
        const execLogs = configManager.extractLogsExitFeeChangeExecuted(txExec.receipt);
        $require.eq(execLogs.length, 1);
        $require.eq(execLogs[0].params.feeJrt, feeJrt);
        $require.eq(execLogs[0].params.feeSrt, feeSrt);
        $require.eq(await cdo.exitFeeJrt(), feeJrt, `Exit fee JRT not updated`);
        $require.eq(await cdo.exitFeeSrt(), feeSrt, `Exit fee SRT not updated`);
    }
}
