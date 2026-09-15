import { UTest } from 'atma-utest';
import { HardhatProvider } from 'dequanto/hardhat/HardhatProvider';
import { $hh } from '../utils/$hh';
import { $erc4626 } from '../utils/$erc4626';
import { $require } from 'dequanto/utils/$require';
import { $date } from 'dequanto/utils/$date';
import { $test } from '../utils/$test';
import { InsuranceVault } from '@0xc/hardhat/InsuranceVault/InsuranceVault';
import { $promise } from 'dequanto/utils/$promise';
import { $erc20 } from '../utils/$erc20';

const test = await $hh.deploy('mhyper', {
    cdoInfo: {
        fees: {
            performanceFee: 0,
        },
        minimumJrtSrtRatio: 0,
        minimumJrtSrtRatioBuffer: 0.000000000001,
        riskPremium: {
            x: 0.5,
            y: 0,
            k: 1
        },
        ContractVersions: {
            accounting: 'dys',
            unstakeImpl: 'MockInstant'
        }
    },
});

const { deployer, client } = test;
const { accounting, feed, jrtVault, srtVault, cdo, acm, USDC } = test.tranches;
const { oracle } = await test.factory.ensureUnderlying();
let vault: InsuranceVault;

const hh = new HardhatProvider();
const { contract: pool } = await hh.deploySol('test/symbiotic/mocks/MockInsurancePool.sol', {
    client,
});

UTest.create({
    async $before () {
        await feed.$receipt().setRoundStaleAfter(deployer, BigInt($date.parseTimespan('5years', { get: 's' })));
        await feed.$receipt().updateRoundData(
            deployer,
            0,
            0,
            (await client.getBlock('latest')).timestamp
        );
        await oracle.$receipt().setRoundData(deployer, 1n, BigInt(1e8), 0n);
        const { contract: vault } = await test.factory.ds.ensureWithProxy(InsuranceVault, {
            initialize: [
                deployer.address,
                acm.address,
                cdo.address,
                USDC.address,
            ]
        });
        await cdo.$receipt().setInsuranceConfig(deployer, pool.address, vault.address);
        await pool.$receipt().setCapacity(deployer, BigInt(1_000_000e6));
        await test.snapshot('symbiotic-nav-loss');
    },
    async $teardown () {
        await test.reset('symbiotic-nav-loss');
    },
    async $after () {
        await test.wipe();
    },
    async 'books Symbiotic coverage on the Senior deposit after an oracle NAV loss' () {
        await $erc4626.deposit(jrtVault, deployer, 10);
        await $erc4626.deposit(srtVault, deployer, 100);

        $require.eq(await accounting.insuranceAmount(), 0n, 'No claim before the NAV loss');

        await oracle.$receipt().setRoundData(deployer, 2n, BigInt(0.5e8), 0n);

        $require.eq(await accounting.insuranceAmount(), 0n);
        await $erc4626.deposit(srtVault, deployer, 10);
        // Before: NAV 110; Senior: 100
        // After: NAV 55; Senior require 45; Junior buffer: 1
        // Symbiotic request: 100 + 1 - 55 = 46;
        $test.compare(
            await accounting.insuranceAmount(),
            46,
            6
        );
        $test.compare(
            await accounting.nav(),
            55 + 10,
            6
        );
        $test.compare(
            await accounting.jrtBaseNav(),
            1,
            6
        );
        $test.compare(
            await accounting.srtBaseNav(),
            110,
            6
        );
        const { error } = await $promise.caught($erc4626.withdraw(srtVault, deployer, 100));
        $require.match(/InsufficientCoverage/, error?.message);


        const insurance = await accounting.insuranceAmount();
        await $erc20.setBalanceAny(USDC as any, deployer, insurance);
        await USDC.$receipt().approve(deployer, cdo.address, insurance);
        await cdo.fundInsuranceClaim(deployer, USDC.address, insurance);

        const claimed = await $erc4626.withdraw(srtVault, deployer, 100);
        $require.eq(claimed, BigInt(100e6));


        // srt covered Nav = 46
        // srt local NAV   = 64
        // srt total NAV   = 110
        // reedem 100 is splited:
        // from covered NAV = 46 * 100 / 110 = 41.81
        $test.compare(
            await accounting.insuranceAmount(),
            46 - (46 * 100 / 110),
            6,
            `from Covered Nav`
        );
        $test.compare(
            await accounting.srtBaseNav(),
            10,
            6,
            `TotalRemaining SrtNav (local + covered)`
        );
    },
});

