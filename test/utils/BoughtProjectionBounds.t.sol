// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AccountingLib} from "../../contracts/tranches/utils/AccountingLib.sol";

contract BoughtProjectionBoundsHarness {
    function castNet(int256 value) external pure returns (int128) {
        return AccountingLib.toInt128(value);
    }
    function castLosses(uint256 value) external pure returns (uint128) {
        return AccountingLib.toUint128(value);
    }
}

contract BoughtProjectionBoundsTest is Test {
    BoughtProjectionBoundsHarness harness = new BoughtProjectionBoundsHarness();

    function test_exactBoundsAreSupported() public view {
        assertEq(harness.castNet(type(int128).min), type(int128).min);
        assertEq(harness.castNet(type(int128).max), type(int128).max);
        assertEq(harness.castLosses(type(uint128).max), type(uint128).max);
    }

    function test_outOfRangeValuesRevertInsteadOfTruncating() public {
        vm.expectRevert(AccountingLib.CastOverflow.selector);
        harness.castNet(int256(type(int128).min) - 1);
        vm.expectRevert(AccountingLib.CastOverflow.selector);
        harness.castNet(int256(type(int128).max) + 1);
        vm.expectRevert(AccountingLib.CastOverflow.selector);
        harness.castLosses(uint256(type(uint128).max) + 1);
    }
}
