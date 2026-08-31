import { UTest } from 'atma-utest';
import { dys } from './dys';
import { $test } from '../utils/$test';
import { $hh } from '../utils/$hh';
import { RiskPremiumSigmoid } from '@0xc/hardhat/RiskPremiumSigmoid/RiskPremiumSigmoid';
import { $bigint } from 'dequanto/utils/$bigint';
import { $require } from 'dequanto/utils/$require';

const { factory } = await $hh.init('ethena')

UTest.create({
    async 'calculates the risk premium for the predefined sigmoid configuration'() {
        const sigmoid = await factory.ds.ensureContract(RiskPremiumSigmoid, {
            arguments: [
                BigInt(0.05e18),
                BigInt(0.225e18),
                BigInt(30e18),
                BigInt(0.85e18)
            ]
        });

        const tvls = [
            // SeniorNAV pct, RiskPremium pct
            [ 95.00, 21.67],
            [ 90.00, 19.3],
            [ 88.00, 17.44],
            [ 85.00, 13.75],
            [ 80.00, 8.19],
            [ 75.00, 5.82],
            [ 70.00, 5.19],
            [ 65.00, 5.04],
        ] as const;

        for (let [tvlRatioPct, expect] of tvls) {
            let result = await sigmoid.riskPremium($bigint.toWei(tvlRatioPct, 16));
            let pct = $bigint.toEther(result, 16, 100n);
            $require.eq(expect, pct);
        }
    },
});
