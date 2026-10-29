// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AccountingLib} from "../../../contracts/tranches/utils/AccountingLib.sol";
import {RoundTripStackBase} from "./SeniorRoundTripProjection.t.sol";
import {DYSAccounting} from "../../../contracts/tranches/DYSAccounting.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {UD60x18} from "@prb/math/src/ud60x18/ValueType.sol";

contract ProportionalPnLMathTest is Test {
    function test_largeLossAndGain() public pure {
        uint256 seniorTime = 500_000_000e18 * 3 days;
        uint256 totalTime = seniorTime * 2;
        assertEq(AccountingLib.proportionalPnL(-500_000_000e18, 0.95e18, seniorTime, totalTime), -237_500_000e18);
        assertEq(AccountingLib.proportionalPnL(500_000_000e18, 0.95e18, seniorTime, totalTime), 237_500_000e18);
    }

    function legacyPnL(int256 pnl, uint256 seniorTime, uint256 totalTime) external pure returns (int256) {
        return pnl * int256(0.95e18) * int256(seniorTime) / (int256(totalTime) * 1e18);
    }

    function test_originalFormulaOverflows() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        this.legacyPnL(-500_000_000e18, 500_000_000e18 * 3 days, 1_000_000_000e18 * 3 days);
    }

    function test_roundsTowardZero() public pure {
        assertEq(AccountingLib.proportionalPnL(7, 0.95e18, 1, 2), 3);
        assertEq(AccountingLib.proportionalPnL(-7, 0.95e18, 1, 2), -3);
    }

    function testFuzz_matchesOriginalWithinSafeRange(int64 pnl, uint64 seniorTime, uint64 totalTime, uint64 factor) public pure {
        totalTime = totalTime == 0 ? 1 : totalTime;
        factor = uint64(uint256(factor) % 1e18);
        int256 expected = int256(pnl) * int256(uint256(factor)) * int256(uint256(seniorTime))
            / (int256(uint256(totalTime)) * 1e18);
        assertEq(AccountingLib.proportionalPnL(pnl, factor, seniorTime, totalTime), expected);
    }

    function test_int256Boundary() public pure {
        int256 limit = type(int256).max;
        assertEq(AccountingLib.proportionalPnL(limit, 1e18, 1, 1), limit);
        assertEq(AccountingLib.proportionalPnL(-limit, 1e18, 1, 1), -limit);
    }
}

abstract contract ProportionalPnLOverflowBase is RoundTripStackBase {
    DYSAccounting accounting;
    function _mtm() internal pure virtual returns (bool);

    function setUp() public {
        vm.warp(1_750_000_000);
        address impl = _mtm()
            ? address(new MTMAccounting(18, false, true, false, false, false, false))
            : address(new DYSAccounting(18, false, false, false, false, false));
        accounting = DYSAccounting(_deploy(impl, 0, 0, 3650 days));
        accounting.setRiskParameters(UD60x18.wrap(0.05e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        _deposit(jrt, alice, 500_000_000e18);
        _deposit(srt, bob, 500_000_000e18);
        vm.warp(block.timestamp + 3 days);
    }

    function _settle(uint256 assets) internal {
        if (_mtm()) {
            strategy.setEpochDuration(0);
        }
        strategy.setTotalAssets(assets);
        _poke();
        assertEq(accounting.nav(), assets);
    }

    function test_largeLossReconciles() public {
        _settle(500_000_000e18);
        assertEq(accounting.jrtBaseNav() + accounting.srtBaseNav() + accounting.reserveNav(), 500_000_000e18);
    }

    function test_largeGainReconciles() public {
        _settle(1_500_000_000e18);
        assertGt(accounting.srtBaseNav(), 500_000_000e18);
        assertEq(accounting.jrtBaseNav() + accounting.srtBaseNav() + accounting.reserveNav(), 1_500_000_000e18);
    }
}

contract ProportionalPnLOverflowDYSTest is ProportionalPnLOverflowBase {
    function _mtm() internal pure override returns (bool) { return false; }
}
contract ProportionalPnLOverflowMTMTest is ProportionalPnLOverflowBase {
    function _mtm() internal pure override returns (bool) { return true; }
}
