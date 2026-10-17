// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;
import { SymbioticCoverageStackBase } from "./FundedClaimReservedTwice.t.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Cyfrin's held-coverage recovery/redip scenario through the real CDO and vault.
contract FundedSurplusStackTest is SymbioticCoverageStackBase {
    function setUp() public override {
        super.setUp();
        cdo.setValuationKeeper(address(this));
    }
    function test_reusePayoutAndManualReturn() public {
        cdo.setValuationPrice(0.88e18);
        uint256 slashed = _totalSlashed();
        uint256 funding = Math.ceilDiv(Math.mulDiv(accounting.insuranceAmount(), 0.88e18, 1e18, Math.Rounding.Ceil), 1e12);
        usdc.mint(multisig, funding);
        vm.startPrank(multisig);
        usdc.approve(address(cdo), funding);
        cdo.fundInsuranceClaim(address(usdc), funding);
        vm.stopPrank();
        for (uint256 i; i < 3; i++) {
            cdo.setValuationPrice(0.95e18);
            assertEq(accounting.insuranceAmount(), 0);
            assertEq(vault.surplusCoverage(), funding);
            cdo.setValuationPrice(0.88e18);
            assertEq(_totalSlashed(), slashed);
            assertEq(vault.fundedCoverage(), funding);
        }
        uint256 shares = srt.balanceOf(bob);
        vm.prank(bob);
        srt.redeem(address(susde), shares, bob, bob);
        assertGt(usdc.balanceOf(bob), 0, "reused funds pay Senior");
        assertLt(vault.fundedCoverage(), funding);
        cdo.setValuationPrice(0.95e18);
        vault.withdrawSurplus(vault.surplusCoverage(), multisig);
        assertEq(vault.fundedCoverage(), 0);
        cdo.setValuationPrice(0.88e18);
        assertGt(_totalSlashed(), slashed, "paid and returned funds cannot be reused");
    }
}
