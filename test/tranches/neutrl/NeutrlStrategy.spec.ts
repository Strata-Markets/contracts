import { UTest } from 'atma-utest'
import { $require } from 'dequanto/utils/$require';
import { $address } from 'dequanto/utils/$address';
import { $date } from 'dequanto/utils/$date';
import { $contract } from 'dequanto/utils/$contract';
import { $hh } from '../utils/$hh';
import { $erc20 } from '../utils/$erc20';
import { $neutrl } from '../utils/$neutrl';
import { $tranche } from '../utils/$tranche';
import { l } from 'dequanto/utils/$logger';
import { $test } from '../utils/$test';
import { $bigint } from 'dequanto/utils/$bigint';
import { Tranches } from '@s/platforms/Tranches';
import { $erc4626 } from '../utils/$erc4626';

const test = $hh.create('neutrl');

UTest.create({

    async $before() {
        await test.deploy();
        await test.snapshot('neutrl-config');
    },
    async $after() {
        await test.reset();
    },
    async $teardown() {
        await test.reset('neutrl-config')
    },
    async 'NeutrlStrategy::test'() {
        let {
            cdo,
            jrtVault,
            srtVault,
            strategy,
            accounting,
            feed,
            provider: sNUSDAprPairProvider,
            acm,
            erc20Cooldown,
            unstakeCooldown,
        } = test.tranches;

        let {
            NUSD,
            sNUSD,
        } = await test.factory.ensureUnderlying();

        // Verify CDO configuration
        $require.eq(await cdo.strategy(), strategy.address, 'CDO strategy should match');
        $require.eq(await cdo.jrtVault(), jrtVault.address, 'CDO jrtVault should match');
        $require.eq(await cdo.srtVault(), srtVault.address, 'CDO srtVault should match');
        $require.eq(await jrtVault.asset(), NUSD.address, 'JRT vault asset should be NUSD');
        $require.eq(await srtVault.asset(), NUSD.address, 'SRT vault asset should be NUSD');

        // Verify strategy configuration
        $require.eq(await strategy.sNUSD(), sNUSD.address, 'Strategy sNUSD should match');
        $require.eq(await strategy.NUSD(), NUSD.address, 'Strategy NUSD should match');

        // Verify cooldowns (0 for JRT, 0 for SRT as per Tranches.neutrl config)
        const jrtCooldown = await strategy.sNUSDCooldownJrt();
        const srtCooldown = await strategy.sNUSDCooldownSrt();
        $require.eq(jrtCooldown, 0n, 'JRT cooldown should be 0');
        $require.eq(srtCooldown, 0n, 'SRT cooldown should be 0');

        // Verify feed configuration
        $require.eq(await feed.provider(), sNUSDAprPairProvider.address, 'Feed provider should match');
        const stalePeriod = await feed.roundStaleAfter();
        const expectedStalePeriod = $date.parseTimespan(test.factory.platform.Feed?.stalePeriodAfter || '4hours', { get: 's' });
        $require.eq(stalePeriod, BigInt(expectedStalePeriod), 'Feed stale period should match platform configuration');
        $require.eq(await accounting.aprPairFeed(), feed.address, 'Accounting feed should match');

        // Verify cooldown implementation
        const cooldownImpl = await unstakeCooldown.implementations(sNUSD.address);
        $require.eq($address.eq(cooldownImpl, $address.ZERO), false, 'Cooldown implementation should be set');

        // Verify roles
        const PAUSER_ROLE = $contract.keccak256('PAUSER_ROLE');
        const UPDATER_STRAT_CONFIG_ROLE = $contract.keccak256('UPDATER_STRAT_CONFIG_ROLE');
        const UPDATER_FEED_ROLE = $contract.keccak256('UPDATER_FEED_ROLE');
        const UPDATER_CDO_APR_ROLE = $contract.keccak256('UPDATER_CDO_APR_ROLE');
        const COOLDOWN_WORKER_ROLE = await erc20Cooldown.COOLDOWN_WORKER_ROLE();

        $require.eq(
            await acm.hasRole(PAUSER_ROLE, test.deployer.address),
            true,
            'Owner should have PAUSER_ROLE'
        );
        $require.eq(
            await acm.hasRole(UPDATER_STRAT_CONFIG_ROLE, test.deployer.address),
            true,
            'Owner should have UPDATER_STRAT_CONFIG_ROLE'
        );
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

        // Verify supported tokens
        const supportedTokens = await strategy.getSupportedTokens();
        $require.eq(supportedTokens.length, 2, 'Strategy should support 2 tokens');
        $require.eq(supportedTokens[0], sNUSD.address, 'First supported token should be sNUSD');
        $require.eq(supportedTokens[1], NUSD.address, 'Second supported token should be NUSD');
    },
    async 'NeutrlStrategy::CDO configuration'() {
        let { cdo, strategy, accounting, jrtVault, srtVault } = test.tranches;

        // Verify CDO is properly configured
        $require.eq($address.eq(await cdo.strategy(), $address.ZERO), false, 'CDO should have a strategy');
        $require.eq($address.eq(await cdo.accounting(), $address.ZERO), false, 'CDO should have accounting');
        $require.eq($address.eq(await cdo.jrtVault(), $address.ZERO), false, 'CDO should have JRT vault');
        $require.eq($address.eq(await cdo.srtVault(), $address.ZERO), false, 'CDO should have SRT vault');

        // Verify strategy points to CDO
        $require.eq(await strategy.cdo(), cdo.address, 'Strategy should point to CDO');
    },
    async 'NeutrlStrategy::Tranche configuration'() {
        let { jrtVault, srtVault, cdo } = test.tranches;
        let {
            NUSD,
        } = await test.factory.ensureUnderlying();

        // Verify tranches are ERC4626 compatible
        $require.eq(await jrtVault.asset(), NUSD.address, 'JRT vault asset');
        $require.eq(await srtVault.asset(), NUSD.address, 'SRT vault asset');

        // Verify tranches are connected to CDO
        $require.eq(await jrtVault.cdo(), cdo.address, 'JRT vault should be connected to CDO');
        $require.eq(await srtVault.cdo(), cdo.address, 'SRT vault should be connected to CDO');
    },
    async 'NeutrlStrategy::Feed and Accounting'() {
        let { feed, provider: sNUSDAprPairProvider, accounting, cdo } = test.tranches;

        // Verify feed is configured
        $require.eq($address.eq(await feed.provider(), $address.ZERO), false, 'Feed should have a provider');
        $require.eq(await feed.provider(), sNUSDAprPairProvider.address, 'Feed provider should match');

        // Verify accounting is configured
        $require.eq(await accounting.cdo(), cdo.address, 'Accounting should point to CDO');
        $require.eq(await accounting.aprPairFeed(), feed.address, 'Accounting should have feed');
    },
    async 'NeutrlStrategy::Cooldown configuration'() {
        let { strategy, erc20Cooldown, unstakeCooldown } = test.tranches;
        let {
            sNUSD,
        } = await test.factory.ensureUnderlying();

        // Verify strategy has cooldown contracts
        $require.eq($address.eq(await strategy.erc20Cooldown(), $address.ZERO), false, 'Strategy should have ERC20Cooldown');
        $require.eq($address.eq(await strategy.unstakeCooldown(), $address.ZERO), false, 'Strategy should have UnstakeCooldown');

        // Verify cooldown implementation is set
        const impl = await unstakeCooldown.implementations(sNUSD.address);
        $require.eq($address.eq(impl, $address.ZERO), false, 'UnstakeCooldown should have implementation for sNUSD');
    },

    async 'should receive performance fee'() {
        const { client } = test;
        const { deployer, owner } = test.factory;

        const { NUSD, sNUSD, accounting, jrtVault } = test.tranches;
        await $erc20.mint(NUSD, deployer, deployer.address, 2001);
        await $tranche.deposit(jrtVault, deployer, NUSD, 1000);

        await sNUSD.$receipt().grantRole(owner, $contract.keccak256('REWARDER_ROLE'), deployer.address);
        await $neutrl.distribute(sNUSD, NUSD, deployer, 1000);

        await client.debug.mine('10days');

        l`Trigger accounting`
        await $tranche.deposit(jrtVault, deployer, NUSD, 1);

        const feeAccrued = $bigint.toEther(await accounting.reserveNav());
        $test.eqDiff(feeAccrued, 1000 * Tranches.neutrl.fees.performanceFee, 1);
    },

    async 'should receive redemption fee'() {
        const { deployer } = test.factory;

        const { NUSD, accounting, jrtVault, srtVault } = test.tranches;
        await $tranche.ensureCoverage(test, 50, { jrt: 10_000 })
        await $erc20.mint(NUSD, deployer, deployer.address, 2000);

        return UTest.create({
            async 'from Junior'() {
                const AMOUNT = 1000;
                await $tranche.deposit(jrtVault, deployer, NUSD, AMOUNT);
                let { tx } = await $erc4626.withdrawMeta(jrtVault, NUSD, deployer, AMOUNT);
                const feeAccrued = accounting.extractLogsFeeAccrued(tx.receipt)[0].params;
                $test.eqDiff(feeAccrued.amountToReserve, feeAccrued.amountToTranche, 1n, `Neutrl 50% retention`);

                const totalFeeFact = $bigint.toEther(feeAccrued.amountToReserve + feeAccrued.amountToTranche);
                const feeRatio = Tranches.neutrl.jrt.sharesCooldown[2].feeBps / 10000;
                const totalFeeCalc = AMOUNT * feeRatio / (1 - feeRatio);
                $test.eqDiff(totalFeeFact, totalFeeCalc, .0001);
            },
            async 'from Senior'() {
                const AMOUNT = 500;
                await $tranche.deposit(srtVault, deployer, NUSD, AMOUNT);
                let { tx } = await $erc4626.withdrawMeta(srtVault, NUSD, deployer, AMOUNT);
                const feeAccrued = accounting.extractLogsFeeAccrued(tx.receipt)[0].params;
                $test.eqDiff(feeAccrued.amountToReserve, feeAccrued.amountToTranche, 1n, `Neutrl 50% retention`);

                const totalFeeFact = $bigint.toEther(feeAccrued.amountToReserve + feeAccrued.amountToTranche);
                const feeRatio = Tranches.neutrl.srt.sharesCooldown[2].feeBps / 10000;
                const totalFeeCalc = AMOUNT * feeRatio / (1 - feeRatio);
                $test.eqDiff(totalFeeFact, totalFeeCalc, .0001);
            },
            async 'small amounts'() {
                const AMOUNT_NET = 1833n;
                await $tranche.deposit(jrtVault, deployer, NUSD, AMOUNT_NET);
                let { tx } = await $erc4626.withdrawMeta(jrtVault, NUSD, deployer, AMOUNT_NET);
                const feeAccrued = accounting.extractLogsFeeAccrued(tx.receipt)[0].params;

                const feeWAD = $bigint.toWei(Tranches.neutrl.jrt.sharesCooldown[2].feeBps / 10000);
                let denominator = 10n ** 18n - feeWAD;
                // Withdrawal fees round up before the retention split.
                let fee = (AMOUNT_NET * feeWAD + denominator - 1n) / denominator;

                $require.eq(feeAccrued.amountToReserve + feeAccrued.amountToTranche, fee);
                $require.eq(feeAccrued.amountToReserve, 2n);
                $require.eq(feeAccrued.amountToTranche, 2n);
            }
        });
    },
    async 'should lock shares for [10..20] coverage'() {
        const { deployer, client } = test.factory;
        const { NUSD, sNUSD, accounting, jrtVault, srtVault, cdo, sharesCooldown, unstakeCooldown } = test.tranches;
        const bounds = await sharesCooldown.vaultExitBounds(jrtVault.address);
        deepEq_(bounds, {
            p0: 100000,
            p1: 200000,
            r0: { feePpm: 0, sharesLock: 3024000 },
            r1: { feePpm: 1000, sharesLock: 864000 },
            r2: { feePpm: 2000, sharesLock: 0 }
        });

        await $tranche.ensureCoverage(test, 15, { jrt: 100_000 });
        await $erc20.mint(NUSD, deployer, deployer.address, 2000);

        return UTest.create({
            async 'from Junior'() {

                const AMOUNT = 100;
                await $tranche.deposit(jrtVault, deployer, NUSD, AMOUNT);
                let { tx } = await $erc4626.withdrawMeta(jrtVault, NUSD, deployer, AMOUNT);
                const feeAccrued = accounting.extractLogsFeeAccrued(tx.receipt)[0].params;
                const feeBPS = Tranches.neutrl.jrt.sharesCooldown[1].feeBps;

                $test.eqDiff(feeAccrued.amountToReserve, feeAccrued.amountToTranche, 1n, `Neutrl 50% retention`);
                $require.eq(feeAccrued.amountToReserve, await accounting.reserveNav());

                const totalFeeFact = $bigint.toEther(feeAccrued.amountToReserve + feeAccrued.amountToTranche);
                const feeRatio = feeBPS / 10000;
                const totalFeeCalc = AMOUNT * feeRatio / (1 - feeRatio);
                $test.eqDiff(totalFeeFact, totalFeeCalc, .0001);


                const locked = await sharesCooldown.balanceOf(jrtVault.address, deployer.address);
                $test.eqDiff(locked.pending, $bigint.toWei(AMOUNT), 1n, `Locked amount may include one wei from share rounding`);

                await client.debug.mine('10days');
                await sharesCooldown.$receipt().finalize(deployer, jrtVault.address, deployer.address);
                const lockedUnstake = await unstakeCooldown.balanceOf(sNUSD.address, deployer.address);
                $require.gt(lockedUnstake.pending, $bigint.toWei(AMOUNT), `Fee retention has increased JRT TVL`);
            },
            async 'from Senior'() {
                const AMOUNT = 100;
                const feeBPS = Tranches.neutrl.srt.sharesCooldown[1].feeBps
                await $tranche.deposit(srtVault, deployer, NUSD, AMOUNT);
                let { tx } = await $erc4626.withdrawMeta(srtVault, NUSD, deployer, AMOUNT);
                const feeAccrued = accounting.extractLogsFeeAccrued(tx.receipt)[0].params;
                $test.eqDiff(feeAccrued.amountToReserve, feeAccrued.amountToTranche, 1n, `Neutrl 50% retention`);

                const totalFeeFact = $bigint.toEther(feeAccrued.amountToReserve + feeAccrued.amountToTranche);
                const feeRatio = feeBPS / 10000;
                const totalFeeCalc = AMOUNT * feeRatio / (1 - feeRatio);
                $test.eqDiff(totalFeeFact, totalFeeCalc, .0001);
            }
        });
    },
    async 'should lock shares for [0..10] coverage'() {
        const { deployer, client } = test.factory;
        const { NUSD, sNUSD, accounting, jrtVault, srtVault, cdo, sharesCooldown, unstakeCooldown } = test.tranches;


        await $tranche.ensureCoverage(test, 8, { jrt: 100_000 });
        await $erc20.mint(NUSD, deployer, deployer.address, 2000);

        return UTest.create({
            async 'from Junior'() {
                const AMOUNT = 100;

                const mode = await cdo.calculateExitMode(jrtVault.address, deployer.address);
                $require.eq(mode.fee, 0n);
                $require.eq(mode.cooldownSeconds, $date.parseTimespan('35days', { get:'s' }));

                await $tranche.deposit(jrtVault, deployer, NUSD, AMOUNT);
                let { tx } = await $erc4626.withdrawMeta(jrtVault, NUSD, deployer, AMOUNT);
                const feeEvents = accounting.extractLogsFeeAccrued(tx.receipt);
                $require.eq(feeEvents.length, 0, `No fee should be accrued`);

                const locked = await sharesCooldown.balanceOf(jrtVault.address, deployer.address);
                $require.eq(locked.pending, $bigint.toWei(AMOUNT));

                await client.debug.mine('35days');
                await sharesCooldown.$receipt().finalize(deployer, jrtVault.address, deployer.address);
                const lockedUnstake = await unstakeCooldown.balanceOf(sNUSD.address, deployer.address);
                $require.eq(lockedUnstake.pending, $bigint.toWei(AMOUNT), `No fees, no TVL increase, remains 1:1`);
            }
        });
    },
});
