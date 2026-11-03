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
        assertEq(_fund(), 80e18);
    }

    function test_recoveryAndDropPreserveJuniorAndSenior() public {
        _enter();
        (uint256 junior, uint256 senior,) = accounting.totalAssets();
        assertEq(junior, 750e18);
        assertEq(senior, 1650e18);
        uint128[3] memory peaks = [uint128(0.95e18), uint128(0.99e18), uint128(0.95e18)];
        for (uint256 i; i < peaks.length; ++i) {
            accounting.setValuationPrice(peaks[i]);
            assertEq(_fund(), 80e18, "entry self-funding retained");
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
        // Pending slash proceeds fully cover the restored claim.
        assertEq(_totalSlashed(), slashedBefore);
    }

    function test_exitAfterRecoveryScalesRetainedBasis() public {
        _enter();
        accounting.setValuationPrice(0.95e18);
        (, uint256 senior,) = accounting.totalAssets();
        uint256 assetsOut = senior / 2;
        accounting.updateBalanceFlow(0, 0, 0, assetsOut);
        mockStrategyTvl -= assetsOut;
        assertApproxEqAbs(_fund(), 40e18, 1);
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
        (, uint256 effectiveBefore,) = accounting.totalAssets();
        uint256 expectedFund = 80e18 - uint256(80e18) * 140e18 / effectiveBefore;
        uint256 expectedGross = 400e18 - uint256(400e18) * 140e18 / effectiveBefore;
        a.accrueFee(false, 140e18);
        assertEq(_fund(), expectedFund);
        assertEq(_gross(), expectedGross);
        accounting.setValuationPrice(0.8e18);
        assertEq(_fund(), expectedFund);
    }

    function test_newDepositAtRecoveryAddsEntryBasis() public {
        _enter();
        accounting.setValuationPrice(0.95e18);
        _deposit(190e18);
        assertEq(_fund(), 89.5e18);
        assertEq(_gross(), 590e18);
        accounting.setValuationPrice(0.8e18);
        assertEq(_fund(), 89.5e18);
        (uint256 junior, uint256 senior,) = accounting.totalAssets();
        assertEq(junior, 714.375e18);
        assertEq(senior, 1875.625e18);
    }

    function test_deeperDepegPreservesEntryDollarValue() public {
        _enter();
        accounting.setValuationPrice(0.5e18);
        (uint256 junior, uint256 senior,) = accounting.totalAssets();
        // Original Senior $1000 plus the deposit's $320, without an extra $30 transfer.
        assertEq(senior, 2640e18);
        assertEq(junior, 1e18);
        assertEq(accounting.insuranceAmount(), 241e18);
        assertEq(_totalSlashed(), 120.5e18);
        assertEq(_fund(), 80e18);
    }

    function test_deeperDepegWithJuniorHeadroom() public {
        mockStrategyTvl += 9000e18;
        accounting.updateBalanceFlow(9000e18, 0, 0, 0);
        _enter();
        accounting.setValuationPrice(0.5e18);
        (uint256 junior, uint256 senior,) = accounting.totalAssets();
        assertEq(senior, 2640e18);
        assertEq(junior, 8760e18);
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(_totalSlashed(), 0);
    }

    function test_partialRecoveryThenDeeperDepegPreservesEntryValue() public {
        _enter();
        accounting.setValuationPrice(0.95e18);
        accounting.setValuationPrice(0.5e18);
        (, uint256 senior,) = accounting.totalAssets();
        assertEq(senior, 2640e18);
        assertEq(accounting.insuranceAmount(), 241e18);
        assertEq(_fund(), 80e18);
    }

    // The auditor's three entry/deeper-depeg scenarios and no-entry control.
    function _checkEntryValue(uint256 junior, uint128 entryPrice, uint128 price, uint256 amount) internal {
        mockStrategyTvl += junior - 1000e18;
        accounting.updateBalanceFlow(junior - 1000e18, 0, 0, 0);
        _deposit(899_000e18);
        accounting.setValuationPrice(entryPrice);
        assertEq(accounting.insuranceAmount(), 0);
        _deposit(amount);
        accounting.setValuationPrice(price);
        uint256 expectedSenior = (900_000e36 + amount * entryPrice) / price;
        uint256 expectedClaim = expectedSenior - (900_000e18 + amount) - (junior - 1e18);
        (, uint256 senior,) = accounting.totalAssets();
        assertApproxEqAbs(senior, expectedSenior, 2, "no excess Senior protection");
        assertApproxEqAbs(accounting.insuranceAmount(), expectedClaim, 2, "no excess insurance claim");
        assertApproxEqAbs(_totalSlashed(), expectedClaim * price / 1e18, 2, "no excess collateral slash");
    }

    function test_auditorEntryAt90Then50() public {
        _checkEntryValue(300_000e18, 0.9e18, 0.5e18, 500_000e18);
    }

    function test_auditorEntryAt95Then80() public {
        _checkEntryValue(200_000e18, 0.95e18, 0.8e18, 500_000e18);
    }

    function test_auditorEntryAt50Then25() public {
        _checkEntryValue(2_700_000e18, 0.5e18, 0.25e18, 1_000_000e18);
    }

    function test_auditorNoEntryControl() public {
        _checkEntryValue(300_000e18, 0.9e18, 0.5e18, 0);
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
    function _deployAccounting() internal override returns (address a) {
        a = address(new ERC1967Proxy(address(new DYSAccounting(18, false, false, false, true, false)),
            abi.encodeWithSignature("initialize(address,address,address,address)", address(this), address(acm), address(this), address(this))));
        _setDefaultRiskModel(a);
    }
}

contract SelfFundLostOnRecoveryMTMTest is SelfFundLostOnRecoveryTests {
    function _deployAccounting() internal override returns (address a) {
        a = address(new ERC1967Proxy(address(new MTMAccounting(18, false, true, false, true, false, true)),
            abi.encodeWithSignature("initialize(address,address,address,address)", address(this), address(acm), address(this), address(this))));
        _setDefaultRiskModel(a);
    }
}
