import { MROXTestHelper } from '@s/strategies/midas/MROXTestHelper';
import type { ICDO } from '../Tranches';

export const MROXTranche = <ICDO> {
    base: 'USDC',
    fees: {
        retention: {
            jrt: 0.5, // 1 == 100%
            srt: 0.5,
        },
        performanceFee: 0.075, // 1 === 100%
    },
    riskPremium: {
        x: 0.125,
        y: 0.15,
        k: 0.3,
    },
    jrt: {
        symbol: 'jrmROX',
        name: 'Strata Junior mROX',
        depositsEnabled: true,
        withdrawalsEnabled: true,
        sharesCooldown: [
            { covPct: 10, feeBps: 0, lock: '21days' },
            { covPct: 20, feeBps: 10, lock: '7days' },
            { covPct: 0, feeBps: 20, lock: 0 },
        ],
    },
    srt: {
        symbol: 'srmROX',
        name: 'Strata Senior mROX',
        depositsEnabled: true,
        withdrawalsEnabled: true,
        sharesCooldown: [
            { covPct: 10, feeBps: 0, lock: 0 },
            { covPct: 20, feeBps: 2.5, lock: 0 },
            { covPct: 0, feeBps: 5, lock: 0 },
        ],
    },
    Feed: {
        name: 'mROX CDO APR Pair',
    },
    ContractVersions: {
        accounting: 'discrete',
    },
    TestHelper: MROXTestHelper,
};
