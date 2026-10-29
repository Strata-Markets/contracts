// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NeutrlDeploy} from "./NeutrlDeploy.t.sol";
import {IsNUSD} from "../../contracts/tranches/strategies/neutrl/IsNUSD.sol";
import {ICooldown} from "../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import {ISharesCooldown} from "../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import {SharesCooldown} from "../../contracts/tranches/base/cooldown/SharesCooldown.sol";
import {CooldownBase} from "../../contracts/tranches/base/cooldown/CooldownBase.sol";
import {IStrataCDO} from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import {ITranche} from "../../contracts/tranches/interfaces/ITranche.sol";
import {ISharesCooldown} from "../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";

/**
 * @title SIP2Test - Shares Cooldown Exit Mode Tests
 * @notice Tests for the SharesLock exit mode as specified in SIP-01 and SIP-02
 */
contract SIP2Test is NeutrlDeploy {
    // Test users
    address public alice;
    address public bob;

    // SharesCooldown contract
    SharesCooldown public sharesCooldown;

    // Test amounts
    uint256 constant INITIAL_BALANCE = 10000 ether;
    uint256 constant DEPOSIT_AMOUNT = 1000 ether;
    uint256 constant MIN_SHARES = 1 ether;

    // Coverage thresholds (in ppm, 1e6 = 100%)
    uint32 constant COVERAGE_THRESHOLD_P0 = 0.5e6; // 50%
    uint32 constant COVERAGE_THRESHOLD_P1 = 1.0e6; // 100%

    // Cooldown periods (in seconds)
    uint32 constant COOLDOWN_7_DAYS = 7 days;
    uint32 constant COOLDOWN_3_DAYS = 3 days;
    uint32 constant COOLDOWN_0 = 0;

    // Fee rates (in ppm, 1e6 = 100%)
    uint32 constant FEE_2_PERCENT = 0.02e6; // 2%
    uint32 constant FEE_1_PERCENT = 0.01e6; // 1%
    uint32 constant FEE_0 = 0;

    function setUp() public override {
        super.setUp();

        // Create test users
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy the Strata stack
        _deployStrataStack();

        // Configure the cooldown deployed before the CDO.
        _configureSharesCooldown();

        // Mint NUSD to test users
        _mintNUSD(alice, INITIAL_BALANCE);
        _mintNUSD(bob, INITIAL_BALANCE);

        // Disable sNUSD protocol cooldown
        _disableSNUSDCooldown();
    }

    /*//////////////////////////////////////////////////////////////
                         SHARES COOLDOWN TESTS
    //////////////////////////////////////////////////////////////*/
    function test_SharesCooldownIsConfigured() public view {
        assertEq(address(cdo.sharesCooldown()), address(sharesCooldown), "SharesCooldown should be configured");
    }

    function test_ExitParams_LowCoverage_HighFeeAndLongCooldown() public {
        // Setup low coverage: JRT < SRT (coverage < 50%)
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT * 3); // 33% coverage

        uint32 coverage = cdo.coverage(); // cov = 333333
        assertLt(coverage, COVERAGE_THRESHOLD_P0, "Coverage should be below P0");

        // Check exit params - should use r0 (highest fee, longest cooldown)
        (IStrataCDO.TExitMode mode, uint256 exitFee, uint32 cooldownSeconds) =
            cdo.calculateExitMode(address(jrtVault), alice);

        assertEq(uint256(mode), uint256(IStrataCDO.TExitMode.SharesLock), "Should be SharesLock mode");
        assertEq(exitFee, uint256(FEE_2_PERCENT) * 1e18 / 1e6, "Should have 2% fee");
        assertEq(cooldownSeconds, COOLDOWN_7_DAYS, "Should have 7 day cooldown");
    }

    function test_LowCoverage_FullDepositToWithdrawFlow() public {
        // 1. Initial State for Alice
        uint256 aliceInitialNUSD = IERC20(NUSD).balanceOf(alice);
        uint256 aliceInitialSNUSD = IERC20(sNUSD).balanceOf(alice);
        uint256 aliceInitialJrtShares = jrtVault.balanceOf(alice);

        assertEq(aliceInitialNUSD, INITIAL_BALANCE, "Alice should start with INITIAL_BALANCE NUSD");
        assertEq(aliceInitialSNUSD, 0, "Alice should start with 0 sNUSD");
        assertEq(aliceInitialJrtShares, 0, "Alice should start with 0 JRT shares");

        // 2. Deposit to JRT and SRT to create low coverage scenario
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT * 3); // Creates 33% coverage

        uint256 aliceJrtSharesAfterDeposit = jrtVault.balanceOf(alice);
        uint256 aliceNUSDAfterDeposit = IERC20(NUSD).balanceOf(alice);

        assertEq(aliceJrtSharesAfterDeposit, DEPOSIT_AMOUNT, "Alice should have 1000 JRT shares after deposit");
        assertEq(
            aliceNUSDAfterDeposit,
            INITIAL_BALANCE - DEPOSIT_AMOUNT - (DEPOSIT_AMOUNT * 3),
            "Alice NUSD should decrease by total deposits"
        );

        // Verify coverage is low (below 50%)
        uint32 coverage = cdo.coverage();
        assertLt(coverage, COVERAGE_THRESHOLD_P0, "Coverage should be below P0 (50%)");

        // 3. Check exit parameters for low coverage scenario
        (IStrataCDO.TExitMode mode, uint256 exitFee, uint32 cooldownSeconds) =
            cdo.calculateExitMode(address(jrtVault), alice);

        assertEq(uint256(mode), uint256(IStrataCDO.TExitMode.SharesLock), "Should be SharesLock mode");
        assertEq(exitFee, uint256(FEE_2_PERCENT) * 1e18 / 1e6, "Should have 2% exit fee (2%)");
        assertEq(cooldownSeconds, COOLDOWN_7_DAYS, "Should have 7 day cooldown");

        // 4. Assert that the assets are in the strategy
        uint256 strategyBalance = IERC20(sNUSD).balanceOf(address(strategy));
        assertEq(strategyBalance, DEPOSIT_AMOUNT * 4, "Strategy should have DEPOSIT_AMOUNT * 4 sNUSD");

        // 5. Request redemption (lock shares in cooldown)
        // Use maxRedeem to get the actual redeemable amount
        uint256 maxRedeemable = jrtVault.maxRedeem(alice);

        uint256 redeemShares = maxRedeemable; // Redeem maximum allowed
        assertGt(redeemShares, 0, "Should have shares to redeem");

        uint256 expectedFeeShares = (redeemShares * exitFee) / 1e18;
        uint256 expectedNetShares = redeemShares - expectedFeeShares;

        // Record state before redeem
        uint256 cooldownJrtSharesBefore = jrtVault.balanceOf(address(sharesCooldown));
        uint256 jrtTotalSupplyBefore = jrtVault.totalSupply();
        uint256 aliceSharesBeforeRedeem = jrtVault.balanceOf(alice);

        vm.prank(alice);
        jrtVault.redeem(sNUSD, redeemShares, alice, alice);

        // 6. Verify state after redemption request
        uint256 aliceJrtSharesAfterRedeem = jrtVault.balanceOf(alice);
        uint256 cooldownJrtSharesAfter = jrtVault.balanceOf(address(sharesCooldown));
        uint256 jrtTotalSupplyAfter = jrtVault.totalSupply();

        // Alice should have her shares reduced by redeemShares
        assertEq(
            aliceJrtSharesAfterRedeem,
            aliceSharesBeforeRedeem - redeemShares,
            "Alice shares should decrease by redeemed amount"
        );

        // Shares (net of fee) should be in cooldown contract
        assertEq(
            cooldownJrtSharesAfter - cooldownJrtSharesBefore,
            expectedNetShares,
            "Cooldown contract should hold net shares"
        );

        // Total supply should decrease by fee shares (burned)
        assertEq(
            jrtTotalSupplyBefore - jrtTotalSupplyAfter,
            expectedFeeShares,
            "Total supply should decrease by fee shares burned"
        );

        // Verify request is recorded in SharesCooldown
        ICooldown.TBalanceState memory state = sharesCooldown.balanceOf(IERC20(address(jrtVault)), alice);
        assertEq(state.totalRequests, 1, "Should have 1 active request");
        assertEq(state.pending, expectedNetShares, "Pending should equal net shares");
        assertEq(state.claimable, 0, "Nothing claimable before cooldown");
        assertGt(state.nextUnlockAt, block.timestamp, "Unlock time should be in the future");

        // Alice should NOT have received sNUSD yet
        uint256 aliceSNUSDAfterRedeem = IERC20(sNUSD).balanceOf(alice);
        assertEq(aliceSNUSDAfterRedeem, 0, "Alice should not have sNUSD during cooldown");

        // Wait for cooldown to complete
        vm.warp(block.timestamp + cooldownSeconds);

        // Verify request is now claimable
        ICooldown.TBalanceState memory stateAfterWarp = sharesCooldown.balanceOf(IERC20(address(jrtVault)), alice);
        assertEq(stateAfterWarp.claimable, expectedNetShares, "Shares should be claimable after cooldown");
        assertEq(stateAfterWarp.pending, 0, "No pending shares after cooldown");

        // 7. Finalize redemption and receive underlying assets
        uint256 aliceSNUSDBefore = IERC20(sNUSD).balanceOf(alice);

        uint256 claimedShares = sharesCooldown.finalize(jrtVault, sNUSD, alice);

        uint256 aliceSNUSDAfter = IERC20(sNUSD).balanceOf(alice);

        // Verify claimed amount
        assertEq(claimedShares, expectedNetShares, "Claimed shares should equal net shares");

        uint256 cooldownShares = jrtVault.balanceOf(address(sharesCooldown));
        assertEq(cooldownShares, 0, "Cooldown contract should have no shares");

        // Verify Alice received sNUSD tokens
        uint256 sNUSDReceived = aliceSNUSDAfter - aliceSNUSDBefore;
        assertGt(sNUSDReceived, 0, "Alice should have received sNUSD");

        // sNUSD received should be proportional to shares redeemed
        // (accounting for vault share price, which may have appreciation)
        uint256 expectedMinSNUSD = jrtVault.convertToAssets(expectedNetShares);
        assertEq(expectedMinSNUSD, sNUSDReceived, "Expected min sNUSD should equal sNUSD received");

        // 8: Verify final state - no pending requests
        ICooldown.TBalanceState memory finalState = sharesCooldown.balanceOf(IERC20(address(jrtVault)), alice);
        assertEq(finalState.totalRequests, 0, "Should have no requests after finalization");
        assertEq(finalState.pending, 0, "Should have no pending shares");
        assertEq(finalState.claimable, 0, "Should have no claimable shares");

        // Alice should still have remaining shares (original - redeemed)
        uint256 expectedRemainingShares = aliceSharesBeforeRedeem - redeemShares;
        assertEq(jrtVault.balanceOf(alice), expectedRemainingShares, "Alice should have remaining shares");
    }

    function test_ExitParams_MediumCoverage_MediumFeeAndCooldown() public {
        // Setup medium coverage: 50% <= coverage < 100%
        _depositToJrt(alice, DEPOSIT_AMOUNT * 3);
        _depositToSrt(alice, DEPOSIT_AMOUNT * 4); // 75% coverage

        uint32 coverage = cdo.coverage();
        assertGe(coverage, COVERAGE_THRESHOLD_P0, "Coverage should be >= P0");
        assertLt(coverage, COVERAGE_THRESHOLD_P1, "Coverage should be < P1");

        // Check exit params - should use r1 (medium fee, medium cooldown)
        (IStrataCDO.TExitMode mode, uint256 exitFee, uint32 cooldownSeconds) =
            cdo.calculateExitMode(address(jrtVault), alice);

        assertEq(uint256(mode), uint256(IStrataCDO.TExitMode.SharesLock), "Should be SharesLock mode");
        assertEq(exitFee, uint256(FEE_1_PERCENT) * 1e18 / 1e6, "Should have 1% fee");
        assertEq(cooldownSeconds, COOLDOWN_3_DAYS, "Should have 3 day cooldown");
    }

    function test_ExitParams_HighCoverage_NoFeeNoCooldown() public {
        // Setup high coverage: JRT >= SRT (coverage >= 100%)
        _depositToJrt(alice, DEPOSIT_AMOUNT * 2);
        _depositToSrt(alice, DEPOSIT_AMOUNT); // 200% coverage

        uint32 coverage = cdo.coverage();
        assertGe(coverage, COVERAGE_THRESHOLD_P1, "Coverage should be >= P1");

        // Check exit params - should use r2 (no fee, no cooldown)
        (IStrataCDO.TExitMode mode, uint256 exitFee, uint32 cooldownSeconds) =
            cdo.calculateExitMode(address(jrtVault), alice);

        // When cooldown is 0, the mode should be Fee (since no shares lock is needed)
        assertEq(uint256(mode), uint256(IStrataCDO.TExitMode.Fee), "Should be Fee mode when no cooldown");
        assertEq(exitFee, 0, "Should have 0% fee");
        assertEq(cooldownSeconds, 0, "Should have 0 cooldown");
    }

    /*//////////////////////////////////////////////////////////////
                         CANCEL REQUEST TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CancelRequest_ReturnsShares() public {
        // 1. Setup medium coverage scenario: 50% <= coverage < 100%
        _depositToJrt(alice, DEPOSIT_AMOUNT * 3);
        _depositToSrt(alice, DEPOSIT_AMOUNT * 4); // 75% coverage

        uint32 coverage = cdo.coverage();
        assertGe(coverage, COVERAGE_THRESHOLD_P0, "Coverage should be >= P0 (50%)");
        assertLt(coverage, COVERAGE_THRESHOLD_P1, "Coverage should be < P1 (100%)");

        // 2. Verify exit mode is SharesLock with 1% fee and 3-day cooldown
        (IStrataCDO.TExitMode mode, uint256 exitFee, uint32 cooldownSeconds) =
            cdo.calculateExitMode(address(jrtVault), alice);

        assertEq(uint256(mode), uint256(IStrataCDO.TExitMode.SharesLock), "Should be SharesLock mode");
        assertEq(exitFee, uint256(FEE_1_PERCENT) * 1e18 / 1e6, "Should have 1% fee");
        assertEq(cooldownSeconds, COOLDOWN_3_DAYS, "Should have 3 day cooldown");

        // 3. Record balances before redemption request
        uint256 aliceSharesBefore = jrtVault.balanceOf(alice);
        uint256 aliceSNUSDBefore = IERC20(sNUSD).balanceOf(alice);
        uint256 cooldownSharesBefore = jrtVault.balanceOf(address(sharesCooldown));

        // Use maxRedeem to get actual redeemable amount
        uint256 maxRedeemable = jrtVault.maxRedeem(alice);
        uint256 redeemShares = maxRedeemable;
        assertGt(redeemShares, 0, "Should have shares to redeem");

        // Calculate expected fee and net shares
        uint256 expectedFeeShares = (redeemShares * exitFee) / 1e18;
        uint256 expectedNetShares = redeemShares - expectedFeeShares;

        // 4. Request redemption - shares get locked in SharesCooldown
        vm.prank(alice);
        jrtVault.redeem(sNUSD, redeemShares, alice, alice);

        // 5. Verify shares are locked in SharesCooldown contract
        uint256 aliceSharesAfterRedeem = jrtVault.balanceOf(alice);
        uint256 cooldownSharesAfterRedeem = jrtVault.balanceOf(address(sharesCooldown));

        assertEq(
            aliceSharesAfterRedeem, aliceSharesBefore - redeemShares, "Alice shares should decrease by redeemed amount"
        );
        assertEq(
            cooldownSharesAfterRedeem - cooldownSharesBefore,
            expectedNetShares,
            "Cooldown contract should hold net shares (after fee burned)"
        );

        // Verify request exists in SharesCooldown
        ICooldown.TBalanceState memory stateBeforeCancel = sharesCooldown.balanceOf(IERC20(address(jrtVault)), alice);
        assertEq(stateBeforeCancel.totalRequests, 1, "Should have 1 active request");
        assertEq(stateBeforeCancel.pending, expectedNetShares, "Pending should equal net shares");
        assertEq(stateBeforeCancel.claimable, 0, "Nothing claimable yet (still in cooldown)");

        // Verify Alice has NOT received any sNUSD (assets are not released during cooldown)
        uint256 aliceSNUSDAfterRedeem = IERC20(sNUSD).balanceOf(alice);
        assertEq(aliceSNUSDAfterRedeem, aliceSNUSDBefore, "Alice should not have received sNUSD");

        // 6. Cancel the redemption request
        vm.prank(alice);
        sharesCooldown.cancel(IERC20(address(jrtVault)), alice, 0, ISharesCooldown.TCancelGuard({shares: 0}));

        // 7. Verify Alice receives back SHARES
        uint256 aliceSharesAfterCancel = jrtVault.balanceOf(alice);
        uint256 aliceSNUSDAfterCancel = IERC20(sNUSD).balanceOf(alice);
        uint256 cooldownSharesAfterCancel = jrtVault.balanceOf(address(sharesCooldown));

        // Alice should get back the net shares (fee was already burned at request time)
        assertEq(
            aliceSharesAfterCancel, aliceSharesAfterRedeem + expectedNetShares, "Alice should receive back net shares"
        );

        // Alice should NOT have received any sNUSD (cancel returns shares, not assets)
        assertEq(aliceSNUSDAfterCancel, aliceSNUSDBefore, "Alice should NOT receive sNUSD - cancel returns shares only");

        // Cooldown contract should no longer hold any shares
        assertEq(cooldownSharesAfterCancel, cooldownSharesBefore, "Cooldown contract should have released all shares");

        // 8. Verify request is fully canceled
        ICooldown.TBalanceState memory stateAfterCancel = sharesCooldown.balanceOf(IERC20(address(jrtVault)), alice);
        assertEq(stateAfterCancel.totalRequests, 0, "Should have no requests after cancel");
        assertEq(stateAfterCancel.pending, 0, "Should have no pending shares");
        assertEq(stateAfterCancel.claimable, 0, "Should have no claimable shares");
    }

    function test_CancelRequest_OnlyOwnerCanCancel() public {
        // Setup: Alice deposits and requests redeem
        _depositToJrt(alice, DEPOSIT_AMOUNT * 3);
        _depositToSrt(alice, DEPOSIT_AMOUNT * 4); // 75% coverage

        uint256 redeemShares = jrtVault.maxRedeem(alice);

        vm.prank(alice);
        jrtVault.redeem(sNUSD, redeemShares, alice, alice);

        // Bob tries to cancel Alice's request
        vm.prank(bob);
        vm.expectRevert("OnlySharesOwner");
        sharesCooldown.cancel(IERC20(address(jrtVault)), alice, 0, ISharesCooldown.TCancelGuard({shares: 0}));
    }

    /*//////////////////////////////////////////////////////////////
                      EARLY EXIT WITH FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_EarlyExitWithFee() public {
        // Setup early exit fee
        vm.prank(owner);
        sharesCooldown.setVaultEarlyExitFee(address(jrtVault), 0.01e18); // 1% per day

        // Setup: Alice deposits and requests redeem
        _depositToJrt(alice, DEPOSIT_AMOUNT * 3);
        _depositToSrt(alice, DEPOSIT_AMOUNT * 4); // 75% coverage

        // uint256 shares = jrtVault.balanceOf(alice);
        uint256 redeemShares = jrtVault.maxRedeem(alice);

        vm.startPrank(alice);

        // Request redeem
        jrtVault.redeem(sNUSD, redeemShares, alice, alice);

        // Get pending amount
        ICooldown.TBalanceState memory state = sharesCooldown.balanceOf(IERC20(address(jrtVault)), alice);
        uint256 pendingShares = state.pending;
        assertGt(pendingShares, 0, "Should have pending shares");

        // Early exit (before cooldown ends)
        uint256 nusdBefore = IERC20(NUSD).balanceOf(alice);

        // finalizeWithFee returns the number of shares claimed (after early exit fee deducted)
        uint256 claimedShares = sharesCooldown.finalizeWithFee(jrtVault, NUSD, alice, 0, ISharesCooldown.TFinalizeWithFeeGuard({shares: uint192(pendingShares), daysLeft: 0}), "");

        uint256 nusdAfter = IERC20(NUSD).balanceOf(alice);
        assertEq(nusdAfter, nusdBefore + claimedShares, "Should receive NUSD tokens");

        vm.stopPrank();

        // Verify shares claimed (with early exit fee deducted from pending)
        assertGt(claimedShares, 0, "Should claim some shares");
        assertLt(claimedShares, pendingShares, "Should receive less than pending due to early exit fee");
        console2.log("claimedShares", claimedShares);
        console2.log("pendingShares", pendingShares);

        // Verify NUSD received (finalizeWithFee redeems to base asset NUSD)
        uint256 nusdReceived = nusdAfter - nusdBefore;
        assertGt(nusdReceived, 0, "Should receive NUSD tokens");

        // Verify request is cleared
        ICooldown.TBalanceState memory stateAfter = sharesCooldown.balanceOf(IERC20(address(jrtVault)), alice);
        assertEq(stateAfter.totalRequests, 0, "Should have no requests after early exit");
    }

    function test_EarlyExitRevertAfterCooldown() public {
        // Setup early exit fee
        vm.prank(owner);
        sharesCooldown.setVaultEarlyExitFee(address(jrtVault), 0.01e18); // 1% per day

        // Setup: Alice deposits and requests redeem
        _depositToJrt(alice, DEPOSIT_AMOUNT * 3);
        _depositToSrt(alice, DEPOSIT_AMOUNT * 4); // 75% coverage

        // Get cooldown period
        (,, uint32 cooldownSeconds) = cdo.calculateExitMode(address(jrtVault), alice);

        uint256 redeemShares = jrtVault.maxRedeem(alice);

        vm.prank(alice);
        jrtVault.redeem(sNUSD, redeemShares, alice, alice);

        // Wait for cooldown to complete
        vm.warp(block.timestamp + cooldownSeconds);

        // Try to call finalizeWithFee after cooldown - should revert
        vm.prank(alice);
        vm.expectRevert("RequestReady");
        sharesCooldown.finalizeWithFee(jrtVault, NUSD, alice, 0, ISharesCooldown.TFinalizeWithFeeGuard({shares: 0, daysLeft: 0}), "");
    }

    /*//////////////////////////////////////////////////////////////
                             HELPERS
    //////////////////////////////////////////////////////////////*/

    function _createSharesCooldown() internal override returns (ISharesCooldown) {

        // Deploy SharesCooldown
        SharesCooldown sharesCooldownImpl = new SharesCooldown();
        vm.label(address(sharesCooldownImpl), "SharesCooldown_Impl");

        sharesCooldown = SharesCooldown(
            address(
                new ERC1967Proxy(
                    address(sharesCooldownImpl),
                    abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
                )
            )
        );
        vm.label(address(sharesCooldown), "SharesCooldown");

        return sharesCooldown;
    }

    function _configureSharesCooldown() internal {
        vm.startPrank(owner);

        // Grant COOLDOWN_WORKER_ROLE to CDO
        bytes32 cooldownWorkerRole = sharesCooldown.COOLDOWN_WORKER_ROLE();
        acm.grantRole(cooldownWorkerRole, address(cdo));

        // Set TwoStepConfigManager for sharesCooldown
        sharesCooldown.setTwoStepConfigManager(owner);

        // Configure exit bounds for JRT vault
        // Coverage < 50%: 2% fee, 7 days cooldown
        // 50% <= Coverage < 100%: 1% fee, 3 days cooldown
        // Coverage >= 100%: 0% fee, 0 cooldown
        ISharesCooldown.TExitUpperBounds memory jrtBounds = ISharesCooldown.TExitUpperBounds({
            p0: COVERAGE_THRESHOLD_P0, // 50%
            p1: COVERAGE_THRESHOLD_P1, // 100%
            r0: ISharesCooldown.TExitParams({feePpm: FEE_2_PERCENT, sharesLock: COOLDOWN_7_DAYS}),
            r1: ISharesCooldown.TExitParams({feePpm: FEE_1_PERCENT, sharesLock: COOLDOWN_3_DAYS}),
            r2: ISharesCooldown.TExitParams({feePpm: FEE_0, sharesLock: COOLDOWN_0})
        });

        sharesCooldown.setVaultExitBounds(address(jrtVault), jrtBounds);

        vm.stopPrank();
    }

    function _mintNUSD(address to, uint256 amount) internal {
        deal(NUSD, to, amount);
    }

    function _depositToJrt(address user, uint256 amount) internal {
        vm.startPrank(user);
        IERC20(NUSD).approve(address(jrtVault), amount);
        jrtVault.deposit(NUSD, amount, user);
        vm.stopPrank();
    }

    function _depositToSrt(address user, uint256 amount) internal {
        vm.startPrank(user);
        IERC20(NUSD).approve(address(srtVault), amount);
        srtVault.deposit(NUSD, amount, user);
        vm.stopPrank();
    }

    function _disableSNUSDCooldown() internal {
        address admin = _getSNUSDAdmin();
        vm.startPrank(admin);
        (bool success,) = sNUSD.call(abi.encodeWithSignature("setCooldownDuration(uint24)", uint24(0)));
        require(success, "Failed to disable cooldown");
        vm.stopPrank();
    }

    function _getSNUSDAdmin() internal view returns (address) {
        (bool success, bytes memory data) = sNUSD.staticcall(abi.encodeWithSignature("owner()"));
        require(success, "Failed to get sNUSD owner");
        return abi.decode(data, (address));
    }
}
