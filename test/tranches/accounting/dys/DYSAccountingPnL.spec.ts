import { UTest } from 'atma-utest';
import { DYSAccountingPnLFactory } from '../common/DYSAccountingPnLFactory';
import { DYSAccounting } from '@0xc/hardhat/DYSAccounting/DYSAccounting';

UTest.create({
    async 'DYS Accounting PnL' () {
        return await DYSAccountingPnLFactory(async ({ ds, cdo, deployer }) => {
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
