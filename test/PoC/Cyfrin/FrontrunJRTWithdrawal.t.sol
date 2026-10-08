// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CDOTest } from "../../CDO.t.sol";
import { IErrors } from "../../../contracts/tranches/interfaces/IErrors.sol";

/// @notice Regression for the Cyfrin "frontrun JRT withdrawal" finding.
/// @dev Originally an SRT deposit could push the JRT/SRT ratio to the hard floor and zero JRT maxWithdraw.
///      Fix: SRT deposits stop at `minimumJrtSrtRatioBuffer` (6%), above the JRT exit floor `minimumJrtSrtRatio` (5%).
///      So at max SRT, JRT keeps `jrt * (1 - 5/6) = jrt / 6` withdrawable. A frontrun can still shrink the headroom,
///      but it can no longer zero it.
contract FrontrunJRTWithdrawal is CDOTest {

    function test_FrontrunJRTWithdrawal() public {
        address victim = address(0x1234);
        address attacker = address(0x5678);
        address initialDepositor = address(0x9999);

        uint256 initialJRTDeposit = 100 ether;
        uint256 initialSRTDeposit = 1000 ether;
        uint256 attackDepositAmount = 1000 ether; // Used to be enough to zero JRT maxWithdraw

        vm.startPrank(victim);
        USDe.mint(victim, initialJRTDeposit);
        USDe.approve(address(jrtVault), initialJRTDeposit);
        jrtVault.deposit(initialJRTDeposit, victim);
        vm.stopPrank();

        vm.startPrank(initialDepositor);
        USDe.mint(initialDepositor, initialSRTDeposit);
        USDe.approve(address(srtVault), initialSRTDeposit);
        srtVault.deposit(initialSRTDeposit, initialDepositor);
        vm.stopPrank();

        assertGt(accounting.maxWithdraw(true), 0, "JRT should be withdrawable before the attack");

        vm.startPrank(attacker);
        USDe.mint(attacker, attackDepositAmount);
        USDe.approve(address(srtVault), attackDepositAmount);

        // The original attack size is now rejected by the SRT deposit buffer
        vm.expectRevert(abi.encodeWithSelector(IErrors.DepositCapReached.selector, address(srtVault)));
        srtVault.deposit(attackDepositAmount, attacker);

        // The strongest frontrun left is filling SRT up to the cap
        uint256 maxSrtDeposit = accounting.maxDeposit(false);
        assertGt(maxSrtDeposit, 0, "SRT should still accept some deposits");
        assertLt(maxSrtDeposit, attackDepositAmount, "Cap should be below the original attack size");
        srtVault.deposit(maxSrtDeposit, attacker);
        vm.stopPrank();

        assertEq(accounting.maxDeposit(false), 0, "SRT should be at the cap");

        // JRT exit is not zeroed: about jrt / 6 stays withdrawable
        uint256 jrtNav = accounting.jrtNav();
        uint256 postMaxWithdraw = accounting.maxWithdraw(true);
        assertGt(postMaxWithdraw, 0, "Frontrun must not zero JRT maxWithdraw");
        assertApproxEqRel(postMaxWithdraw, jrtNav / 6, 0.001e18, "JRT headroom should be about jrt / 6");

        // And the victim can actually use that headroom
        uint256 victimBalanceBefore = jrtVault.balanceOf(victim);
        vm.prank(victim);
        jrtVault.withdraw(postMaxWithdraw, victim, victim);
        assertLt(jrtVault.balanceOf(victim), victimBalanceBefore, "Victim withdrawal should go through");
    }
}
