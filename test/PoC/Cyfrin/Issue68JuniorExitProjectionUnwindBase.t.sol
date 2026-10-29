// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISharesCooldown} from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
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
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";

/// @notice Real StrataCDO + two conservative-price Tranches on an APR-projected accounting, parameters of
///         test/tranches/accounting/dys/ConservativePrice.spec.ts: Junior 1,000, Senior 1,000, base APR 10%,
///         Senior target 5%, risk premium 50%, one year of APR projection with no reconciliation
/// @dev Regression: exits remove only the redeemed shares' own Junior projection, preserving live PPS.
abstract contract ConservativeJuniorExitBase is Test {
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    MockAprPairFeed feed;
    MockMTMStrategy strategy;
    MockERC20 token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    /// @dev Deploys the accounting variant under test
    function _deployAccounting() internal virtual returns (IAccounting);

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
        // 5% Senior target, 10% base APR (SD7x12)
        feed.updateRoundData(50_000_000_000, 100_000_000_000, uint64(block.timestamp));

        acm.grantRole(PAUSER_ROLE, address(this));
        acm.grantRole(UPDATER_FEED_ROLE, address(this));
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, address(this));

        IAccounting accounting = _deployAccounting();

        strategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        // Strategy NAV stays flat so every update is an APR projection, no reconciliation
        strategy.setEpochDuration(3650 days);

        cdo.configure(accounting, IStrategy(address(strategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        // Risk premium 50%: aprSrt = max(5%, 10% * 0.5) = 5% (same signature in both variants)
        DYSAccounting(address(accounting)).setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));

        _deposit(jrt, alice, 500e18);
        _deposit(jrt, bob, 250e18);
        _deposit(jrt, carol, 250e18);
        _deposit(srt, dave, 1_000e18);
    }

    function _run() internal {
        vm.warp(vm.getBlockTimestamp() + 365 days);

        // Junior live 1.15 and settled 1.00
        uint256 liveBefore = cdo.pricePerShare(address(jrt));
        uint256 settledBefore = cdo.pricePerShareSettled(address(jrt));
        uint256 sharesPerDepositBefore = jrt.previewDeposit(1_000e18);
        console.log("Junior live / settled price before exits", liveBefore, settledBefore);
        assertGt(liveBefore, settledBefore, "one year of projection above settled");

        // Alice redeems half of Junior at the settled price
        uint256 aliceShares = jrt.balanceOf(alice);
        uint256 aliceOut = _redeem(jrt, alice, aliceShares);
        assertEq(aliceOut, aliceShares * settledBefore / 1e18, "Alice paid the settled price");

        // Removing only Alice's own projection would leave the remaining Juniors' live price unchanged
        uint256 liveAfterAlice = cdo.pricePerShare(address(jrt));
        uint256 sharesPerDepositAfter = jrt.previewDeposit(1_000e18);
        console.log("Junior live price after Alice", liveAfterAlice);
        console.log("Junior shares per 1,000 deposit before / after", sharesPerDepositBefore, sharesPerDepositAfter);
        assertApproxEqAbs(liveAfterAlice, liveBefore, 1, "Alice exit preserves live PPS");
        assertEq(cdo.pricePerShareSettled(address(jrt)), settledBefore, "settled price unchanged");
        assertApproxEqAbs(sharesPerDepositAfter, sharesPerDepositBefore, 1, "deposit quote unchanged");
        uint256 snapshot = vm.snapshotState();
        assertApproxEqAbs(_deposit(jrt, dave, 1_000e18), sharesPerDepositBefore, 1, "actual deposit mints fair shares");
        vm.revertToState(snapshot);

        // Repeated exits must preserve the remaining holders' live price.
        uint256 bobShares = jrt.balanceOf(bob);
        uint256 bobOut = _redeem(jrt, bob, bobShares);
        assertEq(bobOut, bobShares * settledBefore / 1e18, "Bob paid the settled price");
        uint256 liveAfterBob = cdo.pricePerShare(address(jrt));
        console.log("Junior live price after Bob", liveAfterBob);
        assertApproxEqAbs(liveAfterBob, liveBefore, 1, "Bob exit preserves live PPS");

        // Carol still receives the full settled value.
        uint256 carolShares = 100e18;
        uint256 carolSettledValue = carolShares * cdo.pricePerShareSettled(address(jrt)) / 1e18;
        uint256 carolOut = _redeem(jrt, carol, carolShares);
        console.log("Carol paid / settled value for 100 shares", carolOut, carolSettledValue);
        assertEq(carolOut, carolSettledValue, "Carol paid settled NAV");
        assertApproxEqAbs(cdo.pricePerShare(address(jrt)), liveBefore, 1, "Carol exit preserves live PPS");
    }

    function test_ExitWithoutProjection() public {
        uint256 price = cdo.pricePerShare(address(jrt));
        assertEq(_redeem(jrt, alice, 500e18), 500e18);
        assertEq(cdo.pricePerShare(address(jrt)), price);
        assertEq(cdo.pricePerShareSettled(address(jrt)), price);
    }

    function _checkDepegProjection(bool seniorExit) internal {
        vm.warp(vm.getBlockTimestamp() + 365 days);
        DYSAccounting acc = DYSAccounting(address(cdo.accounting()));
        vm.prank(address(cdo));
        acc.setValuationPrice(0.8e18);
        acc.setValuationGracePeriod(0);
        uint256 juniorLiveBefore = cdo.pricePerShare(address(jrt));
        uint256 juniorSettledBefore = cdo.pricePerShareSettled(address(jrt));
        console.log("depeg Junior live / settled before", juniorLiveBefore, juniorSettledBefore);
        if (seniorExit) {
            _redeem(srt, dave, 500e18);
        } else {
            assertEq(_redeem(jrt, alice, 500e18), 375e18);
        }
        uint256 juniorLiveAfter = cdo.pricePerShare(address(jrt));
        console.log("depeg Junior live after", juniorLiveAfter);
        if (seniorExit) {
            // Half of Senior's 50 projection is forfeited. Its 6.25 valuation top-up is released to Junior.
            assertEq(juniorLiveAfter, 0.89375e18, "Senior exit does not forfeit Junior projection");
        } else {
            assertEq(juniorLiveAfter, juniorLiveBefore, "Junior exit preserves live PPS during depeg");
            assertEq(_redeem(jrt, bob, 250e18), 187.5e18);
            assertEq(cdo.pricePerShare(address(jrt)), juniorLiveBefore, "repeated exit preserves live PPS");
            assertEq(cdo.pricePerShareSettled(address(jrt)), juniorSettledBefore);
            // Keep the final exit within the configured Junior coverage limit.
            assertEq(_redeem(jrt, carol, 50e18), 37.5e18);
            assertEq(cdo.pricePerShare(address(jrt)), juniorLiveBefore);
        }
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

    function _deposit(Tranche t, address user, uint256 amount) internal returns (uint256 shares) {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        shares = t.deposit(amount, user);
        vm.stopPrank();
    }

    function _redeem(Tranche t, address user, uint256 shares) internal returns (uint256 assets) {
        vm.prank(user);
        assets = t.redeem(shares, user, user);
    }
}

/// @notice DYSAccounting with conservative pricing
contract ConservativeJuniorExitPreservesProjectionDYSTest is ConservativeJuniorExitBase {
    function _deployAccounting() internal override returns (IAccounting) {
        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice
        DYSAccounting accounting = DYSAccounting(address(new ERC1967Proxy(
            address(new DYSAccounting(18, false, false, false, true, true)),
            abi.encodeWithSelector(
                DYSAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        )));
        return IAccounting(address(accounting));
    }

    function test_DepegJuniorProjectionFraction() public {
        _checkDepegProjection(false);
    }

    function test_DepegSeniorExitPreservesJuniorProjection() public {
        _checkDepegProjection(true);
    }

    function test_PoC_ConservativeJuniorExitPreservesProjection_DYS() public {
        _run();
    }
}

/// @notice MTMAccounting with conservative pricing and useMTMProjection = false (APR-indexed projection, SIP-10)
contract ConservativeJuniorExitPreservesProjectionMTMTest is ConservativeJuniorExitBase {
    function _deployAccounting() internal override returns (IAccounting) {
        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice, mtmProjection
        MTMAccounting accounting = MTMAccounting(address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, false, false, true, true, false)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        )));
        return IAccounting(address(accounting));
    }

    function test_DepegJuniorProjectionFraction() public {
        _checkDepegProjection(false);
    }

    function test_DepegSeniorExitPreservesJuniorProjection() public {
        _checkDepegProjection(true);
    }

    function test_PoC_ConservativeJuniorExitPreservesProjection_MTMWithoutMTMProjection() public {
        _run();
    }
}

/// @notice MTM reprices assets retained by the strategy after a conservative exit.
contract ConservativeJuniorExitLiveMTMTest is ConservativeJuniorExitBase {
    function _deployAccounting() internal override returns (IAccounting) {
        return IAccounting(address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, true, false, true, true, true)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        )));
    }

    function test_LiveMTMRetainsUnpaidGainWithoutDoubleCounting() public {
        vm.warp(vm.getBlockTimestamp() + 365 days);
        token.mint(address(strategy), 200e18);
        strategy.setTotalAssets(2200e18);
        uint256 liveBefore = cdo.pricePerShare(address(jrt));
        assertEq(liveBefore, 1.15e18);
        assertEq(cdo.pricePerShareSettled(address(jrt)), 1e18);

        assertEq(_redeem(jrt, alice, 500e18), 500e18);
        assertEq(strategy.totalAssetsValue(), 1700e18, "unpaid gain stays in strategy");
        uint256 liveAfter = cdo.pricePerShare(address(jrt));
        assertEq(liveAfter, 1.3e18, "remaining 500 shares own 650 live assets");
        assertEq(cdo.pricePerShare(address(srt)), 1.05e18);
        assertEq(jrt.totalSupply() * liveAfter / 1e18 + srt.totalSupply() * cdo.pricePerShare(address(srt)) / 1e18, 1700e18);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(address(jrt));
            cdo.updateAccounting();
            assertEq(cdo.pricePerShare(address(jrt)), liveAfter, "repeated updates do not compound gain");
        }
        assertApproxEqAbs(jrt.previewDeposit(1000e18), 1000e18 * 1e18 / liveAfter, 1);

        // Settle the same strategy NAV without another interval of accrual.
        strategy.setEpochDuration(0);
        vm.prank(address(jrt));
        cdo.updateAccounting();
        assertEq(cdo.pricePerShare(address(jrt)), liveAfter, "reconciliation preserves live allocation");
        assertEq(cdo.pricePerShareSettled(address(jrt)), liveAfter);
    }
}
