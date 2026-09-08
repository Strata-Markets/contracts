import type { ICDO } from '../Tranches';

export const SpkMhyperIsoTranche = <ICDO> {
    base: 'USDC',
    fees: {
        retention: {
            jrt: 0.5,
            srt: 0.5,
        },
        performanceFee: 0.075,
    },
    riskPremium: {
        x: 0.125,
        y: 0.15,
        k: 0.3,
    },
    jrt: {
        symbol: 'jrIsoSpk',
        name: 'Strata Junior Iso Spark USDC',
        depositsEnabled: true,
        withdrawalsEnabled: true,
        sharesCooldown: [
            { covPct: 10, feeBps: 0, lock: '7days' },
            { covPct: 20, feeBps: 10, lock: '3days' },
            { covPct: 0, feeBps: 20, lock: 0 },
        ],
    },
    srt: {
        symbol: 'srIsoMHYPER',
        name: 'Strata Senior Iso mHYPER',
        depositsEnabled: true,
        withdrawalsEnabled: true,
        sharesCooldown: [
            { covPct: 10, feeBps: 0, lock: 0 },
            { covPct: 20, feeBps: 2.5, lock: 0 },
            { covPct: 0, feeBps: 5, lock: 0 },
        ],
    },
    Feed: {
        name: 'Isolated CDO APR Pair',
    },
    ContractVersions: {
        accounting: 'isolated',
    },
};
