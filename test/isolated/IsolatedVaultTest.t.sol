// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UD60x18} from "@prb/math/src/ud60x18/Math.sol";
import {IsolatedVaultDeploy} from "./IsolatedVaultDeploy.t.sol";
import {console2} from "forge-std/Test.sol";

contract IsolatedVaultTest is IsolatedVaultDeploy {
    address internal alice;

    uint256 internal constant INITIAL_BALANCE = 10_000 ether;
    uint256 internal constant DEPOSIT_AMOUNT = 1_000 ether;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        vm.label(alice, "Alice");

        _deployIsolatedStack();

        baseAsset.mint(alice, INITIAL_BALANCE);
    }

    function test_DepositBaseAsset_ToJrtVault_RoutesToJuniorStrat() public {
        vm.startPrank(alice);

        uint256 balanceBefore = baseAsset.balanceOf(alice);
        baseAsset.approve(address(jrtVault), DEPOSIT_AMOUNT);

        // deposit into the junior strat
        uint256 shares = jrtVault.deposit(address(baseAsset), DEPOSIT_AMOUNT, alice);

        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");
        assertEq(jrtVault.balanceOf(alice), shares, "Alice should own JRT shares");
        assertEq(balanceBefore - baseAsset.balanceOf(alice), DEPOSIT_AMOUNT, "Base asset should be transferred");

        assertEq(baseAsset.balanceOf(address(juniorStrat)), DEPOSIT_AMOUNT, "Junior strat should receive deposit");
        assertEq(baseAsset.balanceOf(address(seniorStrat)), 0, "Senior strat should remain empty");
        assertEq(juniorStrat.totalAssetsValue(), DEPOSIT_AMOUNT, "Junior strat assets should track JRT deposit");
        assertEq(seniorStrat.totalAssetsValue(), 0, "Senior strat assets should remain zero");

        (uint256 jrtAssets, uint256 srtAssets) = strategy.totalAssetsByTranche();
        assertEq(jrtAssets, DEPOSIT_AMOUNT, "JRT assets should be isolated in junior strat");
        assertEq(srtAssets, 0, "SRT assets should remain zero");
    }

    function test_DepositBaseAsset_ToSrtVault_RoutesToSeniorStrat() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        vm.startPrank(alice);

        uint256 balanceBefore = baseAsset.balanceOf(alice);
        baseAsset.approve(address(srtVault), DEPOSIT_AMOUNT);

        uint256 shares = srtVault.deposit(address(baseAsset), DEPOSIT_AMOUNT, alice);

        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");
        assertEq(srtVault.balanceOf(alice), shares, "Alice should own SRT shares");
        assertEq(balanceBefore - baseAsset.balanceOf(alice), DEPOSIT_AMOUNT, "Base asset should be transferred");

        assertEq(
            baseAsset.balanceOf(address(juniorStrat)), DEPOSIT_AMOUNT, "Junior strat should keep JRT deposit only"
        );
        assertEq(baseAsset.balanceOf(address(seniorStrat)), DEPOSIT_AMOUNT, "Senior strat should receive SRT deposit");
        assertEq(juniorStrat.totalAssetsValue(), DEPOSIT_AMOUNT, "Junior strat assets should stay unchanged");
        assertEq(seniorStrat.totalAssetsValue(), DEPOSIT_AMOUNT, "Senior strat assets should track SRT deposit");

        (uint256 jrtAssets, uint256 srtAssets) = strategy.totalAssetsByTranche();
        assertEq(jrtAssets, DEPOSIT_AMOUNT, "JRT assets should stay in junior strat");
        assertEq(srtAssets, DEPOSIT_AMOUNT, "SRT assets should be isolated in senior strat");
    }

    function test_SrtWithdraw_ConsumesJrtLiquidityFirst() public {
        // Setup: deposit into both tranches
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // Snapshot balances before withdrawal
        uint256 juniorBalBefore = baseAsset.balanceOf(address(juniorStrat));
        uint256 seniorBalBefore = baseAsset.balanceOf(address(seniorStrat));
        uint256 aliceBalBefore = baseAsset.balanceOf(alice);

        assertEq(juniorBalBefore, DEPOSIT_AMOUNT, "Junior strat should hold JRT deposit");
        assertEq(seniorBalBefore, DEPOSIT_AMOUNT, "Senior strat should hold SRT deposit");

        // Withdraw half the SRT deposit
        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2;

        vm.startPrank(alice);
        srtVault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        // Junior strat should have been drained first
        uint256 juniorBalAfter = baseAsset.balanceOf(address(juniorStrat));
        uint256 seniorBalAfter = baseAsset.balanceOf(address(seniorStrat));

        uint256 juniorConsumed = juniorBalBefore - juniorBalAfter;
        uint256 seniorConsumed = seniorBalBefore - seniorBalAfter;

        assertEq(juniorConsumed, withdrawAmount, "Junior strat liquidity should be consumed first");
        assertEq(seniorConsumed, 0, "Senior strat should not be touched when junior has sufficient liquidity");
        assertEq(baseAsset.balanceOf(alice) - aliceBalBefore, withdrawAmount, "Alice should receive withdrawn assets");

        // Strategy should track the debt owed from senior to junior
        assertApproxEqAbs(_debtToJunior(), withdrawAmount, 1e3, "Senior debt to junior should equal borrowed amount");
    }

    function test_SrtWithdraw_FallsBackToSeniorStrat_WhenJrtLiquidityInsufficient() public {
        // Setup: deposit into both tranches
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // Withdraw amount exceeds junior liquidity
        uint256 withdrawAmount = DEPOSIT_AMOUNT + (DEPOSIT_AMOUNT / 2); // 1500 — exceeds JRT's 1000

        vm.startPrank(alice);
        // Need extra SRT shares to withdraw this much — deposit more into SRT
        baseAsset.approve(address(srtVault), DEPOSIT_AMOUNT);
        srtVault.deposit(address(baseAsset), DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        uint256 juniorBalBefore = baseAsset.balanceOf(address(juniorStrat));
        uint256 seniorBalBefore = baseAsset.balanceOf(address(seniorStrat));

        vm.startPrank(alice);
        srtVault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        uint256 juniorConsumed = juniorBalBefore - baseAsset.balanceOf(address(juniorStrat));
        uint256 seniorConsumed = seniorBalBefore - baseAsset.balanceOf(address(seniorStrat));

        // Junior strat should be fully drained, remainder from senior
        assertEq(juniorConsumed, DEPOSIT_AMOUNT, "All junior liquidity should be consumed first");
        assertEq(seniorConsumed, withdrawAmount - DEPOSIT_AMOUNT, "Senior strat covers the remainder");
        assertApproxEqAbs(_debtToJunior(), DEPOSIT_AMOUNT, 1e3, "Debt should equal full junior amount borrowed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // JRT Withdrawal — senior strat consumed first
    // ─────────────────────────────────────────────────────────────────────────

    function test_JrtWithdraw_UsesSeniorStratFirst() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2;

        uint256 juniorBalBefore = baseAsset.balanceOf(address(juniorStrat));
        uint256 seniorBalBefore = baseAsset.balanceOf(address(seniorStrat));

        vm.startPrank(alice);
        jrtVault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        uint256 juniorConsumed = juniorBalBefore - baseAsset.balanceOf(address(juniorStrat));
        uint256 seniorConsumed = seniorBalBefore - baseAsset.balanceOf(address(seniorStrat));

        assertEq(seniorConsumed, withdrawAmount, "Senior strat provides liquidity first for JRT withdrawals");
        assertEq(juniorConsumed, 0, "Junior strat should not be touched when senior has sufficient liquidity");
        assertApproxEqAbs(_debtToSenior(), withdrawAmount, 1e3, "Junior owes senior for borrowed liquidity");
    }

    function test_JrtWithdraw_FallsBackToJuniorStrat_WhenSeniorLiquidityInsufficient() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        // Senior strat only has 300 — less than the planned withdrawal of 500
        uint256 srtDeposit = 300 ether;
        _depositToSrt(alice, srtDeposit);

        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2; // 500 > 300

        uint256 juniorBalBefore = baseAsset.balanceOf(address(juniorStrat));
        uint256 seniorBalBefore = baseAsset.balanceOf(address(seniorStrat));

        vm.startPrank(alice);
        jrtVault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        uint256 juniorConsumed = juniorBalBefore - baseAsset.balanceOf(address(juniorStrat));
        uint256 seniorConsumed = seniorBalBefore - baseAsset.balanceOf(address(seniorStrat));

        assertEq(seniorConsumed, srtDeposit, "Senior strat fully consumed first");
        assertEq(juniorConsumed, withdrawAmount - srtDeposit, "Junior strat covers the remainder");
        assertEq(_debtToSenior(), srtDeposit, "Debt equals the full senior liquidity borrowed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Loss waterfall — end-to-end with real tranche shares
    // ─────────────────────────────────────────────────────────────────────────

    function test_LossWaterfall_JrtStratAbsorbsLoss_SrtNavProtected() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // Simulate a 400 loss in the JRT strat
        uint256 lossAmount = 400 ether;
        juniorStrat.setTotalAssets(DEPOSIT_AMOUNT - lossAmount);

        // View accounting reflects the loss in JRT, SRT completely protected
        (uint256 jrtNavT1, uint256 srtNavT1,) = accounting.totalAssets();
        assertEq(jrtNavT1, DEPOSIT_AMOUNT - lossAmount, "JRT nav should reflect the strat loss");
        assertEq(srtNavT1, DEPOSIT_AMOUNT, "SRT nav should be fully protected by JRT");
    }

    function test_LossWaterfall_SrtStratAbsorbedByJrt() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // Simulate an 800 loss in the SRT strat
        uint256 lossAmount = 800 ether;
        seniorStrat.setTotalAssets(DEPOSIT_AMOUNT - lossAmount);

        // JRT absorbs the loss from the SRT strat — SRT nav unchanged
        (uint256 jrtNavT1, uint256 srtNavT1,) = accounting.totalAssets();
        assertEq(jrtNavT1, DEPOSIT_AMOUNT - lossAmount, "JRT nav absorbs the SRT strat loss");
        assertEq(srtNavT1, DEPOSIT_AMOUNT, "SRT nav fully protected by JRT buffer");
    }

    function test_LossWaterfall_JrtFullyWiped_SrtAbsorbsRemainder() public {
        // Deposit smaller JRT so it gets fully wiped
        uint256 jrtDeposit = 300 ether;
        _depositToJrt(alice, jrtDeposit);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // Set senior strategy to 1 wei to simulate near-total loss.
        // Using exactly 0 triggers the oracle-stale gate in MultiStrategy.totalAssets
        // (returns navT0 whenever any sub-strategy returns 0, conflating genuine zero
        // with "oracle not yet updated").
        seniorStrat.setTotalAssets(1);

        // JRT absorbs loss first (loss ≈ 999 ether > jrtDeposit 300 ether), so JRT is fully wiped.
        // SRT absorbs the remainder. Final NAVs must sum to navT1 = juniorStrat + 1 wei.
        uint256 expectedJrtNav = 0;
        uint256 expectedSrtNav = jrtDeposit + 1; // navT1 = 300e18 + 1 wei; JRT=0, SRT gets the rest

        (uint256 jrtNavT1, uint256 srtNavT1,) = accounting.totalAssets();
        assertEq(jrtNavT1, expectedJrtNav, "JRT nav wiped to zero absorbing as much loss as possible");
        assertEq(srtNavT1, expectedSrtNav, "SRT nav absorbs the loss that exceeds JRT capacity");
    }

    function test_LossWaterfall_SharePriceReflectsLoss() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        uint256 jrtSharesBefore = jrtVault.balanceOf(alice);
        uint256 initialJrtPricePerShare = cdo.pricePerShare(address(jrtVault));

        // Simulate 500 loss in JRT strat
        juniorStrat.setTotalAssets(DEPOSIT_AMOUNT / 2);

        uint256 lossJrtPricePerShare = cdo.pricePerShare(address(jrtVault));
        uint256 srtPricePerShare = cdo.pricePerShare(address(srtVault));

        assertLt(lossJrtPricePerShare, initialJrtPricePerShare, "JRT share price should drop after loss");
        // SRT price per share should be unchanged (1e18 with 1:1 initial deposit)
        assertEq(srtPricePerShare, initialJrtPricePerShare, "SRT share price protected from JRT strat loss");
        assertGt(jrtSharesBefore, 0, "Alice holds JRT shares");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Debt repayment — restoring strat balances after cross-strat borrowing
    // ─────────────────────────────────────────────────────────────────────────

    function test_RepaySeniorDebtToJunior_RestoresStratBalances() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // SRT withdrawal: borrows from junior strat
        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2;
        vm.startPrank(alice);
        srtVault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        uint256 juniorDebt = _debtToJunior();
        assertApproxEqAbs(juniorDebt, withdrawAmount, 1e3);
        assertEq(baseAsset.balanceOf(address(juniorStrat)), DEPOSIT_AMOUNT - withdrawAmount);
        assertEq(baseAsset.balanceOf(address(seniorStrat)), DEPOSIT_AMOUNT);

        // Grant repayment role to owner
        vm.startPrank(owner);
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), owner);

        // Repay: moves juniorDebt from senior strat (idx 1) → junior strat (idx 0)
        rebalancer.initiateRebalance(1, 0, address(baseAsset), address(baseAsset), juniorDebt);
        vm.stopPrank();

        assertEq(_debtToJunior(), 0, "Debt cleared after repayment");
        assertApproxEqAbs(
            baseAsset.balanceOf(address(juniorStrat)),
            DEPOSIT_AMOUNT,
            1e3,
            "Junior strat fully restored"
        );
        assertApproxEqAbs(
            baseAsset.balanceOf(address(seniorStrat)),
            DEPOSIT_AMOUNT - withdrawAmount,
            1e3,
            "Senior strat decremented by repaid amount"
        );
    }

    function test_RepayJuniorDebtToSenior_RestoresStratBalances() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // JRT withdrawal: borrows from senior strat
        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2;
        vm.startPrank(alice);
        jrtVault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        uint256 seniorDebt = _debtToSenior();
        assertApproxEqAbs(seniorDebt, withdrawAmount, 1e3);
        assertEq(baseAsset.balanceOf(address(juniorStrat)), DEPOSIT_AMOUNT);
        assertEq(baseAsset.balanceOf(address(seniorStrat)), DEPOSIT_AMOUNT - withdrawAmount);

        // Grant repayment role to owner
        vm.startPrank(owner);
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), owner);

        // Repay: moves seniorDebt from junior strat (idx 0) → senior strat (idx 1)
        rebalancer.initiateRebalance(0, 1, address(baseAsset), address(baseAsset), seniorDebt);
        vm.stopPrank();

        assertEq(_debtToSenior(), 0, "Debt cleared after repayment");
        assertApproxEqAbs(
            baseAsset.balanceOf(address(seniorStrat)),
            DEPOSIT_AMOUNT,
            1e3,
            "Senior strat fully restored"
        );
        assertApproxEqAbs(
            baseAsset.balanceOf(address(juniorStrat)),
            DEPOSIT_AMOUNT - withdrawAmount,
            1e3,
            "Junior strat decremented by repaid amount"
        );
    }

    function test_RepaySeniorDebt_PartialRepayment() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        srtVault.withdraw(DEPOSIT_AMOUNT / 2, alice, alice); // borrows 500 from junior
        vm.stopPrank();

        vm.startPrank(owner);
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), owner);
        rebalancer.initiateRebalance(1, 0, address(baseAsset), address(baseAsset), 200 ether); // partial repay
        vm.stopPrank();

        assertApproxEqAbs(_debtToJunior(), 300 ether, 1e3, "Remaining debt after partial repayment");
        assertEq(baseAsset.balanceOf(address(juniorStrat)), DEPOSIT_AMOUNT - 300 ether, "Junior partially restored");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Access control — withdrawal cap enforcement
    // ─────────────────────────────────────────────────────────────────────────

    function test_MaxWithdraw_JrtConstrainedByMinimumJrtSrtRatio() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // minimumJrtSrtRatio = 0.05e18 (5%), so JRT must keep 50 as a buffer against 1000 SRT
        // maxWithdraw(JRT) = 1000 - (1000 * 0.05) = 950
        uint256 maxJrtWithdraw = cdo.maxWithdraw(address(jrtVault));
        assertEq(maxJrtWithdraw, DEPOSIT_AMOUNT - (DEPOSIT_AMOUNT * 0.05e18 / 1e18));

        // Attempting to withdraw more than the cap should revert
        vm.startPrank(alice);
        vm.expectRevert();
        jrtVault.withdraw(maxJrtWithdraw + 1 ether, alice, alice);
        vm.stopPrank();
    }

    function test_MaxWithdraw_JrtUnconstrainedWhenNoSrt() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        // No SRT deposits — ratio buffer is 0, full JRT is withdrawable

        uint256 maxJrtWithdraw = cdo.maxWithdraw(address(jrtVault));
        assertEq(maxJrtWithdraw, DEPOSIT_AMOUNT, "JRT fully withdrawable when there is no SRT");
    }

    function test_MaxDeposit_SrtLimitedByJrtBuffer() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT); // jrtNav = 1000

        // minimumJrtSrtRatioBuffer = 0.06e18 (6%)
        // maxSrt = jrtNav / 0.06 = 1000 / 0.06 ≈ 16666 ether
        uint256 maxSrtDeposit = cdo.maxDeposit(address(srtVault));
        assertGt(maxSrtDeposit, 0, "SRT deposit should be allowed when JRT exists");

        // Depositing way above the cap should revert
        vm.startPrank(alice);
        baseAsset.approve(address(srtVault), maxSrtDeposit + 1 ether);
        vm.expectRevert();
        srtVault.deposit(address(baseAsset), maxSrtDeposit + 1 ether, alice);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Cross-tranche accounting invariants
    // ─────────────────────────────────────────────────────────────────────────

    function test_TotalStrategyAssets_SumOfBothStrats() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        (uint256 jrtAssets, uint256 srtAssets) = strategy.totalAssetsByTranche();
        uint256 totalFromStrats = juniorStrat.totalAssets() + seniorStrat.totalAssets();

        assertEq(jrtAssets + srtAssets, totalFromStrats, "Strategy total should equal sum of both strats");
        assertEq(cdo.totalStrategyAssets(), totalFromStrats, "CDO total strategy assets should match");
    }

    function test_AccountingNavMatchesStrategyAssets_AfterCrossStratWithdrawal() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // SRT borrows from JRT strat
        vm.startPrank(alice);
        srtVault.withdraw(DEPOSIT_AMOUNT / 2, alice, alice);
        vm.stopPrank();

        // After cross-strat withdrawal: debt tracked correctly in strategy
        uint256 strategySeniorDebt = _debtToJunior();
        assertApproxEqAbs(strategySeniorDebt, DEPOSIT_AMOUNT / 2, 1e3, "Strategy debt should equal borrowed amount");

        // NAV invariant: jrtNav + srtNav == total deposited - total withdrawn
        (uint256 jrtNavT1, uint256 srtNavT1,) = accounting.totalAssets();
        assertEq(
            jrtNavT1 + srtNavT1,
            DEPOSIT_AMOUNT + DEPOSIT_AMOUNT - DEPOSIT_AMOUNT / 2,
            "NAV invariant: total nav equals net deposits"
        );

        // Individual NAV split: JRT entitlement intact (borrowed liquidity is repayable debt),
        // SRT entitlement reflects the net withdrawal.
        assertEq(jrtNavT1, DEPOSIT_AMOUNT, "JRT entitlement unchanged: cross-strat borrow is a repayable debt");
        assertEq(srtNavT1, DEPOSIT_AMOUNT / 2, "SRT entitlement reflects the withdrawal");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Premium accrual — SRT APR target mechanics (SIP-04 §4.3)
    // ─────────────────────────────────────────────────────────────────────────

    function test_PremiumAccrual_ExcessSrtYieldFlowsToJrt() public {
        // Set aprTarget = aprBase = 4% so aprSrt = max(4%, 4%*(1-risk)) = 4% regardless of risk
        vm.startPrank(owner);
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), owner);
        aprFeed.updateRoundData(0.04e12, 0.04e12, uint64(block.timestamp));
        vm.stopPrank();

        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // Activate APR after deposits — indexTimestamp anchored to deposit block
        vm.prank(owner);
        accounting.onAprChanged();

        // Simulate 182 days: SRT strat gains +200 (well above 4% APR target ≈ 19.9 ether)
        vm.warp(block.timestamp + 182 days);
        seniorStrat.setTotalAssets(DEPOSIT_AMOUNT + 200 ether);

        (uint256 jrtNavT1, uint256 srtNavT1,) = accounting.totalAssets();

        // Total NAV conserved
        assertApproxEqAbs(jrtNavT1 + srtNavT1, 2 * DEPOSIT_AMOUNT + 200 ether, 1e12, "Total NAV conserved");

        // SRT capped at its APR target — interestFactor = 4% * 182d / 365d ≈ 1.9945%
        uint256 expectedSrtGain = DEPOSIT_AMOUNT * 4 * uint256(182 days) / (100 * 31_536_000);
        assertApproxEqAbs(srtNavT1, DEPOSIT_AMOUNT + expectedSrtGain, 0.01 ether, "SRT grows by exactly its APR target");

        // JRT captures all strat gain above the SRT target
        assertGt(jrtNavT1, DEPOSIT_AMOUNT, "JRT receives excess SRT yield as premium");
        assertApproxEqAbs(jrtNavT1, DEPOSIT_AMOUNT + 200 ether - expectedSrtGain, 0.01 ether, "JRT gets remainder after SRT target");
    }

    function test_PremiumAccrual_SrtShortfall_JrtSubsidizes() public {
        vm.startPrank(owner);
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), owner);
        aprFeed.updateRoundData(0.04e12, 0.04e12, uint64(block.timestamp));
        vm.stopPrank();

        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        vm.prank(owner);
        accounting.onAprChanged();

        // SRT strat gains only +10 — far below the 4% APR target of ≈19.9 ether
        vm.warp(block.timestamp + 182 days);
        seniorStrat.setTotalAssets(DEPOSIT_AMOUNT + 10 ether);

        (uint256 jrtNavT1, uint256 srtNavT1,) = accounting.totalAssets();

        // Total NAV conserved
        assertApproxEqAbs(jrtNavT1 + srtNavT1, 2 * DEPOSIT_AMOUNT + 10 ether, 1e12, "Total NAV conserved");

        // SRT still receives its full APR target even though the strat earned lesser
        uint256 expectedSrtGain = DEPOSIT_AMOUNT * 4 * uint256(182 days) / (100 * 31_536_000);
        assertApproxEqAbs(srtNavT1, DEPOSIT_AMOUNT + expectedSrtGain, 0.01 ether, "SRT receives full APR target subsidized by JRT");
        assertGt(srtNavT1, DEPOSIT_AMOUNT + 10 ether, "SRT gets more than its strat earned");

        // JRT principal is reduced to fund the shortfall
        assertLt(jrtNavT1, DEPOSIT_AMOUNT, "JRT principal reduced to subsidize SRT shortfall");
        assertApproxEqAbs(jrtNavT1, DEPOSIT_AMOUNT + 10 ether - expectedSrtGain, 0.01 ether, "JRT = net gain minus SRT target");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Junior allocation floor — SRT deposit re-routing
    // ─────────────────────────────────────────────────────────────────────────

    // Setup: JRT=100, SRT=500 → Junior holds 100/600 = 16.7% < 30% floor → toJunior=80.
    // An SRT deposit smaller than the shortfall (50 < 80) must be routed to Junior.
    // An SRT deposit larger than the shortfall (200 > 80) must NOT be rerouted — goes to Senior
    // normally to avoid overshooting and creating debt in the opposite direction.
    function test_SrtDeposit_RoutesToJuniorStrat_WhenBelowAllocationFloor() public {
        uint256 jrtDeposit = 100 ether;
        uint256 srtDeposit1 = 500 ether;
        uint256 smallDeposit = 50 ether;  // < toJunior(80) — should route to Junior
        uint256 largeDeposit = 200 ether; // > toJunior(80) — should NOT be rerouted

        _depositToJrt(alice, jrtDeposit);
        _depositToSrt(alice, srtDeposit1); // Junior ratio = 100/600 = 16.7% — below 30% floor

        uint256 juniorBefore = baseAsset.balanceOf(address(juniorStrat));
        uint256 seniorBefore = baseAsset.balanceOf(address(seniorStrat));

        _depositToSrt(alice, smallDeposit); // fits within shortfall → routes to Junior
        assertEq(
            baseAsset.balanceOf(address(juniorStrat)) - juniorBefore,
            smallDeposit,
            "SRT deposit should route to Junior strat when below floor"
        );
        assertEq(baseAsset.balanceOf(address(seniorStrat)), seniorBefore, "Senior strat should not receive the deposit");

        juniorBefore = baseAsset.balanceOf(address(juniorStrat));
        seniorBefore = baseAsset.balanceOf(address(seniorStrat));

        _depositToSrt(alice, largeDeposit); // exceeds shortfall → normal routing to Senior
        assertEq(
            baseAsset.balanceOf(address(seniorStrat)) - seniorBefore,
            largeDeposit,
            "Oversized SRT deposit should not be rerouted to Junior"
        );
        assertEq(baseAsset.balanceOf(address(juniorStrat)), juniorBefore, "Junior strat should not receive oversized deposit");
    }

    // Setup: JRT=300, SRT=500 → Junior holds 300/800 = 37.5% > 30% floor → toJunior=0.
    // SRT deposits must route to Senior normally when Junior is already above the floor.
    function test_SrtDeposit_ResumesNormalRouting_WhenAboveAllocationFloor() public {
        uint256 jrtDeposit = 300 ether;
        uint256 srtDeposit1 = 500 ether;
        uint256 srtDeposit2 = 100 ether;

        _depositToJrt(alice, jrtDeposit);
        _depositToSrt(alice, srtDeposit1); // Junior ratio = 300/800 = 37.5% — above 30% floor

        uint256 juniorBefore = baseAsset.balanceOf(address(juniorStrat));
        uint256 seniorBefore = baseAsset.balanceOf(address(seniorStrat));

        _depositToSrt(alice, srtDeposit2); // toJunior=0 → normal routing to Senior

        assertEq(
            baseAsset.balanceOf(address(seniorStrat)) - seniorBefore,
            srtDeposit2,
            "SRT deposit routes to Senior strat once above floor"
        );
        assertEq(baseAsset.balanceOf(address(juniorStrat)), juniorBefore, "Junior strat should not receive this deposit");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _depositToJrt(address user, uint256 amount) internal {
        vm.startPrank(user);
        baseAsset.approve(address(jrtVault), amount);
        jrtVault.deposit(address(baseAsset), amount, user);
        vm.stopPrank();
    }

    function _depositToSrt(address user, uint256 amount) internal {
        vm.startPrank(user);
        baseAsset.approve(address(srtVault), amount);
        srtVault.deposit(address(baseAsset), amount, user);
        vm.stopPrank();
    }
}
