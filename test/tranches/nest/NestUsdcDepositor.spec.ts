import { UTest } from 'atma-utest';
import { $hh } from '../utils/$hh';
import { Addresses } from '@s/constants';
import { ERC20 } from 'dequanto/prebuilt/openzeppelin/ERC20';
import { NestUsdcParamsResolver } from '@s/strategies/nestopal/NestUsdcParamsResolver';
import { NestOpalDepositAdapter } from '@0xc/hardhat/NestOpalDepositAdapter/NestOpalDepositAdapter';
import { $erc20 } from '../utils/$erc20';
import { Tranche } from '@0xc/hardhat/Tranche/Tranche';
import { Eth } from '@s/platforms/Eth';
import { NestOpalStrategy } from '@0xc/hardhat/NestOpalStrategy/NestOpalStrategy';
import { $require } from 'dequanto/utils/$require';

const test = await $hh.create('nestopal', {
    forked: 'latest',
    fresh: true,
});

UTest.create({
    $config: {
        timeout: 2 * 60 * 1000
    },
    async $before() {
        await test.init();
        await test.deploy({ initialDeposit: false });
        await test.snapshot();
    },
    async $after() {
        await test.wipe();
    },
    async 'integrational test: deposit usdc'() {
        const nOPAL = new ERC20(Eth.nestopal.nOPAL, test.client);
        const usdc = new ERC20(Addresses.eth.USDC, test.client);
        const depositor = await test.factory.ensureDepositor();
        const adapter = await test.factory.get(NestOpalDepositAdapter);
        const strategy = await test.factory.get(NestOpalStrategy);
        const jrtVault = await test.factory.get(Tranche, { id: 'Jrt' });

        const nestApi = new NestUsdcParamsResolver();
        const amount = BigInt(5e6);


        const { bytes } = await nestApi.getPredicateMessage(adapter.address, amount);
        const deployer = test.deployer;
        await $erc20.setBalanceAny(usdc, deployer.address, amount);

        await usdc.$receipt().approve(deployer.address, depositor.address, amount);
        await depositor.$receipt().deposit(
            deployer,
            jrtVault.address,
            usdc.address,
            amount,
            deployer.address,
            {
                minShares: 0n,
                swapAmountOutMinimum: 0n,
                swapDeadline: 0n,
                swapTokenOut: nOPAL.address,
                data: bytes
            }
        );

        const nOPALExpect = await strategy.convertToTokens(nOPAL.address, amount, 0);
        const strategyNOpalBalance = await nOPAL.balanceOf(strategy.address);
        $require.eq(strategyNOpalBalance, nOPALExpect, `Invalid Strategy's nOPAL Balance`);

        const jrtBalance = await jrtVault.balanceOf(deployer.address);
        $require.eq(jrtBalance, BigInt(4.999999e18), `Invalid User's Junior Balance (1wei-rounding)`);

    }
})
