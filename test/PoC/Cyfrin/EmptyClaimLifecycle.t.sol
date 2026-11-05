// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;
import {ProtectedFeesTerminalLossTest} from "./ProtectedFeesTerminalLoss.t.sol";

contract EmptyClaimLifecycleTest is ProtectedFeesTerminalLossTest {
    function _empty(uint256 variant) internal {
        _deploy(variant, 0, 0);
        pool.setCapacity(2000e18);
        strategyNav = 50e18;
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 50e18);
        assertEq(accounting.underwriterFeeNav(), 100e18);
        _assertIdentity();
    }
    function test_allVariantsEmptyClaimRecovery() public {
        for (uint256 i; i < 4; ++i) {
            _empty(i);
            accounting.updateAccounting();
            _assertIdentity();
            strategyNav = 75e18;
            accounting.updateAccounting();
            assertEq(accounting.insuranceAmount(), 25e18);
            _assertIdentity();
            strategyNav = 120e18;
            accounting.updateAccounting();
            assertEq(accounting.insuranceAmount(), 0);
            assertEq(accounting.reserveNav(), 20e18);
            _assertIdentity();
        }
    }
    function test_allVariantsEmptyClaimFurtherLoss() public {
        for (uint256 i; i < 4; ++i) {
            for (uint256 covered; covered < 2; ++covered) {
                _empty(i);
                if (covered == 0) {
                    pool.setCapacity(0);
                }
                strategyNav = 0;
                accounting.updateAccounting();
                assertEq(accounting.insuranceAmount(), covered == 0 ? 50e18 : 100e18);
                assertEq(accounting.underwriterFeeNav(), accounting.insuranceAmount());
                _assertIdentity();
                accounting.updateAccounting();
                _assertIdentity();
            }
        }
    }
}
