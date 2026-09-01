import { UTest } from 'atma-utest';
import { dys } from './dys';
import { TAccountingFactory } from './TAccountingFactory';

export async function DYSAccountingPaidProjectionFactory(factory: TAccountingFactory) {

    let {
        reset,
        revert,
        deposit,
        redeem,
        mine,
        forceReconciliation,
        expectApprox,
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
        async 'no rewards'() {
            await deposit(500, 500);

            await mine('1year');
            await forceReconciliation();
            await expectApprox(500, 500);
        },
        async 'Junior pays for Seniors projected exit'() {
            await dys.deployAccounting({
                factory,
                useJuniorCoversPaidSrtProjection: true
            });
            await deposit(500, 500);

            await mine('1year');
            // At 10% Projected APR and 5% RiskPremium: JrtGain=75 and SrtGain = 25
            await expectApprox(575, 525);
            await redeem(0, 525 / 2);

            // 12.5 remains as Projected Gain
            await expectApprox(575, 262.5);
            await forceReconciliation();

            // Projected APR 12.5
            await expectApprox(500 - 12.5, 250);
        },

        async 'Senior pays for Seniors projected exit'() {
            await dys.deployAccounting({
                factory,
                useJuniorCoversPaidSrtProjection: false
            });
            await deposit(500, 500);

            await mine('1year');
            // At 10% Projected APR and 5% RiskPremium: JrtGain=75 and SrtGain = 25
            await expectApprox(575, 525);
            await redeem(0, 525 / 2);

            // 12.5 remains as Projected Gain
            await expectApprox(575, 262.5);
            await forceReconciliation();

            // Projected APR 12.5
            await expectApprox(500, 250 - 12.5);
        },
    });
}




