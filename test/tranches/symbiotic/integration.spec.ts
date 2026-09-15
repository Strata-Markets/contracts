import { UTest } from 'atma-utest';
import { $hh } from '../utils/$hh';
import { $erc4626 } from '../utils/$erc4626';
import { $erc20 } from '../utils/$erc20';
import { SymbioticDeployments } from '@s/deployments/SymbioticDeployments';
import { Eth } from '@s/platforms/Eth';
import { ERC20 } from 'dequanto/prebuilt/openzeppelin/ERC20';
import { SymbioticUniversalDelegatorImpl } from '@0xc/eth/SymbioticUniversalDelegatorImpl/SymbioticUniversalDelegatorImpl';
import { $hex } from 'dequanto/utils/$hex';
import { SymbioticAdapterRegistry } from '@0xc/eth/SymbioticAdapterRegistry/SymbioticAdapterRegistry';
import { StrataCDO } from '@0xc/hardhat/StrataCDO/StrataCDO';
import { Accounting } from '@0xc/hardhat/Accounting/Accounting';
import { Tranche } from '@0xc/hardhat/Tranche/Tranche';
import { Strategy } from '@0xc/hardhat/Strategy/Strategy';
import { $bigint } from 'dequanto/utils/$bigint';
import { AccessControlManager } from '@0xc/hardhat/AccessControlManager/AccessControlManager';
import { SymbioticNetworkRegistry } from '@0xc/eth/SymbioticNetworkRegistry/SymbioticNetworkRegistry';
import { SymbioticMiddlewareService } from '@0xc/eth/SymbioticMiddlewareService/SymbioticMiddlewareService';
import { $test } from '../utils/$test';

const test = await $hh.deploy('ethena', {
    forked: 26030000
});
const {
    factory,
    client,
} = test;

const deployer = factory.accounts.deployer;
const symbioticNetwork = deployer;


const [
    cdo,
    acm,
    accounting,
    strategy,
    srtVault,
    jrtVault,
] = await Promise.all([
    factory.get(StrataCDO),
    factory.get(AccessControlManager),
    factory.get(Accounting),
    factory.get(Strategy, { id: 'SUSDeStrategy' }),
    factory.get(Tranche, { id: 'Srt' }),
    factory.get(Tranche, { id: 'Jrt' }),
]);

const baseAsset = Eth.Tokens.USDe;
const share = Eth.Tokens.sUSDe;

const uniBTC = Eth.Tokens.uniBTC;

const symbiotic = new SymbioticDeployments({
    client,
    deployer,
    owner: factory.accounts.timelock.admin,
    acm: acm.address,
    insuranceVaults: true,
    markets: [
        {
            cdo: cdo.address,
            accounting: accounting.address,
            baseAsset: baseAsset.address,
            coverageToken: uniBTC.address,
            bufferBps: 500n,
            enabled: true,
        }
    ]
});
const uniBTCErc20 = new ERC20(uniBTC.address, client);

UTest.create({
    async $before() {
        const owner = factory.accounts.timelock.admin;
        const insuranceUniBtcAmount = BigInt(1000e8);

        // 1. Register network
        const networkRegistry = new SymbioticNetworkRegistry(void 0, client);
        await networkRegistry.$receipt().registerNetwork(symbioticNetwork);

        // 2. Deploy vault
        const symbioticVault = await symbiotic.ensureVault({
            owner: deployer.address,
            asset: { address: uniBTC.address },
        });

        // 3. Deploy AppAdapter
        const symbioticAppAdapter = await symbiotic.ensureAppAdapter({
            owner: deployer.address,
            vault: symbioticVault.address,
            params: {
                burner: deployer.address,
                operator: deployer.address,
                converters: [],
                duration: 10,
                subnetwork: $hex.padBytes(symbioticNetwork.address, 32, { padEnd: true })
            }
        });

        // 4. Whitelist Vault + AppAdapter
        const registry = new SymbioticAdapterRegistry(void 0, client);
        await registry.$receipt().setWhitelistedStatus({
            address: await registry.owner(),
            type: 'impersonated'
        }, symbioticVault.address, symbioticAppAdapter.address, true);

        // 5. Configure Limits
        const symbioticDelegator = new SymbioticUniversalDelegatorImpl(await symbioticVault.delegator(), client);
        await symbioticDelegator.$receipt().addAdapter(owner, symbioticAppAdapter.address);
        await symbioticDelegator.$receipt().setLimits(owner, symbioticAppAdapter.address, insuranceUniBtcAmount, BigInt(1e18));

        // 6. Allocate
        await $erc20.setBalanceAny(uniBTCErc20, deployer.address, insuranceUniBtcAmount);
        await $erc4626.deposit(symbioticVault, deployer, insuranceUniBtcAmount);
        await symbioticDelegator.$receipt().allocate(owner, symbioticAppAdapter.address, insuranceUniBtcAmount);

        // 7. Deploy Strata CDO peripheral
        const { vaults, middleware } = await symbiotic.ensureDeployment({
            appAdapter: symbioticAppAdapter.address
        });

        // 8. Register Strata Tranche InsuranceMiddleware as NetworkMiddleware
        const middlewareService = new SymbioticMiddlewareService(void 0, client);
        await middlewareService.$receipt().setMiddleware(symbioticNetwork, middleware.address);


        await test.snapshot('symbiotic-nav-loss');
    },
    async $teardown() {
        await test.reset('symbiotic-nav-loss');
    },
    async $after() {
        await test.wipe();
    },
    async '2xJunior loss should be covered by Symbiotic'() {
        const { jrtNavT1, srtNavT1, reserveNavT1 } = await accounting.totalAssets();
        const shareErc20 = new ERC20(share.address, client);
        const lossAssets = jrtNavT1 * 2n;
        const lossShares = await strategy.convertToTokens(share.address, lossAssets, 0);
        const balance = await shareErc20.balanceOf(strategy.address);
        await $erc20.setBalanceAny(shareErc20, strategy.address, balance - lossShares);

        const updater = factory.accounts.safe.operator;
        await accounting.$receipt().onAprChanged(updater);

        $test.compare(
            $bigint.toEther(await accounting.insuranceAmount()),
            $bigint.toEther(jrtNavT1 - reserveNavT1),
            18,
            `Total loss 2xJunior: requested coverage 1xJunior - Reserve`
        );

        $test.compare(
            await srtVault.totalAssets(),
            srtNavT1,
            18,
            `Seniors have no loss`
        );

        await client.debug.mine('7days');
        $test.compare(
            await srtVault.totalAssets(),
            srtNavT1,
            18,
            `Seniors have no PnL (Benchmark > 0)`
        );
    },
});

