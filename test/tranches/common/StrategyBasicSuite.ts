import memd from 'memd';
import { DeploymentsBase } from '@s/deployments/DeploymentsBase';
import { $hh } from '../utils/$hh';
import { UTest } from 'atma-utest';
import { $erc4626 } from '../utils/$erc4626';
import { $erc20 } from '../utils/$erc20';
import { IStrategy } from '@0xc/hardhat/IStrategy/IStrategy';
import { ERC20 } from 'dequanto/prebuilt/openzeppelin/ERC20';
import { $bigint } from 'dequanto/utils/$bigint';
import { $require } from 'dequanto/utils/$require';
import { $address } from 'dequanto/utils/$address';
import { Tranche } from '@0xc/hardhat/Tranche/Tranche';
import { TEth } from 'dequanto/models/TEth';
import { $is } from 'dequanto/utils/$is';
import { ITestHelper } from '@s/strategies/interfaces/ITestHelper';
import { l } from 'dequanto/utils/$logger';
import { $bigfloat } from 'dequanto/utils/$bigfloat';
import { $date } from 'dequanto/utils/$date';
import { CDOLens } from '@0xc/hardhat/CDOLens/CDOLens';


export class StrategyBasicSuite<T extends DeploymentsBase> {
    private test: $hh.Test<DeploymentsBase<{
        Tokens: { base: ERC20 }
        Strategy: IStrategy
    }>>

    private contracts: Awaited<ReturnType<typeof this.test.deploy>> & { lens: CDOLens }
    private baseDecimals: number

    constructor(test_: $hh.Test<DeploymentsBase>, private helper: ITestHelper) {
        this.test = test_;
    }

    async deploy() {
        return await this.test.deploy({ initialDeposit: false });
    }

    async wipe() {
        await this.test.wipe();
    }

    async createTests() {
        const contracts = await this.test.deploy({ initialDeposit: false });
        const { lens } = await this.test.factory.ensureLenses();
        this.contracts = {
            ...contracts,
            lens
        };

        const {
            jrtVault,
            srtVault,
            accounting,
            feed,
            base
        } = this.contracts;

        const suite = this;
        const test = this.test;
        const { client } = this.test;
        const alice = await test.createAccount('alice');
        await client.debug.setBalance(alice.address, BigInt(1e18));

        this.baseDecimals = await base.decimals();

        return UTest.create({
            async $after() {
                await test.wipe()
            },
            async $before() {

                const tokens = await suite.helper.getStrategyTokensIn();
                for (const token of tokens) {
                    const erc20 = new ERC20(token.address, client);
                    const decimals = await erc20.decimals();
                    await $erc20.setBalanceAny(erc20, alice, $bigint.toWei(1000, decimals));
                    await $erc20.eqBalance(erc20, alice, 1000);
                }

                await suite.helper.setup?.();
            },
            async 'should deposit tokens'() {
                const tokens = await suite.helper.getStrategyTokensIn();
                for (const token of tokens) {
                    if ($address.eq(token.address, base.address)) {
                        await suite.depositTokenWithTests(alice, jrtVault, base.address, 98);
                        await suite.depositTokenWithTests(alice, srtVault, base.address, 101);
                        continue;
                    }
                    await suite.depositTokenByBaseAmountWithTests(alice, jrtVault, token.address, 100);
                    await suite.depositTokenByBaseAmountWithTests(alice, srtVault, token.address, 110);
                }
            },
            async 'should increase NAVs based on APRs'() {
                const aprs = await feed.latestRoundData();
                const APRbase = $bigint.toEther(aprs.aprBase, 12);
                const APRtarget = $bigint.toEther(aprs.aprTarget, 12);
                const [aprBaseMin, aprBaseMax] = suite.helper.getSanityAprBase?.() ?? [0.005, .30]
                $require.True(aprBaseMin <= APRbase && APRbase <= aprBaseMax, `APR base sanity check failed: ${APRbase}`);

                const [aprTargetMin, aprTargetMax] = suite.helper.getSanityAprTarget?.() ?? [0.005, .10]
                $require.True(aprTargetMin <= APRtarget && APRtarget <= aprTargetMax, `APR target sanity check failed: ${APRtarget}`);

                const APRsrt = $bigint.toEther(await accounting.aprSrt(), 18);
                $require.True(APRtarget <= APRsrt && APRsrt < .10, `APR senior sanity check failed: ${APRsrt} (target: ${APRtarget})`);

                await suite.distributeRewardsWithTests({
                    dt: '4hours',
                    apr: BigInt(aprs.aprBase)
                });
            },
            async 'should redeem tokens'() {
                const tokens = await suite.helper.getStrategyTokensOut();
                await suite.test.snapshot('beforeRedeem');
                for (const token of tokens) {
                    await suite.redeemTokenByBaseAmountWithTests(alice, srtVault, token, 23);

                    // Need to reset as redemption mines block forward to finalize the cooldown
                    // this can make some price oracles unhealthy.
                    await suite.test.reset('beforeRedeem');
                    await suite.redeemTokenByBaseAmountWithTests(alice, jrtVault, token, 27);
                }
            },
        });
    }


    private async depositTokenByBaseAmountWithTests(acc: TEth.IAccount, vault: Tranche, token: TEth.Address, amountInBase: number | bigint) {
        const {
            base,
            strategy,
        } = this.contracts;

        const wei = await this.toWei(base, amountInBase);
        const tokensWei = await strategy.convertToTokens(token, wei, 1);
        return this.depositTokenWithTests(acc, vault, token, tokensWei);
    }
    private async depositTokenWithTests(acc: TEth.IAccount, vault: Tranche, token: TEth.Address, amount: number | bigint) {
        const {
            strategy,
            accounting,
            cdo,
            jrtVault
        } = this.contracts;

        const { lens } = await this.test.factory.ensureLenses();
        const aprs = await lens.getAPRs(cdo.address);

        const amountWei = await this.toWei(token, amount);

        const erc20 = vault.$address(token);
        const isJRT = $address.eq(vault.address, jrtVault.address);
        const navTotalBefore = await strategy.totalAssets();
        const navTrancheBefore = isJRT
            ? await accounting.jrtNav()
            : await accounting.srtNav();

        $require.lte(navTrancheBefore, navTotalBefore + 1n, `Tranche NAV is larger than total assets`);


        const trancheAPR = isJRT ? aprs.jrt : aprs.srt;

        const accountSharesBefore = await vault.balanceOf(acc.address);
        const previewSharesOut = await vault.previewDeposit(token, amountWei);

        l`Deposit cyan<${amount}> bold<yellow<${await erc20.symbol()}>> to bold<${isJRT ? 'JRT' : 'SRT'}>`;
        await $erc4626.depositMeta(vault as any, token, acc, amountWei);

        const accountSharesDiffFact = await vault.balanceOf(acc.address) - accountSharesBefore;

        const symbolTranche = await vault.symbol();
        const symbolToken = await vault.$address(token).symbol();
        const MIN_TOLERANCE = 10n**BigInt(this.baseDecimals - 6);

        const navTrancheVestingTolerance = await this.calcWeiPerT(navTrancheBefore, trancheAPR, 4);
        const navTotalVestingTolerance = await this.calcWeiPerT(navTotalBefore, aprs.base, 4);

        // Recalculated due to vesting between previous calculation and real deposit (~2s)
        const previewSharesOutRecalc = await vault.previewDeposit(token, amountWei);
        const amountAssetsRecalc = await strategy.convertToAssets(token, amountWei, 0);
        const previewSharesOutDiff = $bigint.abs(previewSharesOutRecalc - previewSharesOut);

        this.eqBigInt(
            accountSharesDiffFact
            , previewSharesOut
            , MIN_TOLERANCE + navTrancheVestingTolerance + previewSharesOutDiff
            , `User did not receive expected amount of the ${symbolTranche} tranche tokens, on deposit ${symbolToken}`
        );
        this.eqBigInt(
            await strategy.totalAssets() - navTotalBefore
            , amountAssetsRecalc
            , MIN_TOLERANCE + navTotalVestingTolerance
            , `Strategy did not receive expected assets, on deposit ${symbolToken} into ${symbolTranche}`
        );
        this.eqBigInt(
            isJRT
                ? await accounting.jrtNav()
                : await accounting.srtNav()
            , navTrancheBefore + amountAssetsRecalc
            , MIN_TOLERANCE + navTrancheVestingTolerance
            , `Tranche did not receive expected assets, on deposit ${symbolToken} into ${symbolTranche}`
        );
    }

    private async distributeRewardsWithTests(params: { dt: string, apr: bigint }) {
        const {
            strategy,
            accounting,
        } = this.contracts;

        const [
            totalAssets,
            srtNAV,
            jrtNAV,
            srtAPRBase18,
            reserveBps,
        ] = await Promise.all([
            strategy.totalAssets(),
            accounting.srtNav(),
            accounting.jrtNav(),
            accounting.aprSrt(),
            accounting.reserveBps(),
        ]);
        const dt = params.dt;
        await this.test.client.debug.mine(dt);
        const afterState = await this.helper.distributeRewards({
            assetsBefore: totalAssets,
            dt: dt,
            apr: BigInt(params.apr)
        });
        await accounting.$receipt().onAprChanged(this.test.factory.owner);

        const navGainExpect = (afterState as any)?.navGainExpect ?? this.calcWeiPerT(totalAssets, params.apr, dt);
        const navGainFact = await strategy.totalAssets() - totalAssets;

        const tolerance2SecVesting = this.calcWeiPerT(totalAssets, params.apr, 2);
        const WEI_TOLERANCE = $bigint.max(
            BigInt(2 * 10 ** (this.baseDecimals - 6)),
            10n
        );

        this.eqBigInt(
            navGainFact
            , navGainExpect
            , tolerance2SecVesting + WEI_TOLERANCE
            , `Strategy did not receive expected assets, on ${params.dt} rewards`
        );

        l`Calculate SRT gain based on APR`
        const navSrtGainExpect = this.calcWeiPerT(srtNAV, srtAPRBase18 / 10n ** 6n, dt);
        const navSrtGainFact = await accounting.srtNav() - srtNAV;
        this.eqBigInt(
            navSrtGainFact
            , navSrtGainExpect
            , WEI_TOLERANCE
            , `SRT tranche did not receive expected assets, on ${params.dt} of rewards`
        );

        l`Calculate JRT gain as the remainder of the Total gain minus SRT gain`
        const reserveNav = reserveBps > 0 ? navGainFact * reserveBps / 10n ** 18n : 0n;

        const navJrtGainFact = await accounting.jrtNav() - jrtNAV;
        this.eqBigInt(
            navJrtGainFact
            , navGainFact - navSrtGainFact - reserveNav
            , WEI_TOLERANCE
            , `JRT tranche did not receive expected assets, on ${params.dt} of rewards`
        );
    }

    private async redeemTokenByBaseAmountWithTests(
        acc: TEth.IAccount
        , vault: Tranche
        , tokenOut: Awaited<ReturnType<ITestHelper['getStrategyTokensOut']>>[0]
        , sharesAmount: number | bigint
    ) {
        const {
            cdo,
            unstakeCooldown,
            jrtVault
        } = this.contracts;
        const isJRT = $address.eq(vault.address, jrtVault.address);
        const tokenOutErc20 = vault.$address(tokenOut.address);
        const shares = await this.toWei(vault, sharesAmount);

        const [
            amountOutExpected,
            exitMode,
            balanceBefore,
            tokensMain,
            tokenOutUnderlyingFee,
            apr,
            decimals,
        ] = await Promise.all([
            vault.previewRedeem(tokenOut.address, shares),
            cdo.calculateExitMode(vault.address, acc.address),
            tokenOutErc20.balanceOf(acc.address),
            this.helper.getStrategyTokensMain(),
            this.helper.getUnderlyingExitFee(tokenOut.address),
            this.getApr(isJRT ? 'jrt' : 'srt'),
            tokenOutErc20.decimals(),
        ]);

        // Vesting tolerance
        const tolerance = $bigint.toWei(.0001, decimals);
        const tx = await vault.$receipt().redeem(
            acc
            , tokenOut.address
            , shares
            , acc.address
            , acc.address
        );

        const finalizedLogs = unstakeCooldown.extractLogsFinalized(tx.receipt);
        if (finalizedLogs.length > 0) {
            l`Unstake request has been finalized INSTANTLY yellow<${tokenOut.address}>`
            const amountOutFact = await tokenOutErc20.balanceOf(acc.address) - balanceBefore;

            const amountOutExpectedDeductingFee = tokenOutUnderlyingFee === 0 || tokenOut.cooldown !== 'unstake'
                ? amountOutExpected
                : amountOutExpected - $bigint.multWithFloat(amountOutExpected, tokenOutUnderlyingFee);

            this.eqBigInt(
                amountOutFact
                , amountOutExpectedDeductingFee
                , tolerance
                , `Instant redeem did not transfer enough tokens`
            );
            return;
        }


        if (tokenOut.cooldown === 'unstake') {
            const [transferRequestLog] = unstakeCooldown.extractLogsTransferRequested(tx.receipt);

            const dt = await this.helper.getUnderlyingUnstakePeriod();
            await this.test.mine(dt);
            await this.helper.finalizeUnderlyingUnstake(acc.address);

            const tokenOutErc20 = vault.$address(tokenOut.address);
            const balanceBefore = await tokenOutErc20.balanceOf(acc.address);
            await unstakeCooldown.$receipt().finalize(acc, transferRequestLog.params.token, acc.address);

            const receivedFact = await tokenOutErc20.balanceOf(acc.address) - balanceBefore;

            this.eqBigInt(
                receivedFact
                , amountOutExpected
                , tolerance
                , `Unstake finalized with wrong expected amount`
            );
        }
    }

    private async toWei(token: TEth.Address | ERC20 | { address: TEth.Address }, amount: number | bigint) {
        const address = this.toAddress(token);
        const erc20 = new ERC20(address, this.test.client);
        const decimals = await $erc20.decimals(erc20);
        const wei = typeof amount === 'number' ? $bigint.toWei(amount, decimals) : amount;
        return wei;
    }
    private toAddress(token: TEth.Address | { address: TEth.Address }): TEth.Address {
        if ($is.Address(token as any)) {
            return token as TEth.Address;
        }
        return $require.Address((token as any).address);
    }

    private eqBigInt(fact: bigint, expected: bigint, tolerance: bigint | { up?: bigint; down?: bigint }, message: string) {
        const maxDelta = typeof tolerance === 'bigint' ? $bigint.abs(tolerance) : (tolerance.up ?? 1n);
        const minDelta = typeof tolerance === 'bigint' ? $bigint.abs(tolerance) * -1n : (tolerance.down ?? -1n);

        const diff = fact - expected;
        const msg = `${message}; \n\tFact:     ${fact}, \n\tExpected: ${expected}, \n\tDiff:     ${diff}, \n\tMaxDelta: -${minDelta}:+${maxDelta}`;
        if (fact >= expected) {
            $require.lte(diff, maxDelta, msg);
        } else {
            $require.gte(diff, minDelta, msg);
        }

    }

    private convertToShares(assets: bigint, totalSupply: bigint, totalAssets: bigint, rounding: 0 | 1) {
        const decimalsOffset = BigInt(18 - 6);
        return (assets * (totalSupply + 10n ** decimalsOffset)) / (totalAssets + 1n);
    }

    private calcWeiPerT(nav: bigint, apr: bigint | number, dt: number | string = 1 /* 1 second */) {
        const seconds = typeof dt === 'number'
            ? dt
            : $date.parseTimespan(dt, { get: 's' });

        const WEI_PER_DT = $bigfloat
            .from(nav)
            .mul(apr)
            .mul(seconds)
            .div(365 * 24 * 3600)
            .div(10 ** 12)
            .toBigInt();

        return WEI_PER_DT;
    }
    private async getTimestamp() {
        return (await this.test.client.getBlock('latest')).timestamp;
    }

    @memd.deco.memoize({ maxAge: 10 })
    private async getApr (type: 'jrt' | 'srt' | 'base' | 'target') {
        const { cdo } = this.test.tranches;
        const { lens } = await this.test.factory.ensureLenses();
        const aprs = await lens.getAPRs(cdo.address);
        return aprs[type];
    }
}

