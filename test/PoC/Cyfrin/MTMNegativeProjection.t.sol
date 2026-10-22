// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { IInsuranceMiddleware } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import { IInsuranceVault } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";
import { MockInsurancePool } from "../../symbiotic/mocks/MockInsurancePool.sol";

/// @dev Auditor PoC fixture, restricted to the mock MTM strategy.
contract NegativeProjectionStack is Test {
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");

    bool conservative = true;
    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    MTMAccounting accounting;
    MockAprPairFeed feed;
    MockERC20 token;
    MockMTMStrategy mtmStrategy;
    MockInsurancePool pool;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address feeSafe = makeAddr("feeSafe");

    struct AccFlags {
        bool benchmark;
        bool mtmProjection;
    }

    function _deployCore(IERC20Metadata asset, uint256 navDecimals, AccFlags memory f) internal {
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(asset)),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche(asset, "JRT");
        srt = _tranche(asset, "SRT");

        feed = new MockAprPairFeed();
        // 8% benchmark target, 10% base APR (SD7x12)
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp));

        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice, mtmProjection
        accounting = MTMAccounting(address(new ERC1967Proxy(
            address(new MTMAccounting(navDecimals, f.benchmark, true, false, false, conservative, f.mtmProjection)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector,
                address(this),
                address(acm),
                IStrataCDO(address(cdo)),
                IAprPairFeed(address(feed))
            )
        )));

        acm.grantRole(PAUSER_ROLE, address(this));
        acm.grantRole(UPDATER_FEED_ROLE, address(this));
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, address(this));
        acm.grantRole(RESERVE_MANAGER_ROLE, address(this));
    }

    function _finishCore(IStrategy strategy_) internal {
        cdo.configure(IAccounting(address(accounting)), strategy_, ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
    }

    function _tranche(IERC20Metadata asset, string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(conservative)),
            abi.encodeWithSelector(
                Tranche.initialize.selector,
                address(this), address(acm), name, name, IERC20(address(asset)), IStrataCDO(address(cdo))
            )
        )));
    }

    /// @dev MockMTMStrategy stack, 18 decimals, epoch = 1 day
    function _deployMTMStack(AccFlags memory f) internal {
        token = new MockERC20("BASE", 18);
        _deployCore(IERC20Metadata(address(token)), 18, f);
        mtmStrategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        mtmStrategy.setEpochDuration(1 days);
        _finishCore(IStrategy(address(mtmStrategy)));
    }

    function _enableInsurance(uint256 capacity, uint256 underwriterFeeBps) internal {
        pool = new MockInsurancePool();
        pool.setCapacity(capacity);
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(0)));
        if (underwriterFeeBps > 0) {
            vm.prank(address(pool));
            cdo.setUnderwriterFeeBps(underwriterFeeBps);
        }
        cdo.setManualUnderwriterFeeDistribution(true);
        cdo.setUnderwriterFeeRewardSafe(feeSafe);
    }

    function _deposit(Tranche t, address user, uint256 amount) internal returns (uint256 shares) {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        shares = t.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Stored identity gap: (jrt + srt + reserve + uwFee) - (nav + insuranceAmount)
    function _identityGap() internal view returns (int256) {
        uint256 lhs = accounting.jrtBaseNav() + accounting.srtBaseNav() + accounting.reserveNav()
            + accounting.underwriterFeeNav();
        uint256 rhs = accounting.nav() + accounting.insuranceAmount();
        return int256(lhs) - int256(rhs);
    }
}


contract MTMNegativeProjectionTest is NegativeProjectionStack {
    function _setUpStack(uint256 junior) internal {
        _deployMTMStack(AccFlags({ benchmark: false, mtmProjection: true }));
        _deposit(jrt, alice, junior);
        _deposit(srt, bob, 1000e18);
        vm.warp(block.timestamp + 1 hours);
    }

    function _projectedLoss() internal view returns (uint256) {
        int256 live = accounting.srtPnLProjected() - int256(accounting.srtPaidProjected());
        return live < 0 ? uint256(-live) : 0;
    }

    function _poke() internal {
        vm.prank(carol);
        jrt.burnSharesAsFee(0, carol);
        assertEq(_identityGap(), 0, "stored NAV conservation");
    }

    function test_JuniorExitWithNegativeSeniorProjection() public {
        _setUpStack(1000e18);
        accounting.setFloorRate(0.01e18);
        mtmStrategy.setTotalAssets(1980e18);
        _poke();
        int256 projection = accounting.srtPnLProjected();
        assertLt(projection, 0, "Senior has a projected loss");
        uint256 expected = jrt.previewRedeem(100e18);
        uint256 juniorBefore = accounting.jrtBaseNav();
        vm.prank(alice);
        uint256 assets = jrt.redeem(100e18, alice, alice);
        assertEq(assets, expected, "exit pays the live quote");
        assertEq(accounting.jrtBaseNav(), juniorBefore - assets, "only payout leaves real Junior NAV");
        assertEq(accounting.srtPnLProjected(), projection, "Junior exit preserves Senior loss");
        assertEq(_identityGap(), 0, "stored NAV conservation");
    }

    // Regression for the auditor's repeated-update and full-recovery PoC.
    function test_RepeatedLossDoesNotRatchetAndRecoveryRestoresSenior() public {
        _setUpStack(1000e18);
        accounting.setFloorRate(0.01e18);
        mtmStrategy.setTotalAssets(1980e18);
        for (uint256 i; i < 4; ++i) {
            _poke();
            assertEq(accounting.srtBaseNav(), 995e18);
            assertEq(_projectedLoss(), 5e18);
            assertEq(cdo.totalAssetsDepositable(address(srt)), 1000e18);
        }
        mtmStrategy.setTotalAssets(2000e18);
        _poke();
        assertEq(accounting.srtBaseNav(), 1000e18);
        assertEq(accounting.jrtBaseNav(), 1000e18);
        assertEq(_projectedLoss(), 0);
        vm.warp(block.timestamp + 2 days);
        uint256 shares = srt.balanceOf(bob) - 1e18;
        vm.prank(bob);
        assertEq(srt.redeem(shares, bob, bob), 999e18);
    }

    // Regression for the auditor's Junior-exhaustion PoC, including settled pricing.
    function test_JuniorExhaustionRecovery() public {
        _setUpStack(100e18);
        mtmStrategy.setTotalAssets(950e18);
        _poke();
        assertEq(accounting.srtBaseNav(), 949e18);
        assertEq(_projectedLoss(), 51e18);
        assertEq(cdo.totalAssetsDepositable(address(srt)), 1000e18);
        mtmStrategy.setTotalAssets(1100e18);
        _poke();
        assertEq(accounting.srtBaseNav(), 1000e18);
        assertEq(accounting.jrtBaseNav(), 100e18);
        assertEq(_projectedLoss(), 0);
    }

    function test_PositiveReconciliationMatchesEpochWithoutDip() public {
        _setUpStack(1000e18);
        accounting.setFloorRate(0.01e18);
        uint256 snapshot = vm.snapshotState();
        vm.warp(block.timestamp + 2 days);
        mtmStrategy.setTotalAssets(2010e18);
        _poke();
        uint256 senior = accounting.srtBaseNav();
        uint256 junior = accounting.jrtBaseNav();
        assertGt(senior, 1000e18);
        assertGt(junior, 1000e18);
        vm.revertToState(snapshot);
        mtmStrategy.setTotalAssets(1980e18);
        _poke();
        vm.warp(block.timestamp + 6 hours);
        _poke();
        vm.warp(block.timestamp + 42 hours);
        mtmStrategy.setTotalAssets(2010e18);
        _poke();
        assertEq(accounting.srtBaseNav(), senior);
        assertEq(accounting.jrtBaseNav(), junior);
        assertEq(_projectedLoss(), 0);
    }

    function test_GainAndLossTransitions() public {
        _setUpStack(1000e18);
        accounting.setFloorRate(0.01e18);
        mtmStrategy.setTotalAssets(2020e18);
        _poke();
        assertGt(accounting.srtPnLProjected(), 0);
        mtmStrategy.setTotalAssets(1980e18);
        _poke();
        assertEq(accounting.srtPnLProjected(), -5e18);
        assertEq(_projectedLoss(), 5e18);
        mtmStrategy.setTotalAssets(2020e18);
        _poke();
        assertEq(_projectedLoss(), 0);
        assertGt(accounting.srtPnLProjected(), 0);
        mtmStrategy.setTotalAssets(2000e18);
        _poke();
        assertEq(accounting.srtBaseNav(), 1000e18);
    }

    function test_DepositDuringDipUsesSettledPrice() public {
        _setUpStack(1000e18);
        accounting.setFloorRate(0.01e18);
        mtmStrategy.setTotalAssets(1980e18);
        _poke();
        assertEq(_deposit(srt, carol, 100e18), 100e18);
        assertEq(_projectedLoss(), 5e18);
        mtmStrategy.setTotalAssets(2100e18);
        _poke();
        assertEq(accounting.srtBaseNav(), 1100e18);
        assertEq(_projectedLoss(), 0);
    }

    function test_ExitForfeitsOnlyExitingLossShare() public {
        _setUpStack(100e18);
        mtmStrategy.setTotalAssets(950e18);
        _poke();
        vm.prank(bob);
        uint256 out = srt.redeem(500e18, bob, bob);
        assertEq(out, 474.5e18);
        assertEq(_projectedLoss(), 25.5e18);
        mtmStrategy.setTotalAssets(1100e18 - out);
        _poke();
        assertApproxEqAbs(accounting.srtBaseNav(), 500e18, 2);
        assertEq(accounting.jrtBaseNav(), 125.5e18);
        assertEq(_projectedLoss(), 0);
    }

    function test_RealizedLossClearsTracker() public {
        _setUpStack(100e18);
        mtmStrategy.setTotalAssets(950e18);
        _poke();
        vm.warp(block.timestamp + 2 days);
        _poke();
        assertEq(accounting.srtBaseNav(), 949e18);
        assertEq(accounting.jrtBaseNav(), 1e18);
        assertEq(_projectedLoss(), 0);
    }

    function test_LivePricingPaidProjectionThenLossAndRecovery() public {
        conservative = false;
        _setUpStack(1000e18);
        accounting.setFloorRate(0.01e18);
        mtmStrategy.setTotalAssets(2020e18);
        _poke();
        vm.prank(bob);
        uint256 out = srt.redeem(100e18, bob, bob);
        assertGt(accounting.srtPaidProjected(), 0);
        uint256 snapshot = vm.snapshotState();
        mtmStrategy.setTotalAssets(2000e18 - out);
        _poke();
        uint256 expected = accounting.srtBaseNav();
        vm.revertToState(snapshot);
        mtmStrategy.setTotalAssets(1980e18 - out);
        _poke();
        assertGt(_projectedLoss(), 0);
        mtmStrategy.setTotalAssets(2000e18 - out);
        _poke();
        assertEq(accounting.srtBaseNav(), expected);
    }

    function test_ValuationLossTemporaryDipRecovers() public {
        _setUpStack(1000e18);
        accounting.setFloorRate(0.01e18);
        cdo.setValuationKeeper(address(this));
        cdo.setValuationPrice(0.5e18);
        uint256 senior = accounting.srtBaseNav();
        mtmStrategy.setTotalAssets(1980e18);
        _poke();
        assertGt(_projectedLoss(), 0);
        mtmStrategy.setTotalAssets(2000e18);
        _poke();
        assertEq(_projectedLoss(), 0);
        assertEq(accounting.srtBaseNav(), senior);
    }

    function test_ReconciliationThenNewerMarkResetsOldLoss() public {
        _setUpStack(1000e18);
        accounting.setFloorRate(0.01e18);
        mtmStrategy.setTotalAssets(1980e18);
        _poke();
        vm.warp(block.timestamp + 2 days);
        uint256 settledAt = block.timestamp;
        vm.warp(block.timestamp + 1 hours);
        vm.mockCall(
            address(mtmStrategy),
            abi.encodeWithSelector(MockMTMStrategy.totalAssetsSnapshot.selector),
            abi.encode(2010e18, settledAt, 1990e18, block.timestamp)
        );
        (, uint256 seniorLive,, uint256 seniorSettled) = accounting.totalAssetsLiveAndSettled();
        assertGt(seniorSettled, 1000e18);
        assertLt(seniorLive, seniorSettled);
        _poke();
        assertEq(accounting.srtBaseNav(), seniorLive);
        assertEq(_projectedLoss(), seniorSettled - seniorLive);
        vm.clearMockedCalls();
        mtmStrategy.setTotalAssets(2010e18);
        _poke();
        assertEq(accounting.srtBaseNav(), seniorSettled);
        assertEq(_projectedLoss(), 0);
    }

    function test_InsuredValuationLossTemporaryDipRecovers() public {
        _setUpStack(100e18);
        _enableInsurance(10000e18, 0);
        accounting.setFloorRate(0.01e18);
        cdo.setValuationKeeper(address(this));
        cdo.setValuationPrice(0.5e18);
        uint256 senior = accounting.srtBaseNav();
        uint256 claim = accounting.insuranceAmount();
        mtmStrategy.setTotalAssets(1080e18);
        _poke();
        assertGt(_projectedLoss(), 0);
        mtmStrategy.setTotalAssets(1100e18);
        _poke();
        assertEq(_projectedLoss(), 0);
        assertEq(accounting.srtBaseNav(), senior);
        assertEq(accounting.insuranceAmount(), claim);
    }

    function test_ValuationExitScalesLossByEffectiveNav() public {
        _setUpStack(1000e18);
        accounting.setFloorRate(0.01e18);
        accounting.setValuationGracePeriod(0);
        cdo.setValuationKeeper(address(this));
        cdo.setValuationPrice(0.8e18);
        mtmStrategy.setTotalAssets(1980e18);
        _poke();
        uint256 loss = _projectedLoss();
        assertGt(loss, 0);
        vm.prank(bob);
        uint256 out = srt.redeem(500e18, bob, bob);
        assertApproxEqAbs(_projectedLoss(), loss / 2, 1);
        mtmStrategy.setTotalAssets(2000e18 - out);
        _poke();
        assertApproxEqAbs(accounting.srtBaseNav(), 500e18, 2);
        assertEq(_projectedLoss(), 0);
    }

    function _liveLoss() internal {
        conservative = false;
        _setUpStack(1000e18);
        accounting.setFloorRate(0.01e18);
        mtmStrategy.setTotalAssets(1980e18);
        _poke();
    }

    function _roundTripDuringLoss(uint256 amount) internal {
        uint256 shares = _deposit(srt, carol, amount);
        vm.prank(carol);
        uint256 out = srt.redeem(shares, carol, carol);
        assertApproxEqAbs(out, amount, 2);
        assertApproxEqAbs(accounting.srtPnLProjected(), -5e18, 10);
        assertApproxEqAbs(accounting.srtBoughtProjected(), 0, 10);
        mtmStrategy.setTotalAssets(2000e18 + amount - out);
        _poke();
        assertApproxEqAbs(accounting.srtBaseNav(), 1000e18, 10);
        assertApproxEqAbs(accounting.jrtBaseNav(), 1000e18, 10);
    }

    function test_LiveDepositExitDuringLossIsNeutral() public {
        _liveLoss();
        _roundTripDuringLoss(995e18);
    }

    function testFuzz_LiveLossRoundTrip(uint96 amountIn) public {
        _liveLoss();
        uint256 maximum = accounting.maxDeposit(false);
        uint256 amount = bound(uint256(amountIn), 1e15, maximum < 9950e18 ? maximum : 9950e18);
        _roundTripDuringLoss(amount);
    }

    function test_LossPurchaseSurvivesRecoveryBeforeExit() public {
        _liveLoss();
        uint256 shares = _deposit(srt, carol, 995e18);
        assertApproxEqAbs(accounting.srtBoughtProjected(), -5e18, 1);
        mtmStrategy.setTotalAssets(2995e18);
        _poke();
        assertEq(accounting.srtPnLProjected(), 0);
        vm.prank(carol);
        uint256 out = srt.redeem(shares, carol, carol);
        assertApproxEqAbs(out, 997.5e18, 2);
        assertEq(accounting.srtPnLProjected(), 0);
        assertEq(accounting.srtPaidProjected(), 0);
        // Only purchased loss is consumed; recovery must not create a new live gain.
        assertApproxEqAbs(accounting.srtBoughtProjected(), -2.5e18, 2);
        _poke();
        assertEq(accounting.srtPnLProjected(), 0);
    }

    function test_SignedPurchasesPreserveSplitDepositsAndExits() public {
        _liveLoss();
        uint256 snapshot = vm.snapshotState();
        _deposit(srt, carol, 995e18);
        int256 bought = accounting.srtBoughtProjected();
        vm.revertToState(snapshot);
        _deposit(srt, carol, 199e18);
        _deposit(srt, carol, 796e18);
        assertApproxEqAbs(accounting.srtBoughtProjected(), bought, 2);
        // The live projection changes sign while the purchased loss remains outstanding.
        mtmStrategy.setTotalAssets(3035e18);
        _poke();
        assertGt(accounting.srtPnLProjected(), 0);
        snapshot = vm.snapshotState();
        uint256 shares = srt.balanceOf(carol);
        vm.prank(carol);
        srt.redeem(shares, carol, carol);
        int256 projection = accounting.srtPnLProjected();
        bought = accounting.srtBoughtProjected();
        uint256 paid = accounting.srtPaidProjected();
        vm.revertToState(snapshot);
        vm.prank(carol);
        srt.redeem(shares / 2, carol, carol);
        vm.prank(carol);
        srt.redeem(shares - shares / 2, carol, carol);
        assertApproxEqAbs(accounting.srtPnLProjected(), projection, 10);
        assertApproxEqAbs(accounting.srtBoughtProjected(), bought, 10);
        assertApproxEqAbs(accounting.srtPaidProjected(), paid, 10);
    }

    function test_ValuationLossPurchaseRoundTripIsNeutral() public {
        _liveLoss();
        accounting.setValuationGracePeriod(0);
        cdo.setValuationKeeper(address(this));
        cdo.setValuationPrice(0.8e18);
        cdo.setActionStates(address(srt), true, true);
        _poke();
        int256 projection = accounting.srtPnLProjected();
        uint256 shares = _deposit(srt, carol, 100e18);
        vm.prank(carol);
        uint256 out = srt.redeem(shares, carol, carol);
        assertApproxEqAbs(out, 100e18, 3);
        assertApproxEqAbs(accounting.srtPnLProjected(), projection, 10);
        assertApproxEqAbs(accounting.srtBoughtProjected(), 0, 10);
    }

    function test_PositivePurchaseThenLossDoesNotCreatePaidGain() public {
        conservative = false;
        _setUpStack(1000e18);
        accounting.setFloorRate(0.01e18);
        mtmStrategy.setTotalAssets(2020e18);
        _poke();
        uint256 shares = _deposit(srt, carol, 1005e18);
        assertApproxEqAbs(accounting.srtBoughtProjected(), 5e18, 1);
        mtmStrategy.setTotalAssets(2985e18);
        _poke();
        assertApproxEqAbs(accounting.srtPnLProjected(), -5e18, 1);
        // Purchased gain offsets the live loss in the exit's net projection.
        vm.prank(carol);
        srt.redeem(shares, carol, carol);
        assertEq(accounting.srtPaidProjected(), 0);
        assertApproxEqAbs(accounting.srtBoughtProjected(), 5e18, 2);
        assertApproxEqAbs(accounting.srtPnLProjected(), -5e18, 2);
    }

    function test_ReconciliationClearsNegativePurchase() public {
        _liveLoss();
        _deposit(srt, carol, 995e18);
        assertLt(accounting.srtBoughtProjected(), 0);
        vm.warp(block.timestamp + 2 days);
        mtmStrategy.setTotalAssets(3005e18);
        _poke();
        assertEq(accounting.srtBoughtProjected(), 0);
        assertEq(accounting.srtPaidProjected(), 0);
        assertEq(accounting.srtPnLProjected(), 0);
    }
}
