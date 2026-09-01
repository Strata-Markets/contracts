import { $hh } from '../utils/$hh';
import { $bigint } from 'dequanto/utils/$bigint';
import { DiscreteAccounting as Accounting } from '@0xc/hardhat/DiscreteAccounting/DiscreteAccounting';
import { $require } from 'dequanto/utils/$require';
import { $date } from 'dequanto/utils/$date';
import { l } from 'dequanto/utils/$logger';
import { Web3Client } from 'dequanto/clients/Web3Client';
import { $apr } from '@s/utils/$apr';
import { HardhatProvider } from 'dequanto/hardhat/HardhatProvider';
import { ContractBase } from 'dequanto/contracts/ContractBase';
import { $test } from '../utils/$test';
import { DeploymentsBase } from '@s/deployments/DeploymentsBase';


let client: Web3Client;

export class AccountingExecutor {
    srtNav: bigint
    jrtNav: bigint

    constructor(private test: $hh.Test<DeploymentsBase>) {
        client = test.client;
    }

    async run (data: IExecutionData) {

        await this.test.reset();
        let { client } = this.test;
        let { deployer } = this.test.factory;

        let hh = new HardhatProvider();
        let { contract: mockCdo } = await hh.deployCode(`
            contract MockCDO {
                uint256 public _totalStrategyAssets = 0;
                function setTotalAssets (uint256 amount) external {
                    _totalStrategyAssets = amount;
                }
                function increment (int256 amount) external {
                    _totalStrategyAssets = amount > 0
                        ? _totalStrategyAssets + uint256(amount)
                        : _totalStrategyAssets - uint256(amount * -1);
                }
                function totalStrategyAssets () public view returns (uint256) {
                    return _totalStrategyAssets;
                }
                function totalStrategyAssets (uint256, uint256) public view returns (uint256) {
                    return _totalStrategyAssets;
                }
                function totalStrategyAssetsSnapshot (uint256, uint256) public view returns (uint256, uint256, uint256, uint256) {
                    return (_totalStrategyAssets, block.timestamp, _totalStrategyAssets, block.timestamp);
                }
            }
        `, { client });


        let { cdo, feed, USDe, sUSDe, strategy } = this.test.tranches;
        let accounting = await this.test.factory.ensureAccounting(cdo.address);

        await accounting.storage.$set('cdo', mockCdo.address);
        await feed.$receipt().setRoundStaleAfter(this.test.deployer, BigInt($date.parseTimespan('2years', { get: 's' })));

        await Updater.impersonate(mockCdo as any, accounting);
        await Updater.totalAssets(0);

        for (let step of data.steps) {
            if (step.msg != null) {
                l`green<${step.msg}>`;
            }
            if (step.aprs != null) {
                let aprTarget = $apr.toWei(step.aprs[0]);
                let aprBase = $apr.toWei(step.aprs[1]);
                let timestamp = (await feed.client.getBlock('latest')).timestamp;
                await feed.$receipt().updateRoundData(deployer, aprTarget, aprBase, timestamp);
                await accounting.$receipt().onAprChanged(deployer);
            }
            if (step.risk != null) {
                let x = $bigint.toWei(step.risk[0]);
                let y = $bigint.toWei(step.risk[1]);
                let k = $bigint.toWei(step.risk[2]);
                await accounting.$receipt().setRiskParameters(deployer, x, y, k);
            }
            if (step.balanceFlow != null) {
                l`gray<BalanceFlow>: cyan<${step.balanceFlow.join(' , ')}>`;

                await Updater.balanceFlow(...step.balanceFlow);
            }
            if (step.time != null) {
                await Updater.time(step.time);
            }
            if (step.totalAssets != null) {
                l`gray<UpdateAssets>: cyan<${step.totalAssets}>`;
                await Updater.totalAssets(step.totalAssets);
                await Balance.eq(await accounting.jrtNav() + await accounting.srtNav(), step.totalAssets);
                await Balance.eq(await accounting.nav(), step.totalAssets);
            }
            if (step.eqAvg) {
                console.log('JRT:', $bigint.toEther(await accounting.jrtNav()));
                console.log('SRT:', $bigint.toEther(await accounting.srtNav()));
                step.eqAvg[0] != null && await Balance.eqAvg(accounting.jrtNav(), step.eqAvg[0], 'JRT');
                step.eqAvg[1] != null && await Balance.eqAvg(accounting.srtNav(), step.eqAvg[1], 'SRT');
            }
            if (step.eqProjectedAvg) {
                const acc = accounting as any as Accounting;
                console.log('JRTp:', $bigint.toEther(await acc.jrtNavProjected()));
                console.log('SRT:', $bigint.toEther(await acc.srtNav()));
                console.log(step);
                step.eqProjectedAvg[0] != null && await Balance.eqAvg(acc.jrtNavProjected(), step.eqProjectedAvg[0], 'JRTprojected');
                step.eqProjectedAvg[1] != null && await Balance.eqAvg(acc.srtNav()         , step.eqProjectedAvg[1], 'SRTnav');
            }
            if (step.updateAccounting) {
                await Updater.updateAccounting();
            }
            if (step.eqNav != null) {
                await Balance.eq(accounting.nav(), step.eqNav);
            }
            if (step.logNav != null) {
                console.log(`JrtNav:`, $bigint.toEther(await accounting.jrtNav()));
                console.log(`SrtNav:`, $bigint.toEther(await accounting.srtNav()));
            }
            if (step.logNavP != null) {
                const acc = accounting as any as Accounting;
                console.log(`JrtNavP:`, $bigint.toEther(await acc.jrtNavProjected()));
                console.log(`SrtNav :`, $bigint.toEther(await acc.srtNav()));
            }
            if (step.eqAprSrt != null) {
                let srtApr = $bigint.toEther(await accounting.aprSrt());
                console.log(`SRT APR:`, srtApr);
                $test.eqDiff(srtApr, step.eqAprSrt, .1, `SRT APR should be ${step.eqAprSrt} but got ${srtApr}`);
            }
        }
    }
    static async teardown () {
        await Updater.stopImpersonate()
    }
}

interface IExecutionData {
    steps: IExecutionStep[]
}
interface IExecutionStep {
    aprs?: [targetApr: number, baseApr: number]
    risk?: [x: number, y: number, k: number]
    balanceFlow?: [jrtIn: number, jrtOut: number, srtIn: number, srtOut: number]
    time?: string
    totalAssets?: number
    eqAvg?: [jrtNav: number, srtNav: number]
    eqProjectedAvg?: [jrtNavProjected: number, srtNav: number]
    eqNav?: number
    eqAprSrt?: number
    logNav?: boolean
    logNavP?: boolean
    updateAccounting?: boolean

    msg?: string
}


namespace Updater {
    type MockCDO = ContractBase;
    let cdo: MockCDO;
    let accounting: Accounting;
    export async function impersonate (cdo_: MockCDO, accounting_: Accounting) {
        cdo = cdo_;
        accounting = accounting_;
        await client.debug.setBalance(cdo.address, 10n**18n);
        await client.debug.impersonateAccount(cdo.address);
    }
    export async function stopImpersonate () {
        await client.debug.stopImpersonatingAccount(cdo.address);
    }
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
        l`Setting totalAssets cyan<${ currentNAV }>`;
        await cdo.$receipt().setTotalAssets(cdo, $bigint.toWei(currentNAV));
        await updateAccounting(currentNAV);
    }
    export async function updateAccounting(currentNAV?: number) {
        if (currentNAV != null) {
            await accounting.$receipt().updateAccounting(
                cdo,
                $bigint.toWei(currentNAV),
            );
        } else {
            await accounting.$receipt().updateAccounting(
                cdo
            );
        }
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
            throw new Error(`Balance not around to ${requireBalance}, actual: ${bEther} ${msg ?? ''}`);
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
