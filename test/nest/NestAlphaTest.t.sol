// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NestAlphaDeploy} from "./NestAlphaDeploy.t.sol";
import {NestAlphaStrategy} from "../../contracts/tranches/strategies/nest/NestAlphaStrategy.sol";
import {NestDepositAdapter} from "../../contracts/tranches/strategies/nest/NestDepositAdapter.sol";
import {TrancheDepositor} from "../../contracts/tranches/TrancheDepositor.sol";
import {IAdapter} from "../../contracts/tranches/interfaces/IAdapter.sol";
import {IStrataCDO} from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IMetaVault} from "../../contracts/tranches/interfaces/IMetaVault.sol";
import {IErrors} from "../../contracts/tranches/interfaces/IErrors.sol";
import {ICooldown, IERC20Cooldown} from "../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import {NestAccountantAprProvider} from "../../contracts/tranches/strategies/nest/NestAccountantAprProvider.sol";
import {INestAccountant, IAprSnapshotProvider, PredicateMessage} from "../../contracts/tranches/strategies/nest/interfaces/INestContracts.sol";

/**
 * @title NestAlphaTest
 * @notice Comprehensive tests for the NestAlpha strategy covering:
 *         TG-1: NestAlphaStrategy unit tests
 *         TG-2: NestDepositAdapter unit tests
 *         TG-3: Full adapter deposit path integration
 *         TG-4: TrancheDepositor backward compatibility
 */
contract NestAlphaTest is NestAlphaDeploy {
    address public alice;
    address public bob;

    uint256 constant DEPOSIT_AMOUNT = 1000 * ONE_NALPHA; // 1000 nALPHA
    uint256 constant DEPOSIT_USDC = 1000 * ONE_USDC; // 1000 USDC

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        _deployNestStack();

        // Fund test users
        _mintNAlpha(alice, 10_000 * ONE_NALPHA);
        _mintNAlpha(bob, 10_000 * ONE_NALPHA);
        _mintUSDC(alice, 10_000 * ONE_USDC);
        _mintUSDC(bob, 10_000 * ONE_USDC);
    }

    /*//////////////////////////////////////////////////////////////
                    TG-1: NestAlphaStrategy Unit Tests
    //////////////////////////////////////////////////////////////*/

    // ═══════ Deployment verification ═══════

    function test_StrategyConfiguration() public view {
        assertEq(address(strategy.nALPHA()), address(nAlpha), "nALPHA mismatch");
        assertEq(address(strategy.USDC()), address(usdc), "USDC mismatch");
        assertEq(address(strategy.accountant()), address(nestAccountant), "Accountant mismatch");
        assertEq(address(strategy.erc20Cooldown()), address(erc20Cooldown), "Cooldown mismatch");
    }

    function test_GetSupportedTokens() public view {
        IERC20[] memory tokens = strategy.getSupportedTokens();
        assertEq(tokens.length, 1, "Should support exactly 1 token");
        assertEq(address(tokens[0]), address(nAlpha), "Supported token should be nALPHA");
    }

    // ═══════ Deposit tests ═══════

    function test_DepositNAlpha_ToJrtVault() public {
        uint256 balanceBefore = nAlpha.balanceOf(alice);

        _depositToJrt(alice, DEPOSIT_AMOUNT);

        // Verify nALPHA was transferred from alice
        assertEq(balanceBefore - nAlpha.balanceOf(alice), DEPOSIT_AMOUNT, "nALPHA should transfer from user");

        // Verify strategy holds the nALPHA
        assertEq(nAlpha.balanceOf(address(strategy)), DEPOSIT_AMOUNT, "Strategy should hold nALPHA");

        // Verify shares minted to alice
        assertGt(jrtVault.balanceOf(alice), 0, "Alice should have JRT shares");
    }

    function test_DepositNAlpha_ToSrtVault() public {
        // First deposit JRT for coverage
        _depositToJrt(alice, DEPOSIT_AMOUNT * 2);

        _depositToSrt(alice, DEPOSIT_AMOUNT);

        assertEq(
            nAlpha.balanceOf(address(strategy)),
            DEPOSIT_AMOUNT * 3,
            "Strategy should hold all deposited nALPHA"
        );
        assertGt(srtVault.balanceOf(alice), 0, "Alice should have SRT shares");
    }

    function test_DepositToReceiver() public {
        vm.startPrank(alice);
        IERC20(address(nAlpha)).approve(address(jrtVault), DEPOSIT_AMOUNT);
        jrtVault.deposit(address(nAlpha), DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        assertEq(jrtVault.balanceOf(bob), jrtVault.balanceOf(bob), "Bob should have shares");
        assertGt(jrtVault.balanceOf(bob), 0, "Bob should have non-zero shares");
        assertEq(jrtVault.balanceOf(alice), 0, "Alice should have zero shares");
    }

    function test_RevertDepositUnsupportedToken() public {
        // The CDO/Tranche only accepts nALPHA as base asset, so depositing USDC directly should fail
        vm.startPrank(alice);
        IERC20(address(usdc)).approve(address(jrtVault), ONE_USDC);
        vm.expectRevert();
        jrtVault.deposit(address(usdc), ONE_USDC, alice);
        vm.stopPrank();
    }

    // ═══════ NAV / totalAssets tests ═══════

    function test_TotalAssets_Zero() public view {
        assertEq(strategy.totalAssets(), 0, "Empty strategy should have zero NAV");
    }

    function test_TotalAssets_AfterDeposit() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        uint256 nav = strategy.totalAssets();
        // NAV = 1000e6 * 1094524 / 1e6 = 1094524000
        uint256 expectedNav = Math.mulDiv(DEPOSIT_AMOUNT, INITIAL_RATE, 1e6);
        assertEq(nav, expectedNav, "NAV should equal shares * rate / 1e6");
    }

    function test_TotalAssets_RateIncrease() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        uint256 navBefore = strategy.totalAssets();

        // Rate increases by 10%
        nestAccountant.setExchangeRate(INITIAL_RATE * 110 / 100);

        uint256 navAfter = strategy.totalAssets();
        assertGt(navAfter, navBefore, "NAV should increase with rate");
        assertApproxEqRel(navAfter, navBefore * 110 / 100, 0.001e18, "NAV should increase ~10%");
    }

    function test_TotalAssets_RateDecrease_LossRecognition() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        uint256 navBefore = strategy.totalAssets();

        // Rate decreases by 5% (simulating bad performance)
        nestAccountant.setExchangeRate(INITIAL_RATE * 95 / 100);

        uint256 navAfter = strategy.totalAssets();
        assertLt(navAfter, navBefore, "NAV should decrease with rate");
        assertApproxEqRel(navAfter, navBefore * 95 / 100, 0.001e18, "NAV should decrease ~5%");
    }

    function test_TotalAssets_RevertWhenAccountantPaused() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        nestAccountant.setPaused(true);

        vm.expectRevert();
        strategy.totalAssets();
    }

    function test_TotalAssetsOverloaded() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        uint256 freshNav = strategy.totalAssets();

        // Accountant updated at block.timestamp → checkpoint at same time → fresh
        uint256 nav2 = strategy.totalAssets(0, block.timestamp);
        assertEq(nav2, freshNav, "Should return fresh NAV when accountant updated at checkpoint time");

        // checkpoint in the future → accountant is stale → returns latestNav
        uint256 staleNav = 42e6;
        uint256 nav3 = strategy.totalAssets(staleNav, block.timestamp + 1);
        assertEq(nav3, staleNav, "Should return stale NAV when accountant hasn't updated since checkpoint");
    }

    function test_TotalAssets_StalenessGating() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        uint256 freshNav = strategy.totalAssets();
        uint256 checkpointTime = block.timestamp;

        // Warp forward without updating accountant rate
        vm.warp(block.timestamp + 1 hours);

        // checkpoint <= accountant lastUpdateTimestamp → fresh
        uint256 nav1 = strategy.totalAssets(0, checkpointTime);
        assertEq(nav1, freshNav, "Should still return fresh when checkpoint <= accountant update");

        // checkpoint at current time → accountant is stale
        uint256 nav2 = strategy.totalAssets(99e6, block.timestamp);
        assertEq(nav2, 99e6, "Should return stale NAV when checkpoint is after accountant update");

        // Update rate → lastUpdateTimestamp advances
        nestAccountant.setExchangeRate(1.1e6);
        uint256 newFreshNav = strategy.totalAssets();
        uint256 nav3 = strategy.totalAssets(0, block.timestamp);
        assertEq(nav3, newFreshNav, "Should return fresh after accountant updates");
    }

    // ═══════ Conversion tests ═══════

    function test_ConvertToAssets() public view {
        uint256 assets = strategy.convertToAssets(address(nAlpha), 1000 * ONE_NALPHA, Math.Rounding.Floor);
        uint256 expected = Math.mulDiv(1000 * ONE_NALPHA, INITIAL_RATE, 1e6, Math.Rounding.Floor);
        assertEq(assets, expected, "convertToAssets should use correct formula");
    }

    function test_ConvertToTokens() public view {
        uint256 tokens = strategy.convertToTokens(address(nAlpha), 1000 * ONE_USDC, Math.Rounding.Floor);
        uint256 expected = Math.mulDiv(1000 * ONE_USDC, 1e6, INITIAL_RATE, Math.Rounding.Floor);
        assertEq(tokens, expected, "convertToTokens should use correct formula");
    }

    function test_ConvertRoundTrip() public view {
        uint256 originalTokens = 12345 * ONE_NALPHA;
        uint256 assets = strategy.convertToAssets(address(nAlpha), originalTokens, Math.Rounding.Floor);
        uint256 tokensBack = strategy.convertToTokens(address(nAlpha), assets, Math.Rounding.Ceil);
        // Due to rounding, tokensBack >= originalTokens (ceil rounds up)
        assertGe(tokensBack, originalTokens, "Round-trip should not lose tokens (favors protocol)");
        // But should be very close
        assertApproxEqAbs(tokensBack, originalTokens, 2, "Round-trip difference should be at most 2 wei");
    }

    function test_ConvertToAssets_RevertUnsupportedToken() public {
        vm.expectRevert(abi.encodeWithSelector(IErrors.UnsupportedToken.selector, address(usdc)));
        strategy.convertToAssets(address(usdc), 1000, Math.Rounding.Floor);
    }

    function test_ConvertToTokens_RevertUnsupportedToken() public {
        vm.expectRevert(abi.encodeWithSelector(IErrors.UnsupportedToken.selector, address(usdc)));
        strategy.convertToTokens(address(usdc), 1000, Math.Rounding.Floor);
    }

    function test_ConvertToAssets_RevertWhenPaused() public {
        nestAccountant.setPaused(true);
        vm.expectRevert();
        strategy.convertToAssets(address(nAlpha), 1000, Math.Rounding.Floor);
    }

    // ═══════ Withdraw tests ═══════

    function test_Withdraw_NoCooldown() public {
        // Bob deposits to maintain MIN_SHARES (0.1 ether in 18-dec shares)
        _depositToJrt(bob, DEPOSIT_AMOUNT);
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        vm.startPrank(owner);
        strategy.setCooldowns(0, 0);
        vm.stopPrank();

        // Use redeem(shares) instead of withdraw(tokenAmount) to avoid
        // base-asset vs token-amount mismatch
        uint256 maxShares = jrtVault.maxRedeem(alice);
        assertGt(maxShares, 0, "Max redeem should be positive");

        vm.startPrank(alice);
        jrtVault.redeem(address(nAlpha), maxShares, alice, alice);
        vm.stopPrank();

        assertEq(jrtVault.balanceOf(alice), 0, "Alice should have zero JRT shares after redeem");
    }

    function test_Withdraw_WithCooldown() public {
        // Bob deposits to maintain MIN_SHARES
        _depositToJrt(bob, DEPOSIT_AMOUNT);
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        // Set 1 day cooldown on JRT
        vm.startPrank(owner);
        strategy.setCooldowns(1 days, 0);
        vm.stopPrank();

        // Use redeem(shares) for clean withdrawal
        uint256 maxShares = jrtVault.maxRedeem(alice);

        vm.startPrank(alice);
        jrtVault.redeem(address(nAlpha), maxShares, alice, alice);
        vm.stopPrank();

        // nALPHA should be in cooldown
        assertEq(jrtVault.balanceOf(alice), 0, "JRT shares should be burned");
    }

    // ═══════ Cooldown configuration ═══════

    function test_SetCooldowns() public {
        vm.startPrank(owner);
        strategy.setCooldowns(3 days, 1 days);
        vm.stopPrank();

        assertEq(strategy.nAlphaCooldownJrt(), 3 days, "JRT cooldown should be 3 days");
        assertEq(strategy.nAlphaCooldownSrt(), 1 days, "SRT cooldown should be 1 day");
    }

    function test_SetCooldowns_RevertExceedWeek() public {
        vm.startPrank(owner);
        vm.expectRevert();
        strategy.setCooldowns(8 days, 0);
        vm.stopPrank();
    }

    function test_SetCooldowns_RevertUnauthorized() public {
        vm.startPrank(alice);
        vm.expectRevert();
        strategy.setCooldowns(1 days, 0);
        vm.stopPrank();
    }

    // ═══════ ensureRedeemable ═══════

    function test_EnsureRedeemable_NeverReverts() public view {
        // ensureRedeemable is a no-op for nALPHA — should never revert
        strategy.ensureRedeemable(address(0), address(0), 0);
        strategy.ensureRedeemable(alice, address(nAlpha), type(uint256).max);
    }

    // ═══════ Access control ═══════

    function test_Deposit_RevertNotCDO() public {
        vm.startPrank(alice);
        vm.expectRevert();
        strategy.deposit(address(jrtVault), address(nAlpha), DEPOSIT_AMOUNT, 0, alice);
        vm.stopPrank();
    }

    function test_Withdraw_RevertNotCDO() public {
        vm.startPrank(alice);
        vm.expectRevert();
        strategy.withdraw(address(jrtVault), address(nAlpha), DEPOSIT_AMOUNT, 0, alice, alice);
        vm.stopPrank();
    }

    function test_ReduceReserve_RevertNotCDO() public {
        vm.startPrank(alice);
        vm.expectRevert();
        strategy.reduceReserve(address(nAlpha), DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    TG-2: NestDepositAdapter Unit Tests
    //////////////////////////////////////////////////////////////*/

    function test_Adapter_Swap_Success() public {
        uint256 usdcAmount = 1000 * ONE_USDC;

        // Give USDC to alice who will call the adapter
        vm.startPrank(alice);
        usdc.approve(address(nestAdapter), usdcAmount);

        bytes memory predicateMessage = _validPredicateMessage();

        uint256 nAlphaBefore = nAlpha.balanceOf(alice);
        uint256 amountOut = nestAdapter.swap(
            address(usdc),
            address(nAlpha),
            usdcAmount,
            0, // no min for this test
            alice,
            predicateMessage
        );
        vm.stopPrank();

        assertGt(amountOut, 0, "Should receive nALPHA");
        assertEq(nAlpha.balanceOf(alice) - nAlphaBefore, amountOut, "nALPHA balance should increase by amountOut");
        assertEq(usdc.balanceOf(alice), 10_000 * ONE_USDC - usdcAmount, "USDC should be spent");

        // Adapter should have zero balance
        assertEq(nAlpha.balanceOf(address(nestAdapter)), 0, "Adapter should not retain nALPHA");
        assertEq(usdc.balanceOf(address(nestAdapter)), 0, "Adapter should not retain USDC");
    }

    function test_Adapter_Swap_WrongTokenOut() public {
        vm.startPrank(alice);
        usdc.approve(address(nestAdapter), ONE_USDC);

        bytes memory predicateMessage = _validPredicateMessage();

        vm.expectRevert(abi.encodeWithSelector(NestDepositAdapter.UnexpectedTokenOut.selector, address(usdc)));
        nestAdapter.swap(
            address(usdc),
            address(usdc), // wrong token out
            ONE_USDC,
            0,
            alice,
            predicateMessage
        );
        vm.stopPrank();
    }

    function test_Adapter_Swap_EmptyPredicateReverts() public {
        vm.startPrank(alice);
        usdc.approve(address(nestAdapter), ONE_USDC);

        vm.expectRevert(); // MockNestVaultPredicateProxy reverts on empty predicate
        nestAdapter.swap(
            address(usdc),
            address(nAlpha),
            ONE_USDC,
            0,
            alice,
            _emptyPredicateMessage() // empty taskId triggers revert
        );
        vm.stopPrank();
    }

    function test_Adapter_Swap_InsufficientOutput() public {
        vm.startPrank(alice);
        usdc.approve(address(nestAdapter), ONE_USDC);

        bytes memory predicateMessage = _validPredicateMessage();

        vm.expectRevert(); // minAmountOut too high
        nestAdapter.swap(
            address(usdc),
            address(nAlpha),
            ONE_USDC,
            type(uint256).max, // impossible min
            alice,
            predicateMessage
        );
        vm.stopPrank();
    }

    function test_Adapter_Swap_DepositRejected() public {
        predicateProxy.setRejectDeposits(true);

        vm.startPrank(alice);
        usdc.approve(address(nestAdapter), ONE_USDC);

        bytes memory predicateMessage = _validPredicateMessage();

        vm.expectRevert();
        nestAdapter.swap(
            address(usdc),
            address(nAlpha),
            ONE_USDC,
            0,
            alice,
            predicateMessage
        );
        vm.stopPrank();
    }

    function test_Adapter_ShareCalculation() public {
        uint256 usdcAmount = 1000 * ONE_USDC;

        vm.startPrank(alice);
        usdc.approve(address(nestAdapter), usdcAmount);

        bytes memory predicateMessage = _validPredicateMessage();
        uint256 amountOut = nestAdapter.swap(
            address(usdc),
            address(nAlpha),
            usdcAmount,
            0,
            alice,
            predicateMessage
        );
        vm.stopPrank();

        // shares = depositAmount * 1e6 / exchangeRate
        uint256 expectedShares = (usdcAmount * 1e6) / INITIAL_RATE;
        assertEq(amountOut, expectedShares, "Shares should match rate-based calculation");
    }

    /*//////////////////////////////////////////////////////////////
            TG-3: Full Adapter Deposit Path Integration
    //////////////////////////////////////////////////////////////*/

    function test_Integration_DepositUSDC_ViaAdapter_ToJrt() public {
        uint256 usdcAmount = 1000 * ONE_USDC;

        vm.startPrank(alice);

        // Approve depositor to spend USDC
        usdc.approve(address(depositor), usdcAmount);

        // Build extended deposit params (with adapter data for predicate)
        TrancheDepositor.TDepositParamsCommon memory params = TrancheDepositor.TDepositParamsCommon({
            swapDeadline: 0,
            swapAmountOutMinimum: 0,
            swapTokenOut: address(0),
            minShares: 0,
            data: _validPredicateMessage()
        });

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 sharesBefore = jrtVault.balanceOf(alice);

        depositor.deposit(
            IMetaVault(address(jrtVault)),  // vault
            IERC20(address(usdc)),          // asset
            usdcAmount,                     // amount
            alice,                          // receiver
            params                          // params with adapter data
        );

        vm.stopPrank();

        // Verify USDC was spent
        assertEq(usdcBefore - usdc.balanceOf(alice), usdcAmount, "USDC should be spent");

        // Verify JRT shares received
        uint256 sharesReceived = jrtVault.balanceOf(alice) - sharesBefore;
        assertGt(sharesReceived, 0, "Should receive JRT shares via adapter path");

        // Verify nALPHA ended up in strategy
        assertGt(nAlpha.balanceOf(address(strategy)), 0, "Strategy should hold nALPHA from adapter deposit");

        // Verify no tokens stranded
        assertEq(usdc.balanceOf(address(nestAdapter)), 0, "Adapter should not retain USDC");
        assertEq(nAlpha.balanceOf(address(nestAdapter)), 0, "Adapter should not retain nALPHA");
        assertEq(usdc.balanceOf(address(depositor)), 0, "Depositor should not retain USDC");
        assertEq(nAlpha.balanceOf(address(depositor)), 0, "Depositor should not retain nALPHA");
    }

    /*//////////////////////////////////////////////////////////////
            TG-4: TrancheDepositor Backward Compatibility
    //////////////////////////////////////////////////////////////*/

    function test_BackwardCompat_DirectDeposit_NAlpha_NoAdapter() public {
        // Direct nALPHA deposit should still work (not via adapter)
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        assertGt(jrtVault.balanceOf(alice), 0, "Direct nALPHA deposit should still work");
        assertEq(nAlpha.balanceOf(address(strategy)), DEPOSIT_AMOUNT, "Strategy should hold nALPHA");
    }

    function test_BackwardCompat_MultipleDepositsAndWithdrawals() public {
        // Multiple deposits
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToJrt(bob, DEPOSIT_AMOUNT);
        _depositToJrt(alice, DEPOSIT_AMOUNT / 2);

        uint256 totalInStrategy = nAlpha.balanceOf(address(strategy));
        assertEq(totalInStrategy, DEPOSIT_AMOUNT * 2 + DEPOSIT_AMOUNT / 2, "Total in strategy should match");

        // Disable cooldown for clean withdrawal test
        vm.prank(owner);
        strategy.setCooldowns(0, 0);

        // Partial withdrawal — use maxWithdraw for correct token amount
        vm.startPrank(alice);
        uint256 maxW = jrtVault.maxWithdraw(alice);
        uint256 halfWithdraw = maxW / 2;
        uint256 sharesBefore = jrtVault.balanceOf(alice);
        jrtVault.withdraw(address(nAlpha), halfWithdraw, alice, alice);
        vm.stopPrank();

        assertLt(jrtVault.balanceOf(alice), sharesBefore, "Alice should have fewer shares after partial withdraw");
    }

    /*//////////////////////////////////////////////////////////////
            Decimals Deep Dive: The Critical 1e6 Verification
    //////////////////////////////////////////////////////////////*/

    function test_Decimals_Correctness_6dec() public view {
        // nALPHA has 6 decimals (verified on-chain: 0x593cCcA4... returns 6)
        // Accountant rate is in 6 decimals (verified on-chain: base=USDC, decimals=6)
        // Formula: shares * rate / 1e6 = USDC value

        // Example: 1 nALPHA (= 1e6 raw) at rate 1094524:
        uint256 oneShare = 1e6;
        uint256 rate = 1094524; // mainnet value as of 2026-06-18
        uint256 value = Math.mulDiv(oneShare, rate, 1e6);
        assertEq(value, rate, "1 nALPHA at rate 1094524 should be worth 1094524 USDC-wei = 1.094524 USDC");
    }

    function test_Decimals_WouldBreakIf18() public pure {
        // If nALPHA had 18 decimals (standard ERC20), the formula would break:
        // 1 nALPHA (1e18) * rate (1094524) / 1e6 = 1094524e12 = 1.094524e18
        // This is 1e12 times too large (would report ~$1 trillion per nALPHA share!)
        //
        // But since nALPHA has 6 decimals (verified), this can't happen.
        // This test documents the invariant.

        uint256 oneShare18 = 1e18;
        uint256 rate = 1094524;
        uint256 brokenValue = Math.mulDiv(oneShare18, rate, 1e6);
        uint256 correctValue = Math.mulDiv(1e6, rate, 1e6);

        // brokenValue would be 1094524 * 1e12 = catastrophically wrong
        assert(brokenValue == correctValue * 1e12);
    }

    function test_RateConversion_Dimensional_Analysis() public {
        // Dimensional proof:
        // shares [nALPHA-wei, 6 dec] * rate [USDC-per-nALPHA, 6 dec] / 1e6 = USDC-wei [6 dec]
        //
        // Concrete: 100 nALPHA at rate 1.094524 USDC/nALPHA
        uint256 shares = 100 * 1e6; // 100 nALPHA in raw units
        nestAccountant.setExchangeRate(1094524); // 1.094524 USDC/nALPHA

        _mintNAlpha(alice, shares);
        _depositToJrt(alice, shares);

        uint256 nav = strategy.totalAssets();
        // Expected: 100 * 1.094524 = 109.4524 USDC = 109452400 USDC-wei
        assertEq(nav, 109452400, "100 nALPHA * 1.094524 rate = 109.4524 USDC");
    }

    /*//////////////////////////////////////////////////////////////
            TG-5: APR Snapshot Provider Integration
    //////////////////////////////////////////////////////////////*/

    function test_SetAprProvider() public {
        NestAccountantAprProvider provider = new NestAccountantAprProvider(
            INestAccountant(address(nestAccountant)),
            _makeProviderRounds()
        );

        vm.prank(owner);
        strategy.setAprProvider(IAprSnapshotProvider(address(provider)));
        assertEq(address(strategy.aprProvider()), address(provider), "Provider should be set");
    }

    function test_SetAprProvider_RevertUnauthorized() public {
        vm.startPrank(alice);
        vm.expectRevert();
        strategy.setAprProvider(IAprSnapshotProvider(address(1)));
        vm.stopPrank();
    }

    function test_AprSnapshot_UpdatedOnDeposit() public {
        NestAccountantAprProvider provider = new NestAccountantAprProvider(
            INestAccountant(address(nestAccountant)),
            _makeProviderRounds()
        );
        vm.prank(owner);
        strategy.setAprProvider(IAprSnapshotProvider(address(provider)));

        (,, uint64 tsBefore) = provider.getAprPair();

        vm.warp(block.timestamp + 1 days);
        nestAccountant.setExchangeRate(INITIAL_RATE * 101 / 100);

        _depositToJrt(alice, DEPOSIT_AMOUNT);

        (,, uint64 tsAfter) = provider.getAprPair();
        assertGt(tsAfter, tsBefore, "APR timestamp should advance after deposit");
    }

    function test_AprSnapshot_UpdatedOnWithdraw() public {
        _depositToJrt(bob, DEPOSIT_AMOUNT);
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        NestAccountantAprProvider provider = new NestAccountantAprProvider(
            INestAccountant(address(nestAccountant)),
            _makeProviderRounds()
        );
        vm.prank(owner);
        strategy.setAprProvider(IAprSnapshotProvider(address(provider)));
        vm.prank(owner);
        strategy.setCooldowns(0, 0);

        (,, uint64 tsBefore) = provider.getAprPair();

        vm.warp(block.timestamp + 1 days);
        nestAccountant.setExchangeRate(INITIAL_RATE * 102 / 100);

        uint256 maxShares = jrtVault.maxRedeem(alice);
        vm.prank(alice);
        jrtVault.redeem(address(nAlpha), maxShares, alice, alice);

        (,, uint64 tsAfter) = provider.getAprPair();
        assertGt(tsAfter, tsBefore, "APR timestamp should advance after withdraw");
    }

    function test_AprSnapshot_NoopWhenProviderNotSet() public {
        assertEq(address(strategy.aprProvider()), address(0), "Provider should be zero by default");
        _depositToJrt(alice, DEPOSIT_AMOUNT);
    }
    // ═══════════════════════════════════════════════════════════════════════════
    //  Predicate Message Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Constructs a valid PredicateMessage for test deposits
    function _validPredicateMessage() internal pure returns (bytes memory) {
        return abi.encode(PredicateMessage({
            taskId: "test-task-id",
            expireByBlockNumber: type(uint256).max,
            signerAddresses: new address[](0),
            signatures: new bytes[](0)
        }));
    }

    /// @dev Constructs a PredicateMessage with empty taskId (should trigger revert)
    function _emptyPredicateMessage() internal pure returns (bytes memory) {
        return abi.encode(PredicateMessage({
            taskId: "",
            expireByBlockNumber: 0,
            signerAddresses: new address[](0),
            signatures: new bytes[](0)
        }));
    }

    /// @dev Creates a TRound[10] array from the mock accountant's current state.
    ///      All 10 entries have the same rate, spread 1 second apart ending at block.timestamp.
    ///      This gives a 0% initial APR (rate unchanged across window).
    ///      Uses small intervals to avoid underflow when block.timestamp is low (forge default = 1).
    function _makeProviderRounds() internal view returns (NestAccountantAprProvider.TRound[10] memory rounds) {
        uint96 rate = uint96(nestAccountant.exchangeRate());
        uint64 ts = uint64(block.timestamp);
        for (uint256 i = 0; i < 10; i++) {
            // Oldest first: i=0 is 9 seconds ago, i=9 is now
            // Use small offsets to stay safe with low block.timestamp values
            uint64 offset = uint64(9 - i);
            rounds[i] = NestAccountantAprProvider.TRound({
                answer: rate,
                updatedAt: ts > offset ? ts - offset : uint64(1)
            });
        }
    }
}
