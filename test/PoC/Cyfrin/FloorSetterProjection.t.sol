// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RoundTripStackBase} from "./SeniorRoundTripProjection.t.sol";
import {NegativeProjectionStack} from "./MTMNegativeProjection.t.sol";
import {DYSAccounting} from "../../../contracts/tranches/DYSAccounting.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";

/// @notice Floor resets must protect settled Senior NAV rather than the open projection.
abstract contract FloorSetterProjectionBase is RoundTripStackBase {
    DYSAccounting a; // Common nonnegative projection/configuration ABI for these APR fixtures.
    function _mtm() internal pure virtual returns (bool);

    function setUp() public {
        vm.warp(1_750_000_000);
        address impl = _mtm()
            ? address(new MTMAccounting(18, false, true, false, true, false, false))
            : address(new DYSAccounting(18, false, false, false, true, false));
        a = DYSAccounting(_deploy(impl, 100_000_000_000, 0, 3650 days));
        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
        vm.warp(block.timestamp + 365 days);
        _poke();
        assertApproxEqAbs(a.srtPnLProjected(), 100e18, 1e6);
    }

    function _assertReset(uint256 expected) internal {
        a.setFloorRate(0.009e18);
        assertApproxEqAbs(a.windowStartSrtNav(), expected, 1e6);
        assertEq(a.windowNetFlows(), 0);
        assertEq(a.windowEnd(), block.timestamp + 1 days);
    }

    function test_resetExcludesPositiveProjection() public {
        assertGt(a.srtBaseNav(), 1000e18);
        _assertReset(1000e18);
    }

    function test_resetExcludesOnlyUnpaidProjection() public {
        vm.prank(bob);
        srt.redeem(100e18, bob, bob);
        assertGt(a.srtPaidProjected(), 0);
        _assertReset(900e18);
    }

    function test_resetKeepsDepositPurchasedProjectionAsCapital() public {
        _deposit(srt, carol, 110e18);
        assertGt(a.srtBoughtProjected(), 0);
        _assertReset(1110e18);
    }

    function _settle(uint256 assets) internal {
        if (_mtm()) {
            strategy.setEpochDuration(0);
        }
        strategy.setTotalAssets(assets);
        _poke();
    }

    function test_subsequentLossDoesNotProtectUnrealizedGain() public {
        _assertReset(1000e18);
        vm.warp(block.timestamp + 1 hours);
        _settle(1990e18);
        assertEq(a.srtPnLProjected(), 0);
        assertLe(a.srtBaseNav(), 1000e18);
        assertGe(a.srtBaseNav(), 991e18);
    }

    function test_windowRolloverStillAnchorsReconciledNav() public {
        _assertReset(1000e18);
        vm.warp(block.timestamp + 1 days + 1);
        _settle(1990e18);
        assertEq(a.srtPnLProjected(), 0);
        assertEq(a.windowStartSrtNav(), a.srtBaseNav());
        assertEq(a.windowNetFlows(), 0);
    }
}

contract FloorSetterProjectionDYSTest is FloorSetterProjectionBase {
    function _mtm() internal pure override returns (bool) { return false; }
}
contract FloorSetterProjectionMTMTest is FloorSetterProjectionBase {
    function _mtm() internal pure override returns (bool) { return true; }
}

contract FloorSetterLiveMTMTest is NegativeProjectionStack {
    function setUp() public {
        vm.warp(1_750_000_000);
        _deployMTMStack(AccFlags({benchmark: false, mtmProjection: true}));
        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
        vm.warp(block.timestamp + 1 hours);
    }

    function test_resetExcludesLiveGain() public {
        mtmStrategy.setTotalAssets(2400e18);
        accounting.setFloorRate(0.009e18);
        assertGt(accounting.srtPnLProjected(), 0);
        assertEq(accounting.windowStartSrtNav(), 1000e18);
    }

    function test_resetRestoresLiveLoss() public {
        accounting.setFloorRate(0.01e18);
        mtmStrategy.setTotalAssets(1980e18);
        accounting.setFloorRate(0.009e18);
        assertLt(accounting.srtPnLProjected(), 0);
        assertLt(accounting.srtBaseNav(), 1000e18);
        assertEq(accounting.windowStartSrtNav(), 1000e18);
        assertEq(accounting.windowNetFlows(), 0);
        assertEq(accounting.windowEnd(), block.timestamp + 1 days);
    }
}
