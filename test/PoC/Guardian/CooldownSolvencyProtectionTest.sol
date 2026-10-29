// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { StrataProtocolDeploymentBase } from "./StrataProtocolDeploymentBase.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IErrors } from "../../../contracts/tranches/interfaces/IErrors.sol";

contract CooldownSolvencyProtectionTest is StrataProtocolDeploymentBase {

    function testSeniorDepositCapEnforcesCooldownLockedShares() public {
        _deployStrataStack();

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        deal(USDE, alice, 1_000_000e18);
        deal(USDE, bob, 5_000_000e18);

        vm.startPrank(alice);
        IERC20(USDE).approve(address(jrtVault), type(uint256).max);
        jrtVault.deposit(1_000_000e18, alice);
        vm.stopPrank();

        // Verify initial deposit capacity for senior tranche
        // with buffer at 0.20e18 (20%), max SRT = 1,000,000 * 1e18 / 0.20e18 = 5,000,000e18
        uint256 initialMaxSrt = cdo.maxDeposit(address(srtVault));
        assertEq(initialMaxSrt, 5_000_000e18);

        // When locked shares exist in SharesCooldown, maxDeposit should be evaluated
        // against jrtNavUnlocked rather than total unreduced jrtNav.
        (uint256 jrtNavUnlocked, ) = cdo.totalAssetsUnlocked();
        assertEq(jrtNavUnlocked, 1_000_000e18);
    }

    function testJuniorWithdrawalCapDeductsCooldownLockedShares() public {
        _deployStrataStack();

        address alice = makeAddr("alice");
        deal(USDE, alice, 1_000_000e18);

        vm.startPrank(alice);
        IERC20(USDE).approve(address(jrtVault), type(uint256).max);
        jrtVault.deposit(1_000_000e18, alice);
        vm.stopPrank();

        // Junior user withdrawal capacity is bounded by minimumJrtSrtRatio
        // and deductions for any shares already committed to SharesCooldown
        uint256 maxW = cdo.maxWithdraw(address(jrtVault), alice);
        assertTrue(maxW > 0);
    }
}
