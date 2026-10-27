import { UTest } from 'atma-utest'
import { $require } from 'dequanto/utils/$require';
import { $address } from 'dequanto/utils/$address';
import { $date } from 'dequanto/utils/$date';
import { $contract } from 'dequanto/utils/$contract';
import { $hh } from '../utils/$hh';
import { $erc20 } from '../utils/$erc20';
import { $tranche } from '../utils/$tranche';
import { $test } from '../utils/$test';
import { $bigint } from 'dequanto/utils/$bigint';
import { Tranches } from '@s/platforms/Tranches';
import { $erc4626 } from '../utils/$erc4626';
import { SaturnAprPairProvider } from '@0xc/hardhat/SaturnAprPairProvider/SaturnAprPairProvider';
import { MockStakedUSDat } from '@0xc/hardhat/MockStakedUSDat/MockStakedUSDat';
import { MockStrcPriceOracle } from '@0xc/hardhat/MockStrcPriceOracle/MockStrcPriceOracle';
import { $promise } from 'dequanto/utils/$promise';

const test = $hh.create('saturn');

UTest.create({

    async $before() {
        await test.deploy();
        await test.snapshot('saturn-config');
    },
    async $after() {
        await test.wipe();
    },
    async $teardown() {
        await test.reset('saturn-config')
    },

    // ============================================================
    // Deployment & Configuration
    // ============================================================

    async 'SaturnStrategy::deployment configuration'() {
        let {
            cdo,
            jrtVault,
            srtVault,
            strategy,
            accounting,
            feed,
            provider,
            acm,
            erc20Cooldown,
            unstakeCooldown,
        } = test.tranches;

        let { base, sUSDat } = await test.factory.ensureUnderlying();
        const saturnProvider = new SaturnAprPairProvider(provider.address, provider.client);
        const mockSUSDat = new MockStakedUSDat(sUSDat.address, sUSDat.client);

        // Verify CDO configuration
        $require.eq(await cdo.strategy(), strategy.address, 'CDO strategy should match');
        $require.eq(await cdo.jrtVault(), jrtVault.address, 'CDO jrtVault should match');
        $require.eq(await cdo.srtVault(), srtVault.address, 'CDO srtVault should match');
        $require.eq(await jrtVault.asset(), base.address, 'JRT vault asset should be USDat');
        $require.eq(await srtVault.asset(), base.address, 'SRT vault asset should be USDat');

        // Verify strategy configuration
        $require.eq(await strategy.getSupportedTokens().then(t => t.length), 2, 'Strategy should support 2 tokens');

        // Verify feed configuration
        $require.eq(await feed.provider(), provider.address, 'Feed provider should match');
        $require.eq(await accounting.aprPairFeed(), feed.address, 'Accounting feed should match');

        // Verify cooldown implementation
        const cooldownImpl = await unstakeCooldown.implementations(sUSDat.address);
        $require.eq($address.eq(cooldownImpl, $address.ZERO), false, 'Cooldown implementation should be set');

        // Verify roles
        const UPDATER_FEED_ROLE = $contract.keccak256('UPDATER_FEED_ROLE');
        const UPDATER_CDO_APR_ROLE = $contract.keccak256('UPDATER_CDO_APR_ROLE');
        const COOLDOWN_WORKER_ROLE = await erc20Cooldown.COOLDOWN_WORKER_ROLE();

        $require.eq(
            await acm.hasRole(UPDATER_FEED_ROLE, test.deployer.address),
            true,
            'Owner should have UPDATER_FEED_ROLE'
        );
        $require.eq(
            await acm.hasRole(UPDATER_CDO_APR_ROLE, feed.address),
            true,
            'Feed should have UPDATER_CDO_APR_ROLE'
        );
        $require.eq(
            await acm.hasRole(COOLDOWN_WORKER_ROLE, strategy.address),
            true,
            'Strategy should have COOLDOWN_WORKER_ROLE'
        );

        // Verify action states
        const jrtActions = await cdo.actionsJrt();
        const srtActions = await cdo.actionsSrt();
        $require.eq(jrtActions.isDepositEnabled, true, 'JRT deposits should be enabled');
        $require.eq(jrtActions.isWithdrawEnabled, true, 'JRT withdrawals should be enabled');
        $require.eq(srtActions.isDepositEnabled, true, 'SRT deposits should be enabled');
        $require.eq(srtActions.isWithdrawEnabled, true, 'SRT withdrawals should be enabled');
    },

    // ============================================================
    // Deposit Fee Handling
    // ============================================================

    async 'SaturnStrategy::deposit fee impact'() {
        const { deployer } = test.factory;
        const { base, sUSDat } = await test.factory.ensureUnderlying();
        const { jrtVault, strategy, cdo } = test.tranches;

        const AMOUNT = $bigint.toWei(10_000, 6);
        await $erc20.mint(base, deployer, deployer.address, AMOUNT);
        await $tranche.deposit(jrtVault, deployer, base, AMOUNT);

        // After deposit, strategy totalAssets should be ~99.9% of deposited amount
        // due to sUSDat's 0.1% deposit fee
        const totalAssets = await strategy.totalAssets();
        const expectedPostFee = $bigint.multWithFloat(AMOUNT, 0.999); // 0.1% fee

        // Allow small rounding tolerance
        $test.eqDiff(totalAssets, expectedPostFee, 1n, 'Total assets should reflect 0.1% deposit fee');

        no_fee_with_sUSDat_deposit: {
            // Deposit the sUSDat
            const sUSDatShares = await sUSDat.previewWithdraw(AMOUNT);
            await $erc4626.mint(sUSDat as any, deployer, sUSDatShares);
            await $tranche.deposit(jrtVault, deployer, sUSDat, sUSDatShares);

            const totalAssets = await strategy.totalAssets();
            const totalAssetsExpected = AMOUNT + expectedPostFee; // 0% fee + 0.1% fee
            $test.eqDiff(totalAssets, totalAssetsExpected, 1n, 'Total assets should reflect 0.1% deposit fee');

            const pps = await cdo.pricePerShare(jrtVault.address);
            $require.eq(pps, BigInt(1e18), 'Price per share should remain 1');
        }
    },

    // ============================================================
    // APR Provider
    // ============================================================

    async 'SaturnStrategy::APR provider setAprTarget'() {
        const { deployer } = test.factory;
        const { provider, acm } = test.tranches;
        const saturnProvider = new SaturnAprPairProvider(provider.address, provider.client);

        // Set aprTarget to 8.05% (70% of 11.5% dividend rate)
        const targetAPR = 0.0805e12; // 12 decimal precision
        await saturnProvider.$receipt().setAprTarget(deployer, targetAPR);

        // Verify
        const {aprTarget_} = await saturnProvider.getAprPair();
        $require.eq(aprTarget_, targetAPR, 'aprTarget should be set to 8.05%');
    },

    async 'SaturnStrategy::APR provider bounds check'() {
        const { deployer } = test.factory;
        const { provider } = test.tranches;
        const saturnProvider = new SaturnAprPairProvider(provider.address, provider.client);

        // Should reject APR > 40% (BOUND_MAX = .4e12)
        const tooHigh = 0.41e12;
        let reverted = false;
        try {
            await saturnProvider.$receipt().setAprTarget(deployer, tooHigh);
        } catch (e) {
            reverted = true;
        }
        $require.eq(reverted, true, 'Should revert for APR > 40%');
    },

    // ============================================================
    // Performance Fee
    // ============================================================

    async 'SaturnStrategy::performance fee on yield'() {
        const { client } = test;
        const { deployer } = test.factory;
        const { base, sUSDat } = await test.factory.ensureUnderlying();
        const { accounting, jrtVault, strategy } = test.tranches;

        // Deposit
        await $erc20.mint(base, deployer, deployer.address, 10_001);
        await $tranche.deposit(jrtVault, deployer, base, 10_000);

        // Simulate yield via balance manipulation
        const testHelper = new Tranches.saturn.TestHelper(test);
        await testHelper.distributeRewards({
            assetsBefore: await strategy.totalAssets(),
            dt: '30days',
            apr: 0.10, // 10% annualized
        });

        await client.debug.mine('30days');

        // Trigger accounting update with a small deposit
        await $tranche.deposit(jrtVault, deployer, base, 1);

        const feeAccrued = $bigint.toEther(await accounting.reserveNav(), 6);
        // Expected: 30 days of 10% APR on ~9990 (after deposit fee)
        // ~9990 * 0.10 * 30/365 * 7.5% fee ≈ ~6.15
        $require.gt(feeAccrued, 0, 'Performance fee should accrue');
    },

    // ============================================================
    // STRC Price Volatility (Junior absorbs)
    // ============================================================

    async 'SaturnStrategy::STRC price drop impact'() {
        const { deployer } = test.factory;
        const { base, sUSDat } = await test.factory.ensureUnderlying();
        const { lens } = await test.factory.ensureLenses();
        const { jrtVault, srtVault, strategy, cdo, accounting } = test.tranches;
        const mockSUSDat = new MockStakedUSDat(sUSDat.address, sUSDat.client);

        const oracle = new MockStrcPriceOracle(await sUSDat.strcOracle(), sUSDat.client);
        const [price, priceDecimals] = await oracle.getPrice();
        const priceEth = $bigint.toEther(price, priceDecimals);

        // Deposit into both tranches
        await $erc20.mint(base, deployer, deployer.address, 20_000);
        await $tranche.deposit(jrtVault, deployer, base, 10_000);
        await $tranche.deposit(srtVault, deployer, base, 10_000);

        // Check Saturn' exit fee
        const fee = await strategy.depositFeeBps(jrtVault.address, base.address, BigInt(10_000e18));
        $require.eq(await jrtVault.totalAssets(), BigInt(10_000e6 * (1 - Number(fee) / 10000)));
        $require.eq(await srtVault.totalAssets(), BigInt(10_000e6 * (1 - Number(fee) / 10000)));

        const reserveBps = await accounting.reserveBps();
        const srtGain = await $tranche.calcWeiPerT(srtVault, lens, '1s');


        // Record pre-drop NAV
        const totalNavsT0 = await cdo.totalAssetsUnlocked();
        const totalAssetsT0 = $bigint.toEther(totalNavsT0.jrtNav + totalNavsT0.srtNav, 6);


        // Simulate STRC price drop by reducing sUSDat balance
        // This simulates what happens when totalAssets() returns less
        const currentBalance = await strategy.totalAssets();
        const droppedBalance = currentBalance * 90n / 100n; // 10% drop
        const shares = await mockSUSDat.convertToShares(droppedBalance);

        await $erc20.setBalanceAny(sUSDat as any, strategy.address, shares);
        // Trigger accounting
        await accounting.$receipt().onAprChanged(deployer)

        // Verify totalAssets dropped
        const totalAssetsT1 = $bigint.toEther(await strategy.totalAssets(), 6);
        $test.eqDiff(totalAssetsT1, totalAssetsT0 * 0.9, totalAssetsT0 * 0.02, 'Total assets should drop ~10%');

        const navAfterDrop1 = await cdo.totalAssetsUnlocked();
        $require.eq(totalNavsT0.srtNav + srtGain, navAfterDrop1.srtNav, 'Sr should remain and receive gain for 1s');


        // Increase strcBalance to recover loss
        increase_strc: {
            const loss = totalAssetsT0 - totalAssetsT1;
            const lossInStrc = loss / priceEth;

            const shares = await sUSDat.balanceOf(strategy.address);
            const totalShares = await sUSDat.totalSupply();

            // lossInStrc is what should be recovered for the strategy;
            // however, sUSDat totalSupply is larger (increasing the value per share)
            const totalSrcIn =  $bigint.toWei(lossInStrc, 6) * totalShares / shares

            await sUSDat.storage.$set('strcBalance', totalSrcIn);
            // Trigger accounting
            await accounting.$receipt().onAprChanged(deployer);

            $test.eqDiff(await strategy.totalAssets(), totalNavsT0.jrtNav + totalNavsT0.srtNav, 1n, 'Total assets should recover up to 1wei rounding');
        }

        check_strc_gain: {
            const gain = totalAssetsT0 - totalAssetsT1;
            const reserveNav = await accounting.totalReserve();
            const reserveNavEth = $bigint.toEther(reserveNav, 6);
            const jrtNav = await jrtVault.totalAssets();

            $require.gt(reserveBps, BigInt(0.01e18));
            $test.eqDiff(0, reserveNavEth, .01, `No performance fee under the watermark`);

            // We have recovered the loss;
            // however, for 2 seconds Junior has paid Senior the APR, and we have collected the reserve fee
            $test.eqDiff(jrtNav + reserveNav + 2n * srtGain, totalNavsT0.jrtNav, 2n, 'Jrt+Reserve should be equal to first deposit state');
        }

        decrease_strc_price: {
            const totalUSDat = await base.balanceOf(sUSDat.address);
            const totalAssetsT2 = await strategy.totalAssets();
            const totalNavsT2 = await cdo.totalAssetsUnlocked();

            // 50% price drop equals to 5% strategy loss, as the Strc$ amount held is 10%
            const priceT1 = price / 2n;

            // mine 2 blocks (2s)
            await oracle.$receipt().setPrice(deployer, priceT1);
            // Trigger accounting
            await accounting.$receipt().onAprChanged(deployer)


            // Verify totalAssets dropped
            const totalAssetsT3 = await strategy.totalAssets()
            $test.eqDiff(
                totalAssetsT3 //
                , $bigint.multWithFloat(totalAssetsT2, .95)
                , 1n //
                , 'Total assets should drop ~5%' //
            );

            // Verify Sr gain after 4s
            const totalNavsT3 = await cdo.totalAssetsUnlocked();
            $test.eqDiff(
                totalNavsT3.srtNav //
                , totalNavsT0.srtNav + 4n * srtGain
                , 1n //
                , 'Sr should remain and receive gain for 4 blocks'
            );

            // Verify Jr dropped by 5%
            $test.eqDiff(
                totalNavsT3.jrtNav //
                , totalNavsT2.jrtNav - $bigint.multWithFloat(totalAssetsT2, .05) - 2n * srtGain
                , 2n //
                , 'Jr should drop after price drop and funding Sr for 2 blocks (2s)'
            );
        }
    },

    // ============================================================
    // Redemption Fee
    // ============================================================

    async 'SaturnStrategy::redemption fees'() {
        const { deployer } = test.factory;
        const { base } = await test.factory.ensureUnderlying();
        const { accounting, jrtVault, srtVault } = test.tranches;

        await $tranche.ensureCoverage(test, 50, { jrt: 10_000 });
        await $erc20.mint(base, deployer, deployer.address, 2000);

        return UTest.create({
            async 'from Junior'() {
                const AMOUNT = 1000;
                const AMOUNT_WEI = $bigint.toWei(AMOUNT, 6);
                await $tranche.deposit(jrtVault, deployer, base, AMOUNT_WEI);
                let { tx } = await $erc4626.withdrawMeta(jrtVault, base, deployer, AMOUNT_WEI);
                const feeAccrued = accounting.extractLogsFeeAccrued(tx.receipt)[0].params;
                // At uneven amounts, amountToTranche === amountToReserve + 1wei
                $test.eqDiff(feeAccrued.amountToReserve, feeAccrued.amountToTranche, 1n, `Saturn 50% retention`);

                const totalFeeFact = $bigint.toEther(feeAccrued.amountToReserve + feeAccrued.amountToTranche, 6);
                const feeRatio = Tranches.saturn.jrt.sharesCooldown[2].feeBps / 10000;
                const totalFeeCalc = AMOUNT * feeRatio / (1 - feeRatio);
                $test.eqDiff(totalFeeFact, totalFeeCalc, .0001);
            },
            async 'from Senior'() {
                const AMOUNT = 500;
                const AMOUNT_WEI = $bigint.toWei(AMOUNT, 6);
                await $tranche.deposit(srtVault, deployer, base, AMOUNT_WEI);
                let { tx } = await $erc4626.withdrawMeta(srtVault, base, deployer, AMOUNT_WEI);
                const feeAccrued = accounting.extractLogsFeeAccrued(tx.receipt)[0].params;
                $test.eqDiff(feeAccrued.amountToReserve, feeAccrued.amountToTranche, 1n, `Saturn 50% retention`);

                const totalFeeFact = $bigint.toEther(feeAccrued.amountToReserve + feeAccrued.amountToTranche, 6);
                const feeRatio = Tranches.saturn.srt.sharesCooldown[2].feeBps / 10000;
                const totalFeeCalc = AMOUNT * feeRatio / (1 - feeRatio);
                $test.eqDiff(totalFeeFact, totalFeeCalc, .0001);
            },
        });
    },

    async 'SaturnStrategy:: Token Pause-States'() {
        const { deployer } = test.factory;
        const { base, sUSDat } = await test.factory.ensureUnderlying();
        const { accounting, jrtVault, srtVault, strategy } = test.tranches;

        await $erc4626.deposit(sUSDat as any, deployer, 500);

        return UTest.create({
            async 'disable and enable Senior sUSDat'() {
                await strategy.$receipt().setTokenConfig(deployer, sUSDat.address, {
                    jrtDepositsPaused: false,
                    jrtWithdrawalsPaused: false,
                    srtDepositsPaused: true,
                    srtWithdrawalsPaused: false,
                });

                await $erc4626.depositMeta(jrtVault, sUSDat, deployer, 50)
                const { error: errDeposit } = await $promise.caught(
                    $erc4626.depositMeta(srtVault, sUSDat, deployer, 50)
                );
                $require.match(/DepositRejectedByStrategy/, errDeposit.message);

                await strategy.$receipt().setTokenConfig(deployer, sUSDat.address, {
                    jrtDepositsPaused: true,
                    jrtWithdrawalsPaused: true,
                    srtDepositsPaused: false,
                    srtWithdrawalsPaused: true,
                });

                const shares = await $erc4626.depositMeta(srtVault, sUSDat, deployer, 50);
                $require.eq($bigint.toEther(shares), 50);

                const { error: errWithdraw } = await $promise.caught(
                    $erc4626.redeemMeta(srtVault, sUSDat, deployer, '100%')
                );
                $require.match(/TokenWithdrawalPaused/, errWithdraw.message);
            }
        });
    },
});
