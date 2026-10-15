// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StrataCDO} from "../../../contracts/tranches/StrataCDO.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {NestOpalDeploy} from "../../nest/NestOpalDeploy.t.sol";
import {MockInsurancePool} from "../../symbiotic/mocks/MockInsurancePool.sol";
import {InsuranceVault} from "../../../contracts/tranches/symbiotic/InsuranceVault.sol";
import {IInsuranceVault} from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import {IInsuranceMiddleware} from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IErrors} from "../../../contracts/tranches/interfaces/IErrors.sol";

/// @notice Cyfrin's depleted-Junior deposit PoCs, adapted to assert rejection and preserved recovery.
contract JuniorDepositAfterDepletionTest is NestOpalDeploy {
    MockInsurancePool internal pool;
    InsuranceVault internal insuranceVault;

    address internal alice = makeAddr("aliceJunior");
    address internal bob = makeAddr("bobSenior");
    address internal eve = makeAddr("eveLateJunior");
    address internal keeper = makeAddr("keeper");
    address internal valuationKeeper_ = makeAddr("valuationKeeper");

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
        cdo.setValuationKeeper(valuationKeeper_);
        vm.stopPrank();

        _mintNOpal(alice, 1_000 * ONE_NOPAL);
        _mintNOpal(bob, 5_000 * ONE_NOPAL);
        _mintNOpal(eve, 1_000 * ONE_NOPAL);
        _depositToJrt(alice, 1_000 * ONE_NOPAL);
        _depositToSrt(bob, 5_000 * ONE_NOPAL);
    }

    function _jrtDepositEnabled() internal view returns (bool enabled) {
        (enabled,) = cdo.actionsJrt();
    }

    function _jrtValue(address user) internal view returns (uint256) {
        return jrtVault.convertToAssets(jrtVault.balanceOf(user));
    }

    function _assertDepositRejected() internal {
        uint256 supplyBefore = jrtVault.totalSupply();
        uint256 tokensBefore = nOpal.balanceOf(eve);
        uint256 navBefore = accounting.nav();
        uint256 claimBefore = accounting.insuranceAmount();
        uint256 capacityBefore = pool.capacity();
        vm.startPrank(eve);
        nOpal.approve(address(jrtVault), 1_000 * ONE_NOPAL);
        vm.expectPartialRevert(StrataCDO.Shortfall.selector);
        jrtVault.deposit(address(nOpal), 1_000 * ONE_NOPAL, eve);
        vm.stopPrank();

        assertEq(jrtVault.totalSupply(), supplyBefore, "share mint rolled back");
        assertEq(jrtVault.balanceOf(eve), 0, "late entrant owns no Junior shares");
        assertEq(nOpal.balanceOf(eve), tokensBefore, "asset transfer rolled back");
        assertEq(accounting.nav(), navBefore, "NAV update rolled back");
        assertEq(accounting.insuranceAmount(), claimBefore, "claim update rolled back");
        assertEq(pool.capacity(), capacityBefore, "insurance slash rolled back");
        assertTrue(_jrtDepositEnabled(), "guard rejects without persisting a pause");
    }

    /// The first deposit cannot book the loss and buy depleted shares in the same transaction.
    function test_Cyfrin_DepositRejectedInLossBookingTx() public {
        uint256 aliceBefore = _jrtValue(alice);
        nestAccountant.setExchangeRate(LOSS_RATE);
        assertEq(accounting.insuranceAmount(), 0);
        _assertDepositRejected();
        // Repeated attempts must fail even though the revert cannot persist a pause.
        _assertDepositRejected();

        vm.prank(keeper);
        jrtVault.burnSharesAsFee(0, keeper);
        assertGt(accounting.insuranceAmount(), 0, "standalone accounting can book the claim");
        nestAccountant.setExchangeRate(INITIAL_RATE);
        vm.prank(keeper);
        jrtVault.burnSharesAsFee(0, keeper);
        assertEq(accounting.insuranceAmount(), 0);
        assertApproxEqAbs(_jrtValue(alice), aliceBefore, 1, "original Junior retains recovery");
    }

    /// The original control now relies on the guard, rather than a persistent pause.
    function test_Cyfrin_RecoveryWithoutLateDeposit() public {
        uint256 aliceBefore = _jrtValue(alice);
        nestAccountant.setExchangeRate(LOSS_RATE);
        vm.prank(keeper);
        jrtVault.burnSharesAsFee(0, keeper);
        assertGt(accounting.insuranceAmount(), 0);
        _assertDepositRejected();

        nestAccountant.setExchangeRate(INITIAL_RATE);
        vm.prank(keeper);
        jrtVault.burnSharesAsFee(0, keeper);
        assertApproxEqAbs(_jrtValue(alice), aliceBefore, 1, "original Junior fully restored");
    }

    /// A direct valuation keeper cannot leave a depleted Junior open to entry.
    function test_Cyfrin_DepositRejectedAfterValuationDepletion() public {
        uint256 aliceBefore = _jrtValue(alice);
        vm.prank(valuationKeeper_);
        cdo.setValuationPrice(0.4e18);
        assertGt(accounting.insuranceAmount(), 0);
        assertLe(_jrtValue(alice), ONE_USDC);
        assertLe(cdo.pricePerShare(address(jrtVault)), cdo.jrtShortfallPausePrice());
        _assertDepositRejected();

        vm.prank(valuationKeeper_);
        cdo.setValuationPrice(1e18);
        assertEq(accounting.insuranceAmount(), 0);
        assertApproxEqAbs(_jrtValue(alice), aliceBefore, 1, "repeg value stays with original Junior");
    }

    /// Expiry of the valuation grace period does not bypass the shortfall guard.
    function test_Cyfrin_DepositRejectedAfterValuationGraceLapses() public {
        vm.prank(owner);
        accounting.setValuationGracePeriod(1 days);
        vm.prank(valuationKeeper_);
        cdo.setValuationPrice(0.4e18);
        uint256 enteredAt = vm.getBlockTimestamp();

        vm.startPrank(eve);
        nOpal.approve(address(jrtVault), 1_000 * ONE_NOPAL);
        vm.expectRevert(abi.encodeWithSelector(IErrors.DepositCapReached.selector, address(jrtVault)));
        jrtVault.deposit(address(nOpal), 1_000 * ONE_NOPAL, eve);
        vm.stopPrank();

        vm.warp(enteredAt + 1 days);
        _assertDepositRejected();
    }
}
