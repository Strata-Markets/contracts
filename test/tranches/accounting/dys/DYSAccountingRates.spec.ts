import { UTest } from 'atma-utest';
import { DYSAccounting } from '@0xc/hardhat/DYSAccounting/DYSAccounting';
import { DYSAccountingRatesFactory } from '../common/DYSAccountingRatesFactory';

UTest.create({
    async 'DYSAccountingRates' () {
        return await DYSAccountingRatesFactory(async ({ ds, cdo, deployer }) => {
            const { contract: accounting } = await ds.ensureWithProxy(DYSAccounting, {
                arguments: [
                    18n,   // navDecimals
                    false, // useBenchmarkProjection_
                    true,  // useNavAtReconciliation_
                    true,  // useRatesForReconciliation_
                    false, // useJuniorCoversPaidSrtProjection_
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
