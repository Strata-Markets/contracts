// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { console } from "forge-std/Test.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { CDOTest } from "../../CDO.t.sol";

/// @notice Regression adapted from Cyfrin f-39: rounded exit fees must keep maximum withdrawals executable.
/// @dev Repo CDOTest fixture: real StrataCDO, Tranches, Accounting and sUSDeStrategy over MockStakedUSDe
contract MaxWithdrawGrossExceedsBalanceTest is CDOTest {
    function _deposit(IERC4626 vault, address user, uint256 amount) internal returns (uint256 shares) {
        USDe.mint(user, amount);
        vm.startPrank(user);
        USDe.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    function test_maxWithdrawFitsBalanceAndExecutes() public {
        vm.stopPrank(); // CDOTest.setUp leaves the owner prank active
        vm.startPrank(cdo.owner());
        cdo.setTwoStepConfigManager(cdo.owner());
        cdo.setExitFees(0.001e18, 0); // 0.1% Junior exit fee
        // Settle synchronously so this regression also verifies the received assets.
        sUSDe.setCooldownDuration(0);
        vm.stopPrank();

        address alice = makeAddr("alice");
        _deposit(jrtVault, makeAddr("bob"), 100e18);
        _deposit(srtVault, makeAddr("carol"), 100e18);
        uint256 balance = _deposit(jrtVault, alice, 1e18 + 999);

        uint256 maxAssets = jrtVault.maxWithdraw(alice);
        uint256 grossShares = jrtVault.previewWithdraw(maxAssets);
        console.log("balance", balance);
        console.log("maxWithdraw", maxAssets);
        console.log("previewWithdraw(maxWithdraw)", grossShares);
        assertLe(grossShares, balance, "advertised maximum fits the holder's shares");
        assertGt(jrtVault.previewWithdraw(maxAssets + 1), balance, "one more asset exceeds the share balance");

        uint256 beforeAssets = USDe.balanceOf(alice);
        vm.prank(alice);
        uint256 burned = jrtVault.withdraw(maxAssets, alice, alice);
        assertEq(burned, grossShares, "execution matches preview");
        assertEq(USDe.balanceOf(alice) - beforeAssets, maxAssets);
        assertEq(jrtVault.balanceOf(alice), balance - burned);
    }

    function test_tinyExitRoundsFeeUp() public {
        vm.stopPrank();
        _deposit(jrtVault, makeAddr("seed"), 100e18);
        assertEq(jrtVault.quoteRedeem(1, 0.001e18), 0, "one share pays one share of rounded fee");
        assertEq(jrtVault.quoteWithdraw(1, 0.001e18), 2, "one net share requires an additional fee share");
        assertEq(jrtVault.quoteRedeem(1, 0), 1, "zero fee remains exact");
        assertEq(jrtVault.quoteWithdraw(1, 0), 1, "zero fee remains exact");
    }

    function testFuzz_quotesRespectShareBudget(uint256 shares, uint256 assets, uint256 fee, uint256 nav) public {
        vm.stopPrank();
        _deposit(jrtVault, makeAddr("seed"), 100e18);
        shares = bound(shares, 0, 1e30);
        assets = bound(assets, 0, 1e30);
        fee = bound(fee, 0, 0.5e18);
        nav = bound(nav, 1, 1e30);
        // Exercise fractional prices independently of strategy accrual and ratio limits.
        vm.mockCall(address(cdo), abi.encodeWithSignature("totalAssets(address)", address(jrtVault)), abi.encode(nav));
        vm.mockCall(address(cdo), abi.encodeWithSignature("totalAssetsRedeemable(address)", address(jrtVault)), abi.encode(nav));

        uint256 redeemable = jrtVault.quoteRedeem(shares, fee);
        assertLe(jrtVault.quoteWithdraw(redeemable, fee), shares, "redeem output fits its original share budget");
        assertGt(jrtVault.quoteWithdraw(redeemable + 1, fee), shares, "next asset requires more shares");
        uint256 required = jrtVault.quoteWithdraw(assets, fee);
        assertGe(jrtVault.quoteRedeem(required, fee), assets, "withdraw input covers requested output");
    }

}
