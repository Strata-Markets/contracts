// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { stdStorage, StdStorage } from "forge-std/StdStorage.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CDOTest } from "../../CDO.t.sol";

/// @notice Regression adapted from Cyfrin f-48: token maxima must round down to stay within the base cap.
/// @dev Repo CDOTest fixture: real StrataCDO, Tranches, Accounting and sUSDeStrategy over MockStakedUSDe
contract TokenMaxWithdrawRoundsUpTest is CDOTest {
    using stdStorage for StdStorage;
    function _depositJunior(address user, uint256 amount) internal {
        USDe.mint(user, amount);
        vm.startPrank(user);
        USDe.approve(address(jrtVault), amount);
        jrtVault.deposit(address(USDe), amount, user);
        vm.stopPrank();
    }

    function test_tokenMaxWithdrawFitsBaseCapAndExecutes() public {
        vm.stopPrank(); // CDOTest.setUp leaves the owner prank active

        // The shared fixture deploys ERC20Cooldown without initializing its access-control manager.
        // Supply that fixture dependency so the corrected withdrawal can reach the actual token transfer.
        stdstore.target(address(erc20Cooldown)).sig("acm()").checked_write(address(acm));

        // Non-integral sUSDe price (~1.37): 1000 shares backed by 1370 USDe + 123456789 wei
        USDe.mint(address(this), 1000e18);
        USDe.approve(address(sUSDe), 1000e18);
        sUSDe.deposit(1000e18, address(this));
        USDe.mint(address(sUSDe), 370e18 + 123456789);

        address dave = makeAddr("dave");
        _depositJunior(makeAddr("alice"), 1000e18);
        _depositJunior(dave, 1003000000000023757);

        uint256 cap = jrtVault.maxWithdraw(dave);
        uint256 tokenMax = jrtVault.maxWithdraw(address(sUSDe), dave);
        uint256 tokenMaxInBase = sUSDeStrategy.convertToAssets(address(sUSDe), tokenMax, Math.Rounding.Floor);
        assertEq(cap, 1003000000000023756);
        assertEq(tokenMax, 732116788321119249);
        assertLe(tokenMaxInBase, cap, "floor-rounded maximum stays within the base cap");
        assertGt(sUSDeStrategy.convertToAssets(address(sUSDe), tokenMax + 1, Math.Rounding.Floor), cap,
            "rounding up would exceed the base cap");
        uint256 sharesBefore = jrtVault.balanceOf(dave);
        uint256 tokensBefore = sUSDe.balanceOf(dave);
        vm.prank(dave);
        uint256 burned = jrtVault.withdraw(address(sUSDe), tokenMax, dave, dave);
        assertLe(burned, sharesBefore);
        assertEq(jrtVault.balanceOf(dave), sharesBefore - burned);
        assertEq(sUSDe.balanceOf(dave) - tokensBefore, tokenMax,
            "maximum withdrawal delivers the requested tokens");
    }
}
