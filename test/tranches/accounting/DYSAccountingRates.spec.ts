import { DYSAccounting } from '@0xc/hardhat/DYSAccounting/DYSAccounting';
import { UTest } from 'atma-utest';
import { Deployments } from 'dequanto/contracts/deploy/Deployments';
import { HardhatProvider } from 'dequanto/hardhat/HardhatProvider';
import { TEth } from 'dequanto/models/TEth';
import { $bigint } from 'dequanto/utils/$bigint';
import { $date } from 'dequanto/utils/$date';
import { $number } from 'dequanto/utils/$number';
import { $require } from 'dequanto/utils/$require';

const SECONDS_PER_YEAR = 365 * 24 * 60 * 60;
const hh = new HardhatProvider();
const client = await hh.client();
const deployer = await hh.deployer();
const ds = new Deployments(client, deployer, {

})


UTest.create({
    async $after() {
        await client.debug.reset({});
    },
    async 'useRatesForReconciliation'() {
        const { contract: cdo } = await hh.deployCode(
            `
                contract MockCDO {
                    uint256 public _rate = 1e18;
                    uint256 public _nav = 0;

                    int64 public _aprTarget = 0;
                    int64 public _aprBase = 0.1e12;

                    function setTotalAssets(uint256 amount) external {
                        _nav = amount;
                    }
                    function setRate(uint256 rate) external {
                        _rate = rate;
                    }
                    function setAprs(int64 aprTarget, int64 aprBase) external {
                        _aprTarget = aprTarget;
                        _aprBase = aprBase;
                    }
                    function assetsFlow(int256 amount) external {
                        _nav = amount > 0
                            ? _nav + uint256(amount)
                            : _nav - uint256(-amount);
                    }
                    function totalStrategyAssets() public view returns (uint256) { return _nav; }
                    function totalStrategyAssets(uint256, uint256) public view returns (uint256) { return _nav; }
                    function totalStrategyAssetsSnapshot (uint256, uint256) public view returns (uint256, uint256, uint256, uint256) {
                        return (_nav, block.timestamp, _nav, block.timestamp);
                    }
                    function getRate() public view returns (uint256) { return _rate; }
                    function strategy() public view returns (address) { return address(this); }

                    function latestRoundData () public view returns (int64, int64, uint64, uint64) {
                        return (_aprTarget, _aprBase, uint64(block.timestamp), 1);
                    }
                }
            `,
            { client },
        );

        const cdoAccount = {
            address: cdo.address,
            type: 'impersonated'
        } as TEth.IAccount;

        await client.debug.setBalance(cdoAccount.address, BigInt(1e18));

        const { contract: accounting } = await ds.ensureWithProxy(DYSAccounting, {
            arguments: [
                18n,   // navDecimals
                false, // useBenchmarkProjection_
                true,  // useNavAtReconciliation_
                true,  // useRatesForReconciliation_
                false, // useJuniorCoversPaidSrtProjection_
                false, // useConservativePrice_
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


        // HELPERS
        async function deposit(jrtAssetsInMix: bigint | number, srtAssetsInMix: bigint | number) {
            const jrtAssetsIn = toWei(jrtAssetsInMix);
            const srtAssetsIn = toWei(srtAssetsInMix);
            await accounting.$receipt().updateAccounting(cdoAccount);
            await accounting.$receipt().updateBalanceFlow(cdoAccount, jrtAssetsIn, 0n, srtAssetsIn, 0n);
            await cdo.$receipt().assetsFlow(deployer, jrtAssetsIn + srtAssetsIn);
        }
        async function redeem(jrtAssetsOutMix: bigint | number, srtAssetsOutMix: bigint | number) {
            const jrtAssetsOut = toWei(jrtAssetsOutMix);
            const srtAssetsOut = toWei(srtAssetsOutMix);
            await accounting.$receipt().updateAccounting(cdoAccount);
            await accounting.$receipt().updateBalanceFlow(cdoAccount, 0n, jrtAssetsOut, 0n, srtAssetsOut);
            await cdo.$receipt().assetsFlow(deployer, -jrtAssetsOut - srtAssetsOut);
        }
        async function updateAccounting() {
            await accounting.$receipt().updateAccounting(cdoAccount);
        }
        async function distribute(time: string, aprTVL: number, aprRate: number) {
            const nav = await cdo._nav();
            const rate = await cdo._rate();

            const dt = await $date.parseTimespan(time, { get: 's' });

            let apr = $bigint.toWei(aprRate, 12);
            let gainFactor = apr * BigInt(dt) / BigInt(SECONDS_PER_YEAR);
            let rateT1 = rate * (10n ** 12n + gainFactor) / 10n ** 12n;

            apr = $bigint.toWei(aprTVL, 12);
            let navT1 = nav + nav * apr * BigInt(dt) / BigInt(SECONDS_PER_YEAR) / 10n ** 12n;

            await cdo.$receipt().setRate(deployer, rateT1);
            await cdo.$receipt().setTotalAssets(deployer, navT1);
            await updateAccounting();
        }
        async function distributeAbs(rewardsTVL: bigint | number) {
            const nav = await cdo._nav();
            const navT1 = nav + toWei(rewardsTVL);

            await cdo.$receipt().setTotalAssets(deployer, navT1);
            await updateAccounting();
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
            $require.lte(jrtFactDiff, .5, `JRT should be approximately equal | ${jrt}, ${srt} != ${jrtFact}, ${srtFact}`);
            $require.lte(srtFactDiff, .5, `SRT should be approximately equal | ${jrt}, ${srt} != ${jrtFact}, ${srtFact}`);
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


        let snapshot = await client.debug.snapshot();
        return UTest.create({
            async $teardown() {
                await client.debug.revert(snapshot);
                snapshot = await client.debug.snapshot();
            },
            async 'equal NAV rewards and Rate rewards'() {
                await deposit(500, 500);
                await mine('1year');

                // Projection: Base = 0.10 = 10%; SRT (1/2) = 0.05 = 5%
                await expectApprox(575, 525);

                await distribute('1year', 0.50, 0.50);
                // total NAV = 1000 * 1.50 = 1500
                // SRT gain = 500 * (0.50 * 0.50) = 125
                // SRT = 625
                // JRT = 1500 - 625 = 875
                await expectApprox(875, 625);
            },
            async 'juniors capture excess NAV yield above rate reward'() {
                await deposit(500, 500);
                await mine('1year');

                await distribute('1year', 1.00, 0.50);

                // total NAV = 1000 * 2.00 = 2000
                // SRT gain = 500 * (0.50 * 0.50) = 125
                // SRT = 625
                // JRT = 2000 - 625 = 1375
                await expectApprox(1375, 625);
            },

            async 'rate reward can exceed total NAV pnl'() {
                await deposit(500, 500);
                await mine('1year');
                await distribute('1year', 0.20, 1.00);

                // total NAV = 1000 * 1.20 = 1200
                // SRT gain = 500 * (1.00 * 0.50) = 250
                // SRT = 750
                // JRT = 1200 - 750 = 450
                await expectApprox(450, 750);
            },

            async 'late senior deposit earns only for weighted exposure time'() {
                await deposit(500, 500);
                await mine('0.5year');
                await deposit(0, 500);
                await mine('0.5year');
                await distribute('1year', 0.50, 0.50);
                // total NAV before reward = 1500
                // NAV gain = 1500 * 0.50 = 750
                // total NAV = 2250
                //
                // Senior asset-time over the epoch:
                // 500 for 6m + 1000 for 6m
                // avg SRT NAV = 750
                //
                // SRT gain = 750 * 0.25 = 187.5
                // SRT = 1000 + 187.5 = 1187.5
                // JRT = 2250 - 1187.5  = 1062.5
                await expectApprox(1062.5, 1187.5);
            },
            async 'early senior redemption reduces weighted exposure time'() {
                await deposit(500, 500);

                await mine('0.5year');
                await redeem(0, 250);

                await mine('0.5year');
                await distribute('1year', 0.50, 0.50);

                // total NAV before reward = 750
                // NAV gain = 750 * 0.50 = 375
                // total NAV = 1125
                //
                // srtPaidProjected = 250 * 12.5 / 512.5 = 6.0975609756
                // liveProjected = 12.5 - 6.0975609756 = 6.4024390244
                // srtNavTime = 500 * 0.5 + 262.5 * 0.5 = 381.25
                // srtProjectedPnLTime = 6.4024390244 * 0.5 = 3.2012195122
                // srtNavTimeReal = 381.25 - 3.2012195122 = 378.0487804878
                // SRT gain = 378.0487804878 * 0.50 * 0.50 = 94.5121951220
                // SRT = 250 + 94.5121951220 = 344.5121951220
                // JRT = 1125 - 344.5121951220 = 780.4878048780
                await expectApprox(780.4878048780, 344.5121951220);
            },
            async 'junior deposit does not increase senior rate reward'() {
                await deposit(500, 500);

                await mine('0.5year');
                await deposit(500, 0);

                await mine('0.5year');
                await distribute('1year', 0.50, 0.50);

                // total NAV before reward = 1500
                // NAV gain = 1500 * 0.50 = 750
                // total NAV = 2250
                //
                // avg SRT NAV = 500
                // SRT gain = 500 * 0.25 = 125
                // SRT = 625
                // JRT = 2250 - 625 = 1625
                await expectApprox(1625, 625);
            },
            async 'quarterly reconciliation compounds senior rewards'() {
                await deposit(500, 500);

                await mine('0.25year');
                await distribute('0.25year', 0.50, 0.50);

                await mine('0.25year');
                await distribute('0.25year', 0.50, 0.50);

                await mine('0.25year');
                await distribute('0.25year', 0.50, 0.50);

                await mine('0.25year');
                await distribute('0.25year', 0.50, 0.50);

                // total NAV = 1000 * (1 + 0.50 * 0.25)^4
                //           = 1000 * 1.125^4
                //           = 1601.806640625
                //
                // SRT = 500 * (1 + 0.50 * 0.25 * 0.50)^4
                //     = 500 * 1.0625^4
                //     = 637.7
                //
                // JRT = 1601.806640625 - 637.7
                //     = 964.09130859375
                await expectApprox(964, 637.7);
            },
            async 'zero rate APR sends all NAV reward to juniors'() {
                await deposit(500, 500);

                await mine('1year');
                await distribute('1year', 0.50, 0);

                // total NAV = 1500
                // SRT gain = 0
                // SRT = 500
                // JRT = 1000
                await expectApprox(1000, 500);
            },
            async 'zero NAV APR but positive rate APR should transfer from juniors to seniors'() {
                await deposit(500, 500);

                await mine('1year');
                await distribute('1year', 0, 0.50);

                // As no TVL rewards, it keeps projecting, triggers reconciliation
                await forceReconciliation();

                // total NAV = 1000
                // SRT gain = 500 * 0.25 = 125
                // SRT = 625
                // JRT = 375
                await expectApprox(375, 625);
            },
            async 'senior deposit right before reconciliation earns almost nothing'() {
                await deposit(500, 500);

                const p1 = Math.floor(0.999 * SECONDS_PER_YEAR);
                await mine(`${p1}s`);
                await deposit(0, 500);

                await mine(`${SECONDS_PER_YEAR - p1}s`);
                await distribute('1year', 0.50, 0.50);

                // total NAV before reward = 1500
                // total NAV after reward = 2250
                //
                // avg SRT NAV = 500 * 0.999 + 1000 * 0.001 = 500.5
                // SRT gain = 500.5 * 0.25 = 125.125
                // SRT = 1000 + 125.125 = 1125.125
                // JRT = 2250 - 1125.125 = 1124.875
                await expectApprox(1124.875, 1125.125);
            },
            async 'senior redemption right before reconciliation keeps almost full exposure'() {
                await deposit(500, 500);

                const p1 = Math.floor(0.999 * SECONDS_PER_YEAR);
                await mine(`${p1}s`);
                await redeem(0, 250);

                await mine(`${SECONDS_PER_YEAR - p1}s`);
                await distribute('1year', 0.50, 0.50);

                // total NAV before reward = 750
                // total NAV after reward = 1125
                //
                // avg SRT NAV = 500 * 0.999 + 250 * 0.001 = 499.75
                // SRT gain = 499.75 * 0.25 = 124.9375
                // SRT = 250 + 124.9375 = 374.9375
                // JRT = 1125 - 374.9375 = 750.0625
                await expectApprox(750.0625, 374.9375);
            },
            async 'junior redemption does not reduce senior rate reward'() {
                await deposit(500, 500);

                await mine('0.5year');
                await redeem(250, 0);

                await mine('0.5year');
                await distribute('1year', 0.50, 0.50);

                // total NAV before reward = 750
                // total NAV after reward = 1125
                //
                // avg SRT NAV = 500
                // SRT gain = 125
                // SRT = 625
                // JRT = 500
                await expectApprox(500, 625);
            },
            async 'junior redemption can make senior entitlement consume most rewards'() {
                await deposit(500, 500);

                await mine('0.5year');

                // Keep 5% coverage ratio
                const maxWithdraw = await accounting.maxWithdraw(true, false);
                $require.eq(maxWithdraw, toWei(500 - 500 * .05));

                await redeem(475, 0);


                await mine('0.5year');
                await distribute('1year', 0.10, 0.50);

                // NAV before reward = 525
                // total NAV = 577.5
                // avg SRT = 500
                // SRT gain = 125
                // SRT = 625
                // JRT = -47.5
                // JRT min 1$
                await expectApprox(1, 625 - 47.5 - 1);
            },
            async 'junior only deposit cannot pay senior reward'() {
                await deposit(500, 0);

                await mine('1year');
                await distribute('1year', 0.50, 0.50);

                // avg SRT = 0
                // total NAV = 750
                // SRT = 0
                // JRT = 750
                await expectApprox(750, 0);
            },
            async 'rate decrease gives seniors no rate reward (floor=0)'() {
                await deposit(500, 500);

                await mine('1year');
                await distribute('1year', 0.50, -0.10);

                // if your mock supports negative rate APR:
                // SRT gain = 0
                // total NAV = 1500
                // JRT = 1000
                await expectApprox(1000, 500);
            },
            async 'negative rate with floor caps senior daily loss'() {
                await deposit(500, 500);

                await accounting.$receipt().setFloorRate(deployer, BigInt(0.005e18)); // 0.5% / day

                await mine('1day');
                await distribute('1day', 0.50, -10.00);

                // total NAV gain = 1000 * 0.50 / 365 = 1.3698630137
                // total NAV = 1001.3698630137
                //
                // raw SRT loss = 500 * (-10.00 / 365) * 0.50 = -6.8493150685
                // floor loss cap = 500 * 0.005 = 2.5
                //
                // SRT = 500 - 2.5 = 497.5
                // JRT = 1001.3698630137 - 497.5 = 503.8698630137
                await expectApprox(503.8698630137, 497.5);
            },
            async 'negative rate below floor is not capped'() {
                await deposit(500, 500);

                await accounting.$receipt().setFloorRate(deployer, BigInt(0.005e18)); // 0.5% / day

                await mine('1day');
                await distribute('1day', 0.50, -1.00);

                // total NAV = 1000 + 1000 * 0.50 / 365
                //           = 1001.3698630137
                //
                // raw SRT loss = 500 * (-1.00 / 365) * 0.50
                //              = -0.6849315068
                // floor cap = -2.5, so not binding
                //
                // SRT = 499.3150684932
                // JRT = 1001.3698630137 - 499.3150684932
                //     = 502.0547945205
                await expectApprox(502.0547945205, 499.3150684932);
            },
            async 'floor extends proportionally over two days'() {
                await deposit(500, 500);

                await accounting.$receipt().setFloorRate(deployer, BigInt(0.005e18)); // 0.5% / day

                await mine('2days');
                await distribute('2days', 0.50, -10.00);

                // total NAV gain = 1000 * 0.50 * 2 / 365 = 2.7397260274
                // total NAV = 1002.7397260274
                //
                // raw SRT loss = 500 * (-10.00 * 2 / 365) * 0.50
                //              = -13.698630137
                //
                // floor cap = 500 * 0.005 * 2 = 5
                // SRT = 495
                // JRT = 1002.7397260274 - 495 = 507.7397260274
                await expectApprox(507.7397260274, 495);
            },
            async 'floor reset after changing floor rate uses current senior nav as baseline'() {
                await deposit(500, 500);

                await mine('1year');
                await distribute('1year', 0.50, 0.50);

                await expectApprox(875, 625);

                await accounting.$receipt().setFloorRate(deployer, BigInt(0.005e18));

                await mine('1day');
                await distribute('1day', 0, -10.00);
                // As no TVL rewards, it keeps projecting, triggers reconciliation
                await forceReconciliation();

                // floor baseline = current SRT = 625
                // daily loss cap = 625 * 0.005 = 3.125
                //
                // SRT = 625 - 3.125 = 621.875
                // total NAV remains 1500
                // JRT = 1500 - 621.875 = 878.125
                await expectApprox(878.125, 621.875);
            },
            async 'floor for APR Rate with APR NAV ~ 0 should credit Junior'() {
                await deposit(500, 50000);
                await accounting.$receipt().setFloorRate(deployer, BigInt(0.01e18));
                await redeem(475, 0);
                await mine('1day');

                // SRT lost based on the Rates APR, however underlying PnL was around 0;
                // transfer Seniors Loss to Juniors Profit
                await distribute('1day', 0, -10.00);
                // As no TVL rewards, it keeps projecting, triggers reconciliation
                await forceReconciliation();
                await expectApprox(25 + 500, 49500);
            },
            async 'floor window includes senior deposits as net flows'() {
                await deposit(500, 500);

                await accounting.$receipt().setFloorRate(deployer, BigInt(0.005e18));

                await mine('0.5day');
                await deposit(0, 500);

                await mine('0.5day');
                await distribute('1day', 0, -100.00);
                await forceReconciliation();

                // Floor baseline should be windowStartSrtNav + windowNetFlows = 1000
                // max daily loss = 1000 * 0.005 = 5
                // Juniors receive Profit, while
                // Senior lose here from Rates,
                // Juniors earn from NAV, so whatever Senior lose here is transfered to Junior
                await expectApprox(505, 995);
            },
            async 'floor window includes senior redemptions as net flows'() {
                await deposit(500, 500);

                await accounting.$receipt().setFloorRate(deployer, BigInt(0.005e18));

                await mine('0.5day');
                await redeem(0, 250);

                await mine('0.5day');
                await distribute('1day', 0, -100.00);
                await forceReconciliation();
                // Floor baseline should be 500 - 250 = 250
                // max daily loss = 1.25
                await expectApprox(500 + 1.25, 248.75);
            },
            async 'deposit after full elapsed epoch earns nothing for previous epoch'() {
                await deposit(500, 500);

                await mine('1year');
                await deposit(0, 500);

                await distribute('1year', 0.50, 0.50);

                // avg SRT = 500 for the elapsed year
                // total NAV before reward = 1500
                // total NAV after reward = 2250
                // SRT gain = 500 * 0.25 = 125
                // SRT = 1125
                // JRT = 1125
                await expectApprox(1125, 1125);
            },
            async 'rate unchanged with NAV gain keeps seniors flat'() {
                await deposit(500, 500);
                await mine('1year');
                await distribute('1year', 0.50, 0);
                await expectApprox(1000, 500);
            },
            async 'floor window per day at -1% floor for senior and -2% for underlying protocol'() {
                // Disable RiskPremium for this floor test so the Senior loss matches the raw rate loss.
                // With the default riskX=50%, a -2% daily rate loss becomes only -1% for Senior,
                // because srtFactor = 1 - riskPremium = 50%.
                await accounting.storage.$set('riskX', 0);

                await accounting.$receipt().setFloorRate(deployer, BigInt(0.01e18));
                await deposit(500, 1000);

                await mine('1day');
                await deposit(0, 1000);

                // 2% loss a day = -730%
                await distribute('1day', -7.30, -7.30);
                await forceReconciliation();

                // max senior daily loss = 2000 * 1% = 20
                // total loss = 2500 * 2% = 50
                await expectApprox(500 - 30, 1980);
            },
        })
    }
})
