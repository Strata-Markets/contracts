import { MM1UsdTestHelper } from '@s/strategies/midas/MM1UsdTestHelper';
import type { ICDO } from '../Tranches';

export const MM1UsdTranche = <ICDO> {
    base: 'USDC',
    fees: {
        retention: {
            jrt: 0.5, // 1 == 100%
            srt: 0.5,
        },
        performanceFee: 0, // 1 === 100%
    },
    riskPremium: {
        x: 0.125,
        y: 0.15,
        k: 0.3,
    },
    jrt: {
        symbol: 'jrmM1-USD',
        name: 'Strata Junior mM1-USD',
        depositsEnabled: true,
        withdrawalsEnabled: true,
        sharesCooldown: [
            { covPct: 10, feeBps: 0, lock: '28days' },
            { covPct: 20, feeBps: 0, lock: '14days' },
            { covPct: 0, feeBps: 0, lock: 0 },
        ],
    },
    srt: {
        symbol: 'srmM1-USD',
        name: 'Strata Senior mM1-USD',
        depositsEnabled: true,
        withdrawalsEnabled: true,
        sharesCooldown: [
            { covPct: 10, feeBps: 0, lock: 0 },
            { covPct: 20, feeBps: 0, lock: 0 },
            { covPct: 0, feeBps: 0, lock: 0 },
        ],
    },
    Feed: {
        name: 'mM1-USD CDO APR Pair',
    },
    ContractVersions: {
        accounting: 'discrete',
    },
    TestHelper: MM1UsdTestHelper,
};
