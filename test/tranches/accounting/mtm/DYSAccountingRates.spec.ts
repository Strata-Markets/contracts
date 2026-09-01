import { UTest } from 'atma-utest';
import { DYSAccountingRatesFactory } from '../common/DYSAccountingRatesFactory';
import { MTMAccounting } from '@0xc/hardhat/MTMAccounting/MTMAccounting';

UTest.create({
    async 'DYSAccountingRates using MTMAccounting' () {
        return await DYSAccountingRatesFactory(async ({ ds, cdo, deployer }) => {
            const { contract: accounting } = await ds.ensureWithProxy(MTMAccounting, {
                arguments: [
                    18n,   // navDecimals
                    false, // useBenchmarkProjection_
                    true,  // useNavAtReconciliation_
                    true,  // useRatesForReconciliation_
                    false, // useJuniorCoversPaidSrtProjection_
                    false, // useConservativePrice_
                    false, // useMTMProjection_
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
