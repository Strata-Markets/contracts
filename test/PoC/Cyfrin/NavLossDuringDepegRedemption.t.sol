// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {SymbioticCoverageStackBase} from "./FundedClaimReservedTwice.t.sol";

contract NavLossDuringDepegRedemptionTest is SymbioticCoverageStackBase {
    function test_redemptionFirstTouchPreservesValue() public {
        vm.prank(address(cdo));
        accounting.setValuationPrice(0.8e18);
        _fundOutstandingClaim();
        _strategyLoss(10_000e18);
        uint256 usdcBefore = usdc.balanceOf(bob);
        uint256 strategyBefore = susde.balanceOf(bob);
        uint256 shares = srt.balanceOf(bob);
        vm.prank(bob);
        srt.redeem(address(susde), shares, bob, bob);
        uint256 value = susde.convertToAssets(susde.balanceOf(bob) - strategyBefore) * 0.8e18 / 1e18
            + (usdc.balanceOf(bob) - usdcBefore) * 1e12;
        assertApproxEqAbs(value, 450_000e18, 2e12, "redeemer receives full oracle-valued payout");
    }
}
