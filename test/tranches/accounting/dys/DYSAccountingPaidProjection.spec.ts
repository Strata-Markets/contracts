import { UTest } from 'atma-utest';
import { DYSAccounting } from '@0xc/hardhat/DYSAccounting/DYSAccounting';
import { DYSAccountingPaidProjectionFactory } from '../common/DYSAccountingPaidProjectionFactory';


UTest.create({
    async 'DYSAccountingPaidProjection' () {
        return await DYSAccountingPaidProjectionFactory(async (params) => {
            const { ds, cdo, deployer, options} = params;
            const { contract: accounting } = await ds.ensureWithProxy(DYSAccounting, {
                arguments: [
                    18n,   // navDecimals
                    false, // useBenchmarkProjection_
                    true,  // useNavAtReconciliation_
                    false,  // useRatesForReconciliation_
                    options?.useJuniorCoversPaidSrtProjection ?? false,
                    false, // useConservativePrice_
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
