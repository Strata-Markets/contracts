import { UTest } from 'atma-utest'
import { $hh } from '../utils/$hh';
import { AccountingExecutor } from './AccountingExecutor';
import { $apr } from '@s/utils/$apr';
import { DiscreteAccounting as Accounting } from '@0xc/hardhat/DiscreteAccounting/DiscreteAccounting';
import { $require } from 'dequanto/utils/$require';

const test = $hh.create('ethena', {
    cdoInfo: {
        ContractVersions: { accounting: 'discrete' }
    },
})
const contracts = await test.deploy();
const accounting = contracts.accounting as any as Accounting;

UTest.create({
    async $before () {
        const discrete = new Accounting(accounting.address, accounting.client);
        $require.eq(await discrete.navTargetIndex(), BigInt(1e18));
    },
    async $after () {
        await AccountingExecutor.teardown();
        await test.reset();
    },
    'sUSDe APY ⬆️🟢 SSR': {
        '➡️ deposit 50/50': {
            async 'accrue after 1 year' () {
                let exec = new AccountingExecutor(test);
                await exec.run({
                    steps: [
                        { balanceFlow: [1000, 0, 1000, 0] },
                        { aprs: [ 0.1, 0.2 ] },
                        { eqNav: 2000 },
                        { time: '1year' },
                        // No rewards; use projected values.
                        { totalAssets: 2000 },
                        { eqProjectedAvg: [
                            1000 * 1.272, // ~27.2%
                            1000 * 1.127, // ~12.7%
                        ]},
                        // No rewards again in the next block.
                        { totalAssets: 2000 },
                        { eqProjectedAvg: [
                            1000 * 1.272, // ~27.2%
                            1000 * 1.127, // ~12.7%
                        ]},
                        // Rewards detected; process the true-up.
                        { totalAssets: 2400 },
                        { eqAvg: [
                            1000 * 1.272, // ~27.2%
                            1000 * 1.127, // ~12.7%
                        ]}
                    ]
                });
            },
            async 'update in 0.5 year without yield' () {
                let total = $apr.value(2000);
                let jrt = $apr.value(1000);
                let srt = $apr.value(1000);

                let exec = new AccountingExecutor(test);
                await exec.run({
                    steps: [
                        { balanceFlow: [jrt.$, 0, srt.$, 0] },
                        { aprs: [ 0.1, 0.2 ] },
                        { eqNav: 2000 },
                        { eqAprSrt: $apr.calcAprSrt({
                                tvls: { jrt: jrt.$, srt: srt.$ },
                                risk: [ 0.2, 0.2, 0.3],
                                aprs: { target: 0.1, base: 0.2 }
                            })
                        },
                        { time: '0.5year' },
                        { totalAssets: total.next(.2, 6) },
                        // TVL will be rebalanced.
                        { balanceFlow: [0, 0, 1, 0] },
                        { balanceFlow: [0, 0, 0, 1] },

                        { eqAvg: [
                            jrt.next(.272, 6), // ~27.2%
                            srt.next(.127, 6), // ~12.7%
                        ]},

                        { eqAprSrt: $apr.calcAprSrt({
                                tvls: { jrt: jrt.$, srt: srt.$ },
                                risk: [ 0.2, 0.2, 0.3],
                                aprs: { target: 0.1, base: 0.2 }
                            })
                        },
                        { time: '0.5year' },
                        { updateAccounting: true },
                        { eqProjectedAvg: [
                            jrt.calc(0.272, 6),
                            srt.calc(0.12783, 6),
                        ]},
                        { totalAssets: total.next(.2, 6) },
                        { eqAvg: [
                            jrt.next(0.272, 6),
                            srt.next(0.12783, 6),
                        ]},
                    ]
                });
            },
        },

        '↗️ deposit 80srt/20jrt': {
            async 'accrue after 1 year' () {
                let exec = new AccountingExecutor(test);
                await exec.run({
                    steps: [
                        { balanceFlow: [1600, 0, 400, 0] },
                        { aprs: [ 0.1, 0.2 ] },
                        { eqNav: 2000 },
                        { time: '1year', updateAccounting: true },
                        { eqProjectedAvg: [
                            1600 * 1.216, // ~21.6% // 1945872540087149714534n
                            400 * 1.135, // ~13.5%  // 454127459912850285466n
                        ]},
                        { totalAssets: 2400 },
                        { eqAvg: [
                            1600 * 1.216, // ~21.6% // 1945872540087149714534n
                            400 * 1.135, // ~13.5%  // 454127459912850285466n
                        ]}
                    ]
                });
            },
            async 'update in 0.5 year without yield' () {
                let total = $apr.value(2000);
                let jrt = $apr.value(1600);
                let srt = $apr.value(400);

                let exec = new AccountingExecutor(test);
                await exec.run({
                    steps: [
                        { balanceFlow: [jrt.$, 0, srt.$, 0] },
                        { aprs: [ 0.1, 0.2 ] },
                        { eqNav: total.$ },
                        { eqAprSrt: $apr.calcAprSrt({
                                tvls: { jrt: jrt.$, srt: srt.$ },
                                risk: [ 0.2, 0.2, 0.3],
                                aprs: { target: 0.1, base: 0.2 }
                            })
                        },
                        { time: '0.5year', updateAccounting: true },
                        { eqProjectedAvg: [
                            jrt.calc(.216, 6), // ~21.6%
                            srt.calc(.135, 6), // ~13.5%
                        ]},

                        { totalAssets: total.next(.2, 6) },
                        { eqAvg: [
                            jrt.next(.216, 6), // ~21.6%
                            srt.next(.135, 6), // ~13.5%
                        ]},

                        { eqAprSrt: $apr.calcAprSrt({
                                tvls: { jrt: jrt.$, srt: srt.$ },
                                risk: [ 0.2, 0.2, 0.3],
                                aprs: { target: 0.1, base: 0.2 }
                            })
                        },
                        { time: '0.5year', updateAccounting: true },
                        { eqProjectedAvg: [
                            jrt.calc(0.216, 6),   // ~21.6%
                            srt.calc(0.13553, 6), // ~13.5%
                        ]},

                        { totalAssets: total.next(.2, 6) },
                        { eqAvg: [
                            null,
                            srt.next(0.13553, 6),
                        ]},
                    ]
                });
            },
        },
        '↘️ deposit 20srt/80jrt': {
            async 'accrue after 1 year' () {
                let exec = new AccountingExecutor(test);

                await exec.run({
                    steps: [
                        { balanceFlow: [400, 0, 1600, 0] },
                        { aprs: [ 0.1, 0.2 ] },
                        { eqNav: 2000 },
                        { time: '1year', updateAccounting: true },
                        { eqProjectedAvg: [
                            400 * 1.509, // ~50.9% // 603855894440959176083n
                            1600 * 1.123, // ~12.3%  // 1796144105559040823917n
                        ]},
                        { totalAssets: 2400 },
                        { eqAvg: [
                            400 * 1.509, // ~50.9% // 603855894440959176083n
                            1600 * 1.123, // ~12.3%  // 1796144105559040823917n
                        ]}
                    ]
                });
            },
            async 'update in 0.5 year without yield' () {
                let exec = new AccountingExecutor(test);
                await exec.run({
                    steps: [
                        { balanceFlow: [400, 0, 1600, 0] },
                        { aprs: [ 0.1, 0.2 ] },
                        { eqNav: 2000 },
                        { time: '0.5year' },
                        { totalAssets: 2000 },
                        { time: '0.5year' },
                        { updateAccounting: true },
                        { eqProjectedAvg: [
                            400 * 1.504, //  ~50.4% // 597844558129791419106n
                            1600 * 1.124, // ~12.3% // 1802155441870208580894n
                        ]},
                        { totalAssets: 2400 },
                        // TVL ratio has little influence on aprSrt
                        { eqAvg: [
                            400 * 1.504, //  ~50.4% // 597844558129791419106n
                            1600 * 1.124, // ~12.3% // 1802155441870208580894n
                        ]}
                    ]
                });
            },
        }
    },
    'sUSDe APY ⬇️🔴 SSR': {
        '➡️ deposit 50/50': {
            async 'accrue after 1 year' () {
                let exec = new AccountingExecutor(test);
                await exec.run({
                    steps: [
                        { balanceFlow: [1000, 0, 1000, 0] },
                        { aprs: [ 0.15, 0.1 ] },
                        { eqNav: 2000 },
                        { time: '1year', updateAccounting: true },
                        { eqProjectedAvg: [
                            1000 * 1.05, // ~5%
                            1000 * 1.15, // ~15%
                        ]},
                        { totalAssets: 2200 },
                        { eqAvg: [
                            1000 * 1.05, // ~5%
                            1000 * 1.15, // ~15%
                        ]}
                    ]
                });
            },
            async 'update in 0.5 year without yield' () {
                let exec = new AccountingExecutor(test);
                await exec.run({
                    steps: [
                        { balanceFlow: [1000, 0, 1000, 0] },
                        { aprs: [ 0.15, 0.1 ] },
                        { eqNav: 2000 },
                        { time: '0.5year'},
                        { totalAssets: 2000},
                        { time: '0.5year', updateAccounting: true },
                        { eqProjectedAvg: [
                            1000 * 1.045, // ~4.5%
                            1000 * 1.155, // ~15.5%
                        ]},
                        { totalAssets: 2200},
                        { eqAvg: [
                            1000 * 1.045, // ~4.5%
                            1000 * 1.155, // ~15.5%
                        ]}
                    ]
                });
            },
        },
        '↗️ deposit 80srt/20jrt': {
            async 'accrue after 1 year' () {
                let exec = new AccountingExecutor(test);
                await exec.run({
                    steps: [
                        { balanceFlow: [1600, 0, 400, 0] },
                        { aprs: [ 0.15, 0.1 ] },
                        { eqNav: 2000 },
                        { time: '1year', updateAccounting: true },
                        { eqProjectedAvg: [
                            1600 * 1.087, // ~8.7%
                            400 * 1.15, // ~15%
                        ]},
                        { totalAssets: 2200 },
                        { eqAvg: [
                            1600 * 1.087, // ~8.7%
                            400 * 1.15, // ~15%
                        ]}
                    ]
                });
            },
            async 'update in 0.5 year without yield' () {

                let exec = new AccountingExecutor(test);
                await exec.run({
                    steps: [
                        { balanceFlow: [1600, 0, 400, 0] },
                        { aprs: [ 0.15, 0.1 ] },
                        { eqNav: 2000 },
                        { time: '0.5year' },
                        { totalAssets: 2000 },
                        { time: '0.5year', updateAccounting: true },
                        { eqProjectedAvg: [
                            1600 * 1.087, // ~8.7%
                            400 * 1.15, // ~15%
                        ]},
                        { totalAssets: 2200 },
                        { eqAvg: [
                            1600 * 1.087, // ~8.7%
                            400 * 1.15, // ~15%
                        ]}
                    ]
                });

            },
        },
        '↘️ deposit 20srt/80jrt': {
            async 'accrue after 1 year' () {
                let exec = new AccountingExecutor(test);
                await exec.run({
                    steps: [
                        { balanceFlow: [400, 0, 1600, 0] },
                        { aprs: [ 0.15, 0.1  ] },
                        { eqNav: 2000 },
                        { time: '1year', updateAccounting: true },
                        { eqProjectedAvg: [
                            400 * 0.9,   // ~-10%
                            1600 * 1.15, // ~15%
                        ]},
                        { totalAssets: 2200 },
                        { eqAvg: [
                            400 * 0.9,   // ~-10%
                            1600 * 1.15, // ~15%
                        ]}
                    ]
                });
            },
            async 'update in 0.5 year without yield' () {
                let exec = new AccountingExecutor(test);
                await exec.run({
                    steps: [
                        { balanceFlow: [400, 0, 1600, 0] },
                        { aprs: [ 0.15, 0.1  ] },
                        { eqNav: 2000 },
                        { time: '0.5year' },
                        { totalAssets: 2000 },
                        { time: '0.5year', updateAccounting: true },
                        { eqProjectedAvg: [
                            400 * 0.88,   // ~-10%
                            1600 * 1.153, // ~15.3%
                        ]},
                        { totalAssets: 2200 },
                        { eqAvg: [
                            400 * 0.88,   // ~-10%
                            1600 * 1.153, // ~15.3%
                        ]}
                    ]
                });
            },
        },
        '🛡️ Issue #5: projected NAV split bounds senior gains by real junior assets': {
            async 'preserves conservation invariant and prevents saturation mismatch' () {
                let exec = new AccountingExecutor(test);
                await exec.run({
                    steps: [
                        { balanceFlow: [50, 0, 1950, 0] },
                        { aprs: [ 0.20, 0.10 ] },
                        { eqNav: 2000 },
                        { time: '0.5year' },
                        // 1. Initial projection cycle: Senior target (195) capped by JRT settled (50 - 1 = 49)
                        { totalAssets: 2000 },
                        { eqProjectedAvg: [
                            101,  // JRT projected: 50 + 100 (base yield) - 49 (SRT cap)
                            1999  // SRT projected: 1950 + 49
                        ]},
                        { eqAvg: [
                            1,    // JRT real floored at ONE_ASSET (50 - 49)
                            1999  // SRT real credited with capped accrual (1950 + 49)
                        ]},

                        // 2. Second projection cycle: JRT real is already at ONE_ASSET (1), SRT gets 0 additional real yield
                        { time: '0.5year', updateAccounting: true },
                        { eqProjectedAvg: [
                            201,  // JRT projected continues accumulating projected protocol gain (101 + 100)
                            1999  // SRT capped, no further real junior collateral to absorb
                        ]},
                        { eqAvg: [
                            1,    // JRT real remains preserved at ONE_ASSET
                            1999  // SRT remains 1999
                        ]},

                        // 3. True-up with real strategy yield: executes cleanly without InvalidNavSplit
                        { totalAssets: 2100 },
                        { eqAvg: [
                            101,  // JRT absorbs remaining realized strategy gain (1 + 100)
                            1999  // SRT remains consistent
                        ]}
                    ]
                });
            },

            async 'handles dust / minimum JRT collateral without underflow or phantom accrual' () {
                let exec = new AccountingExecutor(test);
                await exec.run({
                    steps: [
                        // JRT initialized at exact floor ONE_ASSET (1), SRT at 1999
                        { balanceFlow: [1, 0, 1999, 0] },
                        { aprs: [ 0.20, 0.10 ] },
                        { eqNav: 2000 },
                        { time: '0.5year' },
                        { totalAssets: 2000 },
                        { eqAvg: [
                            1,    // saturatingSub(1, 1) = 0 cap; JRT real cannot be depleted below ONE_ASSET
                            1999  // SRT receives 0 real accrual from JRT
                        ]},
                        { totalAssets: 2100 },
                        { eqAvg: [
                            101,
                            1999
                        ]}
                    ]
                });
            }
        }
    }
});
