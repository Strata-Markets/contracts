import { UTest } from 'atma-utest';
import { DYSAccountingPaidProjectionFactory } from '../common/DYSAccountingPaidProjectionFactory';
import { MTMAccounting } from '@0xc/hardhat/MTMAccounting/MTMAccounting';


UTest.create({
    async 'MTMAccountingPaidProjection' () {
        return await DYSAccountingPaidProjectionFactory(async (params) => {
            const { ds, cdo, deployer, options} = params;
            const { contract: accounting } = await ds.ensureWithProxy(MTMAccounting, {
                arguments: [
                    18n,   // navDecimals
                    false, // useBenchmarkProjection_
                    true,  // useNavAtReconciliation_
                    false,  // useRatesForReconciliation_
                    options?.useJuniorCoversPaidSrtProjection ?? false,
                    false, // useConservativePrice_
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
