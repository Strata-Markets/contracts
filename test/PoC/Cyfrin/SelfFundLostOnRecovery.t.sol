// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Accounting} from "../../../contracts/tranches/Accounting.sol";
import {DiscreteAccounting} from "../../../contracts/tranches/DiscreteAccounting.sol";
import {DYSAccounting} from "../../../contracts/tranches/DYSAccounting.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {ValuationInsuranceFixture} from "./InsuredSeniorAssetTime.t.sol";

interface ISelfFundCostBasis {
    function srtFundNav() external view returns (uint256);
    function srtFundedGrossNav() external view returns (uint256);
    function setFeeRetentionBps(uint256, uint256) external;
    function accrueFee(bool, uint256) external;
}

/// @notice Auditor recovery/drop scenario, exercised against each real accounting and middleware.
abstract contract SelfFundLostOnRecoveryTests is ValuationInsuranceFixture {
    function setUp() public override {
        super.setUp();
        mockAprBase = 0;
    }

    function _fund() internal view returns (uint256) {
        return ISelfFundCostBasis(address(accounting)).srtFundNav();
    }

    function _gross() internal view returns (uint256) {
        return ISelfFundCostBasis(address(accounting)).srtFundedGrossNav();
    }

    function _deposit(uint256 amount) internal {
        mockStrategyTvl += amount;
        accounting.updateBalanceFlow(0, 0, amount, 0);
    }

    function _enter() internal {
        accounting.setValuationPrice(0.8e18);
        _deposit(400e18);
        assertEq(_fund(), 100e18);
    }

    function test_recoveryAndDropPreserveJuniorAndSenior() public {
        _enter();
        (uint256 junior, uint256 senior,) = accounting.totalAssets();
        assertEq(junior, 750e18);
        assertEq(senior, 1650e18);
        uint128[3] memory peaks = [uint128(0.95e18), uint128(0.99e18), uint128(0.95e18)];
        for (uint256 i; i < peaks.length; ++i) {
            accounting.setValuationPrice(peaks[i]);
            assertEq(_fund(), 100e18, "entry self-funding retained");
            (, uint256 atPeak,) = accounting.totalAssets();
            assertApproxEqAbs(atPeak, 1000e36 / peaks[i] + 400e18, 1, "current-price cap still applies");
            accounting.setValuationPrice(0.8e18);
            (uint256 j, uint256 s,) = accounting.totalAssets();
            assertEq(j, junior);
            assertEq(s, senior);
        }
    }

    function test_recoveryDoesNotIncreaseInsuranceNeedOnRedip() public {
        mockStrategyTvl -= 900e18;
        accounting.updateBalanceFlow(0, 900e18, 0, 0);
        _enter();
        uint256 claim = accounting.insuranceAmount();
        uint256 senior = accounting.srtBaseNav();
        assertEq(claim, 151e18);
        accounting.setValuationPrice(0.95e18);
        assertEq(accounting.insuranceAmount(), 0);
        uint256 slashedBefore = _totalSlashed();
        accounting.setValuationPrice(0.8e18);
        assertEq(accounting.insuranceAmount(), claim);
        assertEq(accounting.srtBaseNav(), senior);
        // No proceeds were funded in this fixture, so the existing middleware re-slashes the restored claim.
        // It must not also slash for self-funding lost during recovery.
        assertEq(_totalSlashed() - slashedBefore, claim * 8 / 10);
    }

    function test_exitAfterRecoveryScalesRetainedBasis() public {
        _enter();
        accounting.setValuationPrice(0.95e18);
        (, uint256 senior,) = accounting.totalAssets();
        uint256 assetsOut = senior / 2;
        accounting.updateBalanceFlow(0, 0, 0, assetsOut);
        mockStrategyTvl -= assetsOut;
        assertApproxEqAbs(_fund(), 50e18, 1);
        assertApproxEqAbs(_gross(), 200e18, 1);
        accounting.setValuationPrice(0.8e18);
        (, senior,) = accounting.totalAssets();
        assertApproxEqAbs(senior, 825e18, 3);
    }

    function test_feeAfterRecoveryScalesRetainedBasis() public {
        _enter();
        accounting.setValuationPrice(0.95e18);
        ISelfFundCostBasis a = ISelfFundCostBasis(address(accounting));
        a.setFeeRetentionBps(0, 0);
        a.accrueFee(false, 140e18);
        assertEq(_fund(), 90e18);
        assertEq(_gross(), 360e18);
        accounting.setValuationPrice(0.8e18);
        assertEq(_fund(), 90e18);
    }

    function test_newDepositAtRecoveryAddsEntryBasis() public {
        _enter();
        accounting.setValuationPrice(0.95e18);
        _deposit(190e18);
        assertEq(_fund(), 110e18);
        assertEq(_gross(), 590e18);
        accounting.setValuationPrice(0.8e18);
        assertEq(_fund(), 110e18);
        (uint256 junior, uint256 senior,) = accounting.totalAssets();
        assertEq(junior, 712.5e18);
        assertEq(senior, 1877.5e18);
    }

    function test_fullRecoveryClearsBothTrackers() public {
        _enter();
        accounting.setValuationPrice(0.95e18);
        accounting.setValuationPrice(1e18);
        assertEq(_fund(), 0);
        assertEq(_gross(), 0);
    }
}

contract SelfFundLostOnRecoveryAccountingTest is SelfFundLostOnRecoveryTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(address(new Accounting(18)),
            abi.encodeWithSignature("initialize(address,address,address,address)", address(this), address(acm), address(this), address(this))));
    }
}

contract SelfFundLostOnRecoveryDiscreteTest is SelfFundLostOnRecoveryTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(address(new DiscreteAccounting(18, false)),
            abi.encodeWithSignature("initialize(address,address,address,address)", address(this), address(acm), address(this), address(this))));
    }
}

contract SelfFundLostOnRecoveryDYSTest is SelfFundLostOnRecoveryTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(address(new DYSAccounting(18, false, false, false, true, false)),
            abi.encodeWithSignature("initialize(address,address,address,address)", address(this), address(acm), address(this), address(this))));
    }
}

contract SelfFundLostOnRecoveryMTMTest is SelfFundLostOnRecoveryTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(address(new MTMAccounting(18, false, true, false, true, false, true)),
            abi.encodeWithSignature("initialize(address,address,address,address)", address(this), address(acm), address(this), address(this))));
    }
}
