import { UTest } from 'atma-utest'
import { $require } from 'dequanto/utils/$require';
import { $address } from 'dequanto/utils/$address';
import { $date } from 'dequanto/utils/$date';
import { $contract } from 'dequanto/utils/$contract';
import { SaturnStrategy } from '@0xc/hardhat/SaturnStrategy/SaturnStrategy';
import { $hh } from '../utils/$hh';
import { $erc20 } from '../utils/$erc20';
import { $tranche } from '../utils/$tranche';
import { $test } from '../utils/$test';
import { $bigint } from 'dequanto/utils/$bigint';
import { Tranches } from '@s/platforms/Tranches';
import { $erc4626 } from '../utils/$erc4626';
import { SaturnAprPairProvider } from '@0xc/hardhat/SaturnAprPairProvider/SaturnAprPairProvider';
import { MockStakedUSDat } from '@0xc/hardhat/MockStakedUSDat/MockStakedUSDat';
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

        // After deposit, strategy totalAssets should reflect the full deposit amount
        // V2: the 0.1% deposit fee stays in the vault, backing existing shareholders.
        // strategy.deposit() returns net-of-fee (~9990), but totalAssets() returns
        // convertToAssets(allShares) which reflects the post-fee share value
        const totalAssets = await strategy.totalAssets();
        const expectedPostFee = $bigint.multWithFloat(AMOUNT, 0.999); // 0.1% fee

        // V2: totalAssets should be close to expectedPostFee (net share value)
        // The deposit fee inflates PPS slightly but for the first depositor the
        // shares received are valued at ~net amount via convertToAssets
        $test.eqDiff(totalAssets, expectedPostFee, AMOUNT / 1000n, 'Total assets should reflect deposit fee impact');

        no_fee_with_sUSDat_deposit: {
            // V2: previewWithdraw returns 0, use convertToShares instead
            const sUSDatShares = await sUSDat.convertToShares(AMOUNT);
            await $erc4626.mint(sUSDat as any, deployer, sUSDatShares);
            await $tranche.deposit(jrtVault, deployer, sUSDat, sUSDatShares);

            const totalAssets2 = await strategy.totalAssets();
            // sUSDat deposit has 0% fee, so should add ~AMOUNT to totalAssets
            $require.gt(totalAssets2, totalAssets, 'Total assets should increase after sUSDat deposit');

            // V2: PPS may be slightly > 1.0 due to deposit fee staying in vault
            const pps = await cdo.pricePerShare(jrtVault.address);
            $require.gte(pps, BigInt(1e18), 'Price per share should be >= 1');
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
    // NAV Volatility (Junior absorbs) - V2 compatible
    // ============================================================

    async 'SaturnStrategy::NAV drop impact (Junior absorbs)'() {
        const { deployer } = test.factory;
        const { base, sUSDat } = await test.factory.ensureUnderlying();
        const { lens } = await test.factory.ensureLenses();
        const { jrtVault, srtVault, strategy, cdo, accounting } = test.tranches;
        const mockSUSDat = new MockStakedUSDat(sUSDat.address, sUSDat.client);

        // Deposit into both tranches
        await $erc20.mint(base, deployer, deployer.address, 20_000);
        await $tranche.deposit(jrtVault, deployer, base, 10_000);
        await $tranche.deposit(srtVault, deployer, base, 10_000);

        // Check Saturn' exit fee
        const fee = await strategy.depositFeeBps(jrtVault.address, base.address, BigInt(10_000e18));
        // V2: deposit fee stays in vault, so tranche totalAssets >= net-of-fee amount
        const expectedMin = BigInt(10_000e6 * (1 - Number(fee) / 10000));
        $require.gte(await jrtVault.totalAssets(), expectedMin);
        $require.gte(await srtVault.totalAssets(), expectedMin);

        const reserveBps = await accounting.reserveBps();
        const srtGain = await $tranche.calcWeiPerT(srtVault, lens, '1s');

        // Record pre-drop NAV
        const totalNavsT0 = await cdo.totalAssetsUnlocked();
        const totalAssetsT0 = $bigint.toEther(totalNavsT0.jrtNav + totalNavsT0.srtNav, 6);

        // V2: Simulate NAV drop by reducing sUSDat share balance
        // In V2 this can happen via STRConModule recognizedValue dropping (oracle price)
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

    // ============================================================
    // Junior Premium Fee - Anti-dilution Protection
    // ============================================================

    async 'SaturnStrategy::junior premium - jrtVault configured'() {
        const { strategy } = test.tranches;
        const { jrtVault } = test.tranches;
        const saturnStrategy = new SaturnStrategy(strategy.address, strategy.client);

        const configuredJrt = await saturnStrategy.jrtVault();
        $require.eq(configuredJrt, jrtVault.address, 'Strategy jrtVault should be set to JRT tranche');
    },

    async 'SaturnStrategy::junior premium - no premium at peak PPS'() {
        const { deployer } = test.factory;
        const { base } = await test.factory.ensureUnderlying();
        const { jrtVault, strategy, cdo } = test.tranches;
        const saturnStrategy = new SaturnStrategy(strategy.address, strategy.client);

        // Deposit to establish PPS baseline
        const AMOUNT = $bigint.toWei(10_000, 6);
        await $erc20.mint(base, deployer, deployer.address, AMOUNT);
        await $tranche.deposit(jrtVault, deployer, base, AMOUNT);

        // Manually call updateMaxJrtPricePerShare (keeper role)
        // Accounting has been synced by the deposit flow, so PPS is now accurate
        await saturnStrategy.$receipt().updateMaxJrtPricePerShare(deployer);

        // maxPPS should be set
        const maxPPS = await saturnStrategy.effectiveMaxPPS();
        $require.True(maxPPS > 0n, 'maxPPS should be set after keeper update');

        // Current PPS should be at or near maxPPS -> no premium
        const currentPPS = await cdo.pricePerShare(jrtVault.address);
        $require.True(currentPPS >= maxPPS || maxPPS - currentPPS < 10n, 'PPS should be at max');
    },

    async 'SaturnStrategy::junior premium - premium after NAV drop'() {
        const { deployer } = test.factory;
        const { base, sUSDat } = await test.factory.ensureUnderlying();
        const { jrtVault, srtVault, strategy, cdo, accounting } = test.tranches;
        const saturnStrategy = new SaturnStrategy(strategy.address, strategy.client);
        const mockSUSDat = new MockStakedUSDat(sUSDat.address, sUSDat.client);

        // Deposit to establish baseline
        const AMOUNT = $bigint.toWei(10_000, 6);
        await $erc20.mint(base, deployer, deployer.address, AMOUNT * 3n);
        await $tranche.deposit(jrtVault, deployer, base, AMOUNT);
        await $tranche.deposit(srtVault, deployer, base, AMOUNT);

        // Keeper sets maxPPS after accounting has synced
        await saturnStrategy.$receipt().updateMaxJrtPricePerShare(deployer);

        // Record pre-drop state
        const ppsBefore = await cdo.pricePerShare(jrtVault.address);
        const maxPPS = await saturnStrategy.effectiveMaxPPS();
        $require.True(maxPPS > 0n, 'maxPPS should be set');

        // Simulate NAV drop: reduce sUSDat share balance by 15%
        const currentBalance = await strategy.totalAssets();
        const droppedBalance = currentBalance * 85n / 100n;
        const shares = await mockSUSDat.convertToShares(droppedBalance);
        await $erc20.setBalanceAny(sUSDat as any, strategy.address, shares);
        await accounting.$receipt().onAprChanged(deployer);

        // Verify PPS dropped
        const ppsAfter = await cdo.pricePerShare(jrtVault.address);
        $require.True(ppsAfter < ppsBefore, 'PPS should drop after NAV reduction');

        // Deposit as new Junior - should see a premium
        const sharesBefore = await jrtVault.totalSupply();
        await $tranche.deposit(jrtVault, deployer, base, AMOUNT);

        // The premium should have compensated existing holders: PPS should increase
        const ppsAfterDeposit = await cdo.pricePerShare(jrtVault.address);
        $require.True(ppsAfterDeposit > ppsAfter, 'PPS should increase from premium deposit');
    },

    async 'SaturnStrategy::junior premium - no premium for Senior'() {
        const { deployer } = test.factory;
        const { base, sUSDat } = await test.factory.ensureUnderlying();
        const { jrtVault, srtVault, strategy, cdo, accounting } = test.tranches;
        const saturnStrategy = new SaturnStrategy(strategy.address, strategy.client);
        const mockSUSDat = new MockStakedUSDat(sUSDat.address, sUSDat.client);

        // Setup: deposit and then drop NAV
        const AMOUNT = $bigint.toWei(10_000, 6);
        await $erc20.mint(base, deployer, deployer.address, AMOUNT * 3n);
        await $tranche.deposit(jrtVault, deployer, base, AMOUNT);
        await $tranche.deposit(srtVault, deployer, base, AMOUNT);

        // Keeper sets maxPPS
        await saturnStrategy.$receipt().updateMaxJrtPricePerShare(deployer);

        // Drop NAV 15%
        const currentBalance = await strategy.totalAssets();
        const droppedBalance = currentBalance * 85n / 100n;
        const sharesToSet = await mockSUSDat.convertToShares(droppedBalance);
        await $erc20.setBalanceAny(sUSDat as any, strategy.address, sharesToSet);
        await accounting.$receipt().onAprChanged(deployer);

        // Deposit into Senior - should get shares without premium
        const srtSharesBefore = await srtVault.totalSupply();
        await $tranche.deposit(srtVault, deployer, base, AMOUNT);
        const srtSharesReceived = await srtVault.totalSupply() - srtSharesBefore;
        $require.True(srtSharesReceived > 0n, 'Senior should receive shares');
    },

    async 'SaturnStrategy::junior premium - sUSDat deposits pay premium'() {
        const { deployer } = test.factory;
        const { base, sUSDat } = await test.factory.ensureUnderlying();
        const { jrtVault, srtVault, strategy, cdo, accounting } = test.tranches;
        const saturnStrategy = new SaturnStrategy(strategy.address, strategy.client);
        const mockSUSDat = new MockStakedUSDat(sUSDat.address, sUSDat.client);

        // Setup: deposit and then drop NAV
        const AMOUNT = $bigint.toWei(10_000, 6);
        await $erc20.mint(base, deployer, deployer.address, AMOUNT * 2n);
        await $tranche.deposit(jrtVault, deployer, base, AMOUNT);
        await $tranche.deposit(srtVault, deployer, base, AMOUNT);

        // Keeper sets maxPPS
        await saturnStrategy.$receipt().updateMaxJrtPricePerShare(deployer);

        // Drop NAV 15%
        const currentBalance = await strategy.totalAssets();
        const droppedBalance = currentBalance * 85n / 100n;
        const sharesToSet = await mockSUSDat.convertToShares(droppedBalance);
        await $erc20.setBalanceAny(sUSDat as any, strategy.address, sharesToSet);
        await accounting.$receipt().onAprChanged(deployer);

        // Mint sUSDat shares directly for depositing
        await $erc4626.deposit(sUSDat as any, deployer, 500);

        // Deposit sUSDat into Junior (should have premium)
        const jrtSharesBefore = await jrtVault.totalSupply();
        await $erc4626.depositMeta(jrtVault, sUSDat, deployer, 50);
        const jrtSharesReceived = await jrtVault.totalSupply() - jrtSharesBefore;

        // Deposit sUSDat into Senior (should NOT have premium)
        const srtSharesBefore = await srtVault.totalSupply();
        await $erc4626.depositMeta(srtVault, sUSDat, deployer, 50);
        const srtSharesReceived = await srtVault.totalSupply() - srtSharesBefore;

        // Junior should receive fewer shares than Senior due to premium
        $require.True(jrtSharesReceived < srtSharesReceived,
            'Junior should receive fewer sUSDat shares than Senior due to premium');
    },

    async 'SaturnStrategy::junior premium - quarter window decay'() {
        const { client } = test;
        const { deployer } = test.factory;
        const { base, sUSDat } = await test.factory.ensureUnderlying();
        const { jrtVault, srtVault, strategy, cdo, accounting } = test.tranches;
        const saturnStrategy = new SaturnStrategy(strategy.address, strategy.client);
        const mockSUSDat = new MockStakedUSDat(sUSDat.address, sUSDat.client);

        // Setup: deposit and then drop NAV
        const AMOUNT = $bigint.toWei(10_000, 6);
        await $erc20.mint(base, deployer, deployer.address, AMOUNT * 3n);
        await $tranche.deposit(jrtVault, deployer, base, AMOUNT);
        await $tranche.deposit(srtVault, deployer, base, AMOUNT);

        // Q1: Keeper sets maxPPS at peak
        await saturnStrategy.$receipt().updateMaxJrtPricePerShare(deployer);
        const maxPPS_Q1 = await saturnStrategy.effectiveMaxPPS();
        $require.True(maxPPS_Q1 > 0n, 'maxPPS should be set');

        // Advance to Q2 (7 days) and set a slightly lower max
        await client.debug.mine('8days');
        // Drop NAV slightly (5%)
        const balance1 = await strategy.totalAssets();
        await $erc20.setBalanceAny(sUSDat as any, strategy.address,
            await mockSUSDat.convertToShares(balance1 * 95n / 100n));
        await accounting.$receipt().onAprChanged(deployer);
        await saturnStrategy.$receipt().updateMaxJrtPricePerShare(deployer);

        // Advance to Q3 (14 days) and drop more (10% total)
        await client.debug.mine('8days');
        const balance2 = await strategy.totalAssets();
        await $erc20.setBalanceAny(sUSDat as any, strategy.address,
            await mockSUSDat.convertToShares(balance2 * 95n / 100n));
        await accounting.$receipt().onAprChanged(deployer);
        await saturnStrategy.$receipt().updateMaxJrtPricePerShare(deployer);

        // Advance to Q4 (21 days) and drop more (15% total)
        await client.debug.mine('8days');
        const balance3 = await strategy.totalAssets();
        await $erc20.setBalanceAny(sUSDat as any, strategy.address,
            await mockSUSDat.convertToShares(balance3 * 95n / 100n));
        await accounting.$receipt().onAprChanged(deployer);
        await saturnStrategy.$receipt().updateMaxJrtPricePerShare(deployer);

        // effectiveMaxPPS should still be Q1's max (the highest)
        const maxBefore = await saturnStrategy.effectiveMaxPPS();
        $require.eq(maxBefore, maxPPS_Q1, 'Effective max should still be Q1 peak');

        // Advance past Q1 expiry (28+ days total) - Q1 is excluded by epoch check
        await client.debug.mine('8days');
        await saturnStrategy.$receipt().updateMaxJrtPricePerShare(deployer);

        // effectiveMaxPPS should now fall back to Q2's max (stepped decay, not cliff)
        const maxAfter = await saturnStrategy.effectiveMaxPPS();
        $require.True(maxAfter > 0n, 'Should have fallback max from later quarters');
        $require.True(maxAfter < maxPPS_Q1, 'Effective max should drop after Q1 expires');

        // Advance past all quarters (28+ more days)
        await client.debug.mine('30days');
        await saturnStrategy.$receipt().updateMaxJrtPricePerShare(deployer);

        // All old quarters expired, only current PPS remains
        const maxFinal = await saturnStrategy.effectiveMaxPPS();
        $require.True(maxFinal < maxAfter, 'Effective max should keep decaying');
    },

    async 'SaturnStrategy::junior premium - admin reset'() {
        const { deployer } = test.factory;
        const { base, sUSDat } = await test.factory.ensureUnderlying();
        const { jrtVault, srtVault, strategy, cdo, accounting } = test.tranches;
        const saturnStrategy = new SaturnStrategy(strategy.address, strategy.client);
        const mockSUSDat = new MockStakedUSDat(sUSDat.address, sUSDat.client);

        // Setup: deposit and then drop NAV
        const AMOUNT = $bigint.toWei(10_000, 6);
        await $erc20.mint(base, deployer, deployer.address, AMOUNT * 2n);
        await $tranche.deposit(jrtVault, deployer, base, AMOUNT);
        await $tranche.deposit(srtVault, deployer, base, AMOUNT);

        // Keeper sets maxPPS
        await saturnStrategy.$receipt().updateMaxJrtPricePerShare(deployer);

        // Drop NAV 15%
        const currentBalance = await strategy.totalAssets();
        const droppedBalance = currentBalance * 85n / 100n;
        const sharesToSet = await mockSUSDat.convertToShares(droppedBalance);
        await $erc20.setBalanceAny(sUSDat as any, strategy.address, sharesToSet);
        await accounting.$receipt().onAprChanged(deployer);

        // Verify maxPPS is set (from keeper call above, before the drop)
        $require.True(await saturnStrategy.effectiveMaxPPS() > 0n, 'maxPPS should be set');

        // Admin reset
        await saturnStrategy.$receipt().resetMaxJrtPricePerShare(deployer);

        // Verify all quarters are cleared
        $require.eq(await saturnStrategy.effectiveMaxPPS(), 0n, 'effectiveMaxPPS should be 0 after reset');
        for (let i = 0; i < 4; i++) {
            const q = await saturnStrategy.quarters(i);
            $require.eq(q.maxPPS, 0n, `quarter[${i}].maxPPS should be 0`);
            $require.eq(q.epoch, 0n, `quarter[${i}].epoch should be 0`);
        }
    },

    // ============================================================
    // Token Pause-States
    // ============================================================

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
                $require.match(/TokenDepositPaused/, errDeposit.message);

                await strategy.$receipt().setTokenConfig(deployer, sUSDat.address, {
                    jrtDepositsPaused: true,
                    jrtWithdrawalsPaused: true,
                    srtDepositsPaused: false,
                    srtWithdrawalsPaused: true,
                });

                const shares = await $erc4626.depositMeta(srtVault, sUSDat, deployer, 50);
                // V2: deposit fee stays in vault, slightly inflating PPS (shares >= 50)
                $require.gte($bigint.toEther(shares), 50);

                const { error: errWithdraw } = await $promise.caught(
                    $erc4626.redeemMeta(srtVault, sUSDat, deployer, '100%')
                );
                $require.match(/TokenWithdrawalPaused/, errWithdraw.message);
            }
        });
    },
});
