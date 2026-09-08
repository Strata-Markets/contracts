import { ITestHelperConstructor } from '@s/strategies/interfaces/ITestHelper';
import { TEth } from 'dequanto/models/TEth';
import { SpkMhyperIsoTranche } from './strats/SpkMhyperIsoTranche';
import { EthenaTranche } from './strats/EthenaTranche';
import { NeutrlTranche } from './strats/NeutrlTranche';
import { MHyperTranche } from './strats/MHyperTranche';
import { MKRAlphaTranche } from './strats/MKRAlphaTranche';
import { MM1UsdTranche } from './strats/MM1UsdTranche';
import { MROXTranche } from './strats/MROXTranche';
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
        x?: number;
        y?: number;
        k?: number;
        model?: {
            type: 'sigmoid'
            // 0.05 (5%)
            min: number
            // 0.22 (22%)
            max: number
            // 30
            k: number
            // 0.85 (85%)
            sOptimal: number
        }
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
        accounting?: 'continuous' | 'discrete' | 'dys' | 'mtm' | 'isolated';
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
            useConservativePrice?: boolean
            // When true, DYSAccounting uses current strategy MTM NAV during projection.
            useMTMProjection?: boolean
        }
        unstakeImpl?: 'MockInstant'
        strategyImpl?: 'MockMTMStrategy'

        // TrancheDepositor Version
        depositor?: 'V3' | 'V4'

        valuationKeeper?: 'Accountable'
        valuationKeeperOptions?: {
            // timespan, e.g.: 24h
            gracePeriod?: string
            [key: string]: any
        }
    };

    // Contracts prefixes (can be overridden for testing)
    pfx?: string;

    TestHelper?: ITestHelperConstructor;
}

export const Tranches: Record<TCDOKey, ICDO> = {
    spkMhyperIso: SpkMhyperIsoTranche,
    ethena: EthenaTranche,
    neutrl: NeutrlTranche,
    mhyper: MHyperTranche,
    mkralpha: MKRAlphaTranche,
    mm1usd: MM1UsdTranche,
    mrox: MROXTranche,
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
