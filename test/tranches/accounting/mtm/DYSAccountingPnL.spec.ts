import { UTest } from 'atma-utest';
import { DYSAccountingPnLFactory } from '../common/DYSAccountingPnLFactory';
import { MTMAccounting } from '@0xc/hardhat/MTMAccounting/MTMAccounting';

UTest.create({
    async 'DYS Accounting PnL using MTMAccounting' () {
        return await DYSAccountingPnLFactory(async ({ ds, cdo, deployer }) => {
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
        });
    }
})
