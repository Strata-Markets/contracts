// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ProtectedFeesTerminalLossTest} from "./ProtectedFeesTerminalLoss.t.sol";
import {IInsurancePool} from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";

contract DiscreteEmptyClaimTest is ProtectedFeesTerminalLossTest {
    function _emptyWithClaim() internal {
        _deploy(1, 1e18, 0);
        pool.setCapacity(2000e18);
        strategyNav = 50e18;
        accounting.updateAccounting();
        assertEq(accounting.jrtBaseNav(), 0);
        assertEq(accounting.srtBaseNav(), 0);
        assertEq(accounting.insuranceAmount(), 50e18);
        assertEq(accounting.underwriterFeeNav(), 100e18);
        _assertIdentity();
    }

    function test_emptyClaimRepeatedUpdates() public {
        _emptyWithClaim();
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 1 hours);
            accounting.updateAccounting();
            assertEq(accounting.underwriterFeeNav(), 100e18);
            assertEq(accounting.insuranceAmount(), 50e18);
            _assertIdentity();
        }
    }

    function test_emptyClaimRecovery() public {
        _emptyWithClaim();
        strategyNav = 75e18;
        vm.expectCall(address(pool), abi.encodeCall(IInsurancePool.syncInsuranceClaim, (address(this))));
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 25e18);
        assertEq(accounting.underwriterFeeNav(), 100e18);
        _assertIdentity();
        strategyNav = 120e18;
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(accounting.underwriterFeeNav(), 100e18);
        assertEq(accounting.reserveNav(), 20e18);
        _assertIdentity();
        accounting.updateAccounting();
        _assertIdentity();
    }

    function test_emptyClaimFurtherLossWithoutCoverage() public {
        _emptyWithClaim();
        pool.setCapacity(0);
        strategyNav = 0;
        accounting.updateAccounting();
        assertEq(accounting.underwriterFeeNav(), 50e18);
        assertEq(accounting.insuranceAmount(), 50e18);
        _assertIdentity();
        accounting.updateAccounting();
        _assertIdentity();
        strategyNav = 50e18;
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 0);
        _assertIdentity();
    }

    function test_emptyClaimFurtherLossWithCoverage() public {
        _emptyWithClaim();
        strategyNav = 0;
        accounting.updateAccounting();
        assertEq(accounting.underwriterFeeNav(), 100e18);
        assertEq(accounting.insuranceAmount(), 100e18);
        _assertIdentity();
        accounting.updateAccounting();
        _assertIdentity();
    }

    function test_emptyClaimRecapitalizationAndGain() public {
        _emptyWithClaim();
        accounting.updateAccounting();
        strategyNav += 100e18;
        accounting.updateBalanceFlow(100e18, 0, 0, 0);
        accounting.updateAccounting();
        _assertIdentity();
        strategyNav += 1;
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 50e18 - 1);
        _assertIdentity();
    }
}
