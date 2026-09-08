import type { ICDO } from '../Tranches';

export const EthenaTranche = <ICDO> {
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
};
