// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { StrataProtocolDeploymentBase } from "./StrataProtocolDeploymentBase.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AccountingRiskLagTest is StrataProtocolDeploymentBase {
    function pocRiskUsesPreSplitBalances() public {
        _deployStrataStack();

        // Configure risk = tvlRatio (riskX = 0, riskY = 1, k = 1)
        vm.prank(owner);
        accounting.setRiskParameters(
            UD60x18.wrap(0),
            UD60x18.wrap(1e18),
            UD60x18.wrap(1e18)
        );

        // Configure the feed so aprSrt = aprBase * (1 - risk)
        int64 aprTarget = 0;
        int64 aprBase = 50 * 10_000_000_000; // 50% scaled to 1e12
        vm.prank(owner);
        feed.updateRoundData(aprTarget, aprBase, uint64(block.timestamp));
        vm.prank(owner);
        accounting.onAprChanged();

        // Fund this test account with USDe and approve tranches
        deal(USDE, address(this), 1_000e18);
        IERC20(USDE).approve(address(jrtVault), type(uint256).max);
        IERC20(USDE).approve(address(srtVault), type(uint256).max);

        // Seed both tranches with 100 USDe each. Deposits call updateAccounting internally.
        jrtVault.deposit(100e18, address(this)); // establishes initial TVL
        srtVault.deposit(100e18, address(this)); // keeps ratio 50/50

        uint256 aprBefore = accounting.aprSrt().unwrap();
        uint256 jrtBefore = accounting.jrtNav();
        uint256 srtBefore = accounting.srtNav();

        console.log("apr before", aprBefore);
        console.log("jrt before", jrtBefore);
        console.log("srt before", srtBefore);

        // Make an additional Senior deposit. Note: deposit triggers updateAccounting BEFORE
        // accounting balances are incremented, illustrating the lag we want to capture.
        srtVault.deposit(200e18, address(this));

        uint256 aprAfter = accounting.aprSrt().unwrap();
        uint256 jrtAfter = accounting.jrtNav();
        uint256 srtAfter = accounting.srtNav();

        console.log("apr after", aprAfter);
        console.log("jrt after", jrtAfter);
        console.log("srt after", srtAfter);

        uint256 aprBaseVal = accounting.aprBase().unwrap();
        uint256 riskUsed = 1e18 - (aprAfter * 1e18) / aprBaseVal;
        uint256 riskPre = _ratio(srtBefore, jrtBefore);
        uint256 riskPost = _ratio(srtAfter, jrtAfter);

        console.log("risk pre", riskPre);
        console.log("risk post", riskPost);
        console.log("risk used", riskUsed);

        require(riskUsed == riskPre, "risk used should match pre-deposit ratio");
        require(riskUsed != riskPost, "risk should lag post-deposit ratio");
    }

    function _ratio(uint256 srtNav_, uint256 jrtNav_) internal pure returns (uint256) {
        uint256 total = srtNav_ + jrtNav_;
        if (total == 0) return 0;
        return (srtNav_ * 1e18) / total;
    }
}
