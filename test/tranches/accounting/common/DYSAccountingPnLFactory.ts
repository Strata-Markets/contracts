import { UTest } from 'atma-utest';
import { $bigint } from 'dequanto/utils/$bigint';
import { $require } from 'dequanto/utils/$require';
import { dys } from './dys';
import { TAccountingFactory } from './TAccountingFactory';



export async function DYSAccountingPnLFactory(factory: TAccountingFactory) {


    let {
        reset,
        revert,
        deposit,
        redeem,
        mine,
        distribute,
        forceReconciliation,
        expectApprox,
        totalAssets,
        distributeAbs,
    } = await dys.deploy({
        factory,
        options: {
            useJuniorCoversPaidSrtProjection: false
        }
    });

    return UTest.create({
        async $teardown() {
            revert();
        },
        async $after() {
            await reset();
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
            const { srtNav } = await totalAssets();

            // ProjectedAPR: 10%; RiskPremium=0.5
            // 1/2 Year Senior = 500 * 0.05 / 2 = 512.5
            $require.eq($bigint.toEther(srtNav), 262.5, `The first half-year projection: 512.5 - 250 = 262.5`);

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
            await dys.accounting.$receipt().setFloorRate(dys.deployer, BigInt(0.01e18));
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
