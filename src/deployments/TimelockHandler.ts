import { l } from 'dequanto/utils/$logger';
import { TAddress } from 'dequanto/models/TAddress';
import { TEth } from 'dequanto/models/TEth';
import { ETimelockTxStatus } from 'dequanto/services/TimelockService/ITimelockService';
import { TimelockService } from 'dequanto/services/TimelockService/TimelockService';
import { $address } from 'dequanto/utils/$address';
import { StrataMasterChef } from '@0xc/hardhat/StrataMasterChef/StrataMasterChef';
import { ChainAccountService } from 'dequanto/ChainAccountService';
import { DeploymentsBase } from './DeploymentsBase';



export class TimelockHandler {

    constructor (public ds: DeploymentsBase, public owner: TEth.IAccount) {
    }

    async get () {
        let timelockAcc = await ChainAccountService.get(`timelock/${this.ds.client.network}/strata`);
        return new StrataMasterChef(timelockAcc.address, this.ds.client);
    }

    async isOwner (contract: { owner: () => Promise<TAddress> }) {
        let timelock = await this.get();
        if ($address.isEmpty(timelock?.address)) {
            // No timelock for chain
            return false;
        }
        let owner = await contract.owner();
        return $address.eq(owner, timelock.address);
    }

    async isProposer (address: TAddress) {
        let timelock = await this.get();
        return await timelock.hasRole(await timelock.PROPOSER_ROLE(), address);
    }

    async process (pendingKey: string, actions: TEth.DataLike<TEth.Tx>[], options?: { simulate?: boolean, execute?: boolean }) {
        let timelock = await this.get();
        let service = new TimelockService(timelock, options);
        let { status, schedule } = await service.getPendingByTitle(pendingKey);
        if (schedule == null) {
            schedule = await service.scheduleCallBatch(pendingKey, this.owner, actions);
            l`✅ Scheduled green<'${ pendingKey }'> ${schedule.txSchedule}`;
            return { status: ETimelockTxStatus.Pending };
        }
        if (status === ETimelockTxStatus.Pending) {
            l`⏳ Schedule green<'${ pendingKey }'> is still pending`;
            return { status };
        }

        let result = await service.executePendingByTitle(this.owner, pendingKey);
        l`✅✅ Executed ${result.schedule.txExecute}`;
        return { status: ETimelockTxStatus.Executed };
    }

    async execute (sender, txParams) {
        let timelock = await this.get();

        await timelock.$receipt().executeBatch(
            sender,
            [txParams.to as TAddress],
            [txParams.value as bigint],
            [txParams.data as TEth.Hex],
            txParams.predecessor,
            txParams.salt
        )
    }

    async processOrExitWait (pendingKey: string, actions: TEth.DataLike<TEth.Tx>[], options?: { simulate?: boolean, execute?: boolean }) {
        let { status } = await this.process(pendingKey, actions, options);
        if (status === ETimelockTxStatus.Pending) {
            throw new Error(`Okay. Wait for ${pendingKey} to complete`);
        }
    }
}
