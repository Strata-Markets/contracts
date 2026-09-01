import { MTMAccounting } from '@0xc/hardhat/MTMAccounting/MTMAccounting';
import { UTest } from 'atma-utest';
import { Web3Client } from 'dequanto/clients/Web3Client';
import { IContractWrapped } from 'dequanto/contracts/ContractClassFactory';
import { Deployments } from 'dequanto/contracts/deploy/Deployments';
import { HardhatProvider } from 'dequanto/hardhat/HardhatProvider';
import { TEth } from 'dequanto/models/TEth';
import { $bigint } from 'dequanto/utils/$bigint';
import { $date } from 'dequanto/utils/$date';
import { $promise } from 'dequanto/utils/$promise';
import { $require } from 'dequanto/utils/$require';
import { $test } from '../utils/$test';

const SECONDS_PER_YEAR = 365 * 24 * 60 * 60;
const hh = new HardhatProvider();
const client = await hh.client();
const deployer = await hh.deployer();
const MockCDOContractSource = `
    contract MockCDO {
        uint256 public _rate = 1e18;
        uint256 public _nav = 0;
        uint256 public _navMTM = 0;
        uint256 public _epochTime;
        uint256 public _epochStart;
        uint256 public _epochMTMLatest;

        int64 public _aprTarget = 0;
        int64 public _aprBase = 0;

        constructor (uint256 epochTime) {
            _epochTime = epochTime;
            _epochStart = block.timestamp;
            _epochMTMLatest = block.timestamp;
        }

        function setTotalAssets(uint256 amount) external {
            bool isMTM = block.timestamp - _epochStart < _epochTime;
            if (!isMTM) {
                _nav = amount;
                _epochStart = block.timestamp;
            }
            _navMTM = amount;
            _epochMTMLatest = block.timestamp;
        }

        function setSnapshot(uint256 nav_, uint256 navT1Time_, uint256 navMTM_, uint256 navMTMTime_) external {
            _nav = nav_;
            _epochStart = navT1Time_;
            _navMTM = navMTM_;
            _epochMTMLatest = navMTMTime_;
        }

        function setRate(uint256 rate) external {
            _rate = rate;
        }

        function setAprs(int64 aprTarget, int64 aprBase) external {
            _aprTarget = aprTarget;
            _aprBase = aprBase;
        }

        function assetsFlow(int256 amount) external {
            if (amount > 0) {
                _nav += uint256(amount);
                _navMTM += uint256(amount);
            } else {
                _nav -= uint256(-amount);
                _navMTM -= uint256(-amount);
            }
            _epochMTMLatest = block.timestamp;
        }

        function totalStrategyAssets() public view returns (uint256) {
            return _nav;
        }

        function totalStrategyAssets(uint256, uint256) public view returns (uint256) {
            return _nav;
        }

        function totalStrategyAssetsSnapshot (uint256, uint256) public view returns (uint256, uint256, uint256, uint256) {
            return (_nav, _epochStart, _navMTM, _epochMTMLatest);
        }

        function strategy() public view returns (address) { return address(this); }

        function latestRoundData () public view returns (int64, int64, uint64, uint64) {
            return (_aprTarget, _aprBase, uint64(block.timestamp), 1);
        }
    }
`;

let snapshot = await client.debug.snapshot();
UTest.create({
    async $after() {
        await client.debug.reset({});
    },
    async $teardown () {
        await client.debug.revert(snapshot);
        snapshot = await client.debug.snapshot();
    },
    async 'mtm projection: useConservativePrice = false' () {
        let testMTM = await CdoTest.deploy(client, '365days', {
            useConservativePrice: false
        });
        await testMTM.deposit(500, 500);
        await expectMtmSettledEquals(testMTM, {
            settled: [ 500, 500 ]
        }, 'initial deposit');

        type TAction =
        | { type: 'deposit', jrt: number, srt: number, time: string, settled: [number, number] }
        | { type: 'withdraw', jrt: number, srt: number, time: string, settled: [number, number] }
        | { type: 'mtm', amount: number, time: string, settled: [number, number] };

        const actions: TAction[] = [
            { type: 'mtm', amount: 120, time: '10days', settled: [500, 500] },
            { type: 'deposit', jrt: 80, srt: 20, time: '8days', settled: [580, 520] },
            { type: 'withdraw', jrt: 35, srt: 0, time: '14days', settled: [545, 520] },
            { type: 'mtm', amount: 45, time: '9days', settled: [545, 520] },
            { type: 'deposit', jrt: 0, srt: 75, time: '15days', settled: [545, 595] },
            // SRT exits at the projected price, so 0.7332 of the 40 withdrawal is settled from JRT.
            { type: 'withdraw', jrt: 0, srt: 40, time: '11days', settled: [544.2668, 555.73319] },
            { type: 'mtm', amount: 90, time: '21days', settled: [544.2668, 555.73319] },
            { type: 'deposit', jrt: 25, srt: 25, time: '7days', settled: [569.2668, 580.73319] },
            { type: 'withdraw', jrt: 50, srt: 10, time: '19days', settled: [518.90654, 571.09345] },
            { type: 'mtm', amount: 30, time: '13days', settled: [518.90654, 571.09345] },
            { type: 'deposit', jrt: 100, srt: 0, time: '16days', settled: [618.90654, 571.09345] },
            { type: 'withdraw', jrt: 0, srt: 30, time: '12days', settled: [618.5724, 541.42759] },
            { type: 'mtm', amount: 150, time: '18days', settled: [618.5724, 541.42759] },
            { type: 'deposit', jrt: 40, srt: 60, time: '10days', settled: [658.5724, 601.42759] },
            { type: 'withdraw', jrt: 45, srt: 25, time: '20days', settled: [612.17434, 577.82565] },
            { type: 'mtm', amount: 70, time: '17days', settled: [612.17434, 577.82565] },
            { type: 'deposit', jrt: 0, srt: 50, time: '9days', settled: [612.17434, 627.82565] },
            { type: 'withdraw', jrt: 30, srt: 0, time: '14days', settled: [582.17434, 627.82565] },
            { type: 'mtm', amount: 110, time: '23days', settled: [582.17434, 627.82565] },
            { type: 'deposit', jrt: 55, srt: 35, time: '8days', settled: [637.17434, 662.82565] },
        ];

        for (let i = 0; i < actions.length; i++) {
            const action = actions[i];
            await testMTM.mine(action.time);

            if (action.type === 'deposit') {
                await testMTM.deposit(action.jrt, action.srt);
            }
            if (action.type === 'withdraw') {
                await testMTM.withdraw(action.jrt, action.srt);
            }
            if (action.type === 'mtm') {
                await testMTM.distributeAbs(action.amount, { reconcile: false });
            }
            await expectMtmSettledEquals(testMTM, action, `${i + 1}: ${formatAction(action)}`);
        }
    },
    async 'mtm projection: useConservativePrice = true' () {
        let testMTM = await CdoTest.deploy(client, '365days', {
            useConservativePrice: true
        });
        await testMTM.deposit(500, 500);
        await expectMtmSettledEquals(testMTM, {
            settled: [ 500, 500 ]
        }, 'initial deposit');

        type TAction =
        | { type: 'deposit', jrt: number, srt: number, time: string, settled: [number, number] }
        | { type: 'withdraw', jrt: number, srt: number, time: string, settled: [number, number] }
        | { type: 'mtm', amount: number, time: string, settled: [number, number] };

        const actions: TAction[] = [
            { type: 'mtm', amount: 120, time: '10days', settled: [500, 500] },
            { type: 'deposit', jrt: 80, srt: 20, time: '8days', settled: [580, 520] },
            { type: 'withdraw', jrt: 35, srt: 0, time: '14days', settled: [545, 520] },
            { type: 'mtm', amount: 45, time: '9days', settled: [545, 520] },
            { type: 'deposit', jrt: 0, srt: 75, time: '15days', settled: [545, 595] },
            { type: 'withdraw', jrt: 0, srt: 40, time: '11days', settled: [545, 555] },
            { type: 'mtm', amount: 90, time: '21days', settled: [545, 555] },
            { type: 'deposit', jrt: 25, srt: 25, time: '7days', settled: [570, 580] },
            { type: 'withdraw', jrt: 50, srt: 10, time: '19days', settled: [520, 570] },
            { type: 'mtm', amount: 30, time: '13days', settled: [520, 570] },
            { type: 'deposit', jrt: 100, srt: 0, time: '16days', settled: [620, 570] },
            { type: 'withdraw', jrt: 0, srt: 30, time: '12days', settled: [620, 540] },
            { type: 'mtm', amount: 150, time: '18days', settled: [620, 540] },
            { type: 'deposit', jrt: 40, srt: 60, time: '10days', settled: [660, 600] },
            { type: 'withdraw', jrt: 45, srt: 25, time: '20days', settled: [615, 575] },
            { type: 'mtm', amount: 70, time: '17days', settled: [615, 575] },
            { type: 'deposit', jrt: 0, srt: 50, time: '9days', settled: [615, 625] },
            { type: 'withdraw', jrt: 30, srt: 0, time: '14days', settled: [585, 625] },
            { type: 'mtm', amount: 110, time: '23days', settled: [585, 625] },
            { type: 'deposit', jrt: 55, srt: 35, time: '8days', settled: [640, 660] },
        ];

        for (let i = 0; i < actions.length; i++) {
            const action = actions[i];
            await testMTM.mine(action.time);

            if (action.type === 'deposit') {
                await testMTM.deposit(action.jrt, action.srt);
            }
            if (action.type === 'withdraw') {
                await testMTM.withdraw(action.jrt, action.srt);
            }
            if (action.type === 'mtm') {
                await testMTM.distributeAbs(action.amount, { reconcile: false });
            }
            await expectMtmSettledEquals(testMTM, action, `${i + 1}: ${formatAction(action)}`);
        }
    },
    async 'mtm projected equals settled'() {

        let testMTM = await CdoTest.deploy(client, '365days');
        let testLive = await CdoTest.deploy(client, '0s');
        let snapshot = await client.debug.snapshot();

        return UTest.create({
            async $teardown() {
                await client.debug.revert(snapshot);
                snapshot = await client.debug.snapshot();
            },
            async 'same settled NAVs on deposits/redemptions within the year'() {
                await testMTM.deposit(500, 500);
                await testLive.deposit(500, 500);
                await expectMtmSettledEqualsLive(testMTM, testLive, 'initial deposit');

                const actions: TAction[] = [
                    { type: 'mtm', amount: 120, time: '10days' },
                    { type: 'deposit', jrt: 80, srt: 20, time: '8days' },
                    { type: 'withdraw', jrt: 35, srt: 0, time: '14days' },
                    { type: 'mtm', amount: 45, time: '9days' },
                    { type: 'deposit', jrt: 0, srt: 75, time: '15days' },
                    { type: 'withdraw', jrt: 0, srt: 40, time: '11days' },
                    { type: 'mtm', amount: 90, time: '21days' },
                    { type: 'deposit', jrt: 25, srt: 25, time: '7days' },
                    { type: 'withdraw', jrt: 50, srt: 10, time: '19days' },
                    { type: 'mtm', amount: 30, time: '13days' },
                    { type: 'deposit', jrt: 100, srt: 0, time: '16days' },
                    { type: 'withdraw', jrt: 0, srt: 30, time: '12days' },
                    { type: 'mtm', amount: 150, time: '18days' },
                    { type: 'deposit', jrt: 40, srt: 60, time: '10days' },
                    { type: 'withdraw', jrt: 45, srt: 25, time: '20days' },
                    { type: 'mtm', amount: 70, time: '17days' },
                    { type: 'deposit', jrt: 0, srt: 50, time: '9days' },
                    { type: 'withdraw', jrt: 30, srt: 0, time: '14days' },
                    { type: 'mtm', amount: 110, time: '23days' },
                    { type: 'deposit', jrt: 55, srt: 35, time: '8days' },
                ];

                for (let i = 0; i < actions.length; i++) {
                    const action = actions[i];
                    await testMTM.mine(action.time);

                    if (action.type === 'deposit') {
                        await testMTM.deposit(action.jrt, action.srt);
                        await testLive.deposit(action.jrt, action.srt);
                    }
                    if (action.type === 'withdraw') {
                        await testMTM.withdraw(action.jrt, action.srt);
                        await testLive.withdraw(action.jrt, action.srt);
                    }
                    if (action.type === 'mtm') {
                        await testMTM.distributeAbs(action.amount, { reconcile: false });
                    }

                    await expectMtmSettledEqualsLive(testMTM, testLive, `${i + 1}: ${formatAction(action)}`);
                }
            }

        });
    },

});

type TAction =
    | { type: 'deposit', jrt: number, srt: number, time: string }
    | { type: 'withdraw', jrt: number, srt: number, time: string }
    | { type: 'mtm', amount: number, time: string };

async function expectMtmSettledEqualsLive(testMTM: CdoTest, testLive: CdoTest, label: string) {
    const mtm = await testMTM.getNAVs();
    const live = await testLive.getNAVs();

    $test.compare(mtm.jrtNavSettled, live.jrtNavLive, 18, `JRT settled/live mismatch after ${label}`);
    $test.compare(mtm.srtNavSettled, live.srtNavLive, 18, `SRT settled/live mismatch after ${label}`);
}

async function expectMtmSettledEquals(testMTM: CdoTest, navs: {
    settled: [jrt: number, srt: number]
}, label: string) {
    const mtm = await testMTM.getNAVs();

    const [ jrt, srt ] = navs.settled;
    $test.compare(mtm.jrtNavSettled, jrt, 18, `JRT settled mismatch after ${label}`);
    $test.compare(mtm.srtNavSettled, srt, 18, `SRT settled mismatch after ${label}`);
}


function formatAction(action: TAction) {
    if (action.type === 'mtm') {
        return `mtm +${action.amount}`;
    }
    return `${action.type} jrt=${action.jrt} srt=${action.srt}`;
}

class CdoTest {

    cdoAccount: TEth.IAccount;

    constructor(public cdo: IContractWrapped, public accounting: MTMAccounting) {
        this.cdoAccount = {
            address: this.cdo.address,
            type: 'impersonated'
        };
    }

    static async deploy (client: Web3Client, epochTime: string, opts?: {
        // default: true
        useConservativePrice?: boolean
    }) {
         const { contract: cdo } = await hh.deployCode(
            MockCDOContractSource,
            {
                client,
                arguments: [
                    $date.parseTimespan(epochTime, { get: 's' })
                ]
            },
        );

        const ds = new Deployments(client, deployer, {});
        const deploymentId = 'MTMAccountingProjection_' + epochTime.replace(/\W/g, '') + '_' + Date.now();
        const { contract: accounting } = await ds.ensureWithProxy(MTMAccounting, {
            id: deploymentId,
            arguments: [
                18n,
                false,
                /*useNavAtReconciliation_*/true,
                false,
                false,
                opts?.useConservativePrice ?? true,
                true,
            ],
            initialize: [
                deployer.address,
                cdo.address,
                cdo.address,
                cdo.address,
            ]
        });


        await accounting.storage.$set('riskX', .5e18);
        await accounting.storage.$set('riskY', 0);
        await client.debug.setBalance(cdo.address, BigInt(1e18));

        return new CdoTest(cdo, accounting);
    }

    // HELPERS
    async getNAVs() {
        return this.accounting.totalAssetsLiveAndSettled();
    }
    async deposit(jrtAssetsInMix: bigint | number, srtAssetsInMix: bigint | number) {
        const jrtAssetsIn = toWei(jrtAssetsInMix);
        const srtAssetsIn = toWei(srtAssetsInMix);
        await this.accounting.$receipt().updateAccounting(this.cdoAccount);
        await this.accounting.$receipt().updateBalanceFlow(this.cdoAccount, jrtAssetsIn, 0n, srtAssetsIn, 0n);
        await this.cdo.$receipt().assetsFlow(deployer, jrtAssetsIn + srtAssetsIn);
    }
    async withdraw(jrtAssetsOutMix: bigint | number, srtAssetsOutMix: bigint | number) {
        const jrtAssetsOut = toWei(jrtAssetsOutMix);
        const srtAssetsOut = toWei(srtAssetsOutMix);
        await this.accounting.$receipt().updateAccounting(this.cdoAccount);
        await this.accounting.$receipt().updateBalanceFlow(this.cdoAccount, 0n, jrtAssetsOut, 0n, srtAssetsOut);
        await this.cdo.$receipt().assetsFlow(deployer, -jrtAssetsOut - srtAssetsOut);
    }
    async updateAccounting() {
        await this.accounting.$receipt().updateAccounting(this.cdoAccount);
    }
    async distribute(time: string, aprTVL: number, opts?: { reconcile?: boolean }) {
        const nav = await this.cdo._nav();
        const rate = await this.cdo._rate();

        const dt = await $date.parseTimespan(time, { get: 's' });


        let apr = $bigint.toWei(aprTVL, 12);
        let navT1 = nav + nav * apr * BigInt(dt) / BigInt(SECONDS_PER_YEAR) / 10n ** 12n;

        await this.cdo.$receipt().setTotalAssets(deployer, navT1);
        if (opts?.reconcile !== false) {
            await this.updateAccounting();
        }
    }
    async distributeAbs(rewardsTVL: bigint | number, opts?: { reconcile?: boolean }) {
        const nav = await this.cdo._nav();
        const navT1 = nav + toWei(rewardsTVL);

        await this.cdo.$receipt().setTotalAssets(deployer, navT1);
        if (opts?.reconcile !== false) {
            await this.updateAccounting();
        }
    }
    async forceReconciliation() {
        await this.distributeAbs(1001n);
    }
    async expectApprox(jrt: number, srt: number) {
        const assets = await this.accounting.totalAssets();
        const jrtFact = $bigint.toEther(assets.jrtNavT1Projected, 18, 1);
        const srtFact = $bigint.toEther(assets.srtNavT1, 18, 1);

        const jrtFactDiff = Math.abs(jrt - jrtFact);
        const srtFactDiff = Math.abs(srt - srtFact);
        jrt != null && $require.lte(jrtFactDiff, .5, `JRT should be approximately equal | ${jrt}, ${srt} != ${jrtFact}, ${srtFact}`);
        srt != null && $require.lte(srtFactDiff, .5, `SRT should be approximately equal | ${jrt}, ${srt} != ${jrtFact}, ${srtFact}`);
    }
    async expectAssetsApprox(jrt: number, srt: number, reserve: number) {
        const assets = await this.accounting.totalAssets();
        const jrtFact = $bigint.toEther(assets.jrtNavT1Projected, 18, 1);
        const srtFact = $bigint.toEther(assets.srtNavT1, 18, 1);
        const reserveFact = $bigint.toEther(assets.reserveNavT1, 18, 1);

        $require.lte(Math.abs(jrt - jrtFact), .5, `JRT should be approximately equal | ${jrt}, ${srt}, ${reserve} != ${jrtFact}, ${srtFact}, ${reserveFact}`);
        $require.lte(Math.abs(srt - srtFact), .5, `SRT should be approximately equal | ${jrt}, ${srt}, ${reserve} != ${jrtFact}, ${srtFact}, ${reserveFact}`);
        $require.lte(Math.abs(reserve - reserveFact), .5, `Reserve should be approximately equal | ${jrt}, ${srt}, ${reserve} != ${jrtFact}, ${srtFact}, ${reserveFact}`);
    }
    async setSnapshot(nav: bigint | number, navT1Time: bigint, navMTM: bigint | number, navMTMTime: bigint) {
        await this.cdo.$receipt().setSnapshot(deployer, toWei(nav), navT1Time, toWei(navMTM), navMTMTime);
    }
    async expectInvalidAssetsSnapshot(promise: Promise<unknown>) {
        let { error } = await $promise.caught(promise);
        $require.has('InvalidAssetsSnapshot', error.message);
    }
    async expectUnprojectedApprox(jrt: number, srt: number) {
        const assetsUnproj = await this.accounting.totalAssetsSettled();
        const assets = await this.accounting.totalAssets();

        const jrtFact = $bigint.toEther(assetsUnproj.jrtNavT1Real, 18, 1);
        const srtFact = $bigint.toEther(assetsUnproj.srtNavT1, 18, 1);
        const jrtFactDiff = Math.abs(jrt - jrtFact);
        const srtFactDiff = Math.abs(srt - srtFact);
        jrt != null && $require.lte(jrtFactDiff, .5, `JRT should be approximately equal | ${jrt}, ${srt} != ${jrtFact}, ${srtFact}`);
        srt != null && $require.lte(srtFactDiff, .5, `SRT should be approximately equal | ${jrt}, ${srt} != ${jrtFact}, ${srtFact}`);

        const nav = await this.accounting.nav();
        $require.eq(
            assetsUnproj.jrtNavT1Real + assetsUnproj.srtNavT1 + assetsUnproj.reserveNavT1,
            nav,
            'Unprojected tranche NAV must sum to settled NAV'
        );
    }

    async mine(time: string) {
        await this.cdo.client.debug.mine(time);
    }
    async time() {
        return (await this.cdo.client.getBlock('latest')).timestamp;
    }
}

function toWei(n: bigint | number) {
    if (typeof n === 'number') {
        return $bigint.toWei(n, 18);
    }
    return n;
}
