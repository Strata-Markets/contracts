import { MidasTestHelper } from '@s/strategies/midas/MidasTestHelper';
import type { ICDO } from '../Tranches';

export const MHyperTranche = <ICDO> {
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
        symbol: 'jrmHYPER',
        name: 'Strata Junior mHYPER',
        depositsEnabled: true,
        withdrawalsEnabled: true,
        sharesCooldown: [
            { covPct: 10, feeBps: 0, lock: '21days' },
            { covPct: 20, feeBps: 10, lock: '7days' },
            { covPct: 0, feeBps: 20, lock: 0 },
        ],
    },
    srt: {
        symbol: 'srmHYPER',
        name: 'Strata Senior mHYPER',
        depositsEnabled: true,
        withdrawalsEnabled: true,
        sharesCooldown: [
            { covPct: 10, feeBps: 0, lock: 0 },
            { covPct: 20, feeBps: 2.5, lock: 0 },
            { covPct: 0, feeBps: 5, lock: 0 },
        ],
    },
    Feed: {
        name: 'mHyper CDO APR Pair',
    },
    ContractVersions: {
        accounting: 'discrete',
    },
    TestHelper: MidasTestHelper,
};
