// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { RiskPremiumPower } from "../../../contracts/tranches/accounting/premium/RiskPremiumPower.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";

/// @notice Regression for reserve-bound Senior exit fees retaining benchmark in conservative markets.
abstract contract ConservativeSeniorExitFeeKeepsBenchmarkBase is Test {
    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    DYSAccounting accounting; // MTMAccounting exposes the same getters and setters used here
    MockAprPairFeed feed;
    MockMTMStrategy strategy;
    MockERC20 token;

    address alice = makeAddr("alice"); // Junior
    address bob = makeAddr("bob"); // sole Senior
    address carol = makeAddr("carol"); // keeper

    uint256 constant BENCHMARK = 40e18; // 1,000 x 8% x half a year
    uint256 constant EXIT_FEE = 0.01e18; // StrataCDO cap
    uint256 constant TOL = 0.001e18;

    function _implementation() internal virtual returns (address);

    /// @dev Lets the next accounting update read the moved strategy NAV as settled
    function _releaseSnapshot() internal virtual {}

    function setUp() public {
        vm.warp(1_750_000_000);
        token = new MockERC20("BASE", 18);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(IERC20Metadata(address(token)), ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche("JRT");
        srt = _tranche("SRT");

        feed = new MockAprPairFeed();
        // 8% Senior target, 10% base APR (SD7x12)
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp));
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
        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        // Risk premium 50%: aprSrt = max(8%, 10% x 0.5) = 8%
        accounting.setRiskModel(new RiskPremiumPower(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18)));
        cdo.setTwoStepConfigManager(address(this));
        cdo.setExitFees(0, EXIT_FEE);

        _deposit(jrt, alice, 1_000e18);
        _deposit(srt, bob, 1_000e18);
    }

    function test_reserveBoundExitFeeForfeitsBenchmark() public {
        _project();
        assertApproxEqAbs(accounting.srtPnLBenchmark(), BENCHMARK, TOL);
        assertEq(accounting.feeSrtRetentionBps(), 0, "the whole Senior fee goes to the reserve");

        // Bob redeems half the Senior supply: 500 gross at the settled price, 5 fee, 495 paid
        vm.prank(bob);
        uint256 out = srt.redeem(500e18, bob, bob);
        assertApproxEqAbs(out, 495e18, TOL, "net payout");
        assertApproxEqAbs(accounting.reserveNav(), 5e18, TOL, "fee booked to the reserve");

        assertApproxEqAbs(accounting.srtPnLBenchmark(), BENCHMARK / 2, 2, "only remaining capital keeps benchmark");
        _reconcileFlat();
        assertApproxEqAbs(accounting.srtBaseNav(), 520e18, TOL, "no excess Senior gain");
        assertApproxEqAbs(accounting.jrtBaseNav(), 980e18, TOL, "Junior funds only the remaining entitlement");
    }

    function test_repeatedFeeExitsKeepProportionalBenchmark() public {
        _project();
        uint256 supply0 = srt.totalSupply();
        uint256 benchmark0 = accounting.srtPnLBenchmark();
        for (uint256 i; i < 10; ++i) {
            uint256 shares = srt.balanceOf(bob) * 955 / 10_000;
            vm.prank(bob);
            srt.redeem(shares, bob, bob);
        }
        uint256 entitled = Math.mulDiv(benchmark0, srt.totalSupply(), supply0);
        assertApproxEqAbs(accounting.srtPnLBenchmark(), entitled, 25, "no accumulated fee benchmark");
    }

    function _checkRetention(uint256 retention) internal {
        accounting.setFeeRetentionBps(0, retention);
        _project();
        vm.prank(bob);
        srt.redeem(500e18, bob, bob);
        uint256 retained = 5e18 * retention / 1e18;
        assertEq(accounting.reserveNav(), 5e18 - retained);
        uint256 expected = BENCHMARK * (500e18 + retained) / 1000e18;
        assertApproxEqAbs(accounting.srtPnLBenchmark(), expected, 2, "retained fee keeps its benchmark");
    }

    function test_partialRetentionKeepsRetainedBenchmark() public {
        _checkRetention(0.5e18);
    }

    function test_fullRetentionKeepsRetainedBenchmark() public {
        _checkRetention(1e18);
    }

    function test_feeOnlyBurnForfeitsReserveBenchmark() public {
        _project();
        vm.prank(bob);
        srt.burnSharesAsFee(100e18, bob);
        assertEq(accounting.reserveNav(), 100e18);
        assertApproxEqAbs(accounting.srtPnLBenchmark(), 36e18, 2);
    }

    function _project() internal {
        vm.warp(vm.getBlockTimestamp() + 15_768_000);
        _poke();
    }

    function _reconcileFlat() internal {
        vm.warp(vm.getBlockTimestamp() + 1);
        _releaseSnapshot();
        strategy.setTotalAssets(accounting.nav() + 1);
        _poke();
        assertEq(accounting.srtPnLBenchmark(), 0, "epoch reconciled");
    }

    function _poke() internal {
        vm.prank(carol);
        jrt.burnSharesAsFee(0, carol);
    }

    function _tranche(string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(true)),
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
}

contract ConservativeSeniorExitFeeKeepsBenchmarkDYSTest is ConservativeSeniorExitFeeKeepsBenchmarkBase {
    function _implementation() internal override returns (address) {
        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice
        return address(new DYSAccounting(18, true, false, false, true, true));
    }
}

contract ConservativeSeniorExitFeeKeepsBenchmarkMTMTest is ConservativeSeniorExitFeeKeepsBenchmarkBase {
    function _implementation() internal override returns (address) {
        // as above, plus mtmProjection off (APR projection)
        return address(new MTMAccounting(18, true, false, false, true, true, false));
    }

    function _releaseSnapshot() internal override {
        // MTMAccounting reads totalAssetsSnapshot; release the next snapshot for reconciliation
        strategy.setEpochDuration(0);
    }
}
