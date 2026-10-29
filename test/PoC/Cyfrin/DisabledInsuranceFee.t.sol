// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { MTMStackBase } from "./StrategyDepositMaximum.t.sol";
import { IInsuranceMiddleware } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import { IInsuranceVault } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";

/// @notice Regression for Cyfrin's disabled-coverage fee scenario.
contract DisabledInsuranceFeeTest is MTMStackBase {
    event UnderwriterFeePercentageChanged(uint256 fee);

    function setUp() public {
        _deployMTMStack(AccFlags({ benchmark: false, mtmProjection: false }));
        _enableInsurance(1_000_000e18, 0.2e18);
        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
    }

    function _disable() internal {
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(0)), IInsuranceVault(address(0)));
    }

    function _gain(uint256 nav) internal {
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        mtmStrategy.setTotalAssets(nav);
    }

    function _checkpoint() internal {
        vm.prank(address(jrt));
        cdo.updateAccounting();
    }

    function test_disableStopsFutureFees() public {
        vm.expectEmit(false, false, false, true, address(cdo));
        emit UnderwriterFeePercentageChanged(0);
        _disable();
        assertEq(accounting.underwriterFeeBps(), 0);
        assertEq(address(accounting.insurancePool()), address(0));
        _gain(2100e18);
        _checkpoint();
        assertEq(accounting.underwriterFeeNav(), 0, "no fee after disabling coverage");
        assertGt(accounting.srtBaseNav(), 1000e18, "Senior still earns gain");
    }

    function test_disableCheckpointsAndPreservesEarnedFees() public {
        _gain(2100e18);
        _disable();
        uint256 earned = accounting.underwriterFeeNav();
        assertApproxEqRel(earned, 2.5e18, 0.001e18, "pre-disable gain pays the old fee");
        _gain(2200e18);
        _checkpoint();
        assertEq(accounting.underwriterFeeNav(), earned, "booked fees preserved, no new fees");
    }

    function test_disableWithZeroFeeAndRepeatedDisable() public {
        vm.prank(address(pool));
        cdo.setUnderwriterFeeBps(0);
        _disable();
        _disable();
        assertEq(accounting.underwriterFeeBps(), 0);
    }

    function test_nonzeroConfigurationKeepsFee() public {
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(0)));
        assertEq(accounting.underwriterFeeBps(), 0.2e18);
    }
}
