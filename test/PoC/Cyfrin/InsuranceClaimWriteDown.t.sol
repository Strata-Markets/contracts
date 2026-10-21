// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccountingLib} from "../../../contracts/tranches/utils/AccountingLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";
import {IInsurancePool} from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import {MockInsurancePool} from "../../symbiotic/mocks/MockInsurancePool.sol";
import {IProRataAccounting, AccountingRedemptionHarness, DiscreteAccountingRedemptionHarness,
    DYSAccountingRedemptionHarness, MTMRedemptionHarness} from "../../symbiotic/ProRataRedemption.t.sol";
import {MockERC20} from "../../../contracts/test/MockERC20.sol";
import {CoveredClaimFreezeTest} from "./CoveredClaimFreeze.t.sol";

interface IWriteDownAccounting is IProRataAccounting {
    function writeDownInsuranceClaim(uint256 fundedBase, uint256 maxPrincipalLoss) external returns (uint256);
    function updateAccounting() external;
    function setFloorRate(uint256 rate) external;
    function windowNetFlows() external view returns (int256);
    function srtNavTime() external view returns (uint256);
    function navTimeNet() external view returns (uint256);
    function windowStartSrtNav() external view returns (uint256);
}

contract SignedWriteDownMtmHarness is MTMRedemptionHarness {
    constructor() MTMRedemptionHarness(false) {}
    function setProjectedLoss(int256 value) external { srtPnLProjected = value; }
}

contract InsuranceClaimWriteDownTest is Test {
    IWriteDownAccounting a;
    uint256 strategyNav;
    MockInsurancePool pool;
    function totalStrategyAssets() external view returns (uint256) { return strategyNav; }
    function totalStrategyAssets(uint256, uint256) external view returns (uint256) { return strategyNav; }
    function totalStrategyAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        return (strategyNav, block.timestamp, strategyNav, block.timestamp);
    }

    function _deploy(uint256 variant, uint256 projection) internal {
        vm.warp(1_750_000_000);
        strategyNav = 0;
        address impl;
        if (variant == 0) {
            impl = address(new AccountingRedemptionHarness());
        } else if (variant == 1) {
            impl = address(new DiscreteAccountingRedemptionHarness());
        } else if (variant == 2) {
            impl = address(new DYSAccountingRedemptionHarness(false));
        } else {
            impl = address(new SignedWriteDownMtmHarness());
        }
        AccessControlManager acm = new AccessControlManager(address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        a = IWriteDownAccounting(address(new ERC1967Proxy(impl,
            abi.encodeWithSignature("initialize(address,address,address,address)", address(this), address(acm), address(this), address(0)))));
        pool = new MockInsurancePool();
        a.setInsurancePool(IInsurancePool(address(pool)));
        a.seed(101e18, 1000e18 + projection, 101e18, 0, 0, 0, projection, 1e18);
        strategyNav = 1000e18 + projection;
    }

    function _identity() internal view {
        assertEq(a.nav() + a.insuranceAmount(), a.jrtBaseNav() + a.srtBaseNav() + a.reserveNav() + a.underwriterFeeNav());
    }

    function test_allVariantsWriteDownAndRedeem() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 0);
            a.updateAccounting();
            a.writeDownInsuranceClaim(90.9e18, 10.1e18);
            assertEq(a.srtBaseNav(), 989.9e18);
            assertEq(a.insuranceAmount(), 90.9e18);
            assertEq(a.nav(), strategyNav);
            assertEq(a.jrtBaseNav(), 101e18);
            _identity();
            a.updateAccounting();
            assertEq(a.srtBaseNav(), 989.9e18, "same-block checkpoint does not restore write-down");
            uint256 paid = a.updateBalanceFlow(0, 0, 0, 494.95e18);
            assertEq(paid, 45.45e18);
            strategyNav -= 449.5e18;
            _identity();
        }
    }

    function test_depegHaircutScalesCreditAndSurvivesRecovery() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 0);
            // 1,000 principal plus 250 valuation credit at 0.80; Junior is at its floor.
            a.seed(1e18, 1250e18, 351e18, 250e18, 0, 0, 0, 0.8e18);
            strategyNav = 900e18;
            a.updateAccounting();
            pool.setCapacity(10000e18);
            vm.expectRevert("ExceedsMaxPrincipalLoss");
            a.writeDownInsuranceClaim(226e18, 100e18 - 1);
            assertEq(a.writeDownInsuranceClaim(226e18, 125e18), 100e18);
            assertEq(a.srtBaseNav(), 1125e18);
            assertEq(a.srtInsuranceFundNav(), 225e18);
            assertEq(a.insuranceAmount(), 226e18);
            a.updateAccounting();
            assertEq(a.insuranceAmount(), 226e18, "no replacement claim at unchanged price");
            a.setValuationPrice(0.9e18);
            assertEq(a.srtBaseNav(), 1000e18);
            assertEq(a.insuranceAmount(), 101e18);
            a.setValuationPrice(0.8e18);
            assertEq(a.srtBaseNav(), 1125e18, "only the reduced principal is protected");
            a.setValuationPrice(1e18);
            assertEq(a.srtBaseNav(), 900e18, "principal loss remains after credit unwinds");
            assertEq(a.insuranceAmount(), 1e18);
            _identity();
        }
    }

    function test_depegHaircutScalesEntrySelfFunding() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 0);
            a.seed(1e18, 1650e18, 451e18, 250e18, 400e18, 100e18, 0, 0.8e18);
            strategyNav = 1200e18;
            a.updateAccounting();
            pool.setCapacity(10000e18);
            assertEq(a.writeDownInsuranceClaim(286e18, 140e18), 140e18);
            assertEq(a.srtFundedGrossNav(), 360e18);
            assertEq(a.srtFundNav(), 90e18);
            assertEq(a.srtInsuranceFundNav(), 225e18);
            a.updateAccounting();
            assertEq(a.insuranceAmount(), 286e18);
            assertEq(a.srtBaseNav(), 1485e18);
            _identity();
        }
    }

    function test_depegWriteDownCannotConsumeValuationCreditAsPrincipal() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 0);
            a.seed(1e18, 1250e18, 1250e18, 250e18, 0, 0, 0, 0.8e18);
            strategyNav = 1e18;
            vm.expectRevert("ExceedsMaxPrincipalLoss");
            a.writeDownInsuranceClaim(0, 1000e18 - 1);
            assertEq(a.writeDownInsuranceClaim(0, 1001e18), 1000e18);
            assertEq(a.srtBaseNav(), 0);
            assertEq(a.insuranceAmount(), 0);
            assertEq(a.srtInsuranceFundNav(), 0);
            a.updateAccounting();
            _identity();
        }
    }

    function test_depegProjectionUnwindRetainsPrincipalLoss() public {
        for (uint256 i = 2; i < 4; ++i) {
            _deploy(i, 0);
            a.seed(1e18, 1270e18, 371e18, 250e18, 0, 0, 20e18, 0.8e18);
            strategyNav = 900e18;
            pool.setCapacity(10000e18);
            a.updateAccounting();
            assertEq(a.writeDownInsuranceClaim(251e18, 100e18), 100e18);
            assertEq(a.srtPnLProjected(), 20e18);
            strategyNav += 1e18;
            a.updateAccounting();
            assertEq(a.srtPnLProjected(), 0);
            assertEq(a.srtBaseNav() - a.srtInsuranceFundNav(), 900e18);
            _identity();
        }
    }

    function test_valuationOnlyClaimCannotBeWrittenOffAsRealizedLoss() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 0);
            a.seed(1e18, 1250e18, 250e18, 250e18, 0, 0, 0, 0.8e18);
            vm.expectRevert("InsuranceShortfallUnresolved");
            a.writeDownInsuranceClaim(100e18, 1e18);
        }
    }

    function test_creditReleaseCanCloseGapWithoutPrincipalLoss() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 0);
            a.seed(101e18, 1250e18, 351e18, 250e18, 0, 0, 0, 0.8e18);
            strategyNav = 1000e18;
            assertEq(a.writeDownInsuranceClaim(251e18, 0), 0);
            assertEq(a.srtBaseNav(), 1150e18);
            assertEq(a.srtInsuranceFundNav(), 150e18);
            assertEq(a.insuranceAmount(), 251e18);
            _identity();
        }
    }

    function test_assetTimeKeepsStrategyBackedSeniorCapitalUnchanged() public {
        for (uint256 i = 2; i < 4; ++i) {
            _deploy(i, 0);
            vm.warp(block.timestamp + 1 days);
            a.updateAccounting();
            assertEq(a.srtNavTime(), 899e18 * 1 days);
            a.writeDownInsuranceClaim(90.9e18, 10.1e18);
            vm.warp(block.timestamp + 1 days);
            a.updateAccounting();
            assertEq(a.srtNavTime(), 899e18 * 2 days, "claim and Senior decrease equally");
            assertEq(a.navTimeNet(), 1000e18 * 2 days);
            _identity();
        }
    }

    function test_projectionUnwindPreservesWriteDown() public {
        for (uint256 i = 2; i < 4; ++i) {
            _deploy(i, 20e18);
            a.updateAccounting();
            a.writeDownInsuranceClaim(90.9e18, 10.1e18);
            assertEq(a.srtPnLProjected(), 20e18, "projection is not a settled write-down");
            assertEq(a.srtBaseNav(), 1009.9e18);
            strategyNav += 1e18;
            a.updateAccounting();
            assertEq(a.srtPnLProjected(), 0);
            assertEq(a.srtBaseNav(), 989.9e18, "reconciliation retains the permanent loss");
            assertEq(a.insuranceAmount(), 89.9e18, "recovery repays only the remaining claim");
            _identity();
        }
    }

    function test_negativeProjectionRecoveryPreservesWriteDown() public {
        _deploy(3, 0);
        a.seed(121e18, 980e18, 101e18, 0, 0, 0, 0, 1e18);
        SignedWriteDownMtmHarness(address(a)).setProjectedLoss(-20e18);
        a.writeDownInsuranceClaim(90.9e18, 10.1e18);
        assertEq(a.srtBaseNav(), 969.9e18);
        strategyNav += 1e18;
        a.updateAccounting();
        assertEq(a.srtBaseNav(), 989.9e18, "only temporary loss is restored");
        assertEq(a.srtPnLProjected(), 0);
        _identity();
    }

    function test_writeDownCannotConsumeLiveProjection() public {
        for (uint256 i = 2; i < 4; ++i) {
            _deploy(i, 0);
            a.seed(100e18, 20e18, 30e18, 0, 0, 0, 15e18, 1e18);
            vm.expectRevert("InsuranceShortfallUnresolved");
            a.writeDownInsuranceClaim(24e18, 6e18);
            a.writeDownInsuranceClaim(25e18, 5e18);
            assertEq(a.srtBaseNav(), 15e18);
            assertEq(a.srtPnLProjected(), 15e18);
            _identity();
        }
    }

    function test_floorDoesNotRestoreAcceptedLoss() public {
        for (uint256 i = 2; i < 4; ++i) {
            _deploy(i, 0);
            a.setFloorRate(0.01e18);
            a.updateAccounting();
            int256 flows = a.windowNetFlows();
            a.writeDownInsuranceClaim(90.9e18, 10.1e18);
            assertEq(a.windowNetFlows(), flows - int256(10.1e18));
            strategyNav -= 50e18;
            a.updateAccounting();
            assertEq(a.srtBaseNav(), uint256(989.9e18) * 99 / 100);
            _identity();
        }
    }

    function test_accountingRejectsUnauthorizedOrInvalidWriteDown() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i, 0);
            vm.prank(address(0x1234));
            vm.expectRevert();
            a.writeDownInsuranceClaim(100e18, 1e18);
            vm.expectRevert("ExceedsMaxPrincipalLoss");
            a.writeDownInsuranceClaim(90.9e18, 0);
            vm.expectRevert("ExceedsMaxPrincipalLoss");
            a.writeDownInsuranceClaim(0, 100e18);
            a.seed(1e18, 1000e18, 101e18, 0, 0, 0, 0, 0.9e18);
            a.writeDownInsuranceClaim(100e18, 1e18);
            assertEq(a.srtBaseNav(), 999e18);
        }
    }
}

/// @notice Real CDO, Accounting, Ethena strategy, middleware and funded insurance vault.
contract InsuranceClaimWriteDownFullStackTest is CoveredClaimFreezeTest {
    function _prepareShortfall() internal {
        _prepareShortfallAt(1e18);
    }

    function _prepareShortfallAt(uint128 price) internal {
        _seedMarket(1000e18, 1000e18);
        vm.prank(address(sUSDeStrategy));
        sUSDe.transfer(lossSink, 1100e18);
        vm.prank(address(srtVault));
        cdo.updateAccounting();
        assertEq(accounting.insuranceAmount(), 101e18);
        uint256 remaining = collateral.balanceOf(address(adapter));
        vm.prank(address(adapter));
        collateral.transfer(lossSink, remaining);
        vm.prank(cdo.owner());
        cdo.setValuationKeeper(address(this));
        cdo.setValuationPrice(0.9e18);
        USDe.mint(address(this), 90.9e18);
        USDe.approve(address(cdo), 90.9e18);
        cdo.fundInsuranceClaim(address(USDe), 90.9e18);
        assertEq(cdo.writeDownInsuranceClaim(10.1e18), 0);
        cdo.setValuationPrice(price);
    }

    function test_repegShortfallWriteDownEnablesFundedExits() public {
        _prepareShortfall();
        vm.prank(address(0x1234));
        vm.expectRevert();
        cdo.writeDownInsuranceClaim(10.1e18);
        vm.expectRevert("ExceedsMaxPrincipalLoss");
        cdo.writeDownInsuranceClaim(10.1e18 - 1);
        assertEq(cdo.writeDownInsuranceClaim(20e18), 10.1e18);
        assertEq(accounting.insuranceAmount(), 90.9e18);
        assertEq(accounting.srtBaseNav(), 989.9e18);
        assertEq(accounting.jrtBaseNav(), 1e18);
        assertEq(accounting.nav(), 900e18);
        assertEq(middleware.slashedClaimBase(address(cdo)), 90.9e18);
        assertEq(insuranceVault.fundedCoverage(), 90.9e18);
        assertEq(cdo.writeDownInsuranceClaim(1), 0);
        vm.prank(snr);
        srtVault.withdraw(address(USDe), 494.95e18, snr, snr);
        assertEq(insuranceVault.fundedCoverage(), 45.45e18);
        assertEq(accounting.insuranceAmount(), 45.45e18);
        // Insurance pays immediately; the Ethena strategy portion follows its normal cooldown.
        assertEq(USDe.balanceOf(snr), 45.45e18);
        assertEq(accounting.nav(), 450.5e18);
        // Leave the tranche's minimum supply while confirming later exits also have backing.
        vm.prank(snr);
        srtVault.withdraw(address(USDe), 494e18, snr, snr);
        assertEq(USDe.balanceOf(snr), 90.9e18 - insuranceVault.fundedCoverage());
        assertGe(insuranceVault.fundedCoverage(), accounting.insuranceAmount());
    }

    function test_partialRecoveryWriteDownEnablesFundedExit() public {
        _prepareShortfallAt(0.99e18);
        uint256 fundedBase = uint256(90.9e18) * 1e18 / 0.99e18;
        uint256 loss = 101e18 - fundedBase;
        vm.expectRevert("ExceedsMaxPrincipalLoss");
        cdo.writeDownInsuranceClaim(loss - 1);
        assertEq(cdo.writeDownInsuranceClaim(20e18), loss);
        assertEq(accounting.insuranceAmount(), fundedBase);
        assertEq(accounting.srtBaseNav(), 1000e18 - loss);
        vm.prank(address(srtVault));
        cdo.updateAccounting();
        assertEq(accounting.insuranceAmount(), fundedBase);
        vm.prank(snr);
        srtVault.withdraw(address(USDe), (1000e18 - loss) / 2, snr, snr);
        assertApproxEqAbs(insuranceVault.fundedCoverage(), 45.45e18, 1);
    }

    function test_sixDecimalCoverageBoundsWriteDownInBaseUnits() public {
        _seedMarket(1000e18, 1000e18);
        vm.prank(address(sUSDeStrategy));
        sUSDe.transfer(lossSink, 1100e18);
        vm.prank(address(srtVault));
        cdo.updateAccounting();
        MockERC20 coverage = new MockERC20("USDC", 6);
        coverage.mint(address(this), 90_900_000);
        coverage.approve(address(cdo), 90_900_000);
        cdo.fundInsuranceClaim(address(coverage), 90_900_000);
        vm.expectRevert("ExceedsMaxPrincipalLoss");
        cdo.writeDownInsuranceClaim(10.1e18 - 1);
        assertEq(cdo.writeDownInsuranceClaim(20e18), 10.1e18);
        assertEq(accounting.insuranceAmount(), 90.9e18);
        assertEq(insuranceVault.fundedCoverage(), 90_900_000);
    }

    function test_checkpointRecoveryBeforeSizingWriteDown() public {
        _prepareShortfall();
        // Recover five base assets in the strategy before calling the operator entry point.
        vm.prank(lossSink);
        sUSDe.transfer(address(sUSDeStrategy), 5e18);
        assertEq(cdo.writeDownInsuranceClaim(10.1e18), 5.1e18, "checkpoint reduces the actual loss below the limit");
        assertEq(accounting.insuranceAmount(), 90.9e18);
        assertEq(accounting.srtBaseNav(), 994.9e18);
        assertEq(accounting.nav(), 905e18);
    }
}

/// @notice Check the search against exhaustive candidates with integer rounding, self-funding and projection.
contract InsuranceWriteDownSizingTest is Test {
    function testFuzz_minimumPrincipalLoss(
        uint256 principal, uint256 gross, uint256 fund, uint128 price,
        uint256 projection, uint256 junior, uint256 realized, uint256 gap
    ) public pure {
        principal = bound(principal, 1, 100);
        gross = bound(gross, 0, principal);
        fund = bound(fund, 0, gross * 9999);
        price = uint128(bound(price, 0.0001e18, 1e18 - 1));
        projection = bound(projection, 0, 20);
        junior = bound(junior, 0, 100);
        realized = bound(realized, 0, principal);
        uint256 capped = Math.min(fund, Math.mulDiv(gross, 1e18 - price, price));
        uint256 credit = Math.saturatingSub(
            Math.saturatingSub(Math.mulDiv(principal + projection, 1e18, price) - principal - projection, capped), junior
        );
        AccountingLib.InsuranceWriteDownState memory state = AccountingLib.InsuranceWriteDownState({
            claim: realized + credit, seniorNav: principal + projection + credit,
            seniorAvailable: principal + credit, valuationCredit: credit,
            fundedGross: gross, selfFund: fund, juniorAvailable: junior, price: price
        });
        gap = bound(gap, 0, _reduction(state, realized));
        uint256 expected;
        while (_reduction(state, expected) < gap) {
            ++expected;
        }
        assertEq(AccountingLib.insuranceWriteDown(state, state.claim - gap, principal), expected);
    }

    function _reduction(AccountingLib.InsuranceWriteDownState memory s, uint256 loss) private pure returns (uint256) {
        uint256 principal = s.seniorAvailable - s.valuationCredit;
        uint256 gross = s.fundedGross * (principal - loss) / principal;
        uint256 fund = s.selfFund * (principal - loss) / principal;
        uint256 remaining = s.seniorNav - s.valuationCredit - loss;
        uint256 need = remaining * 1e18 / s.price - remaining;
        uint256 cap = Math.min(fund, gross * (1e18 - s.price) / s.price);
        need = Math.saturatingSub(Math.saturatingSub(need, cap), s.juniorAvailable);
        return loss + Math.min(s.claim - loss, Math.saturatingSub(s.valuationCredit, need));
    }
}
