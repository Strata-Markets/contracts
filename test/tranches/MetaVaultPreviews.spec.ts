import { UTest } from 'atma-utest'
import { $erc4626 } from './utils/$erc4626';
import { $hh } from './utils/$hh';
import { $require } from 'dequanto/utils/$require';
import { $ethena } from './utils/$ethena';
import { $erc20 } from './utils/$erc20';
import { l } from 'dequanto/utils/$logger';
import { $bigint } from 'dequanto/utils/$bigint';
import { $test } from './utils/$test';

let test = await $hh.deploy('ethena');
let { jrtVault, sUSDe,  } = test.tranches;
let alice = await test.createAccount('alice');
let USDE_INITIAL = 500;

UTest.create({
    async $before () {
        let { client } = test;
        let { sUSDe, USDe, strategy, jrtVault, srtVault, feed, accounting } = test.tranches;
        let { deployer } = test;
        // Disable default cooldowns
        await sUSDe.$receipt().setCooldownDuration(deployer, 0);
        await strategy.$receipt().setCooldowns(deployer, 0n, 0n);

        l`> Simulate Senior Yield`
        let block = await client.getBlock('latest');
        await feed.$receipt().setRoundStaleAfter(deployer, BigInt(10 * 24 * 60 * 60 ));
        await feed.$receipt().updateRoundData(deployer, .05e12, .04e12, block.timestamp)
        await accounting.$receipt().onAprChanged(deployer);

        l`> Deposit and simulate distribution`
        await $erc4626.deposit(jrtVault, deployer, 1000e18);
        await $erc4626.deposit(srtVault, deployer, 1000e18);
        await $ethena.distribute(sUSDe, USDe, deployer, 200e18);
        await client.debug.mine('9h');

        l`> Disable APR to ensure no yield between preview** and deposit/redeem`
        block = await client.getBlock('latest');
        await feed.$receipt().updateRoundData(deployer, 0, 0, block.timestamp);
        await accounting.$receipt().onAprChanged(deployer);

        await $erc4626.deposit(jrtVault, alice, USDE_INITIAL);

        await test.snapshot('meta-vault');
    },
    async $after () {
        await test.wipe();
    },
    async $teardown () {
        await test.reset('meta-vault');
    },
    async 'ERC4626 standard' () {
        return UTest.create({
            async 'Deposit â†’ Redeem' () {
                let arr = [21.3e18, .3e9];
                for (let value of arr) {
                    let assets = BigInt(value);
                    let shares = await jrtVault.previewDeposit(sUSDe.address, assets);
                    let assets1 = await jrtVault.previewRedeem(sUSDe.address, shares);
                    // assets1 <= assets (1wei rounding)
                    $require.lte(assets1, assets);
                }
            },
            async 'Mint â†’ Withdraw' () {
                let arr = [21.3e18, .3e9];
                for (let value of arr) {
                    let shares = BigInt(value);
                    let assets = await jrtVault.previewMint(sUSDe.address, shares);
                    let shares1 = await jrtVault.previewWithdraw(sUSDe.address, assets);
                    // shares1 >= shares (1 wei rounding)
                    $require.gte(shares1, shares);
                }
            }
        })
    },
    async 'maxWithdraw' () {
        let bob = await test.createAccount('bob');
        let assets = 33;
        await $erc4626.mint(sUSDe, bob, assets);
        await $erc4626.depositMeta(jrtVault, sUSDe.address, bob, assets);
        let assetsPreview = await jrtVault.maxWithdraw(sUSDe.address, bob.address);
        // Converting the base cap back to sUSDe rounds down.
        $require.lte(assetsPreview, $bigint.toWei(assets));
        $test.eqDiff(assetsPreview, $bigint.toWei(assets), 1n, `Token maximum rounds down within this fixture's exchange rate`);

        let sharesBefore = await jrtVault.balanceOf(bob.address);
        let sharesPreview = await jrtVault.previewWithdraw(sUSDe.address, assetsPreview);
        $require.lte(sharesPreview, sharesBefore, `Maximum withdrawal fits the share balance`);
        let tokensBefore = await sUSDe.balanceOf(bob.address);
        let { shares: sharesBurned } = await $erc4626.withdrawMeta(jrtVault, sUSDe.address, bob, assetsPreview);
        $require.eq(sharesBurned, sharesPreview, `Maximum withdrawal burns the previewed shares`);
        $require.eq(await sUSDe.balanceOf(bob.address) - tokensBefore, assetsPreview, `Maximum withdrawal pays the quoted tokens`);
    },
    async 'previewRedeem - full balance' () {
        let bob = await test.createAccount('bob');
        let assets = 33;
        await $erc4626.mint(sUSDe, bob, assets);
        await $erc4626.depositMeta(jrtVault, sUSDe.address, bob, assets);
        let shares = await jrtVault.balanceOf(bob.address);
        let assetsPreview = await jrtVault.previewRedeem(sUSDe.address, shares);
        let assetsFact = await $erc4626.redeemMeta(jrtVault, sUSDe.address, bob, '100%');
        $require.eq(assetsPreview, assetsFact, `Full redemption pays the previewed tokens`);
        $require.eq(await jrtVault.balanceOf(bob.address), 0n);
    },
    async 'previewRedeem' () {
        let shares = BigInt(19.9e18);
        let assets = await jrtVault.previewRedeem(sUSDe.address, shares);
        let tokensOutActual = await $erc4626.redeemMeta(jrtVault, sUSDe, alice, shares);
        $require.eq(assets, tokensOutActual, `previewRedeem returns incorrect amount of actual tokens`);
    },
    async 'previewRedeem - withdraw' () {
        let shares = BigInt(19.9e18);
        let assets = await jrtVault.previewRedeem(sUSDe.address, shares);
        let { shares: sharesFact } = await $erc4626.withdrawMeta(jrtVault, sUSDe, alice, assets);
        $require.eq(shares, sharesFact, `previewRedeem -> withdraw returns incorrect amount of shares burned`);
    },
    async 'previewWithdraw' () {
        let assets = BigInt(21.3e18);
        let shares = await jrtVault.previewWithdraw(sUSDe.address, assets);
        let { shares: sharesOutActual } = await $erc4626.withdrawMeta(jrtVault, sUSDe, alice, assets);

        $require.eq(shares, sharesOutActual, `previewWithdraw returns incorrect amount of actual shares burned`);
        await $erc20.eqBalance(sUSDe, alice, assets);
    },
    async 'previewWithdraw - redeem' () {
        let arr = [21.3e18, 19.9e18, .3e3];
        for (let value of arr) {
            let assets = BigInt(value);
            let shares = await jrtVault.previewWithdraw(sUSDe.address, assets);
            let assets1 = await jrtVault.previewRedeem(sUSDe.address, shares);
            let assetsFact = await $erc4626.redeemMeta(jrtVault, sUSDe, alice, shares);
            $require.eq(assets1, assetsFact, `previewWithdraw -> redeem returns incorrect amount of actual tokens`);
        }
    },

    async 'previewDeposit' () {
        await $erc4626.deposit(sUSDe, alice, 1000);

        let arr = [19.9e18, .3e3];
        for (let value of arr) {
            let assets = BigInt(value);
            let shares = await jrtVault.previewDeposit(sUSDe.address, assets);
            let sharesFact = await $erc4626.depositMeta(jrtVault, sUSDe, alice, assets);
            $require.eq(shares, sharesFact, `previewDeposit returns incorrect amount of actual shares minted`);
        }
    },
    async 'previewDeposit - mint' () {
        await $erc4626.deposit(sUSDe, alice, 1000);

        let arr = [19.9e18, .3e3];
        for (let value of arr) {
            let assets = BigInt(value);
            let shares = await jrtVault.previewDeposit(sUSDe.address, assets);
            let assetsFact = await $erc4626.mintMeta(jrtVault, sUSDe, alice, shares);
            $require.eq(assets, assetsFact, `previewDeposit -> mint returns incorrect amount of actual tokens`);
        }
    },

    async 'previewMint' () {
        await $erc4626.deposit(sUSDe, alice, 1000);

        let arr = [19.9e18, .3e3];
        for (let value of arr) {
            let shares = BigInt(value);
            let assets = await jrtVault.previewMint(sUSDe.address, shares);
            let assetsFact = await $erc4626.mintMeta(jrtVault, sUSDe, alice, shares);
            $require.eq(assets, assetsFact, `previewMint returns incorrect amount of actual tokens`);
        }
    },
    async 'previewMint - deposit' () {
        await $erc4626.deposit(sUSDe, alice, 1000);

        let arr = [19.9e18, .3e3];
        for (let value of arr) {
            let shares = BigInt(value);
            let assets = await jrtVault.previewMint(sUSDe.address, shares);
            let sharesFact = await $erc4626.depositMeta(jrtVault, sUSDe, alice, assets);
            $require.eq(shares, sharesFact, `previewMint -> deposit returns incorrect amount of actual shares minted`);
        }
    },
})

