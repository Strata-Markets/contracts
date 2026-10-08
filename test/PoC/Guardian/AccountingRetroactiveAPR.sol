// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { StrataProtocolDeploymentBase } from "./StrataProtocolDeploymentBase.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/Math.sol";

contract AccountingRetroactiveAPR is StrataProtocolDeploymentBase {
    uint256 constant SECONDS_PER_YEAR = 31_536_000;
    int64 constant ONE_PERCENT = 10_000_000_000; // 0.01 * 1e12

    function pocRetroactiveAPRJump() public {
        _deployStrataStack();

        // Zero risk so aprSrt mirrors the feed APR
        vm.prank(owner);
        accounting.setRiskParameters(UD60x18.wrap(0), UD60x18.wrap(0), UD60x18.wrap(1e18));

        // 1. Publish APR = 10%
        int64 apr10 = 10 * ONE_PERCENT;
        vm.prank(owner);
        feed.updateRoundData(apr10, apr10, uint64(block.timestamp));
        vm.prank(owner);
        accounting.onAprChanged();

        uint256 index0 = accounting.srtTargetIndex();
        uint256 aprOld = accounting.aprSrt().unwrap();
        console.log("initial index        %s", index0);
        console.log("initial APR (1e18)   %s", aprOld);

        // 2. 30 days elapse under APR=10%
        uint256 dt = 30 days;
        vm.warp(block.timestamp + dt);

        // 3. Publish APR = 20% and update accounting
        int64 apr20 = 20 * ONE_PERCENT;
        vm.prank(owner);
        feed.updateRoundData(apr20, apr20, uint64(block.timestamp));
        vm.prank(owner);
        accounting.onAprChanged();

        uint256 index1 = accounting.srtTargetIndex();
        uint256 aprNew = accounting.aprSrt().unwrap();

        uint256 growthOld = index0 * (1e18 + aprOld * dt / SECONDS_PER_YEAR) / 1e18;
        uint256 growthNew = index0 * (1e18 + aprNew * dt / SECONDS_PER_YEAR) / 1e18;

        console.log("elapsed seconds      %s", dt);
        console.log("aprOld (1e18)        %s", aprOld);
        console.log("aprNew (1e18)        %s", aprNew);
        console.log("index after update   %s", index1);
        console.log("expected using old   %s", growthOld);
        console.log("expected using new   %s", growthNew);

        require(index1 == growthNew, "index accrues at new apr");
        require(index1 != growthOld, "expected retroactive jump");
    }
}
