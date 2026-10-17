// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;
import { ValuationInsuranceFixture } from "./ValuationFloorBaseline.t.sol";
import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { DiscreteAccounting } from "../../../contracts/tranches/DiscreteAccounting.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { InsuranceVault } from "../../../contracts/tranches/symbiotic/InsuranceVault.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract FundedSurplusReuseTests is ValuationInsuranceFixture {
    InsuranceVault vault;
    function setUp() public override {
        super.setUp();
        vault = InsuranceVault(address(new ERC1967Proxy(address(new InsuranceVault()),
            abi.encodeCall(InsuranceVault.initialize, (address(this), address(acm), IStrataCDO(address(this)), address(baseAsset))))));
        vm.mockCall(address(this), abi.encodeWithSignature("insuranceVault()"), abi.encode(address(vault)));
        vm.mockCall(address(this), abi.encodeWithSignature("accounting()"), abi.encode(address(accounting)));
        vm.mockCall(address(this), abi.encodeWithSignature("baseAssetDecimals()"), abi.encode(uint256(18)));
    }
    function _fundDepegClaim() internal {
        accounting.setValuationPrice(0.4e18);
        uint256 claim = accounting.insuranceAmount();
        uint256 amount = Math.mulDiv(claim, 0.4e18, 1e18, Math.Rounding.Ceil);
        baseAsset.mint(address(vault), amount);
        vault.recordFunding(address(baseAsset), amount);
        middleware.confirmInsuranceClaimFunding(address(this), claim);
    }
    function test_recoveryAndRepeatedDipsReuseFundedCoverage() public {
        _fundDepegClaim();
        uint256 slashed = _totalSlashed();
        uint256 funding = vault.fundedCoverage();
        for (uint256 i; i < 3; i++) {
            accounting.setValuationPrice(1e18);
            assertEq(vault.surplusCoverage(), funding);
            accounting.setValuationPrice(0.4e18);
            assertEq(accounting.insuranceAmount(), 501e18);
            assertEq(_totalSlashed(), slashed);
            assertEq(vault.surplusCoverage(), 0);
        }
    }
    function test_navLossUsesSurplusBeforeBookingClaim() public {
        _fundDepegClaim();
        uint256 slashed = _totalSlashed();
        accounting.setValuationPrice(1e18);
        vm.warp(block.timestamp + 1 days);
        mockStrategyTvl = 900e18;
        accounting.updateAccounting();
        assertGt(accounting.insuranceAmount(), 0);
        assertLe(accounting.insuranceAmount(), vault.fundedCoverage());
        assertEq(_totalSlashed(), slashed);
        mockStrategyTvl = 500e18;
        accounting.updateAccounting();
        assertGt(_totalSlashed(), slashed);
    }
    function test_releasedSurplusMustBeReplaced() public {
        _fundDepegClaim();
        uint256 slashed = _totalSlashed();
        accounting.setValuationPrice(1e18);
        vault.withdrawSurplus(vault.surplusCoverage(), address(this));
        accounting.setValuationPrice(0.4e18);
        assertEq(_totalSlashed(), 2 * slashed);
    }
}

contract FundedSurplusReuseAccountingTest is FundedSurplusReuseTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(address(new Accounting(18)),
            abi.encodeWithSelector(Accounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this)))));
    }
}

contract FundedSurplusReuseDiscreteAccountingTest is FundedSurplusReuseTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(address(new DiscreteAccounting(18, false)),
            abi.encodeWithSelector(DiscreteAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this)))));
    }
}

contract FundedSurplusReuseDYSAccountingTest is FundedSurplusReuseTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(address(new DYSAccounting(18, false, false, false, true, false)),
            abi.encodeWithSelector(DYSAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this)))));
    }
}

contract FundedSurplusReuseMTMAccountingTest is FundedSurplusReuseTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(address(new MTMAccounting(18, false, true, false, true, true, true)),
            abi.encodeWithSelector(MTMAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this)))));
    }
}
