// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {SymbioticCoverageStackBase} from "./FundedClaimReservedTwice.t.sol";

contract ValuationCheckpointFullStackTest is SymbioticCoverageStackBase {
    function test_cdoPricePushBooksPendingLossBeforeCoverage() public {
        cdo.setValuationKeeper(keeper);
        _strategyLoss(50_000e18);
        uint256 currentNav = cdo.totalStrategyAssets();
        assertGt(accounting.nav(), currentNav, "loss has not been checkpointed");
        vm.prank(keeper);
        cdo.setValuationPrice(0.8e18);
        assertEq(accounting.nav(), currentNav);
        // 900k Senior needs 225k protection; only ~50k Junior remains available.
        assertApproxEqAbs(accounting.insuranceAmount(), 175_001e18, 1e6);
        uint256 claim = accounting.insuranceAmount();
        uint256 slashed = _totalSlashed();
        _keeperSync();
        assertEq(accounting.insuranceAmount(), claim);
        assertEq(_totalSlashed(), slashed, "later checkpoint must not repair stale coverage");
    }
}
