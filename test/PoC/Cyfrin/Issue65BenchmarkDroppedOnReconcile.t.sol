// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

// Adapted from Cyfrin f-65: original exploit assertions replaced by regression expectations.

import { console } from "forge-std/console.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { IERC20Cooldown, IUnstakeCooldown } from "../../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";
import { MockStakedUSDat } from "../../../contracts/test/MockStakedUSDat.sol";
import { SaturnStrategy } from "../../../contracts/tranches/strategies/saturn/SaturnStrategy.sol";
import { IsUSDat } from "../../../contracts/tranches/strategies/saturn/IsUSDat.sol";
import { ERC20Cooldown } from "../../../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import { UnstakeCooldown } from "../../../contracts/tranches/base/cooldown/UnstakeCooldown.sol";
import { CooldownBase } from "../../../contracts/tranches/base/cooldown/CooldownBase.sol";

/// @notice Full Strata stack (StrataCDO + two conservative-price Tranches + MTMAccounting or DYSAccounting) on either
///         MockMTMStrategy (epoch snapshot: navT1 held at the accounting NAV, navMTM live) or the real
///         SaturnStrategy on MockStakedUSDat (inherited default snapshot)
contract Issue65StackBase is Test {
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    MTMAccounting accounting;
    MockAprPairFeed feed;
    MockERC20 token;
    MockMTMStrategy mtmStrategy;
    SaturnStrategy saturn;
    MockStakedUSDat sUSDat;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    struct AccFlags {
        bool benchmark;
        bool mtmProjection;
        bool dys; // deploy DYSAccounting instead of MTMAccounting
    }

    function _deployCore(IERC20Metadata asset, uint256 navDecimals, AccFlags memory f) internal {
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(asset)),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche(asset, "JRT");
        srt = _tranche(asset, "SRT");

        feed = new MockAprPairFeed();
        // 8% benchmark target, 10% base APR (SD7x12)
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp));

        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice, mtmProjection
        // DYSAccounting has the same initializer and the same getters used here, so both sit behind `accounting`
        address impl = f.dys
            ? address(new DYSAccounting(navDecimals, f.benchmark, true, false, false, true))
            : address(new MTMAccounting(navDecimals, f.benchmark, true, false, false, true, f.mtmProjection));
        accounting = MTMAccounting(address(new ERC1967Proxy(
            impl,
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector,
                address(this),
                address(acm),
                IStrataCDO(address(cdo)),
                IAprPairFeed(address(feed))
            )
        )));

        acm.grantRole(PAUSER_ROLE, address(this));
        acm.grantRole(UPDATER_FEED_ROLE, address(this));
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, address(this));
        acm.grantRole(RESERVE_MANAGER_ROLE, address(this));
    }

    function _finishCore(IStrategy strategy_) internal {
        cdo.configure(IAccounting(address(accounting)), strategy_, ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
    }

    function _tranche(IERC20Metadata asset, string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(true)),
            abi.encodeWithSelector(
                Tranche.initialize.selector,
                address(this), address(acm), name, name, IERC20(address(asset)), IStrataCDO(address(cdo))
            )
        )));
    }

    /// @dev MockMTMStrategy stack, 18 decimals, epoch = 1 day
    function _deployMTMStack(AccFlags memory f) internal {
        token = new MockERC20("BASE", 18);
        _deployCore(IERC20Metadata(address(token)), 18, f);
        mtmStrategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        mtmStrategy.setEpochDuration(1 days);
        _finishCore(IStrategy(address(mtmStrategy)));
    }

    /// @dev SaturnStrategy on MockStakedUSDat (USDat 6 decimals, no sUSDat deposit fee)
    function _deploySaturnStack(AccFlags memory f) internal {
        token = new MockERC20("USDat", 6);
        sUSDat = new MockStakedUSDat(IERC20(address(token)), address(this));
        sUSDat.setDepositFeeBps(0);
        _deployCore(IERC20Metadata(address(token)), 6, f);
        address erc20Cd = address(new ERC1967Proxy(
            address(new ERC20Cooldown()),
            abi.encodeWithSelector(CooldownBase.initialize.selector, address(this), address(acm))
        ));
        address unstakeCd = address(new ERC1967Proxy(
            address(new UnstakeCooldown()),
            abi.encodeWithSelector(CooldownBase.initialize.selector, address(this), address(acm))
        ));
        saturn = SaturnStrategy(address(new ERC1967Proxy(
            address(new SaturnStrategy(IsUSDat(address(sUSDat)))),
            abi.encodeWithSelector(
                SaturnStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)),
                IERC20Cooldown(erc20Cd), IUnstakeCooldown(unstakeCd)
            )
        )));
        acm.grantRole(keccak256("COOLDOWN_WORKER_ROLE"), address(saturn));
        _finishCore(IStrategy(address(saturn)));
    }

    function _deposit(Tranche t, address user, uint256 amount) internal returns (uint256 shares) {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        shares = t.deposit(amount, user);
        vm.stopPrank();
    }
}

/// @notice Historical bug: benchmark-mode Senior yield (srtPnLBenchmark) accrued only on non-reconciling updates; the interval that
///         ends in a reconciling update is never credited and updateIndex skips it. SaturnStrategy keeps the
///         default snapshot (navT1 == navMTM == spot), so every update in a block where NAV moved reconciles and
///         Senior only receives its realized risk-premium share instead of the benchmark
contract SaturnBenchmarkDroppedOnReconcileTest is Issue65StackBase {

    uint256 constant DAYS = 30;
    uint256 constant DAILY_YIELD = 0.1e6; // 0.1 USDat/day on 2000 USDat (~1.8% APR), below the 8% benchmark

    function _setUp() internal {
        _deploySaturnStack(AccFlags({ benchmark: true, mtmProjection: true, dys: false }));
        _deposit(jrt, alice, 1000e6);
        _deposit(srt, bob, 1000e6);
    }

    function _poke() internal {
        (uint256 juniorBefore, uint256 seniorBefore,) = accounting.totalAssets();
        vm.prank(carol);
        jrt.burnSharesAsFee(0, carol);
        (uint256 juniorAfter, uint256 seniorAfter,) = accounting.totalAssets();
        assertEq(juniorAfter, juniorBefore, "Junior view matches checkpoint");
        assertEq(seniorAfter, seniorBefore, "Senior view matches checkpoint");
        vm.prank(carol);
        jrt.burnSharesAsFee(0, carol);
        (, uint256 seniorRepeated,) = accounting.totalAssets();
        assertEq(seniorRepeated, seniorAfter, "same-block checkpoint cannot double accrue");
    }

    function _yield() internal {
        sUSDat.setUsdatBalance(sUSDat.usdatBalance() + DAILY_YIELD);
    }

    /// Arm A: Saturn reality, NAV changes before every touch, so every update reconciles
    function _runAlwaysReconciling() internal returns (uint256 srtNav, uint256 jrtNav) {
        _setUp();
        for (uint256 i; i < DAYS; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            _yield();
            _poke();
            assertEq(accounting.srtPnLBenchmark(), 0, "settled benchmark accumulator resets");
        }
        (jrtNav, srtNav,) = accounting.totalAssets();
    }

    /// Arm B: identical NAV path, but a keeper touches the market once per day in a block where NAV is unchanged
    function _runWithProjectionTouch() internal returns (uint256 srtNav, uint256 jrtNav) {
        _setUp();
        for (uint256 i; i < DAYS; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            _poke(); // NAV unchanged since last update: projection branch, benchmark accrues
            _yield();
            _poke(); // same block: reconciliation credits the stored benchmark
        }
        (jrtNav, srtNav,) = accounting.totalAssets();
    }

    function test_Regression_SaturnBenchmarkDroppedOnReconcile() public {
        (uint256 srtA, uint256 jrtA) = _runAlwaysReconciling();
        (uint256 srtB, uint256 jrtB) = _runWithProjectionTouch();

        console.log("30d Senior NAV, always reconciling  ", srtA);
        console.log("30d Senior NAV, with projection touch", srtB);
        console.log("30d Junior NAV, always reconciling  ", jrtA);
        console.log("30d Junior NAV, with projection touch", jrtB);

        // Both paths now include the final benchmark interval.
        assertApproxEqAbs(srtA, srtB, 2, "reconciliation includes the same benchmark as an explicit checkpoint");
        // Arm B: Senior earns the 8% benchmark (~6.58 over 30 days)
        assertApproxEqAbs(srtB, 1006.58e6, 0.05e6, "Senior gets the 8% benchmark");
        // Allocation and total NAV agree in both paths.
        assertApproxEqAbs(srtA + jrtA, srtB + jrtB, 2, "same NAV path");
        assertApproxEqAbs(jrtA, jrtB, 2, "Junior allocation does not depend on checkpoint timing");
    }

    /// DYS also includes the benchmark when every update reconciles.
    function test_Regression_SaturnBenchmarkDroppedOnReconcile_DYS() public {
        _deploySaturnStack(AccFlags({ benchmark: true, mtmProjection: false, dys: true }));
        _deposit(jrt, alice, 1000e6);
        _deposit(srt, bob, 1000e6);
        for (uint256 i; i < DAYS; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            _yield();
            _poke();
        }
        (, uint256 srtNav,) = accounting.totalAssets();
        console.log("30d Senior NAV on DYS, always reconciling", srtNav);
        assertApproxEqAbs(srtNav, 1006.58e6, 0.05e6, "DYS includes the pending benchmark");
    }

    /// A high risk premium must not remove the benchmark floor.
    function test_Regression_SaturnBenchmarkDroppedOnReconcile_FullRiskPremium() public {
        _setUp();
        accounting.setRiskParameters(UD60x18.wrap(0.999e18), UD60x18.wrap(0), UD60x18.wrap(1e18)); // just below the 100% cap
        for (uint256 i; i < DAYS; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            _yield();
            _poke();
        }
        (, uint256 srtNav,) = accounting.totalAssets();
        console.log("30d Senior NAV at RP 99.9%, always reconciling", srtNav);
        assertApproxEqAbs(srtNav, 1006.58e6, 0.05e6, "benchmark applies even with a high risk premium");
    }
}

/// @notice Regression for lagged MTM observations (SIP-10 only requires
///         navMTMTime >= navT1Time). The projection update accrues the benchmark to navMTMTime but
///         updateIndex advances benchmarkIndex to block.timestamp, so the gap is never credited, and a
///         later observation older than indexTimestamp underflows calculateTargetIndex
contract MTMBenchmarkLaggedObservationTest is Issue65StackBase {

    uint256 t0;

    function _setUp() internal {
        vm.warp(1_700_000_000);
        _deployMTMStack(AccFlags({ benchmark: true, mtmProjection: true, dys: false }));
        mtmStrategy.setEpochDuration(365 days); // every update in the test stays inside the epoch (no reconciliation)
        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
        t0 = vm.getBlockTimestamp();
    }

    /// @dev Projection-only update whose MTM observation was taken at `observedAt`
    function _pokeObservedAt(uint256 observedAt) internal {
        uint256 nav = accounting.nav();
        vm.mockCall(
            address(mtmStrategy),
            abi.encodeWithSelector(mtmStrategy.totalAssetsSnapshot.selector),
            abi.encode(nav, accounting.lastReconciliation(), nav, observedAt)
        );
        vm.prank(carol);
        jrt.burnSharesAsFee(0, carol);
        vm.clearMockedCalls();
    }

    /// A lagged mark must still accrue benchmark to the accounting checkpoint.
    function test_Regression_LaggedObservationSkipsBenchmark() public {
        _setUp();
        uint256 snap = vm.snapshotState();

        vm.warp(t0 + 2 days);
        _pokeObservedAt(t0 + 2 days);
        uint256 benchmarkFresh = accounting.srtPnLBenchmark();

        vm.revertToState(snap);
        vm.warp(t0 + 2 days);
        _pokeObservedAt(t0 + 1 days);
        uint256 benchmarkLagged = accounting.srtPnLBenchmark();

        console.log("benchmark after 2 days, fresh observation ", benchmarkFresh);
        console.log("benchmark after 2 days, 1-day-old observation", benchmarkLagged);
        assertEq(accounting.indexTimestamp(), t0 + 2 days, "index advanced to accounting time");
        assertEq(benchmarkLagged, benchmarkFresh, "benchmark and index use accounting time");
    }

    /// An observation older than the stored index no longer causes benchmark-index underflow.
    function test_Regression_LaggedObservationOlderThanIndexSucceeds() public {
        _setUp();
        vm.warp(t0 + 2 days);
        _pokeObservedAt(t0 + 2 days);

        vm.warp(t0 + 3 days);
        uint256 nav = accounting.nav();
        vm.mockCall(
            address(mtmStrategy),
            abi.encodeWithSelector(mtmStrategy.totalAssetsSnapshot.selector),
            abi.encode(nav, accounting.lastReconciliation(), nav, t0 + 2 days - 1 hours)
        );
        vm.prank(carol);
        jrt.burnSharesAsFee(0, carol);
        assertEq(accounting.indexTimestamp(), t0 + 3 days);
        assertGt(accounting.srtPnLBenchmark(), 0);
    }
}
