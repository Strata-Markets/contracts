// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { StrataProtocolDeploymentBase } from "./StrataProtocolDeploymentBase.sol";
import { UD60x18, pow } from "@prb/math/src/ud60x18/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AccountingRiskDoSTest is StrataProtocolDeploymentBase {
    function pocRiskOverOneHundredPercentRevertsUpdate() public {
        _deployStrataStack();

        console.log("\n[Setup] Configuring high risk parameters");
        UD60x18 riskX = UD60x18.wrap(0.80e18);
        UD60x18 riskY = UD60x18.wrap(0.25e18);
        UD60x18 riskK = UD60x18.wrap(0.5e18);
        console.log("    riskX = %s", riskX.unwrap());
        console.log("    riskY = %s", riskY.unwrap());
        console.log("    riskK = %s", riskK.unwrap());

        vm.prank(owner);
        accounting.setRiskParameters(riskX, riskY, riskK);

        console.log("[Setup] Funding test account with USDe");
        deal(USDE, address(this), 10_000e18);
        IERC20(USDE).approve(address(jrtVault), type(uint256).max);
        IERC20(USDE).approve(address(srtVault), type(uint256).max);

        console.log("[Action] Depositing 1 USDe into Junior tranche");
        jrtVault.deposit(1e18, address(this));
        _logTvlState("after JRT deposit");

        console.log("[Action] Depositing 2 USDe into Senior tranche");
        srtVault.deposit(2e18, address(this));
        _logTvlState("after SRT deposit");

        console.log("[Info] Triggering accounting update - expect revert due to risk over 100%");
        vm.expectRevert();
        vm.prank(address(srtVault));
        cdo.updateAccounting();
    }

    function _logTvlState(string memory label) internal view {
        (uint256 jrtNav_, uint256 srtNav_, uint256 reserveNav_) = accounting.totalAssets(accounting.nav());
        uint256 totalNav = jrtNav_ + srtNav_ + reserveNav_;
        uint256 ratioRaw = srtNav_ == 0 ? 0 : (srtNav_ * 1e18) / (srtNav_ + jrtNav_);
        UD60x18 tvlRatio = UD60x18.wrap(ratioRaw);
        UD60x18 risk = accounting.riskX() + accounting.riskY() * pow(tvlRatio, accounting.riskK());

        console.log("    %s:", label);
        console.log("        jrtNav      = %s", jrtNav_);
        console.log("        srtNav      = %s", srtNav_);
        console.log("        reserveNav  = %s", reserveNav_);
        console.log("        totalNav    = %s", totalNav);
        console.log("        tvlRatio    = %s (scaled 1e18)", ratioRaw);
        console.log("        risk        = %s (scaled 1e18)", risk.unwrap());
    }
}
