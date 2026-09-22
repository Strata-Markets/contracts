// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { InsuranceVault } from "../../contracts/tranches/symbiotic/InsuranceVault.sol";
import { MockERC20 } from "../../contracts/test/MockERC20.sol";
import { IStrataCDO } from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IErrors } from "../../contracts/tranches/interfaces/IErrors.sol";

/// @notice Verifies the per-CDO vault that holds the swapped coverage proceeds: only the CDO can pay
///         out, funded coverage is tracked through funding rather than the token balance, an unfunded claim
///         reverts instead of short-paying, and the coverage token can only change while empty.
contract InsuranceVaultTest is Test {

    InsuranceVault vault;
    MockERC20 usdc;
    MockERC20 other;

    address owner = makeAddr("multisig");
    address cdo = makeAddr("cdo");
    address acm = makeAddr("acm");
    address receiver = makeAddr("receiver");
    address stranger = makeAddr("stranger");

    function setUp() public {
        usdc = new MockERC20("USDC", 6);
        other = new MockERC20("OTHER", 18);

        vault = InsuranceVault(address(new ERC1967Proxy(
            address(new InsuranceVault()),
            abi.encodeCall(InsuranceVault.initialize, (owner, acm, IStrataCDO(cdo), address(usdc)))
        )));

        usdc.mint(owner, 1_000e6);
        vm.prank(owner);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _fund(uint256 amount) internal {
        // The CDO moves the proceeds in, then records them.
        vm.prank(owner);
        usdc.transfer(address(vault), amount);
        vm.prank(cdo);
        vault.recordFunding(address(usdc), amount);
    }

    function test_initialize_setsCdoAndToken() public view {
        assertEq(address(vault.cdo()), cdo);
        assertEq(address(vault.coverageToken()), address(usdc));
        assertEq(vault.fundedCoverage(), 0);
        assertEq(vault.coverageTokenDecimals(), 6);
    }

    function test_recordFunding_tracksFundedCoverage() public {
        _fund(100e6);
        assertEq(vault.fundedCoverage(), 100e6);

        _fund(50e6);
        assertEq(vault.fundedCoverage(), 150e6, "funding accumulates");
    }

    function test_recordFunding_onlyCDO() public {
        vm.expectRevert(abi.encodeWithSelector(IErrors.InvalidCaller.selector, stranger));
        vm.prank(stranger);
        vault.recordFunding(address(usdc), 1e6);
    }

    /// A stray transfer is not coverage: only what was recorded can be paid out.
    function test_strayTransferIsNotCoverage() public {
        vm.prank(owner);
        usdc.transfer(address(vault), 100e6);

        assertEq(vault.fundedCoverage(), 0, "unrecorded balance is not funded coverage");
        vm.expectRevert(abi.encodeWithSelector(InsuranceVault.InsufficientCoverage.selector, 1e6, 0));
        vm.prank(cdo);
        vault.payCoverage(1e6, receiver);
    }

    function test_payCoverage_paysAndDecrements() public {
        _fund(100e6);

        vm.prank(cdo);
        vault.payCoverage(40e6, receiver);

        assertEq(usdc.balanceOf(receiver), 40e6);
        assertEq(vault.fundedCoverage(), 60e6);
    }

    function test_payCoverage_onlyCDO() public {
        _fund(100e6);
        vm.expectRevert(abi.encodeWithSelector(IErrors.InvalidCaller.selector, stranger));
        vm.prank(stranger);
        vault.payCoverage(1e6, receiver);
    }

    /// An unfunded claim reverts rather than short-paying the redeeming Senior.
    function test_payCoverage_revertsWhenUnderfunded() public {
        _fund(10e6);

        vm.expectRevert(abi.encodeWithSelector(InsuranceVault.InsufficientCoverage.selector, 25e6, 10e6));
        vm.prank(cdo);
        vault.payCoverage(25e6, receiver);
    }

    /// The keeper may swap into whichever stablecoin is liquid, but only while nothing is held.
    function test_coverageToken_switchesOnlyWhileEmpty() public {
        _fund(100e6);

        vm.expectRevert(abi.encodeWithSelector(InsuranceVault.CoverageTokenInUse.selector, 100e6));
        vm.prank(cdo);
        vault.recordFunding(address(other), 1e18);

        // Drain, then a different token is accepted and becomes the coverage token.
        vm.prank(cdo);
        vault.payCoverage(100e6, receiver);

        other.mint(address(vault), 5e18);
        vm.prank(cdo);
        vault.recordFunding(address(other), 5e18);

        assertEq(address(vault.coverageToken()), address(other));
        assertEq(vault.fundedCoverage(), 5e18);
    }

    function test_setCoverageToken_onlyOwnerAndOnlyWhileEmpty() public {
        _fund(100e6);

        vm.expectRevert(abi.encodeWithSelector(InsuranceVault.CoverageTokenInUse.selector, 100e6));
        vm.prank(owner);
        vault.setCoverageToken(address(other));

        vm.prank(cdo);
        vault.payCoverage(100e6, receiver);

        vm.prank(owner);
        vault.setCoverageToken(address(other));
        assertEq(address(vault.coverageToken()), address(other));
    }

    /// Rescue can take a foreign token outright, but only the unbacked excess of the coverage token.
    function test_rescue_protectsBackedCoverage() public {
        _fund(100e6);
        other.mint(address(vault), 7e18);

        vm.prank(owner);
        vault.rescue(address(other), receiver, 7e18);
        assertEq(other.balanceOf(receiver), 7e18);

        // The backed 100 cannot be swept.
        vm.expectRevert(abi.encodeWithSelector(InsuranceVault.CoverageTokenInUse.selector, 100e6));
        vm.prank(owner);
        vault.rescue(address(usdc), receiver, 1e6);

        // An unrecorded surplus can be.
        vm.prank(owner);
        usdc.transfer(address(vault), 30e6);
        vm.prank(owner);
        vault.rescue(address(usdc), receiver, 30e6);
        assertEq(usdc.balanceOf(receiver), 30e6);
        assertEq(vault.fundedCoverage(), 100e6, "backed coverage untouched");
    }
}
