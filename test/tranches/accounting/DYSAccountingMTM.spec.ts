import { IStrataCDO } from '@0xc/hardhat/IStrataCDO/IStrataCDO';
import { MTMAccounting } from '@0xc/hardhat/MTMAccounting/MTMAccounting';
import { UTest } from 'atma-utest';
import { IContractWrapped } from 'dequanto/contracts/ContractClassFactory';
import { Deployments } from 'dequanto/contracts/deploy/Deployments';
import { HardhatProvider } from 'dequanto/hardhat/HardhatProvider';
import { TEth } from 'dequanto/models/TEth';
import { $bigint } from 'dequanto/utils/$bigint';
import { $date } from 'dequanto/utils/$date';
import { $promise } from 'dequanto/utils/$promise';
import { $require } from 'dequanto/utils/$require';

const SECONDS_PER_YEAR = 365 * 24 * 60 * 60;
const hh = new HardhatProvider();
const client = await hh.client();
const deployer = await hh.deployer();
const ds = new Deployments(client, deployer, {

});

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

let cdo: IContractWrapped;
let accounting: MTMAccounting;
let cdoAccount: TEth.IAccount;

UTest.create({
    async $after() {
        await client.debug.reset({});
    },
    async 'useLiveAndSettledPricing'() {
        const { contract: cdoContract } = await hh.deployCode(
            MockCDOContractSource,
            {
                client,
                arguments: [
                    $date.parseTimespan('365days', { get: 's' })
                ]
            },
        );
        cdo = cdoContract;

        const { contract: accountingContract } = await ds.ensureWithProxy(MTMAccounting, {
            arguments: [
                18n,
                false,
                true,
                false,
                false,
                false,
                true,
            ],
            initialize: [
                deployer.address,
                cdo.address,
                cdo.address,
                cdo.address,
            ]
        });

        accounting = accountingContract;
        cdoAccount = {
            address: cdo.address,
            type: 'impersonated'
        } as TEth.IAccount;

        await accounting.storage.$set('riskX', .5e18);
        await accounting.storage.$set('riskY', 0);
        await client.debug.setBalance(cdoAccount.address, BigInt(1e18));

        let snapshot = await client.debug.snapshot();
        return UTest.create({
            async $teardown() {
                await client.debug.revert(snapshot);
                snapshot = await client.debug.snapshot();
            },
            async 'invalid snapshot reverts when MTM timestamp is older than reconciliation timestamp'() {
                await deposit(500, 500);

                const now = BigInt((await time()).toString());
                await setSnapshot(1000, now, 1100, now - 1n);

                // navMTMTime must be >= navT1Time.
                await expectInvalidAssetsSnapshot(updateAccounting());
            },
            async 'invalid snapshot reverts when equal timestamps have different NAV values'() {
                await deposit(500, 500);

                const now = BigInt((await time()).toString());
                await setSnapshot(1000, now, 1100, now);

                // A single timestamp cannot represent two different NAV values.
                await expectInvalidAssetsSnapshot(updateAccounting());
            },
            async 'invalid snapshot reverts when reconciliation timestamp is older than last accrual'() {
                await deposit(500, 500);

                const lastAccrual = await accounting.lastAccrual();
                const staleNavT1Time = lastAccrual - 1n;
                await setSnapshot(1100, staleNavT1Time, 1100, lastAccrual);

                // Reconciliation is not allowed to move accounting time backwards.
                await expectInvalidAssetsSnapshot(updateAccounting());
            },
            async 'MTM gain with reserve fee is not realized before reconciliation'() {
                await accounting.$receipt().setReserveBps(deployer, 10n ** 17n);
                await deposit(500, 500);

                await mine('0.5year');
                await distribute('0.5year', 0.50, { reconcile: false });

                // navT1 = 1000, navMTM = 1250
                // MTM PnL = 250
                // Projected reserve fee = 250 * 10% = 25, withheld from Junior projection.
                // Senior gain = 250 * 0.5 risk factor * 0.5 exposure = 62.5
                // SRT projected = 562.5
                // JRT projected = 1250 - 562.5 - 25 = 662.5
                // Reserve is not realized during MTM projection, so it remains 0.
                await expectAssetsApprox(662.5, 562.5, 0);
                await expectUnprojectedApprox(500, 500);

                await mine('0.5year');
                await distribute('1year', 0.25);

                // Final navT1 = 1250.
                // The same 25 reserve fee is now realized at reconciliation.
                // SRT = 562.5
                // JRT = 1250 - 562.5 - 25 = 662.5
                await expectAssetsApprox(662.5, 562.5, 25);
                await expectUnprojectedApprox(662.5, 562.5);
            },
            async 'MTM reserve fee only applies above the high-water mark'() {
                await accounting.$receipt().setReserveBps(deployer, 10n ** 17n);
                await deposit(500, 500);

                await mine('1year');
                await distribute('1year', 0.10);

                // First reconciliation: navT1 = 1100.
                // Reserve fee = 100 * 10% = 10, and the high-water mark becomes 1100.
                // Senior gain = 100 * 0.5 * 0.5 = 25
                // SRT = 525
                // JRT = 1100 - 525 - 10 = 565
                await expectAssetsApprox(565, 525, 10);
                await expectUnprojectedApprox(565, 525);

                await mine('0.5year');
                await distributeAbs(20, { reconcile: false });

                // navT1 = 1100, navMTM = 1120.
                // Only 20 is above the 1100 high-water mark, so projected reserve fee is 2.
                // Senior gain = 20 * 0.5 * 525 / 1100 = 4.7727272727
                // SRT projected = 529.7727272727
                // JRT projected = 1120 - 529.7727272727 - 12 = 578.2272727273
                // Reserve projection is not realized, so reported reserve remains 10.
                await expectAssetsApprox(578.2272727273, 529.7727272727, 10);
                await expectUnprojectedApprox(565, 525);

                await mine('0.5year');
                await distributeAbs(20);

                // The 2 projected reserve fee is realized at reconciliation.
                await expectAssetsApprox(578.2272727273, 529.7727272727, 12);
                await expectUnprojectedApprox(578.2272727273, 529.7727272727);
            },
            async 'MTM gain previews tranche NAV but does not change unprojected NAV'() {
                await deposit(500, 500);

                await mine('0.5year');
                await distribute('0.5year', 0.50, { reconcile: false });

                // navT1 = 1000, navMTM = 1250
                // MTM PnL = 250
                // Senior exposure ratio = 500 / 1000 = 0.5
                // Senior gain = 250 * 0.5 risk factor * 0.5 exposure = 62.5
                // SRT projected = 562.5
                // JRT projected = 1250 - 562.5 = 687.5
                await expectApprox(687.5, 562.5);

                // MTM is only a projection, so unprojected NAV remains settled T0.
                await expectUnprojectedApprox(500, 500);
            },
            async 'MTM loss reduces projected Junior first but keeps Senior unprojected NAV unchanged'() {
                await deposit(500, 500);

                await mine('0.5year');
                await distribute('0.5year', -0.20, { reconcile: false });

                // navT1 = 1000, navMTM = 900
                // MTM loss = 100
                // With no floor and no benchmark mode, Senior does not take negative PnL.
                // JRT projected = 500 - 100 = 400
                // SRT projected = 500
                await expectApprox(400, 500);

                // Unrealized MTM loss is not settled.
                await expectUnprojectedApprox(500, 500);
            },
            async 'MTM loss recovers to par before epoch without changing settled NAV'() {
                await deposit(500, 500);

                await mine('0.25year');
                await distribute('0.25year', -0.40, { reconcile: false });

                // navT1 = 1000, navMTM = 900
                // Temporary MTM loss = 100
                // With no floor and no benchmark mode, Senior does not take negative PnL.
                // JRT projected = 500 - 100 = 400
                // SRT projected = 500
                await expectApprox(400, 500);
                await expectUnprojectedApprox(500, 500);

                await mine('0.25year');
                await distributeAbs(0, { reconcile: false });

                // navMTM recovered to the settled navT1 = 1000.
                // No MTM PnL remains, and no accounting state was realized.
                await expectApprox(500, 500);
                await expectUnprojectedApprox(500, 500);
            },
            async 'MTM loss recovers into gain before reconciliation'() {
                await deposit(500, 500);

                await mine('0.25year');
                await distribute('0.25year', -0.40, { reconcile: false });
                await expectApprox(400, 500);
                await expectUnprojectedApprox(500, 500);

                await mine('0.25year');
                await distribute('0.5year', 0.20, { reconcile: false });

                // navT1 = 1000, navMTM = 1100
                // MTM PnL = 100
                // Senior exposure ratio = 500 / 1000 = 0.5
                // Senior gain = 100 * 0.5 risk factor * 0.5 exposure = 25
                // SRT projected = 525
                // JRT projected = 1100 - 525 = 575
                await expectApprox(575, 525);
                await expectUnprojectedApprox(500, 500);

                await mine('0.5year');
                await distribute('1year', 0.10);

                // Final navT1 = 1100, so only the recovered gain is realized.
                // Realized PnL = 100
                // Senior exposure ratio = 500 / 1000 = 0.5
                // Senior realized gain = 100 * 0.5 * 0.5 = 25
                // SRT = 525
                // JRT = 1100 - 525 = 575
                await expectApprox(575, 525);
                await expectUnprojectedApprox(575, 525);
            },
            async 'MTM gain turns into MTM loss before reconciliation'() {
                await deposit(500, 500);

                await mine('0.25year');
                await distribute('0.25year', 0.40, { reconcile: false });

                // navT1 = 1000, navMTM = 1100
                // MTM PnL = 100
                // Senior exposure ratio = 500 / 1000 = 0.5
                // Senior gain = 100 * 0.5 risk factor * 0.5 exposure = 25
                // SRT projected = 525
                // JRT projected = 1100 - 525 = 575
                await expectApprox(575, 525);
                await expectUnprojectedApprox(500, 500);

                await mine('0.25year');
                await distribute('0.5year', -0.20, { reconcile: false });

                // navT1 is still 1000, navMTM = 900.
                // The previous Senior MTM gain is fully unwound.
                // With no floor and no benchmark mode, Senior does not take negative PnL.
                // JRT projected = 500 - 100 = 400
                // SRT projected = 500
                await expectApprox(400, 500);
                await expectUnprojectedApprox(500, 500);

                await mine('0.5year');
                await distribute('1year', -0.10);

                // Final navT1 = 900.
                // Realized loss = 100
                // With no floor and no benchmark mode, Senior principal remains whole.
                // JRT = 500 - 100 = 400
                // SRT = 500
                await expectApprox(400, 500);
                await expectUnprojectedApprox(400, 500);
            },
            async 'multiple MTM updates in one epoch do not double count Senior projection'() {
                await deposit(500, 500);

                await mine('0.25year');
                await distribute('0.25year', 0.40);

                // First MTM update: navT1 = 1000, navMTM = 1100.
                // MTM PnL = 100
                // Senior exposure ratio = 500 / 1000 = 0.5
                // Senior gain = 100 * 0.5 risk factor * 0.5 exposure = 25
                // SRT projected = 525
                // JRT projected = 1100 - 525 = 575
                await expectApprox(575, 525);
                await expectUnprojectedApprox(500, 500);

                await mine('0.25year');
                await distribute('0.5year', 0.60);

                // Second MTM update: navT1 is still 1000, navMTM = 1300.
                // Accrued net exposure before the second update:
                // SRT time = 500 * 0.25 + 525 * 0.25 = 256.25
                // SRT projected PnL time = 25 * 0.25 = 6.25
                // SRT net time = 256.25 - 6.25 = 250
                // NAV net time = 1000 * 0.25 + 1000 * 0.25 = 500
                // Senior gain = 300 * 0.5 * 250 / 500 = 75 total projected gain
                // SRT projected = 500 + 75 = 575
                // JRT projected = 1300 - 575 = 725
                await expectApprox(725, 575);
                await expectUnprojectedApprox(500, 500);

                await mine('0.5year');
                await distribute('1year', 0.20);

                // Final reconciliation settles at navT1 = 1200, not the last 1300 MTM quote.
                // Stored Senior projection is unwound before realized PnL allocation.
                // SRT time = 500 * 0.25 + 525 * 0.25 + 575 * 0.5 = 543.75
                // SRT projected PnL time = 25 * 0.25 + 75 * 0.5 = 43.75
                // SRT net time = 543.75 - 43.75 = 500
                // NAV net time = 1000 * 0.25 + 1000 * 0.25 + 1000 * 0.5 = 1000
                // Senior realized gain = 200 * 0.5 * 500 / 1000 = 50
                // SRT = 500 + 50 = 550
                // JRT = 1200 - 550 = 650
                await expectApprox(650, 550);
                await expectUnprojectedApprox(650, 550);
            },
            async 'MTM gain preview is replaced by lower reconciliation NAV'() {
                await deposit(500, 500);

                await mine('0.5year');
                await distribute('0.5year', 0.50, { reconcile: false });

                // navT1 = 1000, navMTM = 1250
                // MTM PnL = 250
                // Senior exposure ratio = 500 / 1000 = 0.5
                // Senior gain = 250 * 0.5 risk factor * 0.5 exposure = 62.5
                // SRT projected = 562.5
                // JRT projected = 1250 - 562.5 = 687.5
                await expectApprox(687.5, 562.5);
                await expectUnprojectedApprox(500, 500);

                await mine('0.5year');
                await distribute('1year', 0.10);

                // Final navT1 is lower than the earlier MTM quote: 1100 instead of 1250.
                // Realized PnL = 100
                // Senior exposure ratio = 500 / 1000 = 0.5
                // Senior realized gain = 100 * 0.5 * 0.5 = 25
                // SRT = 500 + 25 = 525
                // JRT = 1100 - 525 = 575
                await expectApprox(575, 525);
                await expectUnprojectedApprox(575, 525);
            },
            async 'persisted MTM gain is unwound when reconciliation NAV is lower'() {
                await deposit(500, 500);

                await mine('0.5year');
                await distribute('0.5year', 0.50);

                // The MTM quote was persisted during the open epoch.
                // navT1 = 1000, navMTM = 1250
                // Senior MTM gain = 62.5
                // SRT projected = 562.5
                // JRT projected = 687.5
                await expectApprox(687.5, 562.5);
                await expectUnprojectedApprox(500, 500);

                await mine('0.5year');
                await distribute('1year', 0.10);

                // Reconciliation unwinds the stored Senior projection before allocating realized PnL.
                // Settled navT1 = 1100, not the previous 1250 MTM quote.
                // Unwound real bases: SRT = 562.5 - 62.5 = 500, JRT = 437.5 + 62.5 = 500
                // SRT net time = 500 * 0.5 + 562.5 * 0.5 - 62.5 * 0.5 = 500
                // NAV net time = 1000 * 0.5 + 1000 * 0.5 = 1000
                // Senior realized gain = 100 * 0.5 * 500 / 1000 = 25
                // SRT = 525
                // JRT = 575
                await expectApprox(575, 525);
                await expectUnprojectedApprox(575, 525);
            },
            async 'epoch reconciliation settles previous NAV and clears MTM-only distinction'() {
                await deposit(500, 500);

                await mine('1year');
                await distribute('1year', 0.50);

                // navT1 = navMTM = 1500
                // Realized PnL = 500
                // Senior exposure ratio = 500 / 1000 = 0.5
                // Senior gain = 500 * 0.5 * 0.5 = 125
                // SRT = 625
                // JRT = 1500 - 625 = 875
                await expectApprox(875, 625);
                await expectUnprojectedApprox(875, 625);
            },
            async 'MTM gain after reconciliation previews the next epoch only'() {
                await deposit(500, 500);

                await mine('1year');
                await distribute('1year', 0.50);

                await mine('0.5year');
                await distribute('0.5year', 0.50, { reconcile: false });

                // settled navT1 = 1500, live navMTM = 1875
                // MTM PnL = 375
                // Senior exposure ratio = 625 / 1500
                // Senior gain = 375 * 0.5 * 625 / 1500 = 78.125
                // SRT projected = 625 + 78.125 = 703.125
                // JRT projected = 1875 - 703.125 = 1171.875
                await expectApprox(1171.875, 703.125);

                // The 1500 epoch settlement remains the real/unprojected NAV.
                await expectUnprojectedApprox(875, 625);
            },
            async 'withdraw before MTM quote keeps projected and unprojected NAV aligned'() {
                await deposit(500, 500);

                await mine('0.5year');
                await withdraw(100, 100);

                // No MTM PnL was quoted yet.
                // JRT = 500 - 100 = 400
                // SRT = 500 - 100 = 400
                await expectApprox(400, 400);
                await expectUnprojectedApprox(400, 400);
            },
            async 'junior withdraw during MTM epoch keeps unrealized Senior projection unprojected'() {
                await deposit(500, 500);

                await mine('0.5year');
                await distribute('0.5year', 0.50);
                await withdraw(100, 0);

                // Before withdrawal: navT1 = 1000, navMTM = 1250.
                // Senior MTM gain = 250 * 0.5 risk factor * 500 / 1000 = 62.5.
                // SRT projected = 562.5, JRT projected = 687.5.
                // Junior withdraws 100, and the mock strategy NAV drops both navT1 and navMTM by 100.
                // navT1 = 900, navMTM = 1150
                // SRT projected remains 562.5
                // JRT projected = 1150 - 562.5 = 587.5
                await expectApprox(587.5, 562.5);

                // The Senior MTM gain is still unrealized.
                // Unprojected SRT = 500
                // Unprojected JRT = 900 - 500 = 400
                await expectUnprojectedApprox(400, 500);
            },
            async 'senior withdraw during MTM epoch tracks paid projected Senior NAV'() {
                await deposit(500, 500);

                await mine('0.5year');
                await distribute('0.5year', 0.50, { reconcile: false });
                await withdraw(0, 100);

                // Before withdrawal: Senior MTM gain = 62.5, SRT projected = 562.5.
                // Senior withdraws 100 from gross projected SRT NAV.
                // Paid projection = 100 * 62.5 / 562.5 = 11.1111111111.
                // navT1 = 900, navMTM = 1150
                // SRT projected = 562.5 - 100 = 462.5
                // JRT projected = 1150 - 462.5 = 687.5
                await expectApprox(687.5, 462.5);

                // Only the unpaid Senior projection is removed from unprojected NAV.
                // Unpaid projection = 62.5 - 11.1111111111 = 51.3888888889
                // Unprojected SRT = 462.5 - 51.3888888889 = 411.1111111111
                // Unprojected JRT = 900 - 411.1111111111 = 488.8888888889
                await expectUnprojectedApprox(488.8888888889, 411.1111111111);
            },
            async 'senior withdraw shortly before epoch end is reconciled with boundary asset-time'() {
                await deposit(500, 500);

                await mine('0.99year');
                await withdraw(0, 100);

                // Most of the epoch accrued with JRT = 500, SRT = 500.
                // Right before reconciliation, Senior withdraws 100.
                // JRT = 500, SRT = 400, nav = 900.
                await expectApprox(500, 400);
                await expectUnprojectedApprox(500, 400);

                await mine('0.01year');
                await distribute('1year', 0.50);

                // Final navT1 = 900 + 900 * 50% = 1350.
                // Realized PnL = 450
                // SRT time = 500 * 0.99 + 400 * 0.01 = 499
                // NAV time = 1000 * 0.99 + 900 * 0.01 = 999
                // Senior realized gain = 450 * 0.5 * 499 / 999 = 112.3873873874
                // SRT = 400 + 112.3873873874 = 512.3873873874
                // JRT = 1350 - 512.3873873874 = 837.6126126126
                await expectApprox(837.6126126126, 512.3873873874);
                await expectUnprojectedApprox(837.6126126126, 512.3873873874);
            },
            async 'junior withdraw shortly before epoch end is reconciled with boundary asset-time'() {
                await deposit(500, 500);

                await mine('0.99year');
                await withdraw(100, 0);

                // Most of the epoch accrued with JRT = 500, SRT = 500.
                // Right before reconciliation, Junior withdraws 100.
                // JRT = 400, SRT = 500, nav = 900.
                await expectApprox(400, 500);
                await expectUnprojectedApprox(400, 500);

                await mine('0.01year');
                await distribute('1year', 0.50);

                // Final navT1 = 900 + 900 * 50% = 1350.
                // Realized PnL = 450
                // SRT time = 500 * 0.99 + 500 * 0.01 = 500
                // NAV time = 1000 * 0.99 + 900 * 0.01 = 999
                // Senior realized gain = 450 * 0.5 * 500 / 999 = 112.6126126126
                // SRT = 500 + 112.6126126126 = 612.6126126126
                // JRT = 1350 - 612.6126126126 = 737.3873873874
                await expectApprox(737.3873873874, 612.6126126126);
                await expectUnprojectedApprox(737.3873873874, 612.6126126126);
            },
            async 'withdraw immediately after reconciliation starts next MTM epoch from settled NAV'() {
                await deposit(500, 500);

                await mine('1year');
                await distribute('1year', 0.50);
                await withdraw(0, 100);

                // Reconciliation settled JRT = 875 and SRT = 625.
                // The immediate Senior withdrawal belongs to the next epoch baseline.
                // JRT = 875
                // SRT = 625 - 100 = 525
                // nav = 1400
                await expectApprox(875, 525);
                await expectUnprojectedApprox(875, 525);

                await mine('0.5year');
                await distribute('0.5year', 0.50, { reconcile: false });

                // Next-epoch MTM preview starts from the post-withdraw settled NAV.
                // navT1 = 1400, navMTM = 1750
                // MTM PnL = 350
                // Senior exposure ratio = 525 / 1400 = 0.375
                // Senior gain = 350 * 0.5 * 0.375 = 65.625
                // SRT projected = 525 + 65.625 = 590.625
                // JRT projected = 1750 - 590.625 = 1159.375
                await expectApprox(1159.375, 590.625);
                await expectUnprojectedApprox(875, 525);
            },
            async 'withdraw after reconciliation applies to settled tranche NAV'() {
                await deposit(500, 500);

                await mine('1year');
                await distribute('1year', 0.50);
                await withdraw(100, 100);

                // Reconciliation settled: JRT = 875, SRT = 625.
                // Both withdrawals are against settled NAV.
                // JRT = 875 - 100 = 775
                // SRT = 625 - 100 = 525
                await expectApprox(775, 525);
                await expectUnprojectedApprox(775, 525);
            },
            async 'senior withdraw after MTM gain is true-up at reconciliation'() {
                await deposit(500, 500);

                await mine('0.5year');
                await distribute('0.5year', 0.50, { reconcile: false });
                await withdraw(0, 100);

                // MTM projection before withdrawal:
                // navT1 = 1000, navMTM = 1250
                // Senior MTM gain = 250 * 0.5 risk factor * 500 / 1000 = 62.5
                // SRT projected = 562.5, JRT projected = 687.5
                // Senior withdraws 100 and pays out 100 * 62.5 / 562.5 = 11.1111111111 of projected gain.
                await expectApprox(687.5, 462.5);
                await expectUnprojectedApprox(488.8888888889, 411.1111111111);

                await mine('0.5year');
                await distribute('0.5year', 0.50);

                // After withdrawal: navT0 = 900, final navT1 = 1125, realized PnL = 225.
                // Unwind projected Senior gain back to real T0 NAVs:
                // SRT real base = 462.5 - 62.5 = 400
                // JRT real base = 437.5 + 62.5 = 500
                // Asset-time before MTM = 500 * 0.5 = 250
                // Asset-time after withdraw = 462.5 * 0.5 = 231.25
                // Unpaid projection-time = (62.5 - 11.1111111111) * 0.5 = 25.6944444444
                // SRT net time = 250 + 231.25 - 25.6944444444 = 455.5555555556
                // NAV net time = 1000 * 0.5 + 900 * 0.5 = 950
                // Senior realized gain = 225 * 0.5 * 455.5555555556 / 950 = 53.9473684211
                // SRT = 400 + 53.9473684211 = 453.9473684211
                // JRT = 1125 - 453.9473684211 = 671.0526315789
                await expectApprox(671.0526315789, 453.9473684211);
                await expectUnprojectedApprox(671.0526315789, 453.9473684211);
            },
            async 'junior withdraw after MTM gain is true-up at reconciliation'() {
                await deposit(500, 500);

                await mine('0.5year');
                await distribute('0.5year', 0.50, { reconcile: false });
                await withdraw(100, 0);

                // MTM projection before withdrawal:
                // Senior MTM gain = 62.5, SRT projected = 562.5, JRT projected = 687.5.
                // Junior withdraws 100, so navT1 = 900 and navMTM = 1150.
                await expectApprox(587.5, 562.5);
                await expectUnprojectedApprox(400, 500);

                await mine('0.5year');
                await distribute('0.5year', 0.50);

                // After withdrawal: navT0 = 900, final navT1 = 1125, realized PnL = 225.
                // Unwind projected Senior gain:
                // SRT real base = 562.5 - 62.5 = 500
                // JRT real base = 337.5 + 62.5 = 400
                // SRT net time = 500 * 0.5 + 562.5 * 0.5 - 62.5 * 0.5 = 500
                // NAV net time = 1000 * 0.5 + 900 * 0.5 = 950
                // Senior realized gain = 225 * 0.5 * 500 / 950 = 59.2105263158
                // SRT = 500 + 59.2105263158 = 559.2105263158
                // JRT = 1125 - 559.2105263158 = 565.7894736842
                await expectApprox(565.7894736842, 559.2105263158);
                await expectUnprojectedApprox(565.7894736842, 559.2105263158);
            },
            async 'senior deposit before MTM gain then senior withdraw is true-up at reconciliation'() {
                await deposit(500, 500);

                await mine('0.25year');
                await deposit(0, 500);

                await mine('0.25year');
                await distribute('0.5year', 0.50, { reconcile: false });
                await withdraw(0, 100);

                // Before MTM: SRT was 500 for 0.25y, then 1000 for 0.25y.
                // navT1 = 1500, navMTM = 1875, MTM PnL = 375
                // SRT time = 500 * 0.25 + 1000 * 0.25 = 375
                // NAV time = 1000 * 0.25 + 1500 * 0.25 = 625
                // Senior MTM gain = 375 * 0.5 * 375 / 625 = 112.5
                // SRT projected = 1112.5, JRT projected = 762.5
                // Senior withdraws 100 and pays out 100 * 112.5 / 1112.5 = 10.1123595506 of projected gain.
                await expectApprox(762.5, 1012.5);
                await expectUnprojectedApprox(489.8876404494, 910.1123595506);

                await mine('0.5year');
                await distribute('0.5year', 0.50);

                // After withdrawal: navT0 = 1400, final navT1 = 1750, realized PnL = 350.
                // Unwind projected Senior gain:
                // SRT real base = 1012.5 - 112.5 = 900
                // JRT real base = 387.5 + 112.5 = 500
                // SRT time before MTM = 375
                // SRT time after withdraw = 1012.5 * 0.5 = 506.25
                // Unpaid projection-time = (112.5 - 10.1123595506) * 0.5 = 51.1938202247
                // SRT net time = 375 + 506.25 - 51.1938202247 = 830.0561797753
                // NAV net time = 1000 * 0.25 + 1500 * 0.25 + 1400 * 0.5 = 1325
                // Senior realized gain = 350 * 0.5 * 830.0561797753 / 1325 = 109.6291225948
                // SRT = 900 + 109.6291225948 = 1009.6291225948
                // JRT = 1750 - 1009.6291225948 = 740.3708774052
                await expectApprox(740.3708774052, 1009.6291225948);
                await expectUnprojectedApprox(740.3708774052, 1009.6291225948);
            },
            async 'check MTM projection after 1year reconciliation, and .5 year after'() {
                await deposit(500, 500);

                await mine('1year');
                await distribute('1year', 0.50);
                await expectApprox(875, 625);
                await expectUnprojectedApprox(875, 625);

                await mine('.5year');
                await expectUnprojectedApprox(875, 625);
                await distribute('.5year', 0.50);
                await expectApprox(1171.875, 703.125);
                await expectUnprojectedApprox(875, 625);
                await mine('.1year');
                await expectApprox(1171.875, 703.125);
                await expectUnprojectedApprox(875, 625);
            },

        })
    },

    async 'mtm projected equals settled' () {
        const { contract: cdoContract } = await hh.deployCode(
            MockCDOContractSource,
            {
                client,
                arguments: [
                    $date.parseTimespan('365days', { get: 's' })
                ]
            },
        );
        cdo = cdoContract;

        const { contract: accountingContract } = await ds.ensureWithProxy(MTMAccounting, {
            arguments: [
                18n,
                false,
                true,
                false,
                false,
                false,
                true,
            ],
            initialize: [
                deployer.address,
                cdo.address,
                cdo.address,
                cdo.address,
            ]
        });

        accounting = accountingContract;
        cdoAccount = {
            address: cdo.address,
            type: 'impersonated'
        } as TEth.IAccount;

        await accounting.storage.$set('riskX', .5e18);
        await accounting.storage.$set('riskY', 0);
        await client.debug.setBalance(cdoAccount.address, BigInt(1e18));
    }
});


// HELPERS
async function deposit(jrtAssetsInMix: bigint | number, srtAssetsInMix: bigint | number) {
    const jrtAssetsIn = toWei(jrtAssetsInMix);
    const srtAssetsIn = toWei(srtAssetsInMix);
    await accounting.$receipt().updateAccounting(cdoAccount);
    await accounting.$receipt().updateBalanceFlow(cdoAccount, jrtAssetsIn, 0n, srtAssetsIn, 0n);
    await cdo.$receipt().assetsFlow(deployer, jrtAssetsIn + srtAssetsIn);
}
async function withdraw(jrtAssetsOutMix: bigint | number, srtAssetsOutMix: bigint | number) {
    const jrtAssetsOut = toWei(jrtAssetsOutMix);
    const srtAssetsOut = toWei(srtAssetsOutMix);
    await accounting.$receipt().updateAccounting(cdoAccount);
    await accounting.$receipt().updateBalanceFlow(cdoAccount, 0n, jrtAssetsOut, 0n, srtAssetsOut);
    await cdo.$receipt().assetsFlow(deployer, -jrtAssetsOut - srtAssetsOut);
}
async function updateAccounting() {
    await accounting.$receipt().updateAccounting(cdoAccount);
}
async function distribute(time: string, aprTVL: number, opts?: { reconcile?: boolean }) {
    const nav = await cdo._nav();
    const rate = await cdo._rate();

    const dt = await $date.parseTimespan(time, { get: 's' });


    let apr = $bigint.toWei(aprTVL, 12);
    let navT1 = nav + nav * apr * BigInt(dt) / BigInt(SECONDS_PER_YEAR) / 10n ** 12n;

    await cdo.$receipt().setTotalAssets(deployer, navT1);
    if (opts?.reconcile !== false) {
        await updateAccounting();
    }
}
async function distributeAbs(rewardsTVL: bigint | number, opts?: { reconcile?: boolean }) {
    const nav = await cdo._nav();
    const navT1 = nav + toWei(rewardsTVL);

    await cdo.$receipt().setTotalAssets(deployer, navT1);
    if (opts?.reconcile !== false) {
        await updateAccounting();
    }
}
async function forceReconciliation() {
    await distributeAbs(1001n);
}
async function expectApprox(jrt: number, srt: number) {
    const assets = await accounting.totalAssets();
    const jrtFact = $bigint.toEther(assets.jrtNavT1Projected, 18, 1);
    const srtFact = $bigint.toEther(assets.srtNavT1, 18, 1);

    const jrtFactDiff = Math.abs(jrt - jrtFact);
    const srtFactDiff = Math.abs(srt - srtFact);
    jrt != null && $require.lte(jrtFactDiff, .5, `JRT should be approximately equal | ${jrt}, ${srt} != ${jrtFact}, ${srtFact}`);
    srt != null && $require.lte(srtFactDiff, .5, `SRT should be approximately equal | ${jrt}, ${srt} != ${jrtFact}, ${srtFact}`);
}
async function expectAssetsApprox(jrt: number, srt: number, reserve: number) {
    const assets = await accounting.totalAssets();
    const jrtFact = $bigint.toEther(assets.jrtNavT1Projected, 18, 1);
    const srtFact = $bigint.toEther(assets.srtNavT1, 18, 1);
    const reserveFact = $bigint.toEther(assets.reserveNavT1, 18, 1);

    $require.lte(Math.abs(jrt - jrtFact), .5, `JRT should be approximately equal | ${jrt}, ${srt}, ${reserve} != ${jrtFact}, ${srtFact}, ${reserveFact}`);
    $require.lte(Math.abs(srt - srtFact), .5, `SRT should be approximately equal | ${jrt}, ${srt}, ${reserve} != ${jrtFact}, ${srtFact}, ${reserveFact}`);
    $require.lte(Math.abs(reserve - reserveFact), .5, `Reserve should be approximately equal | ${jrt}, ${srt}, ${reserve} != ${jrtFact}, ${srtFact}, ${reserveFact}`);
}
async function setSnapshot(nav: bigint | number, navT1Time: bigint, navMTM: bigint | number, navMTMTime: bigint) {
    await cdo.$receipt().setSnapshot(deployer, toWei(nav), navT1Time, toWei(navMTM), navMTMTime);
}
async function expectInvalidAssetsSnapshot(promise: Promise<unknown>) {
    let { error } = await $promise.caught(promise);
    $require.has('InvalidAssetsSnapshot', error.message);
}
async function expectUnprojectedApprox(jrt: number, srt: number) {
    const assetsUnproj = await accounting.totalAssetsSettled();
    const assets = await accounting.totalAssets();

    const jrtFact = $bigint.toEther(assetsUnproj.jrtNavT1Real, 18, 1);
    const srtFact = $bigint.toEther(assetsUnproj.srtNavT1, 18, 1);
    const jrtFactDiff = Math.abs(jrt - jrtFact);
    const srtFactDiff = Math.abs(srt - srtFact);
    jrt != null && $require.lte(jrtFactDiff, .5, `JRT should be approximately equal | ${jrt}, ${srt} != ${jrtFact}, ${srtFact}`);
    srt != null && $require.lte(srtFactDiff, .5, `SRT should be approximately equal | ${jrt}, ${srt} != ${jrtFact}, ${srtFact}`);

    const nav = await accounting.nav();
    $require.eq(
        assetsUnproj.jrtNavT1Real + assetsUnproj.srtNavT1 + assetsUnproj.reserveNavT1,
        nav,
        'Unprojected tranche NAV must sum to settled NAV'
    );
}

async function mine(time: string) {
    await client.debug.mine(time);
}
async function time() {
    return (await client.getBlock('latest')).timestamp;
}
function toWei(n: bigint | number) {
    if (typeof n === 'number') {
        return $bigint.toWei(n, 18);
    }
    return n;
}

