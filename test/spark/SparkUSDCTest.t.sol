// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICooldown} from "../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import {MockERC20} from "../../contracts/test/MockERC20.sol";
import {SparkUSDCDeploy} from "./SparkUSDCDeploy.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract SparkUSDCTest is SparkUSDCDeploy {
    address public alice;
    address public bob;

    uint256 constant DEPOSIT_AMOUNT = 1_000e6; // 1 000 USDC
    uint256 constant MIN_SHARES = 1e3; // dust to avoid zero-share revert

    function setUp() public override {
        super.setUp();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        _deployStrataStack();
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositUSDC_ToJrtVault() public {
        vm.startPrank(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        usdc.approve(address(jrtVault), DEPOSIT_AMOUNT);
        uint256 shares = jrtVault.deposit(address(usdc), DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertGt(shares, 0, "Alice should receive JRT shares");
        assertEq(jrtVault.balanceOf(alice), shares);
        assertEq(usdc.balanceOf(alice), usdcBefore - DEPOSIT_AMOUNT, "USDC debited");
        assertEq(strategy.lastReportedAssets(), DEPOSIT_AMOUNT, "lastReportedAssets updated");

        uint256 strategyBalance = IERC4626(spVault).balanceOf(address(strategy));
        assertEq(strategyBalance, DEPOSIT_AMOUNT, "strategy should have deposited USDC");
    }

    function test_DepositUSDC_ToSrtVault() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT * 2);

        vm.startPrank(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        usdc.approve(address(srtVault), DEPOSIT_AMOUNT);
        uint256 shares = srtVault.deposit(address(usdc), DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertGt(shares, 0, "Alice should receive SRT shares");
        assertEq(srtVault.balanceOf(alice), shares);
        assertEq(usdc.balanceOf(alice), usdcBefore - DEPOSIT_AMOUNT, "USDC debited");
    }

    /*//////////////////////////////////////////////////////////////
                             WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawUSDC_FromJrtVault_FinalizeAfterCooldown() public {
        _depositToJrt(bob, DEPOSIT_AMOUNT); // liquidity buffer
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        uint256 shares = jrtVault.balanceOf(alice) - MIN_SHARES;
        jrtVault.redeem(address(usdc), shares, alice, alice);
        vm.stopPrank();

        ICooldown.TBalanceState memory state = erc20Cooldown.balanceOf(IERC20(address(usdc)), alice);
        assertGt(state.pending, 0, "Pending USDC in cooldown");
        assertEq(state.claimable, 0, "notihng to claim");
        assertEq(state.totalRequests, 1);

        uint256 pending = state.pending;

        // Warp past 7-day JRT cooldown
        vm.warp(block.timestamp + 7 days);

        state = erc20Cooldown.balanceOf(IERC20(address(usdc)), alice);
        assertEq(state.claimable, pending, "All pending claimable after cooldown");

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 claimed = erc20Cooldown.finalize(IERC20(address(usdc)), alice);

        assertEq(claimed, pending);
        assertEq(usdc.balanceOf(alice) - usdcBefore, claimed, "USDC received on finalize");
    }

    function test_WithdrawUSDC_FromSrtVault_Instant() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT * 2);
        _depositToJrt(bob, DEPOSIT_AMOUNT); // extra JRT coverage
        _depositToSrt(bob, DEPOSIT_AMOUNT); // SRT liquidity buffer
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        uint256 shares = srtVault.balanceOf(alice) - MIN_SHARES;
        uint256 usdcBefore = usdc.balanceOf(alice);
        srtVault.redeem(address(usdc), shares, alice, alice);
        uint256 usdcAfter = usdc.balanceOf(alice);
        vm.stopPrank();

        // SRT cooldown is 0 → instant delivery
        assertGt(usdcAfter - usdcBefore, 0, "USDC received immediately");

        ICooldown.TBalanceState memory state = erc20Cooldown.balanceOf(IERC20(address(usdc)), alice);
        assertEq(state.totalRequests, 0, "No cooldown requests created");
    }

    /*//////////////////////////////////////////////////////////////
                             VESTING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Vesting_GainSmoothed() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        // Simulate Spark yield by minting USDC directly into the vault
        uint256 yield = 10e6;
        usdc.mint(address(spVault), yield);

        vm.startPrank(owner);
        strategy.drip();
        vm.stopPrank();

        // Immediately after drip: all yield is unvested (1-wei ERC4626 rounding tolerated)
        assertApproxEqAbs(strategy.vestingAmount(), yield, 1);
        assertApproxEqAbs(strategy.getUnvestedAmount(), yield, 1);
        assertApproxEqAbs(
            strategy.totalAssets(), DEPOSIT_AMOUNT, 1, "TVL unchanged right after drip"
        );

        // At 12 h: half vested
        vm.warp(block.timestamp + 12 hours);
        assertApproxEqAbs(strategy.getUnvestedAmount(), yield / 2, 1);
        assertApproxEqAbs(strategy.totalAssets(), DEPOSIT_AMOUNT + yield / 2, 1);

        // At 24 h: fully vested (1-wei OZ ERC4626 virtual-share rounding tolerated)
        vm.warp(block.timestamp + 12 hours);
        assertEq(strategy.getUnvestedAmount(), 0);
        assertApproxEqAbs(strategy.totalAssets(), DEPOSIT_AMOUNT + yield, 1);
    }

    function test_Vesting_DepositDoesNotDistortGain() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        uint256 yield = 10e6;
        usdc.mint(address(spVault), yield);

        vm.startPrank(owner);
        strategy.drip();
        vm.stopPrank();

        // Warp halfway through vesting
        vm.warp(block.timestamp + 12 hours);
        uint256 tvlMidway = strategy.totalAssets(); // DEPOSIT_AMOUNT + yield/2

        // New deposit during active vesting — _drip() fires inside deposit
        _depositToJrt(bob, DEPOSIT_AMOUNT);

        // TVL should be ~midway + new deposit; gain must not be double-counted
        assertApproxEqAbs(strategy.totalAssets(), tvlMidway + DEPOSIT_AMOUNT, 1);

        // After a full new vesting window the remaining gain fully vests.
        // deposit() credits spVault.convertToAssets(shares) and _drip() uses previewRedeem, both floor,
        // so once the vault rate is above 1 each can land 1 wei under. Never over (protocol-favorable).
        vm.warp(block.timestamp + 24 hours);
        assertLe(strategy.totalAssets(), DEPOSIT_AMOUNT * 2 + yield, "rounding must never inflate TVL");
        assertApproxEqAbs(strategy.totalAssets(), DEPOSIT_AMOUNT * 2 + yield, 2);
    }

    function test_Vesting_WithdrawCorrectlyReducesPrincipal() public {
        _depositToJrt(bob, DEPOSIT_AMOUNT); // liquidity buffer
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        uint256 yield = 10e6;
        usdc.mint(address(spVault), yield);

        vm.startPrank(owner);
        strategy.drip();
        vm.stopPrank();

        vm.warp(block.timestamp + 12 hours);

        uint256 tvlBefore = strategy.totalAssets();

        // Withdraw ~half of alice's position
        vm.startPrank(alice);
        uint256 halfShares = jrtVault.balanceOf(alice) / 2;
        jrtVault.redeem(address(usdc), halfShares, alice, alice);
        vm.stopPrank();

        uint256 tvlAfter = strategy.totalAssets();
        assertLt(tvlAfter, tvlBefore, "TVL decreases after withdrawal");

        // After full vesting window no unvested amount remains
        vm.warp(block.timestamp + 24 hours);
        assertEq(strategy.getUnvestedAmount(), 0, "All gain vested after window");
        assertGt(strategy.totalAssets(), 0, "Strategy still has assets");
    }

    function test_DebitRecognized_WithdrawIntoVestingLeavesNoPhantomAssets() public {
        // Setup: 10 USDC principal + 100 USDC yield - lastReportedAssets≈10, vestingAmount≈100
        _depositToJrt(alice, 10e6);
        usdc.mint(address(spVault), 100e6);
        vm.prank(owner);
        strategy.drip();

        // Halfway through vesting: ~half of vestingAmount is still locked
        vm.warp(block.timestamp + 12 hours);
        uint256 vestingBefore = strategy.vestingAmount();
        uint256 unvestedBefore = strategy.getUnvestedAmount();
        uint256 totalBefore = strategy.totalAssets();

        assertApproxEqAbs(unvestedBefore, vestingBefore / 2, 1, "half unvested at midpoint");
        assertGt(totalBefore, 10e6, "totalAssets includes vested yield");

        // Withdraw the entire recognised value (lastReportedAssets + all vested yield).
        // Before the fix this left a phantom ~25 USDC in totalAssets().
        vm.prank(address(cdo));
        strategy.reduceReserve(address(usdc), totalBefore, bob);

        // totalAssets must be 0 — unvested portion is preserved but fully offset
        assertApproxEqAbs(strategy.totalAssets(), 0, 1, "no phantom assets after full withdrawal");

        // The unvested portion is intact: vestingAmount reset to unvested, clock restarted
        assertApproxEqAbs(strategy.vestingAmount(), unvestedBefore, 1, "unvested preserved in vestingAmount");
        assertApproxEqAbs(strategy.getUnvestedAmount(), unvestedBefore, 1, "clock reset: all vestingAmount is unvested");
    }

    /// @notice Multiple deposits and withdrawals across two vesting cycles to
    ///         verify that mid-cycle activity never restarts the vesting clock,
    ///         small withdrawals pay out of lastReportedAssets, and large
    ///         withdrawals that dip into vested-so-far yield preserve the
    ///         unvested schedule.
    function test_Vesting_MultipleDepositWithdraw() external {
        // t=0: Alice seeds the strategy and cycle 1 kicks off with 100 USDC yield
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        uint256 t0 = block.timestamp;

        uint256 yield1 = 100e6;
        usdc.mint(address(spVault), yield1);
        vm.prank(owner);
        strategy.drip();

        assertApproxEqAbs(strategy.vestingAmount(), yield1, 1, "cycle1 vestingAmount");
        assertEq(strategy.lastDistributionTimestamp(), t0, "cycle1 timestamp = t0");
        assertApproxEqAbs(strategy.totalAssets(), DEPOSIT_AMOUNT, 1, "tvl unchanged at drip");

        // t=6h: Bob deposits mid-cycle; _drip() must no-op, schedule preserved
        vm.warp(t0 + 6 hours);
        uint256 unvestedAt6h = strategy.getUnvestedAmount();
        uint256 lastReportedBeforeBob = strategy.lastReportedAssets();

        _depositToJrt(bob, DEPOSIT_AMOUNT);

        assertEq(strategy.lastDistributionTimestamp(), t0, "mid-cycle deposit preserves timestamp");
        assertApproxEqAbs(strategy.vestingAmount(), yield1, 1, "mid-cycle deposit preserves vestingAmount");
        assertApproxEqAbs(strategy.getUnvestedAmount(), unvestedAt6h, 1, "unvested schedule preserved");
        // deposit() credits spVault.convertToAssets(shares) (floor), so up to 1 wei under, never over
        assertLe(
            strategy.lastReportedAssets(),
            lastReportedBeforeBob + DEPOSIT_AMOUNT,
            "deposit must never over-credit lastReportedAssets"
        );
        assertApproxEqAbs(
            strategy.lastReportedAssets(),
            lastReportedBeforeBob + DEPOSIT_AMOUNT,
            1,
            "deposit only grows lastReportedAssets"
        );

        // t=12h: Alice makes a small withdrawal; should drain lastReportedAssets only,
        //     not touch vestingAmount (else branch of _debitRecognized not triggered)
        vm.warp(t0 + 12 hours);
        uint256 vestingBeforeSmall = strategy.vestingAmount();
        uint256 lastReportedBeforeSmall = strategy.lastReportedAssets();

        vm.startPrank(alice);
        uint256 quarterShares = jrtVault.balanceOf(alice) / 4;
        jrtVault.redeem(address(usdc), quarterShares, alice, alice);
        vm.stopPrank();

        assertEq(strategy.lastDistributionTimestamp(), t0, "small withdraw preserves timestamp");
        assertApproxEqAbs(
            strategy.vestingAmount(), vestingBeforeSmall, 1, "small withdraw does not touch vestingAmount"
        );
        assertLt(strategy.lastReportedAssets(), lastReportedBeforeSmall, "lastReportedAssets debited");

        // t=24h: cycle 1 fully vests
        vm.warp(t0 + 24 hours);
        assertEq(strategy.getUnvestedAmount(), 0, "cycle1 fully vested");
        uint256 tvlAtCycle1End = strategy.totalAssets();

        // Cycle 2: fresh 50 USDC yield drips in
        uint256 yield2 = 50e6;
        usdc.mint(address(spVault), yield2);
        vm.prank(owner);
        strategy.drip();
        uint256 t1 = block.timestamp;

        assertApproxEqAbs(strategy.vestingAmount(), yield2, 1, "cycle2 vestingAmount");
        assertEq(strategy.lastDistributionTimestamp(), t1, "cycle2 timestamp");
        assertApproxEqAbs(strategy.totalAssets(), tvlAtCycle1End, 1, "tvl unchanged immediately after drip");

        // t1+18h: Bob exits fully; his claim likely exceeds his principal share,
        //     so _debitRecognized must pull the overflow out of vestingAmount while
        //     leaving lastDistributionTimestamp untouched
        vm.warp(t1 + 18 hours);
        uint256 distTimestampBeforeBob = strategy.lastDistributionTimestamp();
        uint256 unvestedBeforeBob = strategy.getUnvestedAmount();

        vm.startPrank(bob);
        uint256 bobShares = jrtVault.balanceOf(bob);
        jrtVault.redeem(address(usdc), bobShares - MIN_SHARES, bob, bob);
        vm.stopPrank();

        assertEq(
            strategy.lastDistributionTimestamp(),
            distTimestampBeforeBob,
            "large withdraw preserves timestamp"
        );
        // If vestingAmount was reduced, unvested scales proportionally — it must never
        // exceed its pre-withdraw value on the same schedule.
        assertLe(strategy.getUnvestedAmount(), unvestedBeforeBob, "unvested does not grow");

        // t1+24h: cycle 2 fully vests; no underflow anywhere
        vm.warp(t1 + 24 hours);
        assertEq(strategy.getUnvestedAmount(), 0, "cycle2 fully vested");

        // Alice redeems a portion of her remaining shares — must not revert.
        // (A full dust-exit here would push JRT totalSupply under the tranche's
        //  MIN_SHARES since Bob is already dusted out.)
        vm.startPrank(alice);
        uint256 aliceRemaining = jrtVault.balanceOf(alice);
        jrtVault.redeem(address(usdc), aliceRemaining / 2, alice, alice);
        vm.stopPrank();

        assertGt(strategy.totalAssets(), 0, "strategy still solvent after interleaved activity");
    }

    /*//////////////////////////////////////////////////////////////
                            REDUCE RESERVE
    //////////////////////////////////////////////////////////////*/

    function test_ReduceReserve_SendsUSDCDirectly() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        uint256 reserveAmount = 100e6;
        uint256 tvlBefore = strategy.totalAssets();
        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        // Only the CDO may call reduceReserve
        vm.prank(address(cdo));
        strategy.reduceReserve(address(usdc), reserveAmount, bob);

        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, reserveAmount, "Bob received USDC directly");
        assertApproxEqAbs(strategy.totalAssets(), tvlBefore - reserveAmount, 1, "TVL reduced");
        assertEq(strategy.lastReportedAssets(), DEPOSIT_AMOUNT - reserveAmount);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetCooldowns() public {
        vm.prank(owner);
        strategy.setCooldowns(3 days, 1 days);

        assertEq(strategy.usdcCooldownJrt(), 3 days);
        assertEq(strategy.usdcCooldownSrt(), 1 days);
    }

    function test_SetCooldowns_RevertIfExceedsWeek() public {
        vm.prank(owner);
        vm.expectRevert();
        strategy.setCooldowns(8 days, 0);
    }

    function test_SetCooldowns_BothZeroDisablesCooldown() public {
        vm.prank(owner);
        strategy.setCooldowns(0, 0);

        assertEq(strategy.usdcCooldownJrt(), 0);
        assertEq(strategy.usdcCooldownSrt(), 0);
        assertTrue(
            erc20Cooldown.cooldownDisabled(address(usdc)), "Cooldown flag set when both zero"
        );
    }

    function test_EnsureRedeemable_Passes() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        // Strategy owns spVault shares worth DEPOSIT_AMOUNT — should not revert
        strategy.ensureRedeemable(address(strategy), address(usdc), DEPOSIT_AMOUNT);
    }

    function test_EnsureRedeemable_RevertsWhenExceeds() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        vm.expectRevert("MetaVaultExceededMaxWithdraw");
        strategy.ensureRedeemable(address(strategy), address(usdc), DEPOSIT_AMOUNT * 1000);
    }

    /*//////////////////////////////////////////////////////////////
                             REVERT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Revert_UnsupportedTokenOnDeposit() public {
        MockERC20 other = new MockERC20("OTHER", 6);
        other.mint(alice, DEPOSIT_AMOUNT);

        vm.startPrank(address(cdo));
        vm.expectRevert();
        strategy.deposit(address(jrtVault), address(other), DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    function test_GetSupportedTokens() public view {
        IERC20[] memory tokens = strategy.getSupportedTokens();
        assertEq(tokens.length, 1);
        assertEq(address(tokens[0]), address(usdc));
    }

    function test_VestingPeriodConstant() public view {
        assertEq(strategy.vestingPeriod(), 24 hours);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _depositToJrt(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(jrtVault), amount);
        jrtVault.deposit(address(usdc), amount, user);
        vm.stopPrank();
    }

    function _depositToSrt(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(srtVault), amount);
        srtVault.deposit(address(usdc), amount, user);
        vm.stopPrank();
    }
}
