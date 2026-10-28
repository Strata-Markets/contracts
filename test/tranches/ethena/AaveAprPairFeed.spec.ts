import { UTest } from 'atma-utest'
import { $require } from 'dequanto/utils/$require';

import { $hh } from '../utils/$hh';
import { $apr } from '@s/utils/$apr';
import { AaveAprPairProvider } from '@0xc/hardhat/AaveAprPairProvider/AaveAprPairProvider';
import { Addresses } from '@s/constants';
import { $bigint } from 'dequanto/utils/$bigint';
import { l } from 'dequanto/utils/$logger';

const test = await $hh.init('ethena', {
    forked: 24672000,
    fresh : true,
});

UTest.create({

    async $after () {
        await test.wipe();
    },

    async 'aave feed' () {
        const aavePool = '0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2';
        const usdc = Addresses.eth.USDC;
        const usdt = Addresses.eth.USDT;
        const sUSDe = Addresses.eth.sUSDe;

        let { contract: provider } = await test.factory.ds.ensure(AaveAprPairProvider, {
            arguments: [
                aavePool,
                [
                    usdc,
                    usdt
                ],
                sUSDe
            ]
        });

        const apr = await provider.getAPRtarget();
        const aprEth = $bigint.toEther(apr, 12);
        $require.lt(aprEth, 10 / 100);
        $require.gt(aprEth, .5 / 100);

        const apy = $apr.toApy(apr);
        l`avg APY cyan<${apy}>`;

        const usdcData = await provider.getAaveAsset(0n);
        l`USDC APY cyan<${$apr.toApy(usdcData.apr)}>`;

        const usdtData = await provider.getAaveAsset(1n);
        l`USDT APY cyan<${$apr.toApy(usdtData.apr)}>`;

        const pair = await provider.getAprPair();
        $require.eq(pair.aprTarget, apr, `APR target does not match`);
    },

    async 'aave feed zero weight protection (empty benchmark tokens)' () {
        const aavePool = '0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2';
        const sUSDe = Addresses.eth.sUSDe;

        let { contract: provider } = await test.factory.ds.ensure(AaveAprPairProvider, {
            id: 'AaveAprPairProviderZeroWeight',
            arguments: [
                aavePool,
                [],
                sUSDe
            ]
        });

        const apr = await provider.getAPRtarget();
        $require.eq(apr, 0n, 'Empty benchmark tokens should return 0 without division by zero');
        const pair = await provider.getAprPair();
        $require.eq(pair.aprTarget, 0n);
    }
})
