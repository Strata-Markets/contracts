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
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { IInsuranceMiddleware } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import { IInsuranceVault } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";
import { MockInsurancePool } from "../../symbiotic/mocks/MockInsurancePool.sol";

/// @notice Full StrataCDO + Tranches + MTMAccounting (benchmark mode, MTM projection, live pricing) on
///         MockMTMStrategy, which reports the NAV the test sets; MockInsurancePool stands in for the Symbiotic
///         middleware and slashes up to a settable capacity
contract DepegBenchmarkCapReadsMirroredLossTest is Test {
    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    MTMAccounting accounting;
    MockAprPairFeed feed;
    MockERC20 token;
    MockMTMStrategy mtmStrategy;
    MockInsurancePool pool;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address feeSafe = makeAddr("feeSafe");

    uint128 constant PRICE = 0.85e18;

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
        // 8% benchmark target, 10% base APR (SD7x12)
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp));
        // decimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection,
        // conservativePrice, mtmProjection
        accounting = MTMAccounting(address(new ERC1967Proxy(
            address(new MTMAccounting(18, true, true, false, true, false, true)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        )));
        acm.grantRole(keccak256("PAUSER_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        acm.grantRole(keccak256("RESERVE_MANAGER_ROLE"), address(this));
        mtmStrategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        mtmStrategy.setEpochDuration(1 days);
        cdo.configure(IAccounting(address(accounting)), IStrategy(address(mtmStrategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));

        // Symbiotic connected, capacity unavailable during the epoch, zero underwriter fee, zero reserve
        pool = new MockInsurancePool();
        pool.setCapacity(0);
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(0)));
        cdo.setManualUnderwriterFeeDistribution(true);
        cdo.setUnderwriterFeeRewardSafe(feeSafe);

        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
        // realized loss of 800 settles Junior at about 200, Senior held whole at about 1000
        _settleAt(1200e18);
        assertApproxEqAbs(accounting.jrtBaseNav(), 200e18, 1e15, "settled Junior about 200");
        assertApproxEqAbs(accounting.srtBaseNav(), 1000e18, 1e15, "settled Senior about 1000");

        // de-peg to 0.85: Senior needs about 176.47 of Junior's 199 headroom, no insurance needed
        cdo.setValuationKeeper(address(this));
        cdo.setValuationPrice(PRICE);
        assertEq(accounting.insuranceAmount(), 0, "Junior covers the de-peg");
    }

    function _tranche(string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(false)),
            abi.encodeWithSelector(
                Tranche.initialize.selector,
                address(this), address(acm), name, name, IERC20(address(token)), IStrataCDO(address(cdo))
            )
        )));
    }

    function _deposit(Tranche t, address user, uint256 amount) internal returns (uint256 shares) {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        shares = t.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev zero-amount fee burn triggers an accounting update
    function _poke() internal {
        vm.prank(carol);
        jrt.burnSharesAsFee(0, carol);
    }

    /// @dev settle a realized strategy NAV immediately (zero epoch), then open a long epoch
    function _settleAt(uint256 strategyNav) internal {
        mtmStrategy.setEpochDuration(0);
        vm.warp(vm.getBlockTimestamp() + 1);
        mtmStrategy.setTotalAssets(strategyNav);
        _poke();
        mtmStrategy.setEpochDuration(3650 days);
    }

    /// @dev an MTM loss of `dip` opens one hour into the epoch, then a year passes with the strategy flat
    function _runYear(uint256 dip) internal returns (uint256 benchmark) {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        if (dip > 0) {
            mtmStrategy.setTotalAssets(accounting.nav() - dip);
            _poke();
        }
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _poke();
        benchmark = accounting.srtPnLBenchmark();
    }

    function test_depegBenchmarkUsesLiveJuniorHeadroom() public {
        uint256 snap = vm.snapshotState();
        uint256 control = _runYear(0);
        assertGt(control, 18e18);
        assertLt(control, 20e18);
        vm.revertToState(snap);

        uint256 juniorLoss = _runYear(150e18);
        // Only the healthy hour before the loss can accrue; the following year has no effective headroom.
        assertLt(juniorLoss, 0.01e18);
        vm.revertToState(snap);

        uint256 seniorLoss = _runYear(300e18);
        assertEq(accounting.jrtNavProjected(), 1e18);
        assertGt(accounting.jrtBaseNav(), 300e18, "mirrored loss remains in real Junior");
        assertEq(seniorLoss, 0, "depletion interval and depleted year accrue nothing");

        pool.setCapacity(1_000_000e18);
        _settleAt(accounting.nav() - 300e18);
        uint256 realizedClaim = accounting.insuranceAmount() - accounting.srtInsuranceFundNav();
        assertApproxEqAbs(realizedClaim, 101e18, 0.01e18, "insurance covers principal, no new depleted benchmark");
    }

    function _checkPendingInterval(uint256 dip) internal {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        mtmStrategy.setTotalAssets(accounting.nav() - dip);
        _poke();
        uint256 strategyNav = accounting.nav() - dip;
        pool.setCapacity(1_000_000e18);
        uint256 snap = vm.snapshotState();
        _settleAt(strategyNav);
        uint256 seniorWithoutWait = accounting.srtBaseNav();
        uint256 claimWithoutWait = accounting.insuranceAmount();
        vm.revertToState(snap);

        // No intermediate update: reconciliation itself must cap the unpersisted year.
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _settleAt(strategyNav);
        assertApproxEqAbs(accounting.srtBaseNav(), seniorWithoutWait, 0.001e18, "pending interval adds no unsupported gain");
        assertApproxEqAbs(accounting.insuranceAmount(), claimWithoutWait, 0.001e18, "pending interval adds no insurance claim");
    }

    function test_pendingIntervalCapsJuniorAbsorbedLoss() public {
        _checkPendingInterval(150e18);
    }

    function test_pendingIntervalExcludesMirroredSeniorLoss() public {
        _checkPendingInterval(300e18);
    }

    function test_atParDepletionPreservesPriorBenchmarkAndRecoveryDoesNotBackfill() public {
        cdo.setValuationPrice(1e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _poke();
        uint256 priorBenchmark = accounting.srtPnLBenchmark();
        assertGt(priorBenchmark, 0);
        uint256 settledNav = accounting.nav();

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        mtmStrategy.setTotalAssets(settledNav - 300e18);
        _poke();
        assertEq(accounting.jrtNavProjected(), 1e18);
        assertEq(accounting.srtPnLBenchmark(), priorBenchmark, "depleting interval excluded");
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _poke();
        assertEq(accounting.srtPnLBenchmark(), priorBenchmark, "prior entitlement preserved without new accrual");

        mtmStrategy.setTotalAssets(settledNav);
        _poke();
        assertEq(accounting.srtPnLBenchmark(), priorBenchmark, "recovery does not backfill");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _poke();
        assertGt(accounting.srtPnLBenchmark(), priorBenchmark, "healthy accrual resumes");
    }
}
