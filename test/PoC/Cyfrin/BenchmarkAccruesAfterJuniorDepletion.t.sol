// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { RiskPremiumPower } from "../../../contracts/tranches/accounting/premium/RiskPremiumPower.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
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

/// @notice Full StrataCDO + Tranches + MTMAccounting (benchmark mode, live pricing) on MockMTMStrategy, which stands
///         in for a real MTM strategy and reports the NAV the test sets; MockInsurancePool stands in for the
///         Symbiotic middleware and slashes up to a settable capacity
abstract contract BenchmarkDepletionBase is Test {
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

    function _implementation(bool mtmProjection) internal virtual returns (address) {
        return address(new MTMAccounting(18, true, true, false, true, false, mtmProjection));
    }

    function _usesDYS() internal pure virtual returns (bool) { return false; }

    function _deploy(bool mtmProjection) internal {
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
            _implementation(mtmProjection),
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
        accounting.setRiskModel(new RiskPremiumPower(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18)));
    }

    function _enableInsurance(uint256 capacity, uint256 underwriterFeeBps) internal {
        pool = new MockInsurancePool();
        pool.setCapacity(capacity);
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(0)));
        if (underwriterFeeBps > 0) {
            vm.prank(address(pool));
            cdo.setUnderwriterFeeBps(underwriterFeeBps);
        }
        cdo.setManualUnderwriterFeeDistribution(true);
        cdo.setUnderwriterFeeRewardSafe(feeSafe);
    }

    /// @dev settle a realized strategy NAV immediately (zero epoch), then open a long epoch
    function _settleAt(uint256 strategyNav) internal {
        // DYS uses the legacy NAV query; force its fresh-NAV branch even after a long epoch.
        mtmStrategy.setEpochDuration(_usesDYS() ? 3650 days : 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        mtmStrategy.setTotalAssets(strategyNav);
        _poke();
        mtmStrategy.setEpochDuration(_usesDYS() ? 0 : 3650 days);
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
}

/// @notice Deferred fee residue must not allow repeated benchmark accrual against the same Junior headroom.
contract BenchmarkAccruesAfterJuniorDepletionFeeResidueTest is BenchmarkDepletionBase {
    function setUp() public {
        _deploy(false);
        _enableInsurance(1_000_000e18, 0.1e18); // 10% underwriter fee
        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
    }

    function test_feeResidueCannotReuseBenchmarkHeadroom() public {
        // realized loss of 998 leaves Junior with 2 (1 token above its floor), no insurance claim
        _settleAt(1002e18);
        uint256 seniorBefore = accounting.srtBaseNav();
        uint256 headroom = accounting.jrtBaseNav() - 1e18;
        uint256 capBefore = pool.capacity();

        // two flat years
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _poke();
        uint256 b1 = accounting.srtPnLBenchmark();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _poke();
        uint256 b2 = accounting.srtPnLBenchmark();
        uint256 jrtY2 = accounting.jrtBaseNav();

        // flat settlement (+1 wei vs settled)
        _settleAt(accounting.nav() + 1);
        uint256 slashed = capBefore - pool.capacity();

        assertGt(jrtY2, 1e18, "fee residue still exists");
        assertLt(jrtY2, 1.01e18);
        assertEq(b1, headroom, "first interval limited by initial headroom");
        assertEq(b2, b1, "second interval cannot reuse reserved headroom");
        assertEq(slashed, 0, "Junior funds the capped benchmark without insurance");
        assertLe(accounting.srtBaseNav() - seniorBefore, headroom);
    }

    function test_pendingIntervalAtParIsCappedByHeadroom() public {
        _settleAt(1002e18);
        uint256 headroom = accounting.jrtBaseNav() - 1e18;
        uint256 seniorBefore = accounting.srtBaseNav();
        uint256 capacityBefore = pool.capacity();
        vm.warp(vm.getBlockTimestamp() + 2 * 365 days);
        // No projection checkpoint before reconciliation.
        _settleAt(accounting.nav() + 1);
        assertEq(pool.capacity(), capacityBefore, "pending benchmark requires no insurance");
        assertLe(accounting.srtBaseNav() - seniorBefore, headroom);
        assertGe(accounting.jrtBaseNav(), 1e18);
        assertApproxEqAbs(accounting.srtBaseNav() - seniorBefore, headroom * 95 / 100, 10);

    }
}

/// @notice MTM projection mode: a projected Senior MTM loss is mirrored into jrtBaseNav, lifting it above ONE_ASSET
///         while Junior's live and settled NAV stay at the floor, so a 1-wei downtick reopens benchmark accrual
contract BenchmarkAccruesAfterJuniorDepletionMirroredLossTest is BenchmarkDepletionBase {
    function setUp() public {
        _deploy(true);
        _enableInsurance(0, 0); // capacity unavailable until settlement, zero underwriter fee, zero reserve
        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
        // realized loss of 999 settles Junior at its floor, Senior held whole
        _settleAt(1001e18);
        assertEq(accounting.jrtBaseNav(), 1e18, "Junior at its floor");
        assertApproxEqAbs(accounting.srtBaseNav(), 1000e18, 1e12, "Senior held whole");
    }

    function _run(uint256 dip) internal returns (uint256 benchmark, uint256 slashed, uint256 seniorGain) {
        uint256 seniorBefore = accounting.srtBaseNav();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        if (dip > 0) {
            mtmStrategy.setTotalAssets(accounting.nav() - dip);
            _poke();
        }
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _poke();
        benchmark = accounting.srtPnLBenchmark();
        // insurance capacity becomes available, strategy settles flat (+1 wei vs settled)
        pool.setCapacity(1_000_000e18);
        _settleAt(accounting.nav() + 1);
        slashed = 1_000_000e18 - pool.capacity();
        seniorGain = accounting.srtBaseNav() - seniorBefore;
    }

    function test_mirroredLossDoesNotReopenBenchmarkAccrual() public {
        uint256 snap = vm.snapshotState();
        (uint256 bControl, uint256 sControl,) = _run(0);
        vm.revertToState(snap);

        (uint256 b, uint256 s, uint256 g) = _run(1);

        // control: depleted Junior accrues no benchmark and nothing is slashed
        assertEq(bControl, 0, "control accrues no benchmark");
        assertEq(sControl, 0, "control slashes nothing");
        // The current fix closes the mirrored-loss case.
        assertEq(b, 0, "a 1-wei MTM downtick must not reopen the gate");
        assertEq(s, 0, "no depleted-year benchmark is insured");
    }
}

contract DYSBenchmarkAfterDepletionFeeResidueTest is BenchmarkAccruesAfterJuniorDepletionFeeResidueTest {
    function _usesDYS() internal pure override returns (bool) { return true; }
    function _implementation(bool) internal override returns (address) {
        return address(new DYSAccounting(18, true, true, false, true, false));
    }
}
