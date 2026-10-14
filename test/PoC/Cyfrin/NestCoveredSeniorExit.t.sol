// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ITranche} from "../../../contracts/tranches/interfaces/ITranche.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {NestOpalDeploy} from "../../nest/NestOpalDeploy.t.sol";
import {NestAlphaDeploy} from "../../nest/NestAlphaDeploy.t.sol";
import {MockInsurancePool} from "../../symbiotic/mocks/MockInsurancePool.sol";
import {InsuranceVault} from "../../../contracts/tranches/symbiotic/InsuranceVault.sol";
import {IInsuranceVault} from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import {IInsuranceMiddleware} from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";

/// @notice Regression tests adapted from the auditor's covered Nest exit PoCs.
contract NestOpalCoveredSeniorExitTest is NestOpalDeploy {
    bytes32 constant RESERVE_MANAGER = keccak256("RESERVE_MANAGER_ROLE");

    MockInsurancePool internal pool;
    InsuranceVault internal insuranceVault;

    address internal alice = makeAddr("aliceJunior");
    address internal bob = makeAddr("bobSenior");
    address internal carol = makeAddr("carolSenior");
    address internal keeper = makeAddr("keeper");
    address internal multisig = makeAddr("multisig");

    // Nest accountant rate after a credit event (-30%)
    uint256 constant LOSS_RATE = INITIAL_RATE * 70 / 100;

    function setUp() public override {
        super.setUp();
        _deployNestOpalStack();

        pool = new MockInsurancePool();
        pool.setCapacity(type(uint128).max);

        vm.startPrank(owner);
        insuranceVault = InsuranceVault(address(new ERC1967Proxy(
            address(new InsuranceVault()),
            abi.encodeCall(InsuranceVault.initialize, (owner, address(acm), IStrataCDO(address(cdo)), address(usdc)))
        )));
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(insuranceVault)));
        acm.grantRole(RESERVE_MANAGER, multisig);
        vm.stopPrank();

        _mintNOpal(alice, 1_000 * ONE_NOPAL);
        _mintNOpal(bob, 4_000 * ONE_NOPAL);
        _mintNOpal(carol, 1_000 * ONE_NOPAL);
        _depositToJrt(alice, 1_000 * ONE_NOPAL);
        _depositToSrt(bob, 4_000 * ONE_NOPAL);
        _depositToSrt(carol, 1_000 * ONE_NOPAL);
    }

    /// @dev Exogenous nOPAL credit loss, then a permissionless poke books it (Junior -> floor, claim, slash)
    function _bookLoss() internal returns (uint256 claim) {
        nestAccountant.setExchangeRate(LOSS_RATE);
        vm.prank(keeper);
        jrtVault.burnSharesAsFee(0, keeper);
        claim = accounting.insuranceAmount();
    }

    /// @dev RESERVE_MANAGER funds the vault with the claim's full value (valuationPrice = 1, USDC 6 dec = base 6 dec)
    function _fundVault(uint256 usdcAmount) internal {
        usdc.mint(multisig, usdcAmount);
        vm.startPrank(multisig);
        IERC20(address(usdc)).approve(address(cdo), usdcAmount);
        cdo.fundInsuranceClaim(address(usdc), usdcAmount);
        vm.stopPrank();
    }


    function test_CoveredExit() public {
        _checkCoveredExit(false, false);
    }

    function test_CoveredExitWithOptions() public {
        _checkCoveredExit(true, false);
    }

    function test_CoveredExitWithExhaustedInsurance() public {
        _checkCoveredExit(false, true);
    }

    function _checkCoveredExit(bool withOptions, bool exhaustInsurance) internal {
        if (exhaustInsurance) {
            nestAccountant.setExchangeRate(LOSS_RATE);
            pool.setCapacity(accounting.nav() - strategy.totalAssets() - (accounting.jrtBaseNav() - ONE_USDC));
        }
        uint256 claim = _bookLoss();
        assertGt(claim, 0);
        _fundVault(claim);
        uint256 capacityBefore = pool.capacity();
        uint256 carolBefore = srtVault.previewRedeem(srtVault.balanceOf(carol));
        uint256 navBefore = accounting.nav();
        uint256 shares = srtVault.balanceOf(bob);
        uint256 baseAssets = srtVault.previewRedeem(shares);
        uint256 coverage = Math.mulDiv(baseAssets, claim, accounting.srtBaseNav());
        uint256 expectedTokens = strategy.convertToTokens(address(nOpal), baseAssets - coverage, Math.Rounding.Floor);

        vm.prank(bob);
        srtVault.redeem(address(nOpal), shares, bob, bob, ITranche.TRedemptionParams({
            exitMode: IStrataCDO.TExitMode.Dynamic,
            exitFee: 0,
            cooldownSeconds: 0,
            strategyOptions: withOptions ? bytes(hex"01") : bytes("")
        }));

        assertEq(usdc.balanceOf(bob), coverage, "insurance pays its slice");
        assertEq(nOpal.balanceOf(bob), expectedTokens, "strategy pays only the remainder");
        uint256 paid = strategy.convertToAssets(address(nOpal), expectedTokens, Math.Rounding.Floor) + coverage;
        assertLe(paid, baseAssets, "no overpayment");
        assertApproxEqAbs(paid, baseAssets, 2, "full exit value within rounding");
        assertEq(navBefore - accounting.nav(), baseAssets - coverage);
        assertApproxEqAbs(strategy.totalAssets(), accounting.nav(), 2, "no strategy deficit");

        vm.prank(keeper);
        jrtVault.burnSharesAsFee(0, keeper);
        assertEq(pool.capacity(), capacityBefore, "no additional slash");
        assertApproxEqAbs(srtVault.previewRedeem(srtVault.balanceOf(carol)), carolBefore, 2, "remaining Senior preserved");

        // The remaining Senior can exit up to the tranche minimum supply without more funding.
        uint256 carolShares = srtVault.balanceOf(carol) - 0.1 ether;
        uint256 carolExitValue = srtVault.previewRedeem(carolShares);
        vm.prank(carol);
        srtVault.redeem(address(nOpal), carolShares, carol, carol);
        uint256 carolPaid = strategy.convertToAssets(address(nOpal), nOpal.balanceOf(carol), Math.Rounding.Floor) + usdc.balanceOf(carol);
        assertApproxEqAbs(carolPaid, carolExitValue, 3, "remaining Senior receives their value");
        assertEq(srtVault.balanceOf(carol), 0.1 ether);
    }
}

/// @notice The same payout invariant applies to NestAlphaStrategy.
contract NestAlphaCoveredSeniorExitTest is NestAlphaDeploy {
    bytes32 constant RESERVE_MANAGER = keccak256("RESERVE_MANAGER_ROLE");

    function test_CoveredExit() public {
        _deployNestStack();
        MockInsurancePool pool = new MockInsurancePool();
        pool.setCapacity(type(uint128).max);
        address multisig = makeAddr("multisig");
        address bob = makeAddr("bobSenior");
        address keeper = makeAddr("keeper");

        vm.startPrank(owner);
        InsuranceVault insuranceVault = InsuranceVault(address(new ERC1967Proxy(
            address(new InsuranceVault()),
            abi.encodeCall(InsuranceVault.initialize, (owner, address(acm), IStrataCDO(address(cdo)), address(usdc)))
        )));
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(insuranceVault)));
        acm.grantRole(RESERVE_MANAGER, multisig);
        vm.stopPrank();

        _mintNAlpha(address(this), 2_000e6);
        _mintNAlpha(bob, 4_000e6);
        _depositToJrt(address(this), 1_000e6);
        _depositToSrt(bob, 4_000e6);
        _depositToSrt(address(this), 1_000e6);

        nestAccountant.setExchangeRate(INITIAL_RATE * 70 / 100);
        vm.prank(keeper);
        jrtVault.burnSharesAsFee(0, keeper);
        uint256 claim = accounting.insuranceAmount();
        assertGt(claim, 0);

        usdc.mint(multisig, claim);
        vm.startPrank(multisig);
        IERC20(address(usdc)).approve(address(cdo), claim);
        cdo.fundInsuranceClaim(address(usdc), claim);
        vm.stopPrank();

        uint256 shares = srtVault.balanceOf(bob);
        uint256 baseAssets = srtVault.previewRedeem(shares);
        uint256 coverage = Math.mulDiv(baseAssets, claim, accounting.srtBaseNav());
        uint256 expectedTokens = strategy.convertToTokens(address(nAlpha), baseAssets - coverage, Math.Rounding.Floor);

        vm.prank(bob);
        srtVault.redeem(address(nAlpha), shares, bob, bob);

        uint256 got = strategy.convertToAssets(address(nAlpha), nAlpha.balanceOf(bob), Math.Rounding.Floor) + usdc.balanceOf(bob);
        assertEq(nAlpha.balanceOf(bob), expectedTokens, "strategy pays only the remainder");
        assertEq(usdc.balanceOf(bob), coverage, "insurance pays its slice");
        assertLe(got, baseAssets, "no overpayment");
        assertApproxEqAbs(got, baseAssets, 2, "full exit value within rounding");
        assertApproxEqAbs(strategy.totalAssets(), accounting.nav(), 2, "no strategy deficit");
    }
}
