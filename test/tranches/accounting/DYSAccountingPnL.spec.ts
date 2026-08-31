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
                18n,
                false,
                true,
                false,
                false,
                false,
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
        async function distribute(time: string, aprTVL: number, opts?: { reconcile?: boolean}) {
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
        async function distributeAbs(rewardsTVL: bigint | number, opts?: { reconcile?: boolean}) {
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
            async 'equal NAV rewards split by weighted exposure'() {
                await deposit(500, 500);

                await mine('1year');
                await distribute('1year', 0.50);

                // total NAV = 1500
                // PnL = 500
                // srtNavTime / navTime = 500 / 1000 = 0.5
                // SRT gain = 500 * 0.5 * 0.5 = 125
                // SRT = 625
                // JRT = 875
                await expectApprox(875, 625);
            },
            async 'late senior deposit participates by weighted NAV ratio'() {
                await deposit(500, 500);

                await mine('0.5year');
                await deposit(0, 500);

                await mine('0.5year');
                await distribute('1year', 0.50);

                // total NAV before reward = 1500
                // PnL = 750
                //
                // srtNavTime = 500 * 0.5 + 1000 * 0.5 = 750
                // navTime = 1000 * 0.5 + 1500 * 0.5 = 1250
                // ratio = 750 / 1250 = 0.6
                //
                // SRT gain = 750 * 0.5 * 0.6 = 225
                // SRT = 1225
                // JRT = 2250 - 1225 = 1025
                await expectApprox(1025, 1225);
            },

            async 'late junior deposit reduces senior reward ratio'() {
                await deposit(500, 500);

                await mine('0.5year');
                await deposit(500, 0);

                await mine('0.5year');
                await distribute('1year', 0.50);

                // total NAV before reward = 1500
                // PnL = 750
                //
                // srtNavTime = 500
                // navTime = 1000 * 0.5 + 1500 * 0.5 = 1250
                // ratio = 500 / 1250 = 0.4
                //
                // SRT gain = 750 * 0.5 * 0.4 = 150
                // SRT = 650
                // JRT = 2250 - 650 = 1600
                await expectApprox(1600, 650);
            },

            async 'early senior redemption reduces senior reward ratio'() {
                await deposit(500, 500);

                await mine('0.5year');

                await redeem(0, 250);
                const { srtNavT1 } = await accounting.totalAssets();

                // ProjectedAPR: 10%; RiskPremium=0.5
                // 1/2 Year Senior = 500 * 0.05 / 2 = 512.5
                $require.eq($bigint.toEther(srtNavT1), 262.5, `The first half-year projection: 512.5 - 250 = 262.5`);

                await mine('0.5year');

                await distribute('1year', 0.50 /* 50% */);

                // total NAV before reward = 750
                // PnL = 375
                //
                // srtPaidProjected = 250 * 12.5 / 512.5 = 6.0975609756
                // liveProjected = 12.5 - 6.0975609756 = 6.4024390244
                // srtNavTime = 500 * 0.5 + 262.5 * 0.5 = 381.25
                // srtProjectedPnLTime = 6.4024390244 * 0.5 = 3.2012195122
                // srtNavTimeNet = 381.25 - 3.2012195122 = 378.0487804878
                // navTime = 1000 * 0.5 + 750 * 0.5 = 875
                // ratio = 381.25 / 875
                //
                // SRT gain = 375 * 0.5 * 378.0487804878 / 875 = 81.01045296167143
                // SRT = 250 + 81.01045296167143 = 331.01045296167143
                // JRT = 1125 - 331.01045296167143 = 793.9895470383285
                await expectApprox(793.9895470383285, 331.01045296167143);
            },

            async 'junior only receives all NAV rewards'() {
                await deposit(500, 0);

                await mine('1year');
                await distribute('1year', 0.50);

                // srtNavTime = 0
                // SRT = 0
                // JRT = 750
                await expectApprox(750, 0);
            },

            async 'senior only receives capped reward and residual stays junior or reserve'() {
                await deposit(0, 500);

                await mine('1year');
                await distribute('1year', 0.50);

                // total NAV = 750
                // PnL = 250
                // ratio = 1
                // SRT gain = 250 * 0.5 = 125
                // SRT = 625
                //
                // The remaining 125 depends on your accounting rule:
                // JRT/reserve/min-nav handling.
                await expectApprox(125, 625);
            },

            async 'zero APR does not change NAVs'() {
                await deposit(500, 500);

                await mine('1year');
                await distribute('1year', 0);
                await forceReconciliation();

                await expectApprox(500, 500);
            },

            async 'negative NAV pnl does not give senior rewards without floor'() {
                await deposit(500, 500);

                await mine('1year');
                await distribute('1year', -0.10);

                // total NAV = 900
                // no positive rewards to split
                await expectApprox(400, 500);
            },
            async 'large negative NAV PnL coveres Senior'() {
                await deposit(500, 50_000);
                await accounting.$receipt().setFloorRate(deployer, BigInt(0.01e18));
                await redeem(475, 0);
                await mine('1day');

                // SRT Loss:
                // BaseAPR -1000%
                // SrtAPR -500% (BaseAPR - 0.5 RiskPremium)
                // SrtLoss = 1_369 / 2
                // NavLoss = 50_025 * -1000APR = 1370.54
                await distribute('1day', -10.00);
                // Nav Loss covered:
                // JRT 24$
                // SRT 1370.54 - 24

                await expectApprox(1, 50_000 - 1370.54 + 24);
            },

            async 'quarterly reconciliation compounds NAV reward split'() {
                await deposit(500, 500);

                await mine('0.25year');
                await distribute('0.25year', 0.50);

                await mine('0.25year');
                await distribute('0.25year', 0.50);

                await mine('0.25year');
                await distribute('0.25year', 0.50);

                await mine('0.25year');
                await distribute('0.25year', 0.50);

                // total NAV = 1000 * 1.125^4 = 1601.806640625
                // SRT = 500 * 1.0625^4 = 637.71533203125
                // JRT = 964.09130859375
                await expectApprox(964.09, 637.7);
            },

            async 'calculate accrueAssetTime in view function'() {
                await deposit(50, 50);
                await mine('5days');
                // Deposit Junior only
                await deposit(200_000, 0);
                await mine('5days');

                // Without view-accrued asset-time, totalAssets() prices the reconciliation using stale
                // exposure weights and gives Senior too much yield. The view path must simulate
                // _accrueAssetTime() so tranche NAVs reflect the latest time-weighted exposure.
                await distributeAbs(100, { reconcile: false });
                await expectApprox(200_149.975, 50.024975);
            },

        })
    }
})
