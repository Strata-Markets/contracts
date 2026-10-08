// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CDOTest } from "../../CDO.t.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ICooldown } from "../../../contracts/tranches/interfaces/cooldown/ICooldown.sol";

/// @notice Regression for the Cyfrin "unstake requests DoS" finding.
/// @dev Originally anyone could spam tiny withdrawals to a victim and grow their activeRequests array until
///      finalize() ran out of gas. Fix in UnstakeCooldown.transfer:
///      - requests created in the same block reuse the last request (no new slot)
///      - third parties (initialFrom != to) are capped at PUBLIC_REQUEST_SLOTS_CAP (40) slots per receiver
contract TrancheMaxMintTest is CDOTest {
    uint256 constant PUBLIC_REQUEST_SLOTS_CAP = 40;

    function test_DoSUserActiveRequests() public {
        address alice = makeAddr("Alice");
        address bob = makeAddr("Bob");

        uint256 initialDeposit = 1000 ether;
        USDe.mint(alice, initialDeposit);
        USDe.mint(bob, initialDeposit);

        vm.startPrank(alice);
        USDe.approve(address(jrtVault), type(uint256).max);
        jrtVault.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        USDe.approve(address(jrtVault), type(uint256).max);
        jrtVault.deposit(initialDeposit, bob);
        vm.stopPrank();

        // Alice requests to withdraw her full USDe balance
        uint256 totalWithdrawableAssets = jrtVault.maxWithdraw(alice);
        vm.prank(alice);
        jrtVault.withdraw(totalWithdrawableAssets, alice, alice);
        assertEq(_totalRequests(alice), 1, "Alice should have one request");

        // 1) Same-block spam reuses Alice's last request, no new slots
        vm.pauseGasMetering();
        for (uint256 i = 0; i < 100; i++) {
            vm.prank(bob);
            jrtVault.withdraw(1, alice, bob);
        }
        vm.resumeGasMetering();
        assertEq(_totalRequests(alice), 1, "Same-block spam must not add request slots");

        // 2) Cross-block spam from a third party stops at the public cap
        vm.pauseGasMetering();
        for (uint256 i = _totalRequests(alice); i < PUBLIC_REQUEST_SLOTS_CAP; i++) {
            vm.warp(block.timestamp + 1);
            vm.prank(bob);
            jrtVault.withdraw(1, alice, bob);
        }
        vm.resumeGasMetering();
        assertEq(_totalRequests(alice), PUBLIC_REQUEST_SLOTS_CAP, "Spam should fill exactly the public cap");

        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        vm.expectPartialRevert(ICooldown.ExternalReceiverRequestLimitReached.selector);
        jrtVault.withdraw(1, alice, bob);

        // 3) Alice can still finalize everything once the cooldown is over
        skip(1_000_000);
        uint256 aliceUSDeBefore = USDe.balanceOf(alice);
        vm.prank(alice);
        unstakeCooldown.finalize(sUSDe, alice);

        assertEq(_totalRequests(alice), 0, "All requests should be finalized");
        assertGe(USDe.balanceOf(alice) - aliceUSDeBefore, totalWithdrawableAssets, "Alice should receive her USDe");
    }

    function _totalRequests(address user) internal view returns (uint256) {
        ICooldown.TBalanceState memory state = unstakeCooldown.balanceOf(IERC20(address(sUSDe)), user);
        return state.totalRequests;
    }
}
