// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Accounting } from "../../contracts/tranches/Accounting.sol";
import { DiscreteAccounting } from "../../contracts/tranches/DiscreteAccounting.sol";
import { DYSAccounting } from "../../contracts/tranches/DYSAccounting.sol";
import { IInsurancePool } from "../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import { MTMAccounting } from "../../contracts/tranches/MTMAccounting.sol";
import { AccessControlManager } from "../../contracts/governance/AccessControlManager.sol";
import { MockInsurancePool } from "./mocks/MockInsurancePool.sol";

interface IProRataAccounting {
    function seed(uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint128) external;
    function setInsurancePool(IInsurancePool pool) external;
    function setValuationPrice(uint128 price) external returns (bool);
    function updateBalanceFlow(uint256, uint256, uint256, uint256) external returns (uint256);
    function nav() external view returns (uint256);
    function jrtBaseNav() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
    function reserveNav() external view returns (uint256);
    function underwriterFeeNav() external view returns (uint256);
    function insuranceAmount() external view returns (uint256);
    function srtInsuranceFundNav() external view returns (uint256);
    function srtFundedGrossNav() external view returns (uint256);
    function srtFundNav() external view returns (uint256);
    function srtPnLProjected() external view returns (uint256);
    function srtPaidProjected() external view returns (uint256);
}

contract MTMRedemptionHarness is MTMAccounting {
    constructor(bool conservative) MTMAccounting(18, false, false, false, false, conservative, false) {}

    function seed(uint256 junior, uint256 senior, uint256 claim, uint256 credit,
        uint256 fundedGross, uint256 fund, uint256 projection, uint128 price) external
    {
        jrtBaseNav = junior;
        jrtNavProjected = junior;
        srtBaseNav = senior;
        insuranceAmount = claim;
        srtInsuranceFundNav = credit;
        srtFundedGrossNav = fundedGross;
        srtFundNav = fund;
        srtPnLProjected = projection;
        nav = junior + senior - claim;
        feeWatermarkNav = nav;
        valuationPrice = price;
    }
}

contract AccountingRedemptionHarness is Accounting {
    constructor() Accounting(18) {}

    function seed(uint256 junior, uint256 senior, uint256 claim, uint256 credit,
        uint256 fundedGross, uint256 fund, uint256 projection, uint128 price) external
    {
        jrtBaseNav = junior;
        srtBaseNav = senior;
        insuranceAmount = claim;
        srtInsuranceFundNav = credit;
        srtFundedGrossNav = fundedGross;
        srtFundNav = fund;
        require(projection == 0);
        nav = junior + senior - claim;
        feeWatermarkNav = nav;
        valuationPrice = price;
    }
}

contract DiscreteAccountingRedemptionHarness is DiscreteAccounting {
    constructor() DiscreteAccounting(18, false) {}

    function seed(uint256 junior, uint256 senior, uint256 claim, uint256 credit,
        uint256 fundedGross, uint256 fund, uint256 projection, uint128 price) external
    {
        jrtBaseNav = junior;
        jrtNavProjected = junior;
        srtBaseNav = senior;
        insuranceAmount = claim;
        srtInsuranceFundNav = credit;
        srtFundedGrossNav = fundedGross;
        srtFundNav = fund;
        require(projection == 0);
        nav = junior + senior - claim;
        feeWatermarkNav = nav;
        valuationPrice = price;
    }
}

contract DYSAccountingRedemptionHarness is DYSAccounting {
    constructor(bool conservative) DYSAccounting(18, false, false, false, false, conservative) {}

    function seed(uint256 junior, uint256 senior, uint256 claim, uint256 credit,
        uint256 fundedGross, uint256 fund, uint256 projection, uint128 price) external
    {
        jrtBaseNav = junior;
        jrtNavProjected = junior;
        srtBaseNav = senior;
        insuranceAmount = claim;
        srtInsuranceFundNav = credit;
        srtFundedGrossNav = fundedGross;
        srtFundNav = fund;
        srtPnLProjected = projection;
        nav = junior + senior - claim;
        feeWatermarkNav = nav;
        valuationPrice = price;
    }
}

abstract contract ProRataRedemptionTestBase is Test {
    IProRataAccounting a;

    function totalStrategyAssets() external view returns (uint256) {
        return address(a) == address(0) ? 0 : a.nav();
    }

    function totalStrategyAssets(uint256, uint256) external view returns (uint256) {
        return address(a) == address(0) ? 0 : a.nav();
    }

    function totalStrategyAssetsSnapshot(uint256, uint256)
        external view returns (uint256, uint256, uint256, uint256)
    {
        uint256 value = address(a) == address(0) ? 0 : a.nav();
        return (value, block.timestamp, value, block.timestamp);
    }

    function setUp() public {
        _deploy(false);
    }

    function _deploy(bool conservative) internal virtual;

    function _initialize(address implementation) internal {
        AccessControlManager acm = new AccessControlManager(address(this));
        a = IProRataAccounting(address(new ERC1967Proxy(
            implementation,
            abi.encodeWithSignature("initialize(address,address,address,address)",
                address(this), address(acm), address(this), address(0))
        )));
        MockInsurancePool pool = new MockInsurancePool();
        pool.setCapacity(1_000_000e18);
        a.setInsurancePool(pool);
    }

    function _covered() internal {
        a.seed(1000e18, 1501e18, 501e18, 501e18, 0, 0, 0, 0.4e18);
    }

    function _identity() internal view {
        assertEq(a.nav() + a.insuranceAmount(),
            a.jrtBaseNav() + a.srtBaseNav() + a.reserveNav() + a.underwriterFeeNav());
    }

    function test_auditorExample_tenPercentExit() public {
        _covered();
        uint256 insuranceOut = a.updateBalanceFlow(0, 0, 0, 250e18);
        assertEq(insuranceOut, 50.1e18);
        assertEq(a.jrtBaseNav(), 900.1e18);
        assertEq(a.srtBaseNav(), 1350.9e18);
        assertEq(a.insuranceAmount(), 450.9e18);
        assertEq(a.srtInsuranceFundNav(), 450.9e18);
        assertEq(a.nav(), 1800.1e18);
        _identity();
    }

    function test_depositValuationAndExit_publicFlow() public {
        a.updateBalanceFlow(1000e18, 0, 1000e18, 0);
        a.setValuationPrice(0.4e18);
        assertEq(a.insuranceAmount(), 501e18);
        assertEq(a.updateBalanceFlow(0, 0, 0, 250e18), 50.1e18);
        assertEq(a.jrtBaseNav(), 900.1e18);
        assertEq(a.srtBaseNav(), 1350.9e18);
        _identity();
    }

    function testFuzz_chunking(uint96 amountSeed, uint8 partsSeed) public {
        _covered();
        // Leave dust headroom: fixed asset requests must remain below the recalculated NAV.
        uint256 amount = bound(uint256(amountSeed), 1, 2500e18 - 1000);
        uint256 parts = bound(uint256(partsSeed), 1, 10);
        uint256 snap = vm.snapshotState();
        uint256 expectedInsurance = a.updateBalanceFlow(0, 0, 0, amount);
        uint256 expectedJunior = a.jrtBaseNav();
        uint256 expectedSenior = a.srtBaseNav();
        vm.revertToState(snap);
        uint256 paid;
        for (uint256 i; i < parts; i++) {
            uint256 portion = i + 1 == parts ? amount - (amount / parts) * i : amount / parts;
            paid += a.updateBalanceFlow(0, 0, 0, portion);
        }
        // Component rounding also feeds into principal / 0.4 when NAV is recalculated.
        uint256 tolerance = 5 * parts;
        assertApproxEqAbs(paid, expectedInsurance, tolerance);
        assertApproxEqAbs(a.jrtBaseNav(), expectedJunior, tolerance);
        assertApproxEqAbs(a.srtBaseNav(), expectedSenior, tolerance);
        _identity();
    }

    function test_fullExit_settlesAllCoverage() public {
        _covered();
        assertEq(a.updateBalanceFlow(0, 0, 0, 2500e18), 501e18);
        assertEq(a.srtBaseNav(), 0);
        assertEq(a.jrtBaseNav(), 1e18);
        assertEq(a.insuranceAmount(), 0);
        assertEq(a.srtInsuranceFundNav(), 0);
        _identity();
    }

    function _chunked(uint256 junior, uint256 senior, uint256 claim) internal {
        a.seed(junior, senior, claim, claim, 0, 0, 0, 0.4e18);
        uint256 snap = vm.snapshotState();
        uint256 expectedInsurance = a.updateBalanceFlow(0, 0, 0, 250e18);
        uint256 expectedJunior = a.jrtBaseNav();
        uint256 expectedSenior = a.srtBaseNav();
        vm.revertToState(snap);
        uint256 paid;
        for (uint256 i; i < 10; i++) paid += a.updateBalanceFlow(0, 0, 0, 25e18);
        assertApproxEqAbs(paid, expectedInsurance, 10);
        assertApproxEqAbs(a.jrtBaseNav(), expectedJunior, 10);
        assertApproxEqAbs(a.srtBaseNav(), expectedSenior, 10);
        _identity();
    }

    function test_chunking_fullCoverage() public { _chunked(1000e18, 1501e18, 501e18); }
    function test_chunking_partialJunior_noInsurance() public { _chunked(100e18, 1000e18, 0); }
    function test_chunking_partialInsurance() public { _chunked(100e18, 1100e18, 100e18); }

    function test_selfFunding_usesStoredFundAtDeeperDepeg() public {
        // Deposit at 0.5 self-funded 100; a later drop to 0.4 does not reprice that fund upward.
        a.seed(2000e18, 1100e18, 0, 0, 100e18, 100e18, 0, 0.4e18);
        // Effective Senior NAV is 1100 / 0.4 - 100 = 2650.
        assertEq(a.updateBalanceFlow(0, 0, 0, 265e18), 0);
        assertEq(a.srtFundedGrossNav(), 90e18);
        assertEq(a.srtFundNav(), 90e18);
        assertEq(a.srtBaseNav(), 990e18);
        assertEq(a.jrtBaseNav(), 1845e18);
        _identity();
    }

    function test_mixedClaims_redemptionConsumesBothProportionally() public {
        a.seed(1e18, 1501e18, 701e18, 501e18, 0, 0, 0, 0.4e18);
        assertEq(a.updateBalanceFlow(0, 0, 0, 150.1e18), 70.1e18);
        assertEq(a.insuranceAmount(), 630.9e18);
        assertEq(a.srtInsuranceFundNav(), 450.9e18);
        a.setValuationPrice(1e18);
        assertEq(a.srtInsuranceFundNav(), 0);
        assertEq(a.insuranceAmount(), 180e18);
        assertEq(a.srtBaseNav(), 900e18);
        _identity();
    }

    function test_recoveryAfterExit_hasNoExtraJuniorLoss() public {
        _covered();
        a.updateBalanceFlow(0, 0, 0, 250e18);
        a.setValuationPrice(1e18);
        assertEq(a.srtBaseNav(), 900e18);
        assertEq(a.jrtBaseNav(), 900.1e18);
        assertEq(a.insuranceAmount(), 0);
        _identity();
    }

    function test_samePriceAfterExit_doesNotClaimAgain() public {
        _covered();
        a.updateBalanceFlow(0, 0, 0, 250e18);
        a.setValuationPrice(0.4e18);
        assertEq(a.insuranceAmount(), 450.9e18);
        assertEq(a.srtInsuranceFundNav(), 450.9e18);
        _identity();
    }







    function test_newDeposit_doesNotDiluteExitingFunding() public {
        a.seed(2000e18, 1100e18, 0, 0, 100e18, 100e18, 0, 0.4e18);
        a.updateBalanceFlow(0, 0, 100e18, 265e18);
        assertEq(a.srtFundedGrossNav(), 190e18);
        assertEq(a.srtFundNav(), 240e18);
        _identity();
    }

    function test_dustExit_preservesIdentity() public {
        _covered();
        a.updateBalanceFlow(0, 0, 0, 1);
        _identity();
        assertEq(a.insuranceAmount(), 501e18);
    }
}


abstract contract ProRataProjectionTestBase is ProRataRedemptionTestBase {
    function test_conservativeProjection_usesSettledBacking() public {
        _deploy(true);
        a.seed(900e18, 1601e18, 501e18, 501e18, 0, 0, 100e18, 0.4e18);
        assertEq(a.updateBalanceFlow(0, 0, 0, 250e18), 50.1e18);
        assertEq(a.srtPnLProjected(), 90e18);
        assertEq(a.jrtBaseNav(), 810.1e18);
        assertEq(a.srtBaseNav(), 1440.9e18);
        assertEq(a.insuranceAmount(), 450.9e18);
        _identity();
    }

    function test_conservativeProjection_fullExit() public {
        _deploy(true);
        a.seed(900e18, 1601e18, 501e18, 501e18, 0, 0, 100e18, 0.4e18);
        assertEq(a.updateBalanceFlow(0, 0, 0, 2500e18), 501e18);
        assertEq(a.srtBaseNav(), 0);
        assertEq(a.srtPnLProjected(), 0);
        assertEq(a.jrtBaseNav(), 1e18);
        _identity();
    }

    function test_liveProjection_tracksPaidShare() public {
        a.seed(900e18, 1601e18, 501e18, 501e18, 0, 0, 100e18, 0.4e18);
        // Junior is exhausted, so effective Senior backing remains 2500.
        assertEq(a.updateBalanceFlow(0, 0, 0, 250e18), 50.1e18);
        assertEq(a.srtPaidProjected(), 10e18);
        assertEq(a.srtPnLProjected(), 100e18);
        assertEq(a.jrtBaseNav(), 810.1e18);
        assertEq(a.srtBaseNav(), 1440.9e18);
        _identity();
    }

}

contract AccountingProRataRedemptionTest is ProRataRedemptionTestBase {
    function _deploy(bool) internal override {
        _initialize(address(new AccountingRedemptionHarness()));
    }
}

contract DiscreteProRataRedemptionTest is ProRataRedemptionTestBase {
    function _deploy(bool) internal override {
        _initialize(address(new DiscreteAccountingRedemptionHarness()));
    }
}

contract DYSProRataRedemptionTest is ProRataProjectionTestBase {
    function _deploy(bool conservative) internal override {
        _initialize(address(new DYSAccountingRedemptionHarness(conservative)));
    }
}

contract MTMProRataRedemptionTest is ProRataProjectionTestBase {
    function _deploy(bool conservative) internal override {
        _initialize(address(new MTMRedemptionHarness(conservative)));
    }
}
