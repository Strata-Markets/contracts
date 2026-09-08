import { UTest } from 'atma-utest';
import { dys } from './dys';
import { $test } from '../../utils/$test';
import { TAccountingFactory } from './TAccountingFactory';


export async function PerformanceFeeFactory(factory: TAccountingFactory) {
    const {
        accounting,
        client,
        revert,
        deployer,
    } = await dys.deploy({
        factory
    });

    return UTest.create({
        async $after() {
            await client.debug.reset({});
        },
        async $teardown() {
            await revert();
        },

        async 'track reserve NAV watermark: accrue on gains above the watermark'() {
            await accounting.$receipt().setReserveBps(deployer, BigInt(0.1e18));
            await dys.deposit(500, 500);
            await dys.distributeAbs(100);

            // 1% of $100; watermark = 1100
            $test.compare(await accounting.totalReserve(), 10);

            await dys.distributeAbs(-50);
            $test.compare(
                (await dys.totalAssets()).nav
                , 1050
            );

            await dys.distributeAbs(25);
            // 0%; 1075 is below the 1100 watermark
            $test.compare(await accounting.totalReserve(), 10);

            await dys.distributeAbs(20 + 25);
            // 1% of $20; NAV = 1120
            $test.compare(await accounting.totalReserve(), 12);

            await dys.redeem(100, 100);
            await dys.distributeAbs(20);
            // 1% of $20; NAV = 1140
            $test.compare(await accounting.totalReserve(), 14);

            await dys.distributeAbs(-40); // NAV -40 below watermark
            await dys.deposit(10, 10);
            await dys.redeem(80, 80);
            await dys.distributeAbs(-10); // NAV -50 below watermark
            await dys.redeem(0, 5);

            await dys.distributeAbs(60); // NAV +10 above watermark
            // 1% of $10
            $test.compare(await accounting.totalReserve(), 15);

            await dys.distributeAbs(50);
            // 1% of $50
            $test.compare(await accounting.totalReserve(), 20);
        },
    });

}
