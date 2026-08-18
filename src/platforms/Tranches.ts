import { ITestHelperConstructor } from '@s/strategies/interfaces/ITestHelper';
import { MidasTestHelper } from '@s/strategies/midas/MidasTestHelper';
import { MM1UsdTestHelper } from '@s/strategies/midas/MM1UsdTestHelper';
import { MROXTestHelper } from '@s/strategies/midas/MROXTestHelper';
import { NeutrlTestHelper } from '@s/strategies/neutrl/NeutrlTestHelper';
import { TEth } from 'dequanto/models/TEth';
import { MKRAlphaTranche } from './strats/MKRAlphaTranche';
import { SaturnTranche } from './strats/SaturnTranche';
import { FigureTranche } from './strats/FigureTranche';
import { NestOpalTranche } from './strats/NestOpalTranche';

export type TCDOKey = 'ethena' | 'neutrl' | 'mhyper' | 'mkralpha' | 'mm1usd' | 'mrox' | 'saturn' | 'figure' | 'spkMhyperIso' | 'nestopal';
export interface ICDO {
    // token symbol
    base: string;
    jrt: {
        symbol: string;
        name: string;
        depositsEnabled: boolean;
        withdrawalsEnabled: boolean;

        sharesCooldown?: [
            { covPct: number; feeBps: number; lock: string | number },
            { covPct: number; feeBps: number; lock: string | number },
            { covPct: number; feeBps: number; lock: string | number }
        ];

        // additional configuration
        [key: string]: any;
    };
    srt: {
        symbol: string;
        name: string;
        depositsEnabled: boolean;
        withdrawalsEnabled: boolean;

        sharesCooldown?: [
            { covPct: number; feeBps: number; lock: string | number },
            { covPct: number; feeBps: number; lock: string | number },
            { covPct: number; feeBps: number; lock: string | number }
        ];

        // additional configuration
        [key: string]: any;
    };
    fees?: {
        retention?: {
            // 1 == 100%
            jrt: number;
            srt: number;
        };
        // reserveFee: 1 === 100%
        performanceFee: number;
    };
    riskPremium?: {
        x: number;
        y: number;
        k: number;
    };
    minimumJrtSrtRatioBuffer?: number;
    minimumJrtSrtRatio?: number;
    accounts?: {
        [platform: TEth.Platform]:
            | string
            | {
                  deployer: string;
                  timelockAdmin: string;
                  timelockConfig: string;
                  safeAdmin: string;
                  safeOperator: string;
              };
    };
    Feed?: {
        name?: string;
    };
    Contracts?: {
        // Override contract IDs for the platform
        [platform: TEth.Platform | '*']: {
            AccessControlManager?: string;
            SharesCooldown?: string;
            ERC20Cooldown?: string;
            UnstakeCooldown?: string;
        };
    };
    ContractVersions?: {
        // Discrete accounting is the default (backward compatible with previous versions).
        accounting?: 'continuous' | 'discrete' | 'dys' | 'isolated';
        accountingOptions?: {
            // Relevant for DYS accounting
            useBenchmark?: boolean
            // When true, DYSAccounting uses the rate-based senior true-up (MultiStrategy deployments).
            useRatesForReconciliation?: boolean;
            // When true, totalStrategyAssets uses lastReconciliation instead of navTimestamp.
            // navTimestamp - works for single strategy
            // lastReconciliation - works for multi-strategy
            useNavAtReconciliation?: boolean;
            // When true, Junior covers paid-out projected Senior assets if realized PnL is underestimated.
            useJuniorCoversPaidSrtProjection?: boolean
            // When true, redemptions exclude unreconciled projected gains.
            useConservativeRedemptionPrice?: boolean
        }
        unstakeImpl?: 'MockInstant'

        // TrancheDepositor Version
        depositor?: 'V3' | 'V4'
    };

    // Contracts prefixes (can be overridden for testing)
    pfx?: string;

    TestHelper?: ITestHelperConstructor;
}

export const Tranches: Record<TCDOKey, ICDO> = {
    spkMhyperIso: {
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
    },
    ethena: {
        base: 'USDe',
        jrt: {
            symbol: 'jrUSDe',
            name: 'Strata Junior USDe',
            depositsEnabled: true,
            withdrawalsEnabled: true,
            sUSDeCooldown: '7days',
        },
        srt: {
            symbol: 'srUSDe',
            name: 'Strata Senior USDe',
            depositsEnabled: true,
            withdrawalsEnabled: true,
            sUSDeCooldown: 0,
        },
        Feed: {
            name: 'Ethena CDO APR Pair',
        },
        ContractVersions: {
            accounting: 'continuous',
        },
    },
    neutrl: {
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
        },
        TestHelper: NeutrlTestHelper,
    },
    mhyper: {
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
    },
    mkralpha: MKRAlphaTranche,
    mm1usd: {
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
    },
    mrox: {
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
    },
    saturn: SaturnTranche,
    figure: FigureTranche,
    nestopal: NestOpalTranche,
};

export const ContractsIDMapping = {
    jrUSDe: 'USDeJrt',
    srUSDe: 'USDeSrt',
    USDe: 'USDeCDO',
};

export const ContractsPrefixMapping = {
    ethena: 'USDe',
    figure: 'Figure',
    spkMhyperIso: 'SpkMhyperIso',
    neutrl: 'Neutrl',
    mhyper: 'MHyper',
    mkralpha: 'MKRAlpha',
    mm1usd: 'MM1USD',
    mrox: 'MROX',
    saturn: 'Saturn',
    nestopal: 'NestOpal',
} as Record<TCDOKey, string>;
