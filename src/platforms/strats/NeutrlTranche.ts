import { NeutrlTestHelper } from '@s/strategies/neutrl/NeutrlTestHelper';
import type { ICDO } from '../Tranches';

export const NeutrlTranche = <ICDO> {
    base: 'NUSD',
    fees: {
        retention: {
            jrt: 0.5, // 1 == 100%
            srt: 0.5,
        },
        performanceFee: 0.072, // 1 === 100%
    },
    minimumJrtSrtRatioBuffer: 0.055,
    minimumJrtSrtRatio: 0.05,
    riskPremium: {
        x: 0.15,
        y: 0.15,
        k: 0.3,
    },
    jrt: {
        symbol: 'jrNUSD',
        name: 'Strata Junior NUSD',
        depositsEnabled: true,
        withdrawalsEnabled: true,

        sharesCooldown: [
            { covPct: 10, feeBps: 0, lock: '35days' },
            { covPct: 20, feeBps: 10, lock: '10days' },
            { covPct: 0, feeBps: 20, lock: 0 },
        ],
    },
    srt: {
        symbol: 'srNUSD',
        name: 'Strata Senior NUSD',
        depositsEnabled: true,
        withdrawalsEnabled: true,

        sharesCooldown: [
            { covPct: 10, feeBps: 0, lock: 0 },
            { covPct: 20, feeBps: 2.5, lock: 0 },
            { covPct: 0, feeBps: 5, lock: 0 },
        ],
    },
    accounts: {},
    Feed: {
        name: 'Neutrl CDO APR Pair',
    },
    Contracts: {
        '*': {
            AccessControlManager: 'NeutrlAccessControlManager',
            ERC20Cooldown: 'NeutrlERC20Cooldown',
            UnstakeCooldown: 'NeutrlUnstakeCooldown',
            SharesCooldown: 'NeutrlSharesCooldown',
        },
    },
    ContractVersions: {
        accounting: 'continuous',
        depositor: 'V3',
        valuationKeeper: 'Accountable',
        valuationKeeperOptions: {
            gracePeriod: '24h'
        },
    },
    TestHelper: NeutrlTestHelper,
};
