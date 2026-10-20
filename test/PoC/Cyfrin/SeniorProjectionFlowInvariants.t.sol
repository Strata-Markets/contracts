// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RoundTripStackBase} from "./SeniorRoundTripProjection.t.sol";
import {DYSAccounting} from "../../../contracts/tranches/DYSAccounting.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {UD60x18} from "@prb/math/src/ud60x18/ValueType.sol";

/// @notice Cash-flow invariants for purchased projection, across APR and live MTM pricing.
abstract contract SeniorProjectionFlowInvariants is RoundTripStackBase {
    DYSAccounting a; // Shared getter/configuration ABI of DYS and MTM.

    function _mtm() internal pure virtual returns (bool);

    function _liveMtm() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public {
        vm.warp(1_750_000_000);
        address impl = _mtm()
            ? address(new MTMAccounting(18, false, true, false, true, false, _liveMtm()))
            : address(new DYSAccounting(18, false, false, false, true, false));
        a = DYSAccounting(
            _deploy(impl, 50_000_000_000, 100_000_000_000, _liveMtm() ? 1 days : 3650 days)
        );
        a.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        cdo.setValuationKeeper(address(this));
        _deposit(jrt, alice, 500e18);
        _deposit(srt, bob, 500e18);
        vm.warp(block.timestamp + (_liveMtm() ? 1 hours : 365 days));
        if (_liveMtm()) strategy.setTotalAssets(1100e18);
        _poke();
        assertApproxEqAbs(a.srtPnLProjected(), 25e18, 1e6);
    }

    function _redeem(uint256 shares, address who) internal returns (uint256) {
        vm.prank(who);
        return srt.redeem(shares, who, who);
    }

    function _settle(int256 gain) internal {
        if (_mtm()) strategy.setEpochDuration(0);
        vm.warp(block.timestamp + 1);
        uint256 value = uint256(int256(a.nav()) + gain) + (gain == 0 ? 1001 : 0);
        uint256 balance = token.balanceOf(address(strategy));
        if (value > balance) {
            token.mint(address(strategy), value - balance);
        } else if (value < balance) {
            vm.prank(address(strategy));
            token.transfer(address(0xdead), balance - value);
        }
        strategy.updateTotalAssets(value);
        _poke();
        assertEq(a.srtPnLProjected(), 0);
        assertEq(a.srtPaidProjected(), 0);
        assertEq(a.srtBoughtProjected(), 0);
    }

    function _state() internal view returns (uint256[5] memory) {
        return [
            a.srtBaseNav(),
            a.jrtBaseNav(),
            a.srtPnLProjected(),
            a.srtPaidProjected(),
            a.srtBoughtProjected()
        ];
    }

    function _assertState(uint256[5] memory expected) internal view {
        uint256[5] memory actual = _state();
        for (uint256 i; i < actual.length; i++) {
            assertApproxEqAbs(actual[i], expected[i], 1e6);
        }
    }

    function testFuzz_samePriceRoundTrip(uint96 amountIn) public {
        uint256 amount = bound(uint256(amountIn), 1e15, a.maxDeposit(false));
        uint256[5] memory before_ = _state();
        uint256 paid = _roundTrip(carol, amount);
        assertApproxEqAbs(paid, amount, 1e6);
        _assertState(before_);
    }

    function test_splitDepositsMatchSingleDeposit() public {
        uint256 snap = vm.snapshotState();
        _deposit(srt, carol, 1575e18);
        uint256[5] memory expected = _state();
        vm.revertToState(snap);
        _deposit(srt, carol, 525e18);
        _deposit(srt, carol, 1050e18);
        _assertState(expected);
        _redeem(srt.balanceOf(carol), carol);
        assertApproxEqAbs(a.srtBoughtProjected(), 0, 1e6);
        assertApproxEqAbs(a.srtPaidProjected(), 0, 1e6);
    }

    function test_roundTripPreservesLaterExitAndAssetTime() public {
        uint256 snap = vm.snapshotState();
        _redeem(srt.balanceOf(bob) / 2, bob);
        vm.warp(block.timestamp + 1 hours);
        _poke();
        uint256 weight = a.srtProjectedPnLTime();
        uint256 realWeight = a.srtNavTime();
        uint256[5] memory expected = _state();
        _settle(0);
        uint256 senior = a.srtBaseNav();
        uint256 junior = a.jrtBaseNav();
        vm.revertToState(snap);
        _roundTrip(carol, 4725e18);
        _redeem(srt.balanceOf(bob) / 2, bob);
        vm.warp(block.timestamp + 1 hours);
        _poke();
        _assertState(expected);
        assertApproxEqAbs(a.srtProjectedPnLTime(), weight, 1e10);
        assertApproxEqAbs(a.srtNavTime(), realWeight, 1e10);
        _settle(0);
        assertApproxEqAbs(a.srtBaseNav(), senior, 1e6);
        assertApproxEqAbs(a.jrtBaseNav(), junior, 1e6);
    }

    function test_exitThenDepositRestoresProjection() public {
        uint256[5] memory before_ = _state();
        uint256 paid = _redeem(srt.balanceOf(bob) / 2, bob);
        assertGt(a.srtPaidProjected(), 0);
        _deposit(srt, carol, paid);
        _assertState(before_);
    }

    function test_depositCreditIsNotUnrealizedAssetTime() public {
        _deposit(srt, carol, 4725e18);
        assertApproxEqAbs(a.srtBoughtProjected(), 225e18, 1e6);
        uint256 t = a.srtProjectedPnLTime();
        vm.warp(block.timestamp + 1 hours);
        _poke();
        assertApproxEqAbs(a.srtProjectedPnLTime() - t, 25e18 * 1 hours, 1e10);
    }

    function test_roundTripMatchesControlForRealizedGainsAndLosses() public {
        int256[6] memory gains = [
            int256(-100e18),
            int256(0),
            int256(10e18),
            int256(25e18),
            int256(50e18),
            int256(100e18)
        ];
        for (uint256 i; i < gains.length; i++) {
            uint256 snap = vm.snapshotState();
            _settle(gains[i]);
            uint256 senior = a.srtBaseNav();
            uint256 junior = a.jrtBaseNav();
            vm.revertToState(snap);
            _roundTrip(carol, 4725e18);
            _settle(gains[i]);
            assertApproxEqAbs(a.srtBaseNav(), senior, 1e6);
            assertApproxEqAbs(a.jrtBaseNav(), junior, 1e6);
            vm.revertToState(snap);
        }
    }

    function test_samePriceValuationRoundTripIsNeutral() public {
        cdo.setValuationPrice(0.8e18);
        cdo.setActionStates(address(srt), true, true);
        (uint256 juniorBefore, uint256 seniorBefore,) = a.totalAssets();
        uint256 projectedBefore = a.srtPnLProjected();
        uint256 received = _roundTrip(carol, 4725e18);
        (uint256 juniorAfter, uint256 seniorAfter,) = a.totalAssets();
        // Valuation exits redistribute base NAV and self-funding; compare effective NAVs.
        assertApproxEqAbs(received, 4725e18, 1e6);
        assertApproxEqAbs(juniorAfter, juniorBefore, 1e6);
        assertApproxEqAbs(seniorAfter, seniorBefore, 1e6);
        assertApproxEqAbs(a.srtPnLProjected(), projectedBefore, 1e6);
        assertApproxEqAbs(a.srtPaidProjected(), 0, 1e6);
        assertApproxEqAbs(a.srtBoughtProjected(), 0, 1e6);
    }

    function test_projectionChangeBetweenDepositAndExitPreservesSplitEquivalence() public {
        uint256 snap = vm.snapshotState();
        uint256 shares = _deposit(srt, carol, 1575e18);
        _changeProjection();
        _redeem(shares, carol);
        uint256[5] memory expected = _state();
        _settle(0);
        uint256 senior = a.srtBaseNav();
        uint256 junior = a.jrtBaseNav();
        vm.revertToState(snap);
        uint256 splitShares = _deposit(srt, carol, 525e18) + _deposit(srt, carol, 1050e18);
        _changeProjection();
        _redeem(splitShares, carol);
        _assertState(expected);
        _settle(0);
        assertApproxEqAbs(a.srtBaseNav(), senior, 1e6);
        assertApproxEqAbs(a.jrtBaseNav(), junior, 1e6);
    }

    function _changeProjection() internal {
        if (_liveMtm()) {
            strategy.setTotalAssets(a.nav());
            _poke();
            assertEq(a.srtPnLProjected(), 0);
            strategy.setTotalAssets(a.nav() + 200e18);
            _poke();
            assertGt(a.srtPnLProjected(), 0);
        } else {
            vm.warp(block.timestamp + 30 days);
            _poke();
            assertGt(a.srtPnLProjected(), 25e18);
        }
    }

    function test_nearFullExitLeavesOnlyProportionalPurchaseCredit() public {
        _deposit(srt, carol, 4725e18);
        if (_liveMtm()) {
            strategy.setTotalAssets(a.nav());
            _poke();
        }
        _redeem(srt.balanceOf(carol), carol);
        uint256 bobShares = srt.balanceOf(bob);
        uint256 expectedCredit = a.srtBoughtProjected() * 0.1e18 / bobShares;
        _redeem(bobShares - 0.1e18, bob);
        assertApproxEqAbs(a.srtBoughtProjected(), expectedCredit, 1e6);
    }
}

contract SeniorProjectionFlowDYSTest is SeniorProjectionFlowInvariants {
    function _mtm() internal pure override returns (bool) {
        return false;
    }
}

contract SeniorProjectionFlowMTMAPRTest is SeniorProjectionFlowInvariants {
    function _mtm() internal pure override returns (bool) {
        return true;
    }
}

contract SeniorProjectionFlowMTMLiveTest is SeniorProjectionFlowInvariants {
    function _mtm() internal pure override returns (bool) {
        return true;
    }

    function _liveMtm() internal pure override returns (bool) {
        return true;
    }
}
