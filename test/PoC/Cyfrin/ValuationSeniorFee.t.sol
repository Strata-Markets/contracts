// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISharesCooldown} from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
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

import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { DiscreteAccounting } from "../../../contracts/tranches/DiscreteAccounting.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";

abstract contract ValuationSeniorFeeBase is Test {
    function _accountingImplementation() internal virtual returns (address);
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");

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

    function _deployCore(IERC20Metadata asset) internal {
        vm.warp(1_790_000_000);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(asset, ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche(asset, "JRT");
        srt = _tranche(asset, "SRT");

        feed = new MockAprPairFeed();
        // 8% benchmark target, 10% base APR (SD7x12)
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp));

        accounting = MTMAccounting(address(new ERC1967Proxy(
            _accountingImplementation(),
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
            address(new Tranche(true)),
            abi.encodeWithSelector(
                Tranche.initialize.selector,
                address(this), address(acm), name, name, IERC20(address(asset)), IStrataCDO(address(cdo))
            )
        )));
    }

    /// @dev MockMTMStrategy stack, 18 decimals, epoch = 1 day
    function _deployMTMStack() internal {
        token = new MockERC20("BASE", 18);
        _deployCore(IERC20Metadata(address(token)));
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

/// @notice Auditor fee-shift and underflow PoCs adapted into regressions for all four variants.
abstract contract ValuationSeniorFeeTests is ValuationSeniorFeeBase {

    uint256 constant JRT_DEP = 1000e18;
    uint256 constant SRT_EACH = 400e18;
    uint256 constant EXIT_FEE = 0.01e18;       // StrataCDO cap
    uint256 constant SRT_RETENTION = 0.5e18;   // live Saturn and NestOpal Senior retention

    function _setUp(uint256 exitFee) internal {
        _deployMTMStack();
        _deposit(jrt, alice, JRT_DEP);
        _deposit(srt, bob, SRT_EACH);
        _deposit(srt, carol, SRT_EACH);

        cdo.setTwoStepConfigManager(address(this));
        cdo.setExitFees(0, exitFee);
        accounting.setFeeRetentionBps(0, SRT_RETENTION);
        cdo.setValuationKeeper(address(this));
    }

    /// @dev Returns (carol Senior value, Junior NAV) after bob's full exit at valuation price `price`
    function _runExit(uint128 price, uint256 exitFee) internal returns (uint256 carolValue, uint256 jrtValue, uint256 fee) {
        _setUp(exitFee);
        cdo.setValuationPrice(price);

        uint256 bobShares = srt.balanceOf(bob);
        uint256 gross = srt.convertToAssets(bobShares);
        vm.prank(bob);
        uint256 net = srt.redeem(bobShares, bob, bob);
        fee = gross - net;

        carolValue = cdo.totalAssets(address(srt)); // carol is the only Senior left
        jrtValue = cdo.totalAssets(address(jrt));
    }

    function test_depegFeePreservesJuniorValue() public {
        // p = 0.8: Senior effective 1000 (800 factual + 200 Junior top-up), Junior effective 800
        (uint256 carolValue, uint256 jrtValue, uint256 fee) = _runExit(0.8e18, EXIT_FEE);
        assertEq(fee, 5e18, "1% of bob's 500 effective");
        // Expected: carol keeps 500 plus the full fee (5), Junior keeps 800
        assertApproxEqAbs(carolValue, 505e18, 5, "Senior retains the whole fee");
        assertApproxEqAbs(jrtValue, 800e18, 5, "Junior effective NAV unchanged");
    }

    function test_deepDepegFeePreservesJuniorValue() public {
        // p = 0.5: Senior factual 800 -> effective 1600, Junior factual 1000 covers the 800 top-up
        (uint256 carolValue, uint256 jrtValue, uint256 fee) = _runExit(0.5e18, EXIT_FEE);
        assertEq(fee, 8e18, "1% of bob's 800 effective");
        // Carol keeps 800 plus 8 retained; Junior receives no unintended transfer.
        assertApproxEqAbs(carolValue, 808e18, 5, "Senior retains the whole fee");
        assertApproxEqAbs(jrtValue, 200e18, 5, "Junior effective NAV unchanged");
    }

    /// @dev Control: same exit without an exit fee leaves both tranches exact
    function test_noFeeControl() public {
        (uint256 carolValue, uint256 jrtValue,) = _runExit(0.8e18, 0);
        assertApproxEqAbs(carolValue, 500e18, 2);
        assertApproxEqAbs(jrtValue, 800e18, 2);
    }

    /// @dev Accepted minimum valuation with Junior NAV far larger than factual Senior NAV.
    function _setUpUnderflowCase() internal {
        _deployMTMStack();
        _deposit(jrt, alice, 2_000_000e18);
        _deposit(srt, bob, 500e18);
        _deposit(srt, carol, 500e18);
        cdo.setTwoStepConfigManager(address(this));
        cdo.setExitFees(0, EXIT_FEE);
        accounting.setFeeRetentionBps(0, SRT_RETENTION);
        cdo.setValuationKeeper(address(this));
        cdo.setValuationPrice(0.0005e18);
    }

    function test_partialRedemptionWithFeeAboveFactualSeniorNav() public {
        _setUpUnderflowCase();
        uint256 bobShares = srt.balanceOf(bob);
        uint256 grossAssets = srt.convertToAssets(bobShares);
        uint256 fee = grossAssets * EXIT_FEE / 1e18;
        uint256 reserveDebit = fee * (1e18 - SRT_RETENTION) / 1e18;
        assertLe(bobShares, srt.maxRedeem(bob), "request is within advertised redemption limit");
        assertGt(reserveDebit, accounting.srtBaseNav(), "reserve debit exceeds factual Senior NAV");

        uint256 seniorNavBefore = accounting.srtBaseNav();
        uint256 reserveNavBefore = accounting.reserveNav();
        vm.prank(bob);
        srt.redeem(bobShares, bob, bob);

        assertEq(srt.balanceOf(bob), 0, "redeemed shares burned");
        assertLt(accounting.srtBaseNav(), seniorNavBefore);
        assertEq(accounting.reserveNav(), reserveNavBefore);
    }

    function test_feeBurnWithFeeAboveFactualSeniorNav() public {
        _setUpUnderflowCase();
        uint256 bobShares = srt.balanceOf(bob);
        uint256 feeShares = bobShares / 10;
        uint256 feeAssets = srt.convertToAssets(feeShares);
        uint256 reserveDebit = feeAssets * (1e18 - SRT_RETENTION) / 1e18;
        assertLe(feeShares, srt.maxRedeem(bob), "fee burn is within advertised redemption limit");
        assertGt(reserveDebit, accounting.srtBaseNav(), "reserve debit exceeds factual Senior NAV");

        vm.prank(bob);
        srt.approve(feeSafe, feeShares);
        uint256 seniorNavBefore = accounting.srtBaseNav();
        uint256 reserveNavBefore = accounting.reserveNav();
        vm.prank(feeSafe);
        srt.burnSharesAsFee(feeShares, bob);

        assertEq(srt.balanceOf(bob), bobShares - feeShares);
        assertEq(accounting.srtBaseNav(), seniorNavBefore);
        assertEq(accounting.reserveNav(), reserveNavBefore);
    }
    function test_selfFundedFeePreservesJuniorValue() public {
        _setUp(EXIT_FEE);
        cdo.setValuationPrice(0.8e18);
        cdo.setActionStates(address(srt), true, true);
        _deposit(srt, bob, 400e18);
        uint256 seniorBefore = cdo.totalAssets(address(srt));
        uint256 juniorBefore = cdo.totalAssets(address(jrt));
        uint256 fundBefore = accounting.srtFundNav();
        uint256 feeShares = srt.balanceOf(bob) / 10;
        vm.prank(bob);
        srt.burnSharesAsFee(feeShares, bob);
        uint256 reserveFee = 0;
        assertApproxEqAbs(cdo.totalAssets(address(srt)), seniorBefore - reserveFee, 5);
        assertApproxEqAbs(cdo.totalAssets(address(jrt)), juniorBefore, 5);
        assertEq(accounting.srtFundNav(), fundBefore);
        assertEq(accounting.reserveNav(), reserveFee);
        assertEq(_identityGap(), 0);
    }

    function _assertInsuredFeeRetained() internal {
        uint256 claimBefore = accounting.insuranceAmount();
        assertGt(claimBefore, 0);
        uint256 seniorBefore = cdo.totalAssets(address(srt));
        uint256 juniorBefore = cdo.totalAssets(address(jrt));
        uint256 reserveBefore = accounting.reserveNav();
        uint256 feeShares = srt.balanceOf(bob) / 10;
        vm.prank(bob);
        srt.burnSharesAsFee(feeShares, bob);
        assertEq(accounting.insuranceAmount(), claimBefore);
        assertEq(accounting.reserveNav(), reserveBefore);
        assertEq(cdo.totalAssets(address(srt)), seniorBefore);
        assertEq(cdo.totalAssets(address(jrt)), juniorBefore);
        vm.prank(address(jrt));
        cdo.updateAccounting();
        assertEq(accounting.insuranceAmount(), claimBefore, "no credit released on the next checkpoint");
        assertEq(_identityGap(), 0);
    }

    function test_openValuationClaimRetainsWholeSeniorFee() public {
        _setUp(EXIT_FEE);
        _enableInsurance(1_000_000e18, 0);
        cdo.setValuationPrice(0.2e18);
        accounting.setFeeRetentionBps(0, SRT_RETENTION);
        _assertInsuredFeeRetained();
    }

    function test_depletionAtParDisablesReserveAccrual() public {
        _setUp(EXIT_FEE);
        _enableInsurance(1_000_000e18, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        mtmStrategy.setTotalAssets(100e18);
        // Supply the same finalized loss to the DYS/Discrete overload as to the MTM snapshot.
        vm.mockCall(address(mtmStrategy), abi.encodeWithSignature("totalAssets(uint256,uint256)"), abi.encode(100e18));
        vm.prank(address(jrt));
        cdo.updateAccounting();
        assertGt(accounting.insuranceAmount(), 0);
        assertEq(accounting.feeJrtRetentionBps(), 1e18);
        assertEq(accounting.feeSrtRetentionBps(), 1e18);
        _assertInsuredFeeRetained();
    }

    function test_reenabledReserveFeeUsesValuationSplit() public {
        _setUp(EXIT_FEE);
        cdo.setValuationPrice(0.8e18);
        accounting.setFeeRetentionBps(0, SRT_RETENTION);
        uint256 shares = srt.balanceOf(bob);
        vm.prank(bob);
        srt.redeem(shares, bob, bob);
        assertApproxEqAbs(cdo.totalAssets(address(srt)), 502.5e18, 5);
        assertApproxEqAbs(cdo.totalAssets(address(jrt)), 800e18, 5);
        assertEq(accounting.reserveNav(), 2.5e18);
        assertEq(_identityGap(), 0);
    }

    function _assertReenabledFeeBurn() internal {
        accounting.setFeeRetentionBps(0, SRT_RETENTION);
        uint256 seniorBefore = cdo.totalAssets(address(srt));
        uint256 juniorBefore = cdo.totalAssets(address(jrt));
        uint256 shares = srt.balanceOf(bob) / 10;
        vm.prank(bob);
        uint256 fee = srt.burnSharesAsFee(shares, bob);
        uint256 reserveFee = fee / 2;
        // Rounding one raw principal unit is amplified by the inverse valuation price.
        uint256 roundingTolerance = 1e18 / accounting.valuationPrice() + 3;
        assertApproxEqAbs(cdo.totalAssets(address(srt)), seniorBefore - reserveFee, roundingTolerance);
        assertApproxEqAbs(cdo.totalAssets(address(jrt)), juniorBefore, roundingTolerance);
        assertEq(accounting.reserveNav(), reserveFee);
        assertEq(_identityGap(), 0);
    }

    function test_reenabledReserveFeeAboveFactualNav() public {
        _setUpUnderflowCase();
        _assertReenabledFeeBurn();
    }

    function test_reenabledReserveFeeWithSelfFundedDeposit() public {
        _setUp(EXIT_FEE);
        cdo.setValuationPrice(0.8e18);
        cdo.setActionStates(address(srt), true, true);
        _deposit(srt, bob, 400e18);
        uint256 fundBefore = accounting.srtFundNav();
        _assertReenabledFeeBurn();
        assertLt(accounting.srtFundNav(), fundBefore);
    }

    event FeeRetentionChanged(uint256 junior, uint256 senior);

    function test_depegDisablesReserveAccrualWithPerformanceFeeAlreadyZero() public {
        _setUp(EXIT_FEE);
        assertEq(accounting.reserveBps(), 0);
        vm.expectEmit(false, false, false, true, address(accounting));
        emit FeeRetentionChanged(1e18, 1e18);
        cdo.setValuationPrice(0.8e18);
        assertEq(accounting.feeJrtRetentionBps(), 1e18);
        assertEq(accounting.feeSrtRetentionBps(), 1e18);
        uint256 juniorBefore = cdo.totalAssets(address(jrt));
        uint256 reserveBefore = accounting.reserveNav();
        uint256 shares = jrt.balanceOf(alice) / 10;
        cdo.setActionStates(address(jrt), true, true);
        vm.prank(alice);
        jrt.burnSharesAsFee(shares, alice);
        assertEq(cdo.totalAssets(address(jrt)), juniorBefore);
        assertEq(accounting.reserveNav(), reserveBefore);
    }

    function test_recoveryRequiresExplicitRetentionRestore() public {
        _setUp(EXIT_FEE);
        accounting.setReserveBps(0.1e18);
        cdo.setValuationPrice(0.8e18);
        assertEq(accounting.reserveBps(), 0);
        cdo.setValuationPrice(1e18);
        assertEq(accounting.feeJrtRetentionBps(), 1e18);
        assertEq(accounting.feeSrtRetentionBps(), 1e18);
        accounting.setFeeRetentionBps(0.25e18, 0.5e18);
        assertEq(accounting.feeJrtRetentionBps(), 0.25e18);
        assertEq(accounting.feeSrtRetentionBps(), 0.5e18);
    }

    function test_eachBelowPegUpdateRestoresFullRetention() public {
        _setUp(EXIT_FEE);
        cdo.setValuationPrice(0.8e18);
        cdo.setValuationPrice(0.8e18); // Already disabled: remains valid.
        accounting.setFeeRetentionBps(0.25e18, 0.5e18);
        cdo.setValuationPrice(0.9e18);
        assertEq(accounting.feeJrtRetentionBps(), 1e18);
        assertEq(accounting.feeSrtRetentionBps(), 1e18);
    }

}

contract ContinuousValuationSeniorFeeTest is ValuationSeniorFeeTests {
    function _accountingImplementation() internal override returns (address) {
        return address(new Accounting(18));
    }
}

contract DiscreteValuationSeniorFeeTest is ValuationSeniorFeeTests {
    function _accountingImplementation() internal override returns (address) {
        return address(new DiscreteAccounting(18, true));
    }
}

contract DYSValuationSeniorFeeTest is ValuationSeniorFeeTests {
    function _accountingImplementation() internal override returns (address) {
        return address(new DYSAccounting(18, false, true, false, false, true));
    }
}

contract MTMValuationSeniorFeeTest is ValuationSeniorFeeTests {
    function _accountingImplementation() internal override returns (address) {
        return address(new MTMAccounting(18, false, true, false, false, true, false));
    }
}
