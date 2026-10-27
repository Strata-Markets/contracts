// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;
import {CDOTest} from "../../CDO.t.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IStrategy} from "../../../contracts/tranches/interfaces/IStrategy.sol";
import {IErrors} from "../../../contracts/tranches/interfaces/IErrors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SharesCooldown} from "../../../contracts/tranches/base/cooldown/SharesCooldown.sol";
import {CooldownBase} from "../../../contracts/tranches/base/cooldown/CooldownBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

contract DepositOnlyWithdrawalRouteTest is CDOTest {
    using stdStorage for StdStorage;
    function _prepare(uint256 capacity) internal {
        vm.stopPrank();
        USDe.mint(address(this), 1000e18);
        USDe.approve(address(jrtVault), 1000e18);
        jrtVault.deposit(1000e18, address(this));
        vm.mockCall(address(sUSDeStrategy), abi.encodeWithSelector(IStrategy.maxWithdraw.selector), abi.encode(capacity));
    }
    function test_zeroRouteCapacity() public {
        _prepare(0);
        assertEq(cdo.maxWithdraw(address(jrtVault), address(this), address(USDe)), 0);
        assertEq(jrtVault.maxWithdraw(address(USDe), address(this)), 0);
        assertGt(jrtVault.previewDeposit(address(USDe), 100e18), 0);
    }
    function test_finiteStrategyCapacityIsConvertedToTokens() public {
        _prepare(100e18);
        USDe.mint(address(sUSDe), 370e18);
        uint256 expected = sUSDeStrategy.convertToTokens(address(sUSDe), 100e18, Math.Rounding.Floor);
        assertLt(expected, 100e18);
        assertEq(cdo.maxWithdraw(address(jrtVault), address(this), address(sUSDe)), 100e18);
        assertEq(jrtVault.maxWithdraw(address(sUSDe), address(this)), expected);
    }
    function test_unlimitedStrategyStillRespectsOwnerBalance() public {
        _prepare(type(uint256).max);
        assertEq(jrtVault.maxWithdraw(address(USDe), address(this)), jrtVault.maxWithdraw(address(this)));
        assertEq(jrtVault.maxWithdraw(address(USDe), address(0x123)), 0);
    }
    function _assertRejected(bool redeemShares) internal {
        _prepare(0);
        uint256 sharesBefore = jrtVault.balanceOf(address(this));
        uint256 reserveBefore = accounting.reserveNav();
        vm.expectRevert(abi.encodeWithSelector(IErrors.WithdrawalRejectedByStrategy.selector, address(jrtVault), address(USDe)));
        if (redeemShares) {
            jrtVault.redeem(address(USDe), 100e18, address(this), address(this));
        } else {
            jrtVault.withdraw(address(USDe), 100e18, address(this), address(this));
        }
        assertEq(jrtVault.balanceOf(address(this)), sharesBefore);
        assertEq(accounting.reserveNav(), reserveBefore);
    }
    function _assertLockedWithOverride(bool redeemShares) internal {
        _prepare(type(uint256).max);
        // Only the requested base route is closed; the share-token route remains available.
        vm.mockCall(address(sUSDeStrategy),
            abi.encodeWithSelector(IStrategy.maxWithdraw.selector, address(jrtVault), address(USDe)),
            abi.encode(uint256(0)));
        SharesCooldown cooldown = SharesCooldown(address(new ERC1967Proxy(
            address(new SharesCooldown()),
            abi.encodeCall(CooldownBase.initialize, (address(this), address(acm)))
        )));
        vm.prank(cdo.owner());
        cdo.setSharesCooldown(cooldown);
        bytes32 workerRole = cooldown.COOLDOWN_WORKER_ROLE();
        vm.prank(cdo.owner());
        acm.grantRole(workerRole, address(cdo));
        vm.mockCall(address(cdo),
            abi.encodeWithSelector(IStrataCDO.calculateExitMode.selector, address(jrtVault), address(this)),
            abi.encode(IStrataCDO.TExitMode.SharesLock, uint256(0), uint32(1 days)));
        uint256 sharesBefore = jrtVault.balanceOf(address(this));
        if (redeemShares) {
            jrtVault.redeem(address(USDe), 100e18, address(this), address(this));
        } else {
            jrtVault.withdraw(address(USDe), 100e18, address(this), address(this));
        }
        (, uint192 locked, address token,) = cooldown.activeRequests(address(jrtVault), address(this), 0);
        assertEq(token, address(USDe));
        assertGt(locked, 0);
        assertEq(jrtVault.balanceOf(address(cooldown)), locked);
        assertEq(jrtVault.balanceOf(address(this)), sharesBefore - locked);

        // Shared fixture leaves ERC20Cooldown uninitialized; provide its access-control dependency.
        stdstore.target(address(erc20Cooldown)).sig("acm()").checked_write(address(acm));
        vm.warp(block.timestamp + 1 days);
        uint256 tokensBefore = sUSDe.balanceOf(address(this));
        uint256 claimed = cooldown.finalizeWithTokenOverride(IERC20(address(jrtVault)), address(sUSDe), address(this));
        assertEq(claimed, locked);
        assertEq(jrtVault.balanceOf(address(cooldown)), 0);
        assertGt(sUSDe.balanceOf(address(this)), tokensBefore);
    }
    function test_lockedWithdrawAllowsClosedRouteAndTokenOverride() public { _assertLockedWithOverride(false); }
    function test_lockedRedeemAllowsClosedRouteAndTokenOverride() public { _assertLockedWithOverride(true); }
    function test_directWithdrawRejected() public { _assertRejected(false); }
    function test_directRedeemRejected() public { _assertRejected(true); }
}
