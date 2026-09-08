import { UTest } from 'atma-utest';
import { DYSAccounting } from '@0xc/hardhat/DYSAccounting/DYSAccounting';
import { PerformanceFeeFactory } from '../common/PerformanceFeeFactory';

UTest.create({
    async 'Performance Fee Factory' () {
        return await PerformanceFeeFactory(async ({ ds, cdo, deployer }) => {
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
            return { accounting };
        })
    }
});
