import { UTest } from 'atma-utest';
import { PerformanceFeeFactory } from '../common/PerformanceFeeFactory';
import { MTMAccounting } from '@0xc/hardhat/MTMAccounting/MTMAccounting';

UTest.create({
    async 'Performance Fee Factory'() {
        return await PerformanceFeeFactory(async ({ ds, cdo, deployer }) => {
            const { contract: accounting } = await ds.ensureWithProxy(MTMAccounting, {
                arguments: [
                    18n,
                    false,
                    true,
                    false,
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
