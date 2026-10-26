// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
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
import { MockInsurancePool } from "../../symbiotic/mocks/MockInsurancePool.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";

/// @notice Regression for forfeited benchmark being reallocated to remaining Seniors.
///         Adapted from the Cyfrin PoC: passing assertions require the corrected allocation.
contract BenchmarkTrackerOnExitTest is Test {
    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    DYSAccounting accounting;
    MockAprPairFeed feed;
    MockMTMStrategy strategy;
    MockERC20 token;
    bool conservative = true;

    address alice = makeAddr("alice"); // Junior
    address bob = makeAddr("bob"); // sole Senior
    address carol = makeAddr("carol");
    address dave = makeAddr("dave"); // second Senior, enters after reconciliation

    function setUp() public {
        vm.warp(1_750_000_000);
        token = new MockERC20("BASE", 18);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(IERC20Metadata(address(token)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche("JRT");
        srt = _tranche("SRT");

        feed = new MockAprPairFeed();
        // 8 percent Senior target, 10 percent base APR (SD7x12)
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp));

        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice
        accounting = DYSAccounting(address(new ERC1967Proxy(
            _implementation(),
            abi.encodeWithSelector(
                DYSAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        )));

        strategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        // Strategy NAV changes only when the test moves it, so intra-epoch updates stay projections
        strategy.setEpochDuration(3650 days);

        acm.grantRole(keccak256("PAUSER_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));

        cdo.configure(
            IAccounting(address(accounting)),
            IStrategy(address(strategy)),
            ITranche(address(jrt)),
            ITranche(address(srt))
        );
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        // Risk premium 50 percent: aprSrt = max(8 percent, 10 percent x 0.5) = 8 percent
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));

        _deposit(jrt, alice, 1_000e18);
        _deposit(srt, bob, 1_000e18);
    }

    function _implementation() internal virtual returns (address) {
        return address(new DYSAccounting(18, true, false, false, true, conservative));
    }

    function _tranche(string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(conservative)),
            abi.encodeWithSelector(
                Tranche.initialize.selector,
                address(this), address(acm), name, name, IERC20(address(token)), IStrataCDO(address(cdo))
            )
        )));
    }

    function _deposit(Tranche t, address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        t.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Permissionless accounting refresh
    function _poke() internal {
        vm.prank(carol);
        jrt.burnSharesAsFee(0, carol);
    }



    uint256 constant BENCHMARK = 40e18;
    uint256 constant TOL = 0.001e18;

    function _project() internal {
        vm.warp(vm.getBlockTimestamp() + 15_768_000);
        _poke();
    }

    function _reconcileFlat() internal virtual {
        // Another half-year earns benchmark on the remaining gross Senior NAV.
        vm.warp(vm.getBlockTimestamp() + 15_768_000);
        strategy.setTotalAssets(accounting.nav() + 1);
        _poke();
    }

    function _redeem(Tranche t, address user, uint256 shares) internal returns (uint256 received) {
        uint256 before = token.balanceOf(user);
        vm.prank(user);
        t.redeem(shares, user, user);
        received = token.balanceOf(user) - before;
    }

    function test_idleIntervalReconciliationAccruesBenchmark() public {
        _reconcileFlat();
        assertApproxEqAbs(accounting.srtBaseNav(), 1040e18, TOL);
        assertApproxEqAbs(accounting.jrtBaseNav(), 960e18, TOL);
        assertEq(accounting.srtPnLBenchmark(), 0);
        uint256 senior = accounting.srtBaseNav();
        _poke();
        assertEq(accounting.srtBaseNav(), senior, "repeated checkpoint cannot double accrue");
    }

    function test_control_noExit_juniorPaysOnce() public {
        _project();
        _reconcileFlat();
        assertApproxEqAbs(accounting.jrtBaseNav(), 918.4e18, TOL);
        assertApproxEqAbs(accounting.srtBaseNav(), 1081.6e18, TOL);
        assertApproxEqAbs(_redeem(jrt, alice, 500e18), 459.2e18, TOL);
    }

    function test_halfExit_forfeitedBenchmarkStaysWithJunior() public {
        _project();
        assertApproxEqAbs(accounting.srtPnLBenchmark(), BENCHMARK, TOL);
        assertApproxEqAbs(_redeem(srt, bob, 500e18), 500e18, TOL);
        assertApproxEqAbs(accounting.jrtBaseNav(), 980e18, TOL);
        assertApproxEqAbs(accounting.srtPnLProjected(), 20e18, TOL);
        assertApproxEqAbs(accounting.srtPnLBenchmark(), 20e18, TOL);

        _reconcileFlat();
        assertApproxEqAbs(accounting.jrtBaseNav(), 959.2e18, TOL, "Junior keeps forfeiture but pays the remaining Senior for the second interval");
        assertApproxEqAbs(accounting.srtBaseNav(), 540.8e18, TOL, "remaining Seniors earn both intervals on their remaining NAV");
        assertApproxEqAbs(strategy.totalAssets(), accounting.jrtBaseNav() + accounting.srtBaseNav(), TOL);
        assertApproxEqAbs(_redeem(srt, bob, 400e18), 432.64e18, TOL);
        assertApproxEqAbs(_redeem(jrt, alice, 500e18), 479.6e18, TOL);
    }

    function test_nearFullExit_dustCannotCollectForfeitedBenchmark() public {
        _project();
        assertApproxEqAbs(_redeem(srt, bob, 999.9e18), 999.9e18, TOL);
        assertApproxEqAbs(accounting.jrtBaseNav(), 999.996e18, TOL);
        assertApproxEqAbs(accounting.srtPnLBenchmark(), 0.004e18, TOL);

        _reconcileFlat();
        assertApproxEqAbs(accounting.jrtBaseNav(), 999.99184e18, TOL);
        assertApproxEqAbs(srt.convertToAssets(srt.balanceOf(bob)), 0.10816e18, TOL);
        assertApproxEqAbs(strategy.totalAssets(), accounting.jrtBaseNav() + accounting.srtBaseNav(), TOL);
        // A second depositor permits Bob to exit without breaching MIN_SHARES.
        _deposit(srt, dave, 100e18);
        assertApproxEqAbs(_redeem(srt, bob, srt.balanceOf(bob)), 0.10816e18, TOL);
        assertApproxEqAbs(token.balanceOf(bob), 1000.00816e18, TOL);
        assertApproxEqAbs(_redeem(jrt, alice, 500e18), 499.99592e18, TOL);
    }

    function test_nonConservativeExit_keepsBenchmarkForPaidProjection() public {
        conservative = false;
        setUp();
        _project();
        assertApproxEqAbs(_redeem(srt, bob, 500e18), 520e18, TOL);
        assertApproxEqAbs(accounting.srtPnLBenchmark(), BENCHMARK, TOL);
        assertApproxEqAbs(accounting.srtPaidProjected(), 20e18, TOL);
        _reconcileFlat();
        assertApproxEqAbs(accounting.jrtBaseNav(), 939.2e18, TOL);
        assertApproxEqAbs(accounting.srtBaseNav(), 540.8e18, TOL);
    }

    function test_repeatedExits_reduceRemainingBenchmarkProportionally() public {
        _project();
        _redeem(srt, bob, 500e18);
        _redeem(srt, bob, 250e18);
        assertApproxEqAbs(accounting.srtPnLBenchmark(), 10e18, TOL);
        _reconcileFlat();
        assertApproxEqAbs(accounting.jrtBaseNav(), 979.6e18, TOL);
        assertApproxEqAbs(accounting.srtBaseNav(), 270.4e18, TOL);
    }

    function _valuationExit(uint256 assets) internal returns (uint256 insuranceOut) {
        // Exercise accounting directly and mirror strategy outflow without a real insurance vault.
        vm.prank(address(cdo));
        insuranceOut = accounting.updateBalanceFlow(0, 0, 0, assets);
        strategy.setTotalAssets(accounting.nav());
    }

    function test_valuationExit_usesEffectiveNavForRepeatedExits() public {
        _project();
        vm.prank(address(cdo));
        accounting.setValuationPrice(0.8e18);
        // Net base NAV is 1000, but effective Senior NAV is 1250.
        _valuationExit(625e18);
        assertApproxEqAbs(accounting.srtPnLBenchmark(), 20e18, TOL);
        assertApproxEqAbs(accounting.srtPnLProjected(), 20e18, TOL);
        _valuationExit(312.5e18);
        assertApproxEqAbs(accounting.srtPnLBenchmark(), 10e18, TOL);
        assertApproxEqAbs(accounting.srtPnLProjected(), 10e18, TOL);
        vm.prank(address(cdo));
        accounting.setValuationPrice(1e18);
        _reconcileFlat();
        assertApproxEqAbs(accounting.srtBaseNav(), 270.4e18, TOL, "only remaining NAV earns the second interval after recovery");
        assertApproxEqAbs(accounting.jrtBaseNav(), 792.1e18, TOL);
    }

    function test_insuredValuationExit_usesFullEffectiveNav() public {
        MockInsurancePool pool = new MockInsurancePool();
        pool.setCapacity(1_000_000e18);
        vm.prank(address(cdo));
        accounting.setInsurancePool(pool);
        _project();
        vm.prank(address(cdo));
        accounting.setValuationPrice(0.4e18);
        uint256 insuranceBefore = accounting.insuranceAmount();
        assertGt(insuranceBefore, 0);
        // Effective Senior NAV is 2500, including Junior and insurance coverage.
        uint256 insuranceOut = _valuationExit(1250e18);
        assertApproxEqAbs(insuranceOut, insuranceBefore / 2, TOL);
        assertApproxEqAbs(accounting.srtPnLBenchmark(), 20e18, TOL);
        assertApproxEqAbs(accounting.srtPnLProjected(), 20e18, TOL);
    }

    function test_valuationExitAfterJuniorDepletion_hasNoNewBenchmark() public {
        vm.prank(address(cdo));
        accounting.updateBalanceFlow(0, 999e18, 0, 0);
        strategy.setTotalAssets(accounting.nav());
        _project();
        vm.prank(address(cdo));
        accounting.setValuationPrice(0.8e18);
        assertEq(accounting.srtPnLProjected(), 0);
        assertEq(accounting.srtPnLBenchmark(), 0);
        // No available Junior or insurance coverage: effective Senior NAV remains 1000.
        _valuationExit(500e18);
        assertEq(accounting.srtPnLProjected(), 0);
        assertEq(accounting.srtPnLBenchmark(), 0);
    }

    function test_nonConservativeValuationExit_keepsBenchmark() public {
        conservative = false;
        setUp();
        _project();
        vm.prank(address(cdo));
        accounting.setValuationPrice(0.8e18);
        // Gross effective NAV is 1040 / 0.8 = 1300.
        _valuationExit(650e18);
        assertApproxEqAbs(accounting.srtPnLBenchmark(), BENCHMARK, TOL);
        assertApproxEqAbs(accounting.srtPaidProjected(), 20e18, TOL);
    }

    function test_juniorDepositResumesBenchmarkWithoutBackfill() public {
        vm.prank(address(cdo));
        accounting.updateBalanceFlow(0, 999e18, 0, 0);
        strategy.setTotalAssets(accounting.nav());
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _deposit(jrt, carol, 100e18);
        assertEq(accounting.srtPnLBenchmark(), 0, "deposit cannot earn benchmark for the depleted year");
        _project();
        assertApproxEqAbs(accounting.srtPnLBenchmark(), BENCHMARK, TOL, "only the funded half-year accrues");
    }

    function test_exitAfterJuniorDepletion_hasNoNewBenchmark() public {
        // Simulate Junior outflow to its protected floor before benchmark accrues.
        vm.prank(address(cdo));
        accounting.updateBalanceFlow(0, 999e18, 0, 0);
        strategy.setTotalAssets(accounting.nav());
        _project();
        assertEq(accounting.srtPnLProjected(), 0, "Junior cannot fund projection");
        assertEq(accounting.srtPnLBenchmark(), 0);
        assertApproxEqAbs(_redeem(srt, bob, 500e18), 500e18, TOL);
        assertEq(accounting.srtPnLProjected(), 0);
        assertEq(accounting.srtPnLBenchmark(), 0);
    }
}

// The two contracts expose the same accounting ABI used by this fixture.
contract MTMBenchmarkTrackerOnExitTest is BenchmarkTrackerOnExitTest {
    function _reconcileFlat() internal override {
        // MTMAccounting reads totalAssetsSnapshot; release the next snapshot for reconciliation.
        strategy.setEpochDuration(0);
        super._reconcileFlat();
    }

    function _implementation() internal override returns (address) {
        return address(new MTMAccounting(18, true, false, false, true, conservative, false));
    }
}
