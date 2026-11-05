// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
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
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";

/// @notice Non-conservative markets (Tranche(false), conservativePrice=false) with no insurance configured
///         While Junior has an open gain (jrtNavProjected > jrtBaseNav) and the de-peg exceeds Junior's settled
///         headroom, Senior exits are priced on live Junior NAV (totalAssets -> jrtNavProjected) but
///         live pricing must use the same settled backing as the withdrawal split.
import {RiskPremiumStatic} from "../../../contracts/tranches/accounting/premium/RiskPremiumStatic.sol";

contract DepegExitOpenJuniorGainSplitTest is Test {
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    IAccounting accounting;
    MockAprPairFeed feed;
    MockERC20 token;
    MockMTMStrategy strategy;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function test_MTMOpenJuniorGainIsNotSeniorBacking() public {
        _deployCore(80_000_000_000, 100_000_000_000);
        _configure(address(new MTMAccounting(18, false, true, false, false, false, true)), MTMAccounting.initialize.selector, 1 days);
        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 4500e18);
        _deposit(srt, carol, 4500e18);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        strategy.setTotalAssets(strategy.totalAssets() + 200e18);
        _poke();
        cdo.setValuationPrice(0.5e18);
        _poke(); // Apply valuation scaling before comparing flow-neutrality.
        _checkHalfExit();
    }

    function test_DYSOpenJuniorGainIsNotSeniorBacking() public {
        vm.warp(1_790_000_000);
        _deployCore(80_000_000_000, 100_000_000_000);
        _configure(address(new DYSAccounting(18, false, true, false, true, false)), DYSAccounting.initialize.selector, 3650 days);
        _deposit(jrt, alice, 100_000e18);
        _deposit(srt, bob, 450_000e18);
        _deposit(srt, carol, 450_000e18);
        vm.warp(block.timestamp + 7 days);
        _poke();
        cdo.setValuationPrice(0.85e18);
        _checkHalfExit();
    }

    function _checkHalfExit() internal {
        _checkPendingReconciliation();
        DYSAccounting a = DYSAccounting(address(accounting)); // Common getter ABI.
        uint256 junior = a.jrtBaseNav();
        uint256 projected = a.jrtNavProjected();
        uint256 senior = a.srtBaseNav();
        assertGt(projected, junior, "open Junior gain");
        (uint256 juniorLive, uint256 seniorLive,) = accounting.totalAssets();
        assertEq(seniorLive, senior + junior - 1e18, "Senior uses only settled Junior headroom");
        assertEq(juniorLive, projected - junior + 1e18, "Junior keeps its open gain");
        assertEq(juniorLive + seniorLive, projected + senior, "live NAV conserved");
        (uint256 combinedJunior, uint256 combinedSenior,,) = accounting.totalAssetsLiveAndSettled();
        assertEq(combinedJunior, juniorLive);
        assertEq(combinedSenior, seniorLive);
        uint256 bobShares = srt.balanceOf(bob);
        uint256 quoted = srt.previewRedeem(bobShares);
        vm.prank(bob);
        uint256 paid = srt.redeem(bobShares, bob, bob);
        assertEq(paid, quoted);
        assertApproxEqAbs(paid, seniorLive / 2, 2);
        assertApproxEqAbs(a.srtBaseNav(), senior / 2, 2, "remaining Senior keeps half its base NAV");

        uint256 snap = vm.snapshotState();
        int256 settledRemaining = int256(a.srtBaseNav()) - a.srtPnLProjected() + int256(a.srtPaidProjected());
        cdo.setValuationPrice(1e18);
        _poke(); // Live MTM gain is no longer valuation-scaled after repeg.
        assertApproxEqAbs(int256(a.srtBaseNav()) - a.srtPnLProjected() + int256(a.srtPaidProjected()), settledRemaining, 2, "repeg preserves settled principal");
        assertApproxEqAbs(srt.previewRedeem(srt.balanceOf(carol)), a.srtBaseNav(), 2, "remaining holder owns all Senior NAV");
        vm.revertToState(snap);

        _poke();
        uint256 remainingShares = srt.balanceOf(carol);
        uint256 exitShares = remainingShares - 1e18; // Keep the minimum supply.
        assertGe(srt.maxRedeem(carol), exitShares, "maximum no longer strands valuable shares");
        uint256 expectedPaid = srt.previewRedeem(exitShares);
        uint256 expectedLeft = srt.previewRedeem(1e18);
        vm.prank(carol);
        assertEq(srt.redeem(exitShares, carol, carol), expectedPaid);
        assertApproxEqAbs(srt.previewRedeem(srt.balanceOf(carol)), expectedLeft, 10, "remaining shares retain proportional value");
    }

    function _checkPendingReconciliation() internal {
        uint256 snap = vm.snapshotState();
        strategy.setEpochDuration(0);
        strategy.updateTotalAssets(strategy.totalAssets() + 200e18);
        (uint256 juniorPreview, uint256 seniorPreview,) = accounting.totalAssets();
        (uint256 combinedJunior, uint256 combinedSenior,,) = accounting.totalAssetsLiveAndSettled();
        assertEq(combinedJunior, juniorPreview);
        assertEq(combinedSenior, seniorPreview);
        _poke();
        (uint256 juniorAfter, uint256 seniorAfter,) = accounting.totalAssets();
        assertApproxEqAbs(juniorPreview, juniorAfter, 2, "preview uses newly settled Junior backing");
        assertApproxEqAbs(seniorPreview, seniorAfter, 2);
        vm.revertToState(snap);
    }

    function _deployCore(int64 aprTarget, int64 aprBase) internal {
        token = new MockERC20("BASE", 18);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(IERC20Metadata(address(token)), ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche("JRT");
        srt = _tranche("SRT");
        feed = new MockAprPairFeed();
        feed.updateRoundData(aprTarget, aprBase, uint64(block.timestamp));
        acm.grantRole(PAUSER_ROLE, address(this));
        acm.grantRole(UPDATER_FEED_ROLE, address(this));
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, address(this));
        acm.grantRole(RESERVE_MANAGER_ROLE, address(this));
    }

    function _configure(address accountingImpl, bytes4 initSelector, uint256 epoch) internal {
        accounting = IAccounting(address(new ERC1967Proxy(
            accountingImpl,
            abi.encodeWithSelector(
                initSelector, address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        )));
        strategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        strategy.setEpochDuration(epoch);
        cdo.configure(accounting, IStrategy(address(strategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        // constant 50% risk premium
        MTMAccounting(address(accounting)).setRiskModel(new RiskPremiumStatic(UD60x18.wrap(0.5e18)));
        cdo.setValuationKeeper(address(this));
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

    function _deposit(Tranche t, address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        t.deposit(amount, user);
        vm.stopPrank();
    }

    /// permissionless zero-share fee burn that runs the accounting update
    function _poke() internal {
        address poker = makeAddr("poker");
        vm.prank(poker);
        jrt.burnSharesAsFee(0, poker);
    }
}
