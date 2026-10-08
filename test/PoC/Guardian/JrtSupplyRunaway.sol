// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import "./StrataProtocolDeploymentBase.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";

contract JrtSupplyRunawayTest is StrataProtocolDeploymentBase {
    string constant RESET = "\x1b[0m";
    string constant BLUE = "\x1b[34m";
    string constant GREEN = "\x1b[32m";
    string constant YELLOW = "\x1b[33m";
    string constant RED = "\x1b[31m";

    int64 constant APR_LOW  = 10_000_000_000;    // 1% (1e12 scale)
    int64 constant APR_HIGH = 1_000_000_000_000; // 100%  <<-- stronger push

    function pocJrtSupplyRunawayDueToTinyPrice() public {
        _deployStrataStack();

        address junior = makeAddr("Junior");
        address senior = makeAddr("Senior");

        vm.prank(address(owner));
        cdo.setJrtShortfallPausePrice(999999936562089475);
        (bool isDepositEnabledBefore, ) = cdo.actionsJrt();
        require(isDepositEnabledBefore == true, "JRT deposit should be enabled");

        _setApr(APR_LOW, 0);
        _deposit(address(jrtVault), junior, 1_000_000e18);
        _deposit(address(srtVault), senior, 1e18);
        vm.prank(address(jrtVault));
        cdo.updateAccounting();


        console2.log(string.concat(BLUE, "[setup] Initial JRT price:", RESET), _jrtPrice());
        console2.log(string.concat(BLUE, "[setup] Initial JRT supply:", RESET), IERC20(address(jrtVault)).totalSupply());
        console2.log(string.concat(BLUE, "[setup] Initial SRT supply:", RESET), IERC20(address(srtVault)).totalSupply());

        // drive the accounting to take from JRT
        for (uint256 i = 0; i < 12; i++) {
            _setApr(APR_HIGH, 0);                       // <<-- aggressive jump; no yield donation this time

            uint256 priceBefore = _jrtPrice();
            uint256 srtPriceBefore = _srtPrice();
            uint256 prevShares = jrtVault.previewDeposit(1_000_000e18);
            uint256 jSupplyBefore = IERC20(address(jrtVault)).totalSupply();
            uint256 sSupplyBefore = IERC20(address(srtVault)).totalSupply();
            console2.log(string.concat(YELLOW, "\n[loop] Iteration ", vm.toString(i), RESET));
            console2.log(string.concat(GREEN, "[state] JRT Price before deposits:", RESET), priceBefore);
            console2.log(string.concat(GREEN, "[state] SRT price before:", RESET), srtPriceBefore);
            console2.log(string.concat(GREEN, "[state] JRT supply before:", RESET), jSupplyBefore);
            console2.log(string.concat(GREEN, "[state] SRT supply before:", RESET), sSupplyBefore);
            console2.log(string.concat(GREEN, "[state] previewDeposit(1000000e18) shares:", RESET), prevShares);

            // trigger updateAccounting (Tranche.deposit already calls it)
            _deposit(address(jrtVault), junior, 1_000_000e18);

            uint256 priceAfter = _jrtPrice();
            uint256 srtPriceAfter = _srtPrice();
            uint256 jSupplyAfter = IERC20(address(jrtVault)).totalSupply();
            uint256 sSupplyAfter = IERC20(address(srtVault)).totalSupply();
            console2.log(string.concat(GREEN, "[state] JRT Price after deposits:", RESET), priceAfter);
            console2.log(string.concat(GREEN, "[state] SRT price after:", RESET), srtPriceAfter);
            console2.log(string.concat(GREEN, "[state] JRT supply after:", RESET), jSupplyAfter);
            console2.log(string.concat(GREEN, "[state] SRT supply after:", RESET), sSupplyAfter);
            console2.log(string.concat(RED, "[delta] JRT supply growth:", RESET), jSupplyAfter - jSupplyBefore);

            _setApr(APR_LOW, 0);                        // oscillate back (optional)
        }

        (bool isDepositEnabledAfter, ) = cdo.actionsJrt();
        require(isDepositEnabledAfter == true, "(PoC) JRT deposit is still enabled");
    }

    function _setApr(int64 target, int64 base) internal {
        vm.prank(owner);
        feed.updateRoundData(target, base, uint64(block.timestamp));
        vm.prank(owner);
        accounting.onAprChanged();
        vm.warp(block.timestamp + 7 days);
        vm.prank(address(jrtVault));
        cdo.updateAccounting();
    }
    function _deposit(address vault, address depositor, uint256 amount) internal {
        deal(USDE, depositor, amount, true);
        vm.startPrank(depositor);
        IERC20(USDE).approve(vault, amount);
        ITranche(vault).deposit(amount, depositor);
        vm.stopPrank();
    }
    function _jrtPrice() internal view returns (uint256) {
        uint256 A = jrtVault.totalAssets();
        uint256 S = IERC20(address(jrtVault)).totalSupply();
        return S == 0 ? 1e18 : A * 1e18 / S;
    }

    function _srtPrice() internal view returns (uint256) {
        uint256 A = srtVault.totalAssets();
        uint256 S = IERC20(address(srtVault)).totalSupply();
        return S == 0 ? 1e18 : A * 1e18 / S;
    }
}
