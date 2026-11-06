// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { RiskPremiumStatic } from "../../../contracts/tranches/accounting/premium/RiskPremiumStatic.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";

/// @notice Policy regression derived from the Cyfrin f-62 follow-up.
///         Senior exits finalize losses; subsequent deposits do not restore that recovery entitlement.
///         Live-priced deposits share the remaining recovery, so round-trip ordering affects allocation.
/// @dev See specs/SIPs/SIP-10-mtm-projection.md, Sections 10.2 and 10.3.
///      Original auditor scenarios and numerical assertions are retained as accepted-policy checks.
///      Uses the real CDO, live-priced Tranches and MTMAccounting with MockMTMStrategy,
///      useJuniorCoversPaidSrtProjection, no benchmark, zero fees and a 1% daily floor.
contract MTMSeniorExitRecoveryPolicyTest is Test {
    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    MTMAccounting accounting;
    MockAprPairFeed feed;
    MockERC20 token;
    MockMTMStrategy mtmStrategy;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

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
        // 8% target, 10% base APR (SD7x12)
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp));
        // decimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection,
        // conservativePrice, mtmProjection
        accounting = MTMAccounting(address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, true, false, true, false, true)),
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
        accounting.setRiskModel(new RiskPremiumStatic(UD60x18.wrap(0.5e18)));

        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
        accounting.setFloorRate(0.01e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        // dip: Senior marked 995 with a projected loss of 5
        mtmStrategy.setTotalAssets(1980e18);
        _poke();
        assertEq(accounting.srtBaseNav(), 995e18, "Senior marked 995");
        assertEq(accounting.srtPnLProjected(), -5e18, "Senior projection -5");
    }

    function test_redeemFirstFinalizesLossWhileDepositFirstIsNeutral() public {
        uint256 bobShares = srt.balanceOf(bob);
        uint256 snap = vm.snapshotState();

        // control: no round trip, the mark recovers and the epoch settles flat
        (uint256 srtControl, uint256 jrtControl) = _settleFlat();
        uint256 bobControl = srt.previewRedeem(srt.balanceOf(bob));
        console2.log("control           Senior / Junior", srtControl, jrtControl);
        assertApproxEqAbs(srtControl, 1000e18, 1e6, "control Senior 1000");
        assertApproxEqAbs(jrtControl, 1000e18, 1e6, "control Junior 1000");
        vm.revertToState(snap);

        // deposit first: Bob deposits 497.5 and redeems the new shares at once, which is neutral
        uint256 newShares = _deposit(srt, bob, 497.5e18);
        uint256 out = _redeem(srt, bob, newShares);
        assertApproxEqAbs(out, 497.5e18, 2, "deposit-first round trip returns the deposit");
        (uint256 srtDepositFirst, uint256 jrtDepositFirst) = _settleFlat();
        console2.log("deposit first     Senior / Junior", srtDepositFirst, jrtDepositFirst);
        assertApproxEqAbs(srtDepositFirst, srtControl, 1e6, "deposit-first keeps Senior");
        assertApproxEqAbs(jrtDepositFirst, jrtControl, 1e6, "deposit-first keeps Junior");
        vm.revertToState(snap);

        // Redeem first: the exit finalizes its loss in Junior's favor on recovery; re-entry is a new position.
        out = _redeem(srt, bob, bobShares / 2);
        assertApproxEqAbs(out, 497.5e18, 2, "half of Senior at the live price");
        assertApproxEqAbs(accounting.srtPnLProjected(), -2.5e18, 2, "exit forfeits its share of the loss");
        _deposit(srt, bob, out);
        assertGe(srt.balanceOf(bob), bobShares, "Bob holds at least his original shares");
        assertApproxEqAbs(accounting.srtBaseNav(), 995e18, 0.05e18, "tranche NAV unchanged by the round trip");
        // Policy: purchased loss is tracked for matching future exits, not for reversing earlier finalization.
        assertApproxEqRel(accounting.srtPnLProjected(), -2.5e18, 0.02e18, "redeposit does not restore finalized Senior loss");
        (int128 boughtNet, uint128 boughtLosses) = accounting.srtBoughtProjection();
        assertApproxEqRel(int256(boughtNet), -2.5e18, 0.02e18, "purchased loss booked separately");
        assertApproxEqRel(uint256(boughtLosses), 2.5e18, 0.02e18, "unmatched purchased loss");

        (uint256 srtRedeemFirst, uint256 jrtRedeemFirst) = _settleFlat();
        uint256 bobAfter = srt.previewRedeem(srt.balanceOf(bob));
        console2.log("redeem first      Senior / Junior", srtRedeemFirst, jrtRedeemFirst);
        console2.log("Bob value, control / after round trip", bobControl, bobAfter);
        assertApproxEqAbs(srtRedeemFirst, 997.5e18, 1e6, "Senior recovers only 997.5");
        assertApproxEqAbs(jrtRedeemFirst, 1002.5e18, 1e6, "Junior keeps 2.5 of Senior's recovery");
        assertApproxEqAbs(jrtRedeemFirst - jrtControl, 2.5e18, 1e6, "accepted ordering policy leaves finalized loss recovery with Junior");
        assertApproxEqAbs(bobControl - bobAfter, 2.5e18, 1e6, "Bob loses 2.5 while holding at least his shares");
    }

    /// @dev pull the mark back to settled, then reconcile flat (+1 wei) after the epoch ends
    function _settleFlat() internal returns (uint256 srtNav, uint256 jrtNav) {
        mtmStrategy.setTotalAssets(accounting.nav());
        _poke();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        mtmStrategy.setTotalAssets(accounting.nav() + 1);
        _poke();
        assertEq(accounting.srtPnLProjected(), 0, "reconciled");
        srtNav = accounting.srtBaseNav();
        jrtNav = accounting.jrtBaseNav();
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

    function _redeem(Tranche t, address user, uint256 shares) internal returns (uint256 assets) {
        vm.prank(user);
        assets = t.redeem(shares, user, user);
    }

    /// @dev zero-amount fee burn triggers an accounting update
    function _poke() internal {
        vm.prank(carol);
        jrt.burnSharesAsFee(0, carol);
    }
}
