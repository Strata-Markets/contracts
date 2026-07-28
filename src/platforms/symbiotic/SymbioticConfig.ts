import { TEth } from 'dequanto/models/TEth';

/// A Strata market backstopped by the shared Symbiotic AppAdapter.
export interface ISymbioticMarketConfig {
    /// Human-readable market name (for logs only).
    name: string;
    /// The market's StrataCDO proxy.
    cdo: TEth.Address;
    /// The market's Accounting proxy (source of pendingCoverageDeficit).
    accounting: TEth.Address;
    /// Token symbol of the market's base asset; resolved to an address via Addresses[network].
    baseAsset: string;
    /// Extra buffer (bps) added to the slashed amount to pre-fund the true-up swap discount.
    bufferBps: bigint;
    enabled: boolean;
}

export interface ISymbioticConfig {
    /// The Symbiotic AppAdapter this middleware drives (deployed on the Symbiotic side).
    /// Leave unset until it exists; the deploy then requires it to be passed explicitly.
    appAdapter?: TEth.Address;
    /// Markets sharing the AppAdapter.
    markets: ISymbioticMarketConfig[];
}

/// Per-network Symbiotic coverage config, read by SymbioticNMDeployments.
export const SymbioticConfig = {
    eth: {
        // TODO: set once the AppAdapter is deployed on the Symbiotic side.
        appAdapter: undefined,
        markets: [
            {
                name: 'Ethena',
                cdo: '0x908B3921aaE4fC17191D382BB61020f2Ee6C0e20',
                accounting: '0xa436c5Dd1Ba62c55D112C10cd10E988bb3355102',
                baseAsset: 'USDe',
                bufferBps: 500n,
                enabled: true,
            },
            {
                name: 'Hastra',
                cdo: '0xff408b4843CDD4a33CD49EB2aBe057fE8D71C234',
                accounting: '0x0e90b8971bC0aBba696641eee85b39fD986267D7',
                baseAsset: 'USDC',
                bufferBps: 250n,
                enabled: true,
            },
            {
                name: 'mHYPER',
                cdo: '0x39C7E67b25fB14eAec8717B20664C2E35327e6cf',
                accounting: '0xAf32D44D510B82b64f13602f4A22c6A7FfF2b228',
                baseAsset: 'USDC',
                bufferBps: 250n,
                enabled: true,
            },
            {
                name: 'mM1-USD',
                cdo: '0x613D1790d9BA381D27B4071C04380Db8ED120E5f',
                accounting: '0xE4A3A21Cf73a8F34fc7f45D7FcE99c569AbB2A4A',
                baseAsset: 'USDC',
                bufferBps: 250n,
                enabled: true,
            },
        ],
    },
} as Record<string, ISymbioticConfig>;
