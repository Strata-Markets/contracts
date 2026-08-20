import { UTest } from 'atma-utest'
import { $hh } from '../utils/$hh';
import { $erc4626 } from '../utils/$erc4626';
import { $require } from 'dequanto/utils/$require';
import { $test } from '../utils/$test';
import { l } from 'dequanto/utils/$logger';
import { $address } from 'dequanto/utils/$address';
import { $bigint } from 'dequanto/utils/$bigint';
import { $strata } from '../utils/$strata';
import { $ethena } from '../utils/$ethena';
import { DYSAccounting } from '@0xc/hardhat/DYSAccounting/DYSAccounting';
import { TEth } from 'dequanto/models/TEth';
import { $accounting } from '../utils/$accounting';
import { $sig } from 'dequanto/utils/$sig';
import { $abiCoder } from 'dequanto/abi/$abiCoder';
import { $buffer } from 'dequanto/utils/$buffer';


const test = await $hh.deploy('ethena', {
    cdoInfo: {
        ContractVersions: {
            accounting: 'dys',
            valuationKeeper: 'Accountable',
        }
    },
});

const accounting = test.tranches.accounting as any as DYSAccounting;
const { deployer, client } = test;
const { cdo, jrtVault, srtVault, sUSDe } = test.tranches;
const alice = await test.createAccount('alice');
const bob = await test.createAccount('bob');

UTest.create({

    async $before() {
        await cdo.$receipt().setValuationKeeper(deployer, deployer.address);
        await $strata.disableAPRs(test.factory);
        await $ethena.setCooldownDuration(sUSDe, deployer, 0);
        await test.snapshot('spec');
    },
    async $teardown() {
        await test.reset('spec');
    },
    async $after() {
        await test.wipe();
    },

    async 'applies 0.50 valuation loss by shifting Junior liquidity to Senior at 50:50 coverage'() {
        await $erc4626.deposit(jrtVault, deployer, 100);
        await $erc4626.deposit(srtVault, deployer, 100);
        $require.eq(await jrtVault.totalAssets(), BigInt(100e18));
        $require.eq(await srtVault.totalAssets(), BigInt(100e18));


        // 60seconds after entering the valuation loss, no redemption or deposits should be allowed
        await accounting.$receipt().setValuationGracePeriod(deployer, 60);

        const tx = await cdo.$receipt().setValuationPrice(deployer, BigInt(.5e18));
        const [changed] = accounting.extractLogsValuationPriceChanged(tx.receipt);
        $require.eq(changed?.params.valuationPrice, BigInt(.5e18));
        $require.eq(await accounting.valuationPrice(), BigInt(.5e18), `Valuation price should be 0.5$`);

        $require.eq(await jrtVault.maxDeposit($address.ZERO), 0n, `GracePeriod: disabled Jrt deposit`);
        $require.eq(await srtVault.maxDeposit($address.ZERO), 0n, `ValuationLoss: disabled Srt deposit`);

        $require.eq(await jrtVault.maxWithdraw(deployer.address), 0n, `ValuationLoss: disabled Jrt redemption`);
        $require.eq(await srtVault.maxDeposit(deployer.address), 0n, `GracePeriod: disabled Srt redemption`);

        await client.debug.mine('2hour');


        // Here we would require 100$ from JR, but we keep ONE_ASSET as Buffer
        $require.eq(await jrtVault.totalAssets(), BigInt(1e18));
        $require.eq(await srtVault.totalAssets(), BigInt(199e18));

        l`Deposit 1 USDe to JRT, that should be moved to SRT for full coverage`;
        await $erc4626.deposit(jrtVault, deployer, 1);
        $require.eq(await jrtVault.totalAssets(), BigInt(1e18));
        $require.eq(await srtVault.totalAssets(), BigInt(200e18));

        l`PreviewFunctions`
        const srtPPS = await cdo.pricePerShare(srtVault.address);
        $require.eq(srtPPS, BigInt(2e18), `SRT price per share should be 2 Assets`);

        const jrtPPS = await cdo.pricePerShare(jrtVault.address);
        $require.eq(jrtPPS, BigInt(0.005e18), `JRT price per share should be 0.005$ Assets (rounded)`);

        $test.eqDiff(
            await jrtVault.previewDeposit(BigInt(10e18))
            , BigInt(10e18) * BigInt(1e18) / BigInt(0.005e18)
            , 10_000n
        );
        $require.eq(await srtVault.previewDeposit(BigInt(10e18)), BigInt(5e18));


        l`Deposit 1 USDe to JRT, that should remain`;
        // Re-enable JRT deposits, as due to loss pps dropped < jrtShortfallPausePrice
        await cdo.$receipt().setActionStates(deployer, jrtVault.address, true, true);

        $require.eq(await cdo.maxDeposit(jrtVault.address), $bigint.MAX_UINT256, `JRT max depositable`);
        $require.eq(await cdo.maxDeposit(srtVault.address), 0n, `SRT deposit should be disabled`);


        await $erc4626.deposit(jrtVault, deployer, 11);
        $require.eq(await srtVault.totalAssets(), BigInt(200e18));
        $require.eq(await jrtVault.totalAssets(), BigInt(12e18));

        l`maxWithdraw should be adjusted`;
        const minJRTRatio = Number(await accounting.minimumJrtSrtRatio()) / 10 ** 18;
        $require.eq(await cdo.maxWithdraw(jrtVault.address), BigInt(12e18 - 200e18 * minJRTRatio));
        $require.eq(await cdo.maxWithdraw(srtVault.address), BigInt(200e18));


        l`Should recover to pre-drop NAV including JRT new deposits`;
        await cdo.$receipt().setValuationPrice(deployer, BigInt(1e18));
        $require.eq(await jrtVault.totalAssets(), BigInt(112e18));
        $require.eq(await srtVault.totalAssets(), BigInt(100e18));
    },

    async 'handles redemptions during valuation loss'() {
        await $erc4626.deposit(jrtVault, alice, 10_000);
        await $erc4626.deposit(srtVault, alice, 5);

        await $erc4626.deposit(jrtVault, deployer, 100);
        await $erc4626.deposit(srtVault, deployer, 100);

        await cdo.$receipt().setValuationPrice(deployer, BigInt(.5e18));

        // Re-enable JRT deposits, as due to loss pps dropped < jrtShortfallPausePrice
        await cdo.$receipt().setActionStates(deployer, jrtVault.address, true, true);

        const srRedeemed = await $erc4626.redeem(srtVault, deployer, '100%');
        $test.eqDiff(srRedeemed, BigInt(200e18), 1n, `Senior should withdraw 200 assets`);

        const jrRedeemed = await $erc4626.redeem(jrtVault, deployer, '100%');
        const jrPerDollarLoss = $bigint.toWei(105 / 10_100, 18);

        $test.eqDiff(
            jrRedeemed
            , BigInt(100e18) - 100n * jrPerDollarLoss
            , 10n
            , `Junior should withdraw`
        );

        $test.eqDiff(
            await accounting.srtBaseNav()
            , BigInt(5e18)
            , 1n
            , `Remains 5$ in senior's base nav (fact)`
        );

        $test.eqDiff(
            await accounting.jrtBaseNav()
            , $bigint.toWei(10_100) - /* SR covered */ BigInt(100e18) - jrRedeemed
            , 10n
            , `Remains 10_000$ in junior's base NAV minus senior coverage and redemption`
        );
    },
    async 'depletes Junior to the buffer during severe valuation loss' () {
        await $erc4626.deposit(jrtVault, alice, 10);
        await $erc4626.deposit(srtVault, alice, 100);
        await $erc4626.deposit(srtVault, deployer, 3);
        await cdo.$receipt().setValuationPrice(deployer, BigInt(.5e18));
        await test.snapshot('redeem-sr');

        const srtAssets = await srtVault.totalAssets();
        $require.eq(srtAssets, BigInt(100 /* alice */ + 3 /* deployer */ + 9 /** JRT Coverage */) * 10n**18n);
        return UTest.create({
            async $teardown () {
                await test.reset('redeem-sr');
            },
            async 'allows Alice to redeem 100% of Senior shares' () {
                const srRedeemed = await $erc4626.redeem(srtVault, alice, '100%');
                $test.eqDiff(srRedeemed, BigInt(109e18), BigInt(.5e18));
                const [
                    jrtAssets,
                    srtAssets,
                    srtNav,
                    jrtNav,
                ] = await Promise.all([
                    jrtVault.totalAssets(),
                    srtVault.totalAssets(),
                    accounting.srtBaseNav(),
                    accounting.jrtBaseNav(),
                ]);
                $require.eq(jrtAssets, BigInt(1e18), `JRT should be 1 Asset`);
                $require.eq(srtNav, BigInt(3e18), `SRT base NAV should be 3 Assets (100 redeemed of of 103)`);
                $require.eq(srtAssets, jrtNav + srtNav - jrtAssets, `SRT should contain all from JRT minus 1 buffer asset`);
            },
            async 'allows Alice to redeem 50% of Senior shares' () {
                const srRedeemed = await $erc4626.redeem(srtVault, alice, '50%');
                $test.eqDiff(srRedeemed, BigInt(109e18 / 2), BigInt(.5e18));
                const [
                    jrtAssets,
                    srtAssets,
                    srtNav,
                    jrtNav,
                ] = await Promise.all([
                    jrtVault.totalAssets(),
                    srtVault.totalAssets(),
                    accounting.srtBaseNav(),
                    accounting.jrtBaseNav(),
                ]);
                $require.eq(jrtAssets, BigInt(1e18), `JRT should be 1 Asset`);
                $require.eq(srtNav, BigInt(50e18 + 3e18), `SRT base NAV should be 3 Assets (100 redeemed of of 103)`);
                $require.eq(srtAssets, jrtNav + srtNav - jrtAssets, `SRT should contain all from JRT minus 1 buffer asset`);
            },
        });
    },

    async 'sets Senior maxDeposit to zero after depositing the full remaining capacity' () {
        await t.deposit(alice, 800_000, 10_000_000);
        await cdo.$receipt().setValuationPrice(deployer, BigInt(.99e18));
        await cdo.$receipt().setActionStates(deployer, srtVault.address, true, true);

        $test.compare(
            await accounting.maxDeposit(false),
            1_548_821.548
        );
        await t.deposit(alice, 0, 1_548_821.548);
        $test.compare(
            await accounting.maxDeposit(false),
            0
        );
    },
    async 'does not exempt Senior deposits from later valuation losses' () {
        await t.deposit(alice, 800_000, 10_000_000);

        await cdo.$receipt().setValuationPrice(deployer, BigInt(.99e18));
        await cdo.$receipt().setActionStates(deployer, srtVault.address, true, true);

        // Loss: 10M * 0.01 / 0.99 = 101010.101
        // SRT price: (10M + Loss) / 10M = 1.0101
        // JRT price: (800k - Loss) / 800k = 0.8737
        await t.comparePrices(.8737, 1.0101);
        await t.deposit(bob, 0, 990_000);
        $test.compare(
            await accounting.srtFundNav(),
            10_000,
            18,
            `Senior deposit should only fund the existing 1% valuation loss`
        );

        await cdo.$receipt().setValuationPrice(deployer, BigInt(.95e18));
        $test.compare(
            await accounting.srtFundNav(),
            10_000,
            18,
            `Later valuation loss should not increase Senior-funded exemption`
        );

        // Bob mints 990k / 1.0101 = 980_100 Senior shares.
        // Senior base NAV: 10M + 990k = 10_990_000
        // Additional valuation loss: 10_990_000 * 0.05 / 0.95 - 10_000 = 568_421.052
        // JRT price: (800k - 568_421.052) / 800k = 0.28947
        // SRT price: (10_990_000 + 568_421.052) / 10_980_100 = 1.05266
        await t.comparePrices(0.28947, 1.05266);

        const { srt: bobAssets } = await t.redeem(bob, 0, '100%');
        await t.comparePrices(0.28947, 1.05266, 'Expected no price impact');

        // Junior intentionally covers about $540_000 of later valuation loss.
        // Additionally, aggregate accounting over-credits Senior by about $400 versus exact bucketed accounting.
        // That $400 is socialized across Senior holders: Bob gets about $36, Alice gets about $364.

        // Aggregate accounting over-credits Senior by about $400:
        // (10_990_000 + 568_421.052) * 0.95 - (10_000_000 + 990_000 * 0.99) = 400
        // Bob owns 980_100 / 10_980_100 of Senior shares, so his share is ~400 * 8.93% = 36.
        $test.compare(
            bobAssets * 0.95,
            990_000 * 0.99 + 36,
            18,
            `Expected Bob exit value to match his entry value`
        );
    },
    async 'recoveres losses' () {
        await t.deposit(alice, 1_000_000, 1_000_000);

        await cdo.$receipt().setValuationPrice(deployer, BigInt(.99e18));
        await cdo.$receipt().setActionStates(deployer, srtVault.address, true, true);

        await t.deposit(bob, 0, 990_000);

        await cdo.$receipt().setValuationPrice(deployer, BigInt(.95e18));
        // ensure accounting
        await t.deposit(alice, 0, 20);

        await cdo.$receipt().setValuationPrice(deployer, BigInt(.99e18));

        const { srt: bobAssets } = await t.redeem(bob, 0, '100%');
        $test.compare(
            990_000,
            bobAssets,
            18,
            `Bob should receive the same amount as deposited`
        );
    },
    async 'tracks Senior-funded NAV separately for each valuation-loss deposit' () {
        await t.deposit(alice, 500_000, 500_000);

        await cdo.$receipt().setValuationPrice(deployer, BigInt(.99e18));
        await cdo.$receipt().setActionStates(deployer, srtVault.address, true, true);

        await t.deposit(bob, 0, 10_000);
        $test.compare(
            await accounting.srtFundNav(),
            10_000 * 0.01 / 0.99,
            18,
            `Senior deposit should only fund the existing 1% valuation loss`
        );

        await cdo.$receipt().setValuationPrice(deployer, BigInt(.98e18));
        await t.deposit(bob, 0, 10_000);
        $test.compare(
            await accounting.srtFundNav(),
            10_000 * 0.01 / 0.99
            + 10_000 * 0.02 / 0.98,
            18,
            `Senior deposit fund should increase after the 2. valuation loss`
        );

        await cdo.$receipt().setValuationPrice(deployer, BigInt(.97e18));
        await t.deposit(bob, 0, 10_000);
        $test.compare(
            await accounting.srtFundNav(),
            10_000 * 0.01 / 0.99
            + 10_000 * 0.02 / 0.98
            + 10_000 * 0.03 / 0.97,
            18,
            `Senior deposit fund should increase after the 3. valuation loss`
        );

        // 1. deposit 10_000 ->
        //      Bobs NAV = 10_000
        //      Bobs Shares = 10_000 / 1.010101 = 9_900
        // 2. Valuation drop: 0.98 ->
        //      Bobs NAV = (Shares 9_900 * NewPrice 1.020410) = 10_102.060828
        // 3. deposit 10_000 ->
        //      Bobs NAV = 10_102.060828 + 10_000 = 20_102.060828
        //      Bobs Shares = 10_000 / 1.020410 + 9_900
        // 4. Valuation drop: 0.97 ->
        //      Bobs NAV = (Shares 19_699.980586 * NewPrice 1.030936) = 20_309.417795
        // 5. deposit 10_000 ->
        //      Bobs NAV 20_309.417795 + 10_000 = 30_309.417795
        const { srt: bobAssets } = await t.redeem(bob, 0, '100%');
        $test.compare(
            bobAssets,
            30_309.417795,
            18,
            `Expected no PnL for Bob`
        );
    },
    async 'partial recovery after multiple drops with deposits' () {
        await t.deposit(alice, 1_000_000, 50_000);

        const felix = await test.createAccount('felix');
        const carol = await test.createAccount('carol');

        await t.deposit(felix, 0, 10_000);
        await cdo.$receipt().setValuationPrice(deployer, BigInt(.99e18));
        await cdo.$receipt().setActionStates(deployer, srtVault.address, true, true);

        await t.deposit(bob, 0, 10_000);

        await cdo.$receipt().setValuationPrice(deployer, BigInt(.95e18));
        await t.deposit(carol, 0, 10_000);

        await cdo.$receipt().setValuationPrice(deployer, BigInt(.97e18));

        $test.compare(
            await t.maxSrtWithdraw$(carol),
            10_000 * .95,
            18,
            `Expected no PnL for Carol`
        );
        $test.compare(
            await t.maxSrtWithdraw$(bob),
            10_000 * .99,
            18,
            `Expected no PnL for Bob`
        );
        $test.compare(
            await t.maxSrtWithdraw$(felix),
            10_000 * 1,
            18,
            `Expected no PnL for Felix`
        );
        $test.compare(
            await t.maxSrtWithdraw$(alice),
            50_000 * 1,
            18,
            `Expected no PnL for Alice`
        );
    },
    async 'keeps the minimum Junior/Senior ratio stable after new Senior deposits' () {
        await t.deposit(alice, 200, 100);
        $test.compare(
            await accounting.maxDeposit(false),
            $accounting.maxDepositSenior(200, 100, 0.06)
        );

        await cdo.$receipt().setValuationPrice(deployer, BigInt(.5e18));
        await cdo.$receipt().setActionStates(deployer, srtVault.address, true, true);

        $test.compare(
            await accounting.maxDeposit(false),
            $accounting.maxDepositSenior(100, 200, 0.06)
        );

        await t.deposit(alice, 50, 100);
        $test.compare(
            await accounting.maxDeposit(false),
            $accounting.maxDepositSenior(150, 300, 0.06)
        );
    },
    async 'keeps prices stable across Senior deposits and withdrawals within one valuation period' () {
        await t.deposit(alice, 200, 100);

        await cdo.$receipt().setValuationPrice(deployer, BigInt(0.25e18));
        await t.comparePrices(0.005, 2.99);

        await cdo.$receipt().setValuationPrice(deployer, BigInt(1e18));
        await t.comparePrices(1, 1);

        await cdo.$receipt().setValuationPrice(deployer, BigInt(0.5e18));

        // Short-lived valuation loss is treated as a temporary protected state with actions paused.
        // If actions are later re-enabled, the loss becomes the active market regime: deposits and
        // redemptions settle at the current valuation, and any future recovery belongs to all holders.
        await cdo.$receipt().setActionStates(deployer, srtVault.address, true, true);
        await t.comparePrices(0.5, 2);

        await t.deposit(alice, 0, 100);
        await t.comparePrices(0.5, 2);

        await t.withdraw(alice, 0, 100);
        await t.comparePrices(0.5, 2);

        await cdo.$receipt().setValuationPrice(deployer, BigInt(0.25e18));
        await t.comparePrices(0.005, 2.99);

        await cdo.$receipt().setValuationPrice(deployer, BigInt(1e18));
        await t.comparePrices(0.833333, 1.333333);
    },

    async 'handles Senior withdrawals after Senior deposits during valuation loss' () {
        await t.deposit(alice, 200, 100);
        await cdo.$receipt().setValuationPrice(deployer, BigInt(0.5e18));
        await cdo.$receipt().setActionStates(deployer, srtVault.address, true, true);

        await t.deposit(alice, 0, 1000);
        await t.compareNavs(100, 1200);
        await t.withdraw(alice, 0, 1150);
    },

    async 'uses AccountablePushOracle' () {
        await t.deposit(alice, 200, 100);

        const { accountable } = await test.factory.ensureValuationOracles();

        const totalSupply = BigInt(1000e18);
        const totalReserveUsd = BigInt(500e18);
        const observer = await test.factory.getAccount('observer') as TEth.EoAccount;

        const payload = $abiCoder.encode(
            ['uint256', 'address', 'uint256', 'uint256'],
            [await accountable.nonce(), cdo.address, totalSupply, totalReserveUsd]
        );
        const sig = await $sig.signMessage($buffer.fromHex(payload), observer);

        await accountable.$receipt().pushProofOfReserve(
            test.factory.owner,
            cdo.address,
            totalSupply,
            totalReserveUsd,
            sig.signature
        );

        await $test.compare(.5, await accounting.valuationPrice());

        await cdo.$receipt().setActionStates(deployer, srtVault.address, true, true);
        await t.deposit(alice, 0, 1000);
        await t.compareNavs(100, 1200);
        await t.withdraw(alice, 0, 1150);
    },
})

namespace t {
    export async function deposit(depositor: TEth.IAccount, jrtAssets: number, srtAssets: number) {
        jrtAssets > 0 && await $erc4626.deposit(jrtVault, depositor, jrtAssets);
        srtAssets > 0 && await $erc4626.deposit(srtVault, depositor, srtAssets);
    }
    export async function withdraw(depositor: TEth.IAccount, jrtAssets: number, srtAssets: number) {
        jrtAssets > 0 && await $erc4626.withdraw(jrtVault, depositor, jrtAssets);
        srtAssets > 0 && await $erc4626.withdraw(srtVault, depositor, srtAssets);
    }
    export async function redeem(depositor: TEth.IAccount, jrtAssets: number | `${number}%`, srtAssets: number | `${number}%`) {
        const jrtOut = jrtAssets === 0
            ? 0n
            : await $erc4626.redeem(jrtVault, depositor, jrtAssets);
        const srtOut = srtAssets === 0
            ? 0n
            : await $erc4626.redeem(srtVault, depositor, srtAssets);

        const decimals = 18;
        return {
            jrt: $bigint.toEther(jrtOut, decimals),
            srt: $bigint.toEther(srtOut, decimals),
        };
    }
    export async function maxSrtWithdraw$(depositor: TEth.IAccount) {
        const [
            srtOut,
            price,
        ] = await Promise.all([
            srtVault.maxWithdraw(depositor.address),
            accounting.valuationPrice()
        ]);
        const decimals = 18;
        return $bigint.toEther(srtOut * price / BigInt(1e18), decimals);
    }
    export async function comparePrices(jrtPrice: number, srtPrice: number, msg?: string) {
        const [jrtPriceFact, srtPriceFact] = await Promise.all([
            cdo.pricePerShare(jrtVault.address),
            cdo.pricePerShare(srtVault.address),
        ]);
        const jrtPriceFactEth = $bigint.toEther(jrtPriceFact);
        const srtPriceFactEth = $bigint.toEther(srtPriceFact);
        $test.compare(
            jrtPriceFactEth,
            jrtPrice,
            18,
            `JRT price | ${jrtPrice}, ${srtPrice} != ${jrtPriceFactEth}, ${srtPriceFactEth} ${msg ?? ''}`
        );
        $test.compare(
            srtPriceFactEth,
            srtPrice,
            18,
            `SRT price | ${jrtPrice}, ${srtPrice} != ${jrtPriceFactEth}, ${srtPriceFactEth} ${msg ?? ''}`
        );
    }
    export async function compareNavs(jrtNav: number, srtNav: number, msg?: string) {
        const navs = await accounting.totalAssets();
        const jrtNavFactEth = $bigint.toEther(navs.jrtNavT1Projected ?? (navs as any).jrtNavT1 /* continuous accounting */);
        const srtNavFactEth = $bigint.toEther(navs.srtNavT1);
        $test.compare(
            jrtNavFactEth,
            jrtNav,
            18,
            `JRT price | ${jrtNav}, ${srtNav} != ${jrtNavFactEth}, ${srtNavFactEth} ${msg ?? ''}`
        );
        $test.compare(
            srtNavFactEth,
            srtNav,
            18,
            `SRT price | ${jrtNav}, ${srtNav} != ${jrtNavFactEth}, ${srtNavFactEth} ${msg ?? ''}`
        );
    }
}
