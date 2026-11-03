import { $bigint } from 'dequanto/utils/$bigint';
import { $date } from 'dequanto/utils/$date';
import { $number } from 'dequanto/utils/$number';
import { HardhatProvider } from 'dequanto/hardhat/HardhatProvider';
import { Web3Client } from 'dequanto/clients/Web3Client';
import { TEth } from 'dequanto/models/TEth';
import { RiskPremiumPower } from '@0xc/hardhat/RiskPremiumPower/RiskPremiumPower';
import { DiscreteAccounting } from '@0xc/hardhat/DiscreteAccounting/DiscreteAccounting';
import { DYSAccounting } from '@0xc/hardhat/DYSAccounting/DYSAccounting';
import { MTMAccounting } from '@0xc/hardhat/MTMAccounting/MTMAccounting';

export namespace $accounting {

    export async function deployRiskPremiumPower (client: Web3Client, x: number, y: number, k: number) {
        const { contract } = await new HardhatProvider().deployClass(RiskPremiumPower, {
            client,
            arguments: [ $bigint.toWei(x), $bigint.toWei(y), $bigint.toWei(k) ],
        });
        return contract;
    }

    // MTM/DYS have no built-in x + y * tvlRatio^k premium; they read it from a RiskPremiumPower model.
    export async function setRiskPremium (
        accounting: DiscreteAccounting,
        sender: TEth.IAccount,
        accountingType: string,
        x: number,
        y: number,
        k: number
    ) {
        if (accountingType === 'mtm' || accountingType === 'dys') {
            const model = await deployRiskPremiumPower(accounting.client, x, y, k);
            await accounting.$receipt().setRiskModel(sender, model.address);
            return;
        }
        await accounting.$receipt().setRiskParameters(sender, $bigint.toWei(x), $bigint.toWei(y), $bigint.toWei(k));
    }

    // Writes a RiskPremiumPower model straight into MTM/DYS storage, for fixtures without the config role.
    export async function setRiskModelStorage (accounting: MTMAccounting | DYSAccounting, x: number, y: number, k: number = 0.3) {
        const model = await deployRiskPremiumPower(accounting.client, x, y, k);
        await accounting.storage.$set('riskPremiumModel', model.address);
    }

    export function calculateGain (lastNav, targetIndexCurrent, targetIndex) {
        // Gain = Assets * (TargetIndex1 / TargetIndex0 - 1);
        if (targetIndexCurrent <= targetIndex) {
            // If zero or negative targetIndex, no gain
            return 0;
        }
        return lastNav * targetIndexCurrent / targetIndex - lastNav;
    }


    export function calculateApr (b1: number | bigint, b2: number | bigint, secondsMix: string | number = '1year') {
        let b1_ = typeof b1 === 'bigint'? $bigint.toEther(b1, 18) : b1;
        let b2_ = typeof b2 === 'bigint'? $bigint.toEther(b2, 18) : b2;

        let gain = b2_ - b1_;
        let seconds = typeof secondsMix === 'string'
            ? $date.parseTimespan(secondsMix, { get: 's' })
            : secondsMix;
        let YEAR = 31536000;

        console.log(`CalulateAPR`, gain, 'for s', seconds, secondsMix);

        let return_ = gain / b1_ * YEAR / seconds * 100;
        return $number.round(return_, 2);
    }


    export function maxDepositSenior (jrtNav: number, srtNav: number, ratio: number) {
        const maxSrt = jrtNav / ratio;
        const maxDeposit = maxSrt - srtNav;
        return maxDeposit;
    }
}
