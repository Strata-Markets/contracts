import { UAction } from 'atma-utest';
import { PlatformFactory } from './PlatformFactory';
import { $bigint } from 'dequanto/utils/$bigint';
import { l } from 'dequanto/utils/$logger';
import { Accounting } from '@0xc/hardhat/Accounting/Accounting';
import { StrataCDO } from '@0xc/hardhat/StrataCDO/StrataCDO';
import { Tranche } from '@0xc/hardhat/Tranche/Tranche';
import { CDOLens } from '@0xc/hardhat/CDOLens/CDOLens';
import { BatchAgent } from 'dequanto/txs/agents/BatchAgent';
import { Addresses } from '@s/constants';
import { $address } from 'dequanto/utils/$address';
import { TEth } from 'dequanto/models/TEth';

UAction.create({

    async 'ensure-get-price'() {
        const factories = await PlatformFactory.getTranches();
        const batch = new BatchAgent().enable();
        const ignore = ['neutrl'];
        const oracles = {
            [Addresses.eth.USDe]: '0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961',
            [Addresses.eth.USDC]: '0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6',
        };
        const [ factory ] = factories;
        const tranches = factory.tranches;
        const lens = await tranches.common.get(CDOLens);
        const owner = await factory.tranches.getAccountOwner(lens.address);

        for (let asset in oracles) {
            const oracle = oracles[asset];

            await tranches.ds.configure(lens, {
                title: `Price Feed for ${asset}`,
                shouldUpdate: async () => false === $address.eq(oracle, await lens.priceFeeds(asset as TEth.Address)),
                updater: async () => {
                    await lens.$receipt().setPriceFeed(owner, asset as TEth.Address, oracle as TEth.Address)
                }
            });
        }

        for (const factory of factories) {
            const { tranches, deployer, client } = factory;
            const { cdo } = tranches.params;
            if (ignore.includes(cdo)) {
                continue;
            }
            l`green<${cdo}>`

            await tranches.configureLenses?.();

            const lens = await tranches.common.get(CDOLens);

            l`Lens: cyan<${lens.address}>`;
            const jrt = await tranches.get(Tranche, { id: 'Jrt' });
            const srt = await tranches.get(Tranche, { id: 'Srt' });

            const [jrtPrice, srtPrice] = await Promise.all([
                lens.getPrice(jrt.address),
                lens.getPrice(srt.address),
            ]);
            l`Junior: bold<${ $bigint.toEther(jrtPrice)}$>`;
            l`Senior: bold<${ $bigint.toEther(srtPrice)}$>`;
        }
        await batch.execute();
    },

    async 'view-risk-premium'() {
        const factories = await PlatformFactory.getTranches();
        for (const factory of factories) {
            const { tranches, deployer, client } = factory;
            l`green<${tranches.params.cdo}>`

            const cdo = await tranches.get(StrataCDO);
            const accounting = await tranches.get(Accounting);
            const lens = await tranches.get(CDOLens);

            const info = await lens.getAPRsBreakdown(cdo.address);
            const srtFact = await accounting.aprSrt();

            l`Base        : ${$bigint.toEther(info.base, 10, 100n)}%`;
            l`SRT         : ${$bigint.toEther(info.srt, 10, 100n)}%`;
            l`SRTr        : ${$bigint.toEther(srtFact, 18 - 2, 100n)}%`;
            l`JRT         : ${$bigint.toEther(info.jrt, 10, 100n)}%`;
            l`SrtRatio    : ${$bigint.toEther(info.tvlRatioSrt, 18, 1000000n)}`;
            l`Risk Premium: ${$bigint.toEther(info.riskPremium, 18, 1000000n)}`;
        }
    },
});
