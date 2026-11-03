import { $hh } from './$hh';
import { $bigint } from 'dequanto/utils/$bigint';
import { DiscreteAccounting as Accounting } from '@0xc/hardhat/DiscreteAccounting/DiscreteAccounting';
import { $require } from 'dequanto/utils/$require';
import { $date } from 'dequanto/utils/$date';
import { l } from 'dequanto/utils/$logger';
import { Web3Client } from 'dequanto/clients/Web3Client';
import { ContractBase } from 'dequanto/contracts/ContractBase';
import { TEth } from 'dequanto/models/TEth';
import { $strata } from './$strata';
import { $erc4626 } from './$erc4626';
import { $test } from './$test';
import { $tranche } from './$tranche';
import { $accounting } from './$accounting';
import { DeploymentsBase } from '@s/deployments/DeploymentsBase';

let client: Web3Client;

export class ProtocolExecutor {
    users:Record<string, TEth.IAccount> = {};
    user: TEth.IAccount

    constructor(private test: $hh.Test<DeploymentsBase>) {
        client = test.client;
    }

    async run (data: IExecutionData) {
        let { sUSDe } = this.test.underlying;
        let { accounting, feed, jrtVault, srtVault, cdo } = this.test.tranches;
        let { deployer } = this.test;

        await $erc4626.deposit(sUSDe, deployer, 1000);


        for (let step of data.steps) {
            if (step.user != null) {
                this.user = this.users[step.user] ?? (this.users[step.user] = await this.test.createAccount(step.user));
            }
            if (step.aprs != null) {
                l`gray<Aprs>: Target: cyan<${step.aprs.target}> Base: cyan<${step.aprs.target}>`;
                await $strata.setAprsViaDistribution(this.test, step.aprs.target, step.aprs.base);
            }
            if (step.aprsFixed != null) {
                l`gray<Aprs Feed>: Target: cyan<${step.aprsFixed.target}> Base: cyan<${step.aprsFixed.target}>`;
                let { target, base } = step.aprsFixed;
                await $strata.setAprsViaFeed(this.test, target, base);
            }
            if (step.risk != null) {
                let [ x, y, k ] = step.risk;
                let accountingType = this.test.factory.cdoInfo.ContractVersions?.accounting;
                await $accounting.setRiskPremium(accounting as any, deployer, accountingType, x, y, k);
            }
            if (step.deposit != null) {
                if (step.deposit.jrt) {
                    await $erc4626.deposit(jrtVault, this.user, step.deposit.jrt);
                }
                if (step.deposit.srt) {
                    await $erc4626.deposit(srtVault, this.user, step.deposit.srt);
                }
            }
            if (step.time != null) {
                await Updater.time(step.time);
            }
            if (step.eqAvg) {
                console.log('JRT:', $bigint.toEther(await accounting.jrtNav()));
                console.log('SRT:', $bigint.toEther(await accounting.srtNav()));
                if (step.eqAvg.jrtNav) {
                    await Balance.eqAvg(accounting.jrtNav(), step.eqAvg.jrtNav);
                }
                if (step.eqAvg.srtNav) {
                    await Balance.eqAvg(accounting.srtNav(), step.eqAvg.srtNav);
                }
            }
            if (step.eqAprSrt != null) {
                let srtApr = $bigint.toEther(await accounting.aprSrt());
                $test.eqDiff(srtApr, step.eqAprSrt, .1);
            }
            if (step.eqNav != null) {
                await Balance.eq(accounting.nav(), step.eqNav);
            }
            if (step.logNav != null) {
                let assets = await accounting.totalAssets(await cdo.totalStrategyAssets());
                console.log(`JrtNav:`, $bigint.toEther(assets.jrtNavT1Projected));
                console.log(`SrtNav:`, $bigint.toEther(assets.srtNavT1));
            }
            if (step.eqUserAssets) {
                if (step.eqUserAssets.jrt) {
                    let balance = await $tranche.balanceOfAssets(jrtVault, cdo, this.user);
                    l`User USDe balance in Jrt: cyan<${balance}>, expected: cyan<${step.eqUserAssets.jrt}>`;
                    $test.eqDiff(balance, step.eqUserAssets.jrt, 5);
                }
                if (step.eqUserAssets.srt) {
                    let balance = await $tranche.balanceOfAssets(srtVault, cdo, this.user);
                    l`User USDe balance in Srt: cyan<${balance}>, expected: cyan<${step.eqUserAssets.srt}>`;
                    $test.eqDiff(balance, step.eqUserAssets.srt, 5);
                }
            }
        }

    }
}

interface IExecutionData {
    steps: IExecutionStep[]
}
interface IExecutionStep {
    aprs?: { target: number, base: number }
    aprsFixed?: { target: number, base: number }
    risk?: [x: number, y: number, k: number]
    deposit?: { jrt?: number | `${number}%`, srt?: number | `${number}%` }
    withdraw?: { jrt?: number | `${number}%`, srt?: number | `${number}%` }
    user?: string
    eqUserAssets?: {
        jrt?: number
        srt?: number
    }

    time?: string

    eqAvg?: { jrtNav: number, srtNav: number }
    eqAprSrt?: number
    eqNav?: number
    logNav?: boolean
}


namespace Updater {
    type MockCDO = ContractBase;
    let cdo: MockCDO;
    let accounting: Accounting;

    export async function balanceFlow(jrtIn: number, jrtOut: number, srtIn: number, srtOut: number) {
        let diff = $bigint.toWei(jrtIn + srtIn - jrtOut - srtOut);
        await cdo.$receipt().increment(cdo, diff);
        await accounting.$receipt().updateBalanceFlow(
            cdo,
            $bigint.toWei(jrtIn),
            $bigint.toWei(jrtOut),
            $bigint.toWei(srtIn),
            $bigint.toWei(srtOut)
        );
    }
    export async function totalAssets(currentNAV: number) {
        await cdo.$receipt().setTotalAssets(cdo, currentNAV);
        await accounting.$receipt().updateAccounting(
            cdo,
            $bigint.toWei(currentNAV),
        );
    }
    export async function time(t: string) {
        let dateBefore = await Block.getDate();
        await client.debug.mine(t);
        let dateAfter = await Block.getDate();
        let seconds = Math.floor((dateAfter.valueOf() - dateBefore.valueOf()) / 1000)
        l`Moved time from gray<${ $date.format(dateBefore, 'yyyy-MM-dd HH:mm') }> to cyan<${ $date.format(dateAfter, 'yyyy-MM-dd HH:mm') }> (s: gray<${ seconds} >)`
    }
}

namespace Balance {
    export async function eq (balance: bigint | Promise<bigint>, requireBalance: number, msg?: string) {
        $require.eq(await balance, $bigint.toWei(requireBalance), msg);
    }
    export async function eqAvg (balance: bigint | Promise<bigint>, requireBalance: number, msg?: string) {
        let b = await balance;
        let bEther = $bigint.toEther(b, 18);
        let diff = Math.abs(bEther - requireBalance);
        if (diff > 5) {
            throw new Error(`Balance not around to ${requireBalance}, actual: ${bEther}`);
        }

    }
}

namespace Block {
    export async function getDate () {
        let nr = await client.getBlockNumber();
        let block = await client.getBlock(nr);
        return $date.fromUnixTimestamp(block.timestamp);
    }
}
