import { UTest } from 'atma-utest'
import { HardhatProvider } from 'dequanto/hardhat/HardhatProvider';
import { AccessControlManager } from '@0xc/hardhat/AccessControlManager/AccessControlManager';
import { $require } from 'dequanto/utils/$require';
import { $promise } from 'dequanto/utils/$promise';
import { l } from 'dequanto/utils/$logger';
import { $hh } from './utils/$hh';
import { Accounting } from '@0xc/hardhat/Accounting/Accounting';
import { StrataMasterChef } from '@0xc/hardhat/StrataMasterChef/StrataMasterChef';
import { $date } from 'dequanto/utils/$date';
import { $contract } from 'dequanto/utils/$contract';
import { TEth } from 'dequanto/models/TEth';
import { $address } from 'dequanto/utils/$address';



const hh = new HardhatProvider();
const client = await hh.client();
const deployer = await hh.deployer();
await $hh.test.init();

UTest.create({

    async 'should check permission' () {
        let { contract: acm } = await hh.deployClass(AccessControlManager, {
            client,
            arguments: [ deployer.address ]
        });

        const hasPermission = await acm.hasPermission( deployer.address, deployer.address, '0x12345612');
        $require.eq(hasPermission, false);

        const sel = '0x12345612';
        const { error } = await $promise.caught(acm.isAllowedToCall(deployer.address, sel));
        $require.notNull(error, `Should revert`);

        l`Grant`
        await acm.$receipt().grantCall(deployer, deployer.address, sel, deployer.address);

        const isAllowed = await acm.$config({ from: deployer.address }).isAllowedToCall(deployer.address, sel);
        $require.eq(isAllowed, true);

        l`Revoke`
        await acm.$receipt().revokeCall(deployer, deployer.address, sel, deployer.address);

        const { error: errorAfter } = await $promise.caught(acm.isAllowedToCall(deployer.address, sel));
        $require.notNull(errorAfter, `Should revert`);


        await $hh.test.init();
        let { contract: accounting } = await $hh.test.factory.ds.ensureWithProxy(Accounting, {
            arguments: [ 18n ],
            initialize: [
                deployer.address,
                deployer.address,
                deployer.address,
                deployer.address,
            ]
        });

        await accounting.$receipt().setAccessControlManager(deployer, acm.address);

        const seconds = BigInt($date.parseTimespan('24hours', { get: 's' }));
        const { contract: timelock } = await hh.deployClass(StrataMasterChef, {
            client,
            arguments: [
                seconds,
                [ deployer.address ],
                [ $address.ZERO ]
             ]
        });

        $require.eq(await timelock.getMinDelay(), seconds);
    },
    async 'should check call permission' () {
        let acm = await $hh.test.factory.ensureACM();
        let { contract } = await hh.deploySol('test/fixtures/acm/CallAccess.sol', {
            client,
            arguments: [
                acm.address
            ]
        });

        let { error } = await $promise.caught(contract.$receipt().setValue(deployer, 5n));
        $require.notNull(error, `Should revert`);
        $require.eq(await contract.value(), 0n);

        const sig = $contract.keccak256('setValue(uint256)', 'hex').substring(0, 10) as TEth.Hex;
        await acm.$receipt().grantCall(deployer, contract.address, sig, deployer.address);

        await contract.$receipt().setValue(deployer, 8n);
        $require.eq(await contract.value(), 8n);
    }
})
