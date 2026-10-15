// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {NestOpalDeploy} from "./NestOpalDeploy.t.sol";
import {StrataCDO} from "../../contracts/tranches/StrataCDO.sol";

contract ShortfallCheckTest is NestOpalDeploy {
    address internal junior = makeAddr("junior");
    address internal senior = makeAddr("senior");
    address internal entrant = makeAddr("entrant");

    function setUp() public override {
        super.setUp();
        _deployNestOpalStack();
        _mintNOpal(junior, 1000 * ONE_NOPAL);
        _mintNOpal(senior, 5000 * ONE_NOPAL);
        _mintNOpal(entrant, 1000 * ONE_NOPAL);
        _depositToJrt(junior, 1000 * ONE_NOPAL);
        _depositToSrt(senior, 5000 * ONE_NOPAL);
        vm.startPrank(entrant);
        nOpal.approve(address(jrtVault), type(uint256).max);
        nOpal.approve(address(srtVault), type(uint256).max);
        vm.stopPrank();
    }

    function _lose() internal {
        nestAccountant.setExchangeRate(INITIAL_RATE * 70 / 100);
    }

    function _bookLoss() internal {
        _lose();
        // Accounting-only updates must succeed without pausing either tranche.
        jrtVault.burnSharesAsFee(0, address(this));
        assertLe(cdo.pricePerShare(address(jrtVault)), cdo.jrtShortfallPausePrice());
        (bool jrtEnabled,) = cdo.actionsJrt();
        (bool srtEnabled,) = cdo.actionsSrt();
        assertTrue(jrtEnabled);
        assertTrue(srtEnabled);
    }

    function test_FirstDepositAfterLossRevertsAndRollsBack() public {
        _lose();
        uint256 navBefore = accounting.nav();
        uint256 supplyBefore = jrtVault.totalSupply();
        uint256 tokensBefore = nOpal.balanceOf(entrant);
        vm.expectPartialRevert(StrataCDO.Shortfall.selector);
        vm.prank(entrant);
        jrtVault.deposit(address(nOpal), 1000 * ONE_NOPAL, entrant);
        assertEq(accounting.nav(), navBefore, "accounting update rolled back");
        assertEq(jrtVault.totalSupply(), supplyBefore, "mint rolled back");
        assertEq(nOpal.balanceOf(entrant), tokensBefore, "transfer rolled back");
        _bookLoss();
    }

    function test_MintBelowThresholdReverts() public {
        _bookLoss();
        vm.expectPartialRevert(StrataCDO.Shortfall.selector);
        vm.prank(entrant);
        jrtVault.mint(address(nOpal), 1 ether, entrant);
    }

    function test_ReenablingActionsDoesNotBypassCheck() public {
        _bookLoss();
        vm.prank(owner);
        cdo.setActionStates(address(jrtVault), true, true);
        vm.expectPartialRevert(StrataCDO.Shortfall.selector);
        vm.prank(entrant);
        jrtVault.deposit(address(nOpal), ONE_NOPAL, entrant);
    }

    function test_SeniorRedemptionAllowedBelowThreshold() public {
        _bookLoss();
        uint256 shares = srtVault.balanceOf(senior) / 10;
        vm.prank(senior);
        srtVault.redeem(address(nOpal), shares, senior, senior);
        assertGt(nOpal.balanceOf(senior), 0);
        assertLe(cdo.pricePerShare(address(jrtVault)), cdo.jrtShortfallPausePrice());
    }

    function _restoreCoverageWithSeniorExit() internal {
        _bookLoss();
        uint256 shares = srtVault.balanceOf(senior) - 1 ether;
        vm.prank(senior);
        srtVault.redeem(address(nOpal), shares, senior, senior);
        assertGt(accounting.maxDeposit(false), ONE_USDC, "coverage permits a Senior deposit");
    }

    function test_SeniorDepositRejectedEvenWithSufficientCoverage() public {
        _restoreCoverageWithSeniorExit();
        uint256 jrtPrice = cdo.pricePerShare(address(jrtVault));
        vm.expectRevert(abi.encodeWithSelector(StrataCDO.Shortfall.selector, jrtPrice));
        vm.prank(entrant);
        srtVault.deposit(address(nOpal), ONE_NOPAL, entrant);
    }

    function test_JuniorRedemptionBelowThresholdReverts() public {
        _restoreCoverageWithSeniorExit();
        uint256 shares = jrtVault.balanceOf(junior) / 10;
        vm.expectPartialRevert(StrataCDO.Shortfall.selector);
        vm.prank(junior);
        jrtVault.redeem(address(nOpal), shares, junior, junior);
    }

    function test_RecoveryAllowsDepositsWithoutUnpausing() public {
        _bookLoss();
        nestAccountant.setExchangeRate(INITIAL_RATE);
        vm.prank(entrant);
        jrtVault.deposit(address(nOpal), ONE_NOPAL, entrant);
        assertGt(jrtVault.balanceOf(entrant), 0);
    }

    function test_LoweringThresholdAllowsExplicitRecapitalization() public {
        _bookLoss();
        vm.prank(owner);
        cdo.setJrtShortfallPausePrice(0);
        vm.prank(entrant);
        jrtVault.deposit(address(nOpal), ONE_NOPAL, entrant);
        assertGt(jrtVault.balanceOf(entrant), 0);
    }
}
