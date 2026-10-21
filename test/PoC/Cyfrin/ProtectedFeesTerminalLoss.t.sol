// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";
import {IInsurancePool} from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import {MockInsurancePool} from "../../symbiotic/mocks/MockInsurancePool.sol";
import {IProRataAccounting, AccountingRedemptionHarness, DiscreteAccountingRedemptionHarness,
    DYSAccountingRedemptionHarness, MTMRedemptionHarness} from "../../symbiotic/ProRataRedemption.t.sol";

interface ITerminalLossAccounting is IProRataAccounting {
    function seedFee(uint256 fee) external;
    function updateAccounting() external;
    function totalUnderwriterFeeNav() external view returns (uint256);
}

contract TerminalAccounting is AccountingRedemptionHarness {
    function seedFee(uint256 fee) external {
        underwriterFeeNav = fee;
        nav += fee;
        feeWatermarkNav = nav;
    }
}

contract TerminalDiscrete is DiscreteAccountingRedemptionHarness {
    function seedFee(uint256 fee) external {
        underwriterFeeNav = fee;
        nav += fee;
        feeWatermarkNav = nav;
    }
}

contract TerminalDYS is DYSAccountingRedemptionHarness {
    constructor() DYSAccountingRedemptionHarness(false) {}
    function seedFee(uint256 fee) external {
        underwriterFeeNav = fee;
        nav += fee;
        feeWatermarkNav = nav;
    }
}

contract TerminalMTM is MTMRedemptionHarness {
    constructor() MTMRedemptionHarness(false) {}
    function seedFee(uint256 fee) external {
        underwriterFeeNav = fee;
        nav += fee;
        feeWatermarkNav = nav;
    }
}

/// @notice Reproduces the report's already-accrued fee state; real accounting, mocked strategy and coverage.
contract ProtectedFeesTerminalLossTest is Test {
    ITerminalLossAccounting accounting;
    MockInsurancePool pool;
    uint256 strategyNav;

    function totalStrategyAssets() external view returns (uint256) { return strategyNav; }
    function totalStrategyAssets(uint256, uint256) external view returns (uint256) { return strategyNav; }
    function totalStrategyAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        return (strategyNav, block.timestamp, strategyNav, block.timestamp);
    }

    function _deploy(uint256 variant, uint256 junior, uint256 senior) internal {
        vm.warp(1_750_000_000);
        strategyNav = 0;
        address impl;
        if (variant == 0) {
            impl = address(new TerminalAccounting());
        } else if (variant == 1) {
            impl = address(new TerminalDiscrete());
        } else if (variant == 2) {
            impl = address(new TerminalDYS());
        } else {
            impl = address(new TerminalMTM());
        }
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = ITerminalLossAccounting(address(new ERC1967Proxy(impl,
            abi.encodeWithSignature("initialize(address,address,address,address)", address(this), address(acm), address(this), address(0)))));
        pool = new MockInsurancePool();
        accounting.setInsurancePool(IInsurancePool(address(pool)));
        accounting.seed(junior, senior, 0, 0, 0, 0, 0, 1e18);
        accounting.seedFee(100e18);
        strategyNav = junior + senior + 100e18;
    }

    function _assertIdentity() internal view {
        assertEq(accounting.nav() + accounting.insuranceAmount(), accounting.jrtBaseNav() +
            accounting.srtBaseNav() + accounting.reserveNav() + accounting.underwriterFeeNav());
    }

    function _settle(uint256 variant) internal {
        _deploy(variant, 1000e18, 1000e18);
        strategyNav = 50e18;
        uint256 dust = variant == 1 ? 0 : 1e18;
        vm.expectCall(address(pool), abi.encodeCall(IInsurancePool.request, (address(this), 1050e18 + dust)));
        accounting.updateAccounting();
        assertEq(accounting.nav(), 50e18);
        assertEq(accounting.jrtBaseNav(), dust);
        assertEq(accounting.srtBaseNav(), 50e18 - dust);
        assertEq(accounting.reserveNav(), 0);
        assertEq(accounting.underwriterFeeNav(), 0);
        assertEq(accounting.insuranceAmount(), 0);
        _assertIdentity();
        accounting.updateAccounting();
        assertEq(accounting.totalUnderwriterFeeNav(), 0, "fee preview no longer blocks settlement");
        // Senior can now exit against the residual assets.
        accounting.updateBalanceFlow(0, 0, 0, 10e18);
        strategyNav -= 10e18;
        _assertIdentity();
    }

    function test_AccountingSettlesResidualAssets() public { _settle(0); }
    function test_DiscreteSettlesResidualAssets() public { _settle(1); }
    function test_DYSSettlesResidualAssets() public { _settle(2); }
    function test_MTMSettlesResidualAssets() public { _settle(3); }

    function test_allVariantsInsurancePrecedesFees() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 1000e18, 1000e18);
            pool.setCapacity(2000e18);
            strategyNav = 1050e18;
            accounting.updateAccounting();
            uint256 dust = i == 1 ? 0 : 1e18;
            assertEq(accounting.srtBaseNav(), 1000e18);
            assertEq(accounting.underwriterFeeNav(), 100e18);
            assertEq(accounting.totalUnderwriterFeeNav(), 100e18);
            assertEq(accounting.insuranceAmount(), 50e18 + dust);
            assertEq(pool.capacity(), 1950e18 - dust);
            _assertIdentity();
        }
    }

    function test_allVariantsInsureFullRemainderIncludingFeesAndDust() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 1000e18, 1000e18);
            pool.setCapacity(2000e18);
            strategyNav = 50e18;
            accounting.updateAccounting();
            uint256 dust = i == 1 ? 0 : 1e18;
            assertEq(accounting.insuranceAmount(), 1050e18 + dust);
            assertEq(accounting.srtBaseNav(), 1000e18);
            assertEq(accounting.jrtBaseNav(), dust);
            assertEq(accounting.underwriterFeeNav(), 100e18);
            assertEq(pool.capacity(), 950e18 - dust);
            _assertIdentity();
        }
    }

    function test_allVariantsPartialInsuranceLeavesSeniorResidual() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 1000e18, 1000e18);
            pool.setCapacity(100e18);
            strategyNav = 50e18;
            accounting.updateAccounting();
            uint256 dust = i == 1 ? 0 : 1e18;
            assertEq(accounting.insuranceAmount(), 100e18);
            assertEq(accounting.srtBaseNav(), 150e18 - dust);
            assertEq(accounting.underwriterFeeNav(), 0);
            _assertIdentity();
        }
    }

    function test_allVariantsInsureFeesWithoutSenior() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 1e18, 0);
            pool.setCapacity(2000e18);
            strategyNav = 50e18;
            accounting.updateAccounting();
            uint256 dust = i == 1 ? 0 : 1e18;
            assertEq(accounting.insuranceAmount(), 50e18 + dust);
            assertEq(accounting.srtBaseNav(), 0);
            assertEq(accounting.jrtBaseNav(), dust);
            assertEq(accounting.underwriterFeeNav(), 100e18);
            assertEq(pool.capacity(), 1950e18 - dust);
            _assertIdentity();
        }
    }

    function test_existingTerminalDustCheckIsPreserved() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 1000e18, 1000e18);
            strategyNav = 0;
            if (i != 1) {
                vm.expectRevert("NavBelowMinimum");
                accounting.updateAccounting();
                assertEq(accounting.nav(), 2100e18);
            } else {
                accounting.updateAccounting();
                assertEq(accounting.jrtBaseNav(), 0);
                assertEq(accounting.srtBaseNav(), 0);
                assertEq(accounting.underwriterFeeNav(), 0);
                assertEq(accounting.insuranceAmount(), 0);
            }
            _assertIdentity();
        }
    }

    function test_allVariantsZeroNavInsuresFeesAndDust() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 1000e18, 1000e18);
            pool.setCapacity(2000e18);
            strategyNav = 0;
            accounting.updateAccounting();
            uint256 dust = i == 1 ? 0 : 1e18;
            assertEq(accounting.jrtBaseNav(), dust);
            assertEq(accounting.srtBaseNav(), 1000e18);
            assertEq(accounting.underwriterFeeNav(), 100e18);
            assertEq(accounting.insuranceAmount(), 1100e18 + dust);
            assertEq(pool.capacity(), 900e18 - dust);
            _assertIdentity();
        }
    }

    function test_emptyMarketZeroNavPreservesExistingShortcutPolicy() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 0, 0);
            pool.setCapacity(2000e18);
            strategyNav = 0;
            accounting.updateAccounting();
            uint256 covered = i == 3 ? 0 : 100e18;
            assertEq(accounting.underwriterFeeNav(), covered);
            assertEq(accounting.insuranceAmount(), covered);
            assertEq(pool.capacity(), 2000e18 - covered);
            _assertIdentity();
        }
    }

    function test_allVariantsEmptyMarketZeroNavWritesOffUncoveredFees() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 0, 0);
            strategyNav = 0;
            accounting.updateAccounting();
            assertEq(accounting.underwriterFeeNav(), 0);
            assertEq(accounting.insuranceAmount(), 0);
            _assertIdentity();
        }
    }
}
