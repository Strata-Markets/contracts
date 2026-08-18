import { NestOpalTestHelper } from '@s/strategies/nestopal/NestOpalTestHelper';
import type { ICDO } from '../Tranches';

export const NestOpalTranche = <ICDO> {
    base: 'USDC',
    fees: {
        retention: {
            jrt: 0.5, // 1 == 100%
            srt: 0.5,
        },
        performanceFee: 0.05, // 1 === 100%
    },
    minimumJrtSrtRatioBuffer: 0.08,
    minimumJrtSrtRatio: 0.075,
    riskPremium: {
        x: 0.125,
        y: 0.125,
        k: 0.3,
    },
    jrt: {
        symbol: 'jrnOPAL',
        name: 'Strata Junior nOPAL',
        depositsEnabled: true,
        withdrawalsEnabled: true,
        sharesCooldown: [
            { covPct: 15, feeBps: 0, lock: '28days' },
            { covPct: 30, feeBps: 7.5, lock: '14days' },
            { covPct: 0, feeBps: 15, lock: 0 },
        ],
    },
    srt: {
        symbol: 'srnOPAL',
        name: 'Strata Senior nOPAL',
        depositsEnabled: true,
        withdrawalsEnabled: true,
        sharesCooldown: [
            { covPct: 15, feeBps: 0, lock: 0 },
            { covPct: 30, feeBps: 2.5, lock: 0 },
            { covPct: 0, feeBps: 5, lock: 0 },
        ],
    },
    Feed: {
        name: 'nOPAL CDO APR Pair',
    },
    ContractVersions: {
        accounting: 'dys',
        depositor: 'V4',
        accountingOptions: {
            useNavAtReconciliation: true,
        }
    },
    TestHelper: NestOpalTestHelper
};
