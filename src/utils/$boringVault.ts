import { MockNestAccountant } from '@0xc/hardhat/MockNestAccountant/MockNestAccountant';
import { Web3ClientFactory } from 'dequanto/clients/Web3ClientFactory';
import { TEth } from 'dequanto/models/TEth';
import { $date } from 'dequanto/utils/$date';
import { $require } from 'dequanto/utils/$require';
import { $apr } from './$apr';

const SECONDS_PER_YEAR = BigInt(365 * 24 * 60 * 60);
const ONE_APR = BigInt(1e12); // 1e12 (SD7x12: 1e12 = 100%)



export namespace $boringVault {
    // Fetches the last two ExchangeRateUpdated events from the given Boring Vault accountant
    // and returns the annualised APR in SD7x12 format (1e12 = 100%), matching the on-chain
    // BoringVaultAprProvider formula.
    export async function getApr(accountantAddress: TEth.Address): Promise<bigint> {

        const logs = await fetchExchangeRateUpdates(accountantAddress, {
            fromBlock: $date.additive(new Date(), '-3days')
        })

        if (logs.length < 2) {
            throw new Error(`[getBoringVaultApr] Found ${logs.length} ExchangeRateUpdated event(s) in last 3days; need at least 2`);
        }

        const { params: prev } = logs[logs.length - 2];
        const { params: last } = logs[logs.length - 1];


        const timeDelta = BigInt(last.currentTime - prev.currentTime);
        if (timeDelta === 0n) {
            throw new Error('[getBoringVaultApr] timeDelta is 0 between last two events');
        }

        return (last.newRate - prev.newRate) * SECONDS_PER_YEAR * ONE_APR / prev.newRate / timeDelta;
    }

    export function fetchLatestRounds (accountantAddress: TEth.Address, count: number, options?: {
        toBlock?: number
    }) {
        let toBlock = options?.toBlock;
        let fromBlock = toBlock
            ? toBlock - Math.ceil(7 * 24 * 60 * 60 / 12)
            : $date.additive(new Date(), '-7days');

        return fetchLatestRoundsInner(
            accountantAddress,
            count,
            fromBlock,
            toBlock,
        );
    }

    async function fetchLatestRoundsInner (
        accountantAddress: TEth.Address,
        count: number,
        fromBlock?: number | Date,
        toBlock?: number | Date
    ) {
        const MIN_MEANINGFUL_APR = 0.005;
        const logs = await fetchExchangeRateUpdates(accountantAddress, {
            fromBlock: fromBlock,
            toBlock: toBlock,
        });

        $require.gte(logs.length, count, 'NoEnoughLogs');
        for (let i = 1; i < logs.length; i++) {
            let log0 = logs[i - 1];
            let log1 = logs[i];
            let apr = $apr.calcAprFromExchangeRates(
                log0.params.newRate,
                log1.params.newRate,
                log0.params.currentTime,
                log1.params.currentTime
            );
            $require.lte(log0.params.currentTime, log1.params.currentTime, 'TimeArrow');
            if (Math.abs(apr) < MIN_MEANINGFUL_APR) {
                logs.splice(i, 1);
                i--;
            }
        }

        $require.gte(logs.length, count, 'NoEnoughMeaningfulLogs');
        const arr = logs.slice(-count).map(log => {
            return {
                answer: log.params.newRate,
                updatedAt: log.params.currentTime
            };
        });
        return arr;
    }

    export async function fetchExchangeRateUpdates (accountantAddress: TEth.Address, params: {
        fromBlock: number | Date
        toBlock?: number | Date
    }) {
        const client = await Web3ClientFactory.getAsync('eth');
        const accounting = new MockNestAccountant(accountantAddress, client);
        return accounting.getPastLogsExchangeRateUpdated({
            fromBlock: params.fromBlock,
            toBlock: params.toBlock,
        });
    }
}
