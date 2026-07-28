import { UTest } from 'atma-utest';
import { $hh } from '../tranches/utils/$hh';
import { $require } from 'dequanto/utils/$require';
import { Addresses, ChainlinkFeeds } from '@s/constants';
import { SymbioticConfig } from '@s/platforms/symbiotic/SymbioticConfig';
import { SymbioticNMDeployments } from '@s/deployments/SymbioticNMDeployments';
import { DeploymentsBase } from '@s/deployments/DeploymentsBase';

await $hh.test.init();

// The AppAdapter lives on the Symbiotic side; the deploy path only stores its address, so a
// placeholder is enough to exercise oracle + middleware deployment, feed and market registration.
const APP_ADAPTER = '0x000000000000000000000000000000000000dEaD';
const ZERO = '0x0000000000000000000000000000000000000000';

let forked: DeploymentsBase;

function newDeployments() {
    return new SymbioticNMDeployments({
        client: forked.client,
        deployer: forked.deployer,
        owner: forked.deployer,
        appAdapter: APP_ADAPTER,
        isTest: true,
    });
}

UTest.create({

    async $before() {
        forked = await $hh.forked({ cdo: 'ethena' });
    },

    async $after() {
        await $hh.reset(forked.client);
    },

    async 'deploys oracle + middleware and wires them'() {
        const { middleware, oracle } = await newDeployments().ensureDeployment();

        $require.eq((await middleware.oracle()).toLowerCase(), oracle.address.toLowerCase(), 'middleware.oracle');
        $require.eq((await middleware.appAdapter()).toLowerCase(), APP_ADAPTER.toLowerCase(), 'middleware.appAdapter');
    },

    async 'registers the Chainlink feeds from constants'() {
        const { oracle } = await newDeployments().ensureDeployment();
        const F = ChainlinkFeeds.eth;

        // USDe: single-hop (no quote)
        const usde = await oracle.feeds(Addresses.eth.USDe);
        $require.eq(usde.base.toLowerCase(), F['USDe/USD'].address.toLowerCase(), 'USDe base feed');
        $require.eq(usde.quote.toLowerCase(), ZERO, 'USDe has no quote hop');

        // USDC: single-hop
        const usdc = await oracle.feeds(Addresses.eth.USDC);
        $require.eq(usdc.base.toLowerCase(), F['USDC/USD'].address.toLowerCase(), 'USDC base feed');

        // uniBTC: two-hop uniBTC/BTC x BTC/USD
        const uni = await oracle.feeds(Addresses.eth.uniBTC);
        $require.eq(uni.base.toLowerCase(), F['uniBTC/BTC'].address.toLowerCase(), 'uniBTC base feed');
        $require.eq(uni.quote.toLowerCase(), F['BTC/USD'].address.toLowerCase(), 'uniBTC quote feed');

        // The stored feeds are functional: two-hop uniBTC prices in 18-dec USD, BTC-sized.
        const { price, decimals } = await oracle.getPrice(Addresses.eth.uniBTC);
        $require.eq(Number(decimals), 18, 'normalized to 18 decimals');
        $require.gt(price, 10_000n * 10n ** 18n, 'uniBTC USD price is BTC-sized');
    },

    async 'registers the covered markets from SymbioticConfig'() {
        const { middleware } = await newDeployments().ensureDeployment();

        for (const m of SymbioticConfig.eth.markets) {
            const market = await middleware.markets(m.cdo);
            const expectedBase = (Addresses.eth as any)[m.baseAsset] as string;

            $require.eq(market.accounting.toLowerCase(), m.accounting.toLowerCase(), `${m.name} accounting`);
            $require.eq(market.baseAsset.toLowerCase(), expectedBase.toLowerCase(), `${m.name} baseAsset`);
            $require.eq(market.bufferBps, m.bufferBps, `${m.name} bufferBps`);
            $require.eq(market.enabled, m.enabled, `${m.name} enabled`);
        }
    },

    async 'is idempotent: re-running keeps the same addresses'() {
        const first = await newDeployments().ensureDeployment();
        const second = await newDeployments().ensureDeployment();

        $require.eq(second.oracle.address.toLowerCase(), first.oracle.address.toLowerCase(), 'oracle reused');
        $require.eq(second.middleware.address.toLowerCase(), first.middleware.address.toLowerCase(), 'middleware reused');
    },
});
