// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/console2.sol";

import "./StrataProtocolDeploymentBase.sol";

contract ReserveWithdrawalUnitMismatchTest is StrataProtocolDeploymentBase {
    string constant RESET = "\x1b[0m";
    string constant BLUE = "\x1b[34m";
    string constant GREEN = "\x1b[32m";
    string constant YELLOW = "\x1b[33m";
    string constant RED = "\x1b[31m";

    function pocReserveWithdrawalShareMismatch() public {
        _deployStrataStack();

        address reserveManager = owner;
        address treasury = makeAddr("treasury");
        vm.label(treasury, "Treasury");
        vm.startPrank(owner);
        _grantRole(RESERVE_MANAGER_ROLE, reserveManager);
        cdo.setReserveTreasury(treasury);
        vm.stopPrank();

        uint256 initialUSDe = 1000e18;
        _seedStrategy(initialUSDe);
        console2.log(string.concat(BLUE, "[setup] Seeded strategy base assets:", RESET), initialUSDe);

        uint256 sharePrice = _sharePrice();
        console2.log(string.concat(GREEN, "[info] Before sUSDe share price (scaled 1e18):", RESET), sharePrice);

        uint256 extraYield = 1000000000e18;
        uint256 preVaultBalance = IERC20(USDE).balanceOf(address(SUSDE));
        deal(USDE, address(SUSDE), preVaultBalance + extraYield, true);
        console2.log(string.concat(BLUE, "[setup] Injected raw USDe yield into sUSDe vault:", RESET), extraYield);

        sharePrice = _sharePrice();
        console2.log(string.concat(GREEN, "[info] After injecting yield sUSDe share price (scaled 1e18):", RESET), sharePrice);

        // to call updateAccounting
        _seedStrategy(1e18);

        uint256 reserveUSDe = 1e18;
        address reserveDepositor = makeAddr("reserve-depositor");
        vm.label(reserveDepositor, "ReserveDepositor");
        deal(USDE, reserveDepositor, reserveUSDe, true);
        vm.startPrank(reserveDepositor);
        IERC20(USDE).approve(address(jrtVault), reserveUSDe);
        uint256 sharesMinted = Tranche(address(jrtVault)).deposit(reserveUSDe, reserveDepositor);
        console2.log(string.concat(BLUE, "[setup] Reserve depositor mint shares:", RESET), sharesMinted);
        vm.stopPrank();

        vm.prank(address(jrtVault));
        cdo.updateAccounting();
        console2.log(string.concat(BLUE, "[setup] Accounting updated after new deposit", RESET));

        uint256 sharesBefore = IERC20(SUSDE).balanceOf(address(strategy));
        console2.log(string.concat(GREEN, "[info] Strategy share balance before reduction:", RESET), sharesBefore);

        vm.prank(reserveManager);
        cdo.reduceReserve(address(USDE), reserveUSDe);
        console2.log(string.concat(YELLOW, "[action] CDO.reduceReserve called for USDe amount:", RESET), reserveUSDe);

        uint256 sharesAfter = IERC20(SUSDE).balanceOf(address(strategy));
        uint256 sharesTransferred = sharesBefore - sharesAfter;
        console2.log(string.concat(GREEN, "[result] Shares actually transferred out of strategy:", RESET), sharesTransferred);

        uint256 expectedShares = IsUSDe(SUSDE).previewWithdraw(reserveUSDe);
        console2.log(string.concat(YELLOW, "[expect] Shares needed for that many USDe (previewWithdraw):", RESET), expectedShares);

        uint256 usdePayout = IsUSDe(SUSDE).previewRedeem(sharesTransferred);
        console2.log(string.concat(GREEN, "[result] Underlying USDe owed for transferred shares:", RESET), usdePayout);
        console2.log(string.concat(RED, "[delta] Overpayment relative to accounting (USDe):", RESET), usdePayout - reserveUSDe);

        require(sharesTransferred == reserveUSDe, "strategy sends amount in shares");
        require(expectedShares < sharesTransferred, "share price should be > 1");
        require(usdePayout > reserveUSDe, "treasury receives more USDe than deducted");
    }

    function _seedStrategy(uint256 depositAmount) internal {
        address depositor = makeAddr("seed-depositor");
        vm.label(depositor, "SeedDepositor");

        deal(USDE, depositor, depositAmount, true);
        vm.startPrank(depositor);
        IERC20(USDE).approve(address(jrtVault), depositAmount);
        Tranche(address(jrtVault)).deposit(depositAmount, depositor);
        vm.stopPrank();
    }

    function _sharePrice() internal view returns (uint256) {
        uint256 shares = IERC20(SUSDE).balanceOf(address(strategy));
        return shares == 0 ? 1e18 : IsUSDe(SUSDE).previewRedeem(shares) * 1e18 / shares;
    }
}
