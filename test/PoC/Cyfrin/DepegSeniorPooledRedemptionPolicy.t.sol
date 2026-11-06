// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { RiskPremiumStatic } from "../../../contracts/tranches/accounting/premium/RiskPremiumStatic.sol";
import { IRiskPremiumModel } from "../../../contracts/tranches/accounting/premium/IRiskPremiumModel.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";

interface IPooledRedemptionAccounting {
    function setRiskModel(IRiskPremiumModel model) external;
    function jrtBaseNav() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
    function srtFundNav() external view returns (uint256);
    function srtFundedGrossNav() external view returns (uint256);
    function maxDeposit(bool isJrt) external view returns (uint256);
}

/// @notice Policy regression derived from the Cyfrin follow-up: reopened Senior deposits permit round trips
///         to crystallize pooled Junior backing, benefiting remaining Seniors on recovery.
/// @dev See specs/SIPs/SIP-07-nav-loss.md, Section 15.1. Original scenarios and numerical assertions retained.
///      Full StrataCDO + two live-priced Tranches + accounting on MockMTMStrategy, default ratio buffer,
///      grace period and shortfall price, no fees, no insurance pool, flat strategy, everything in one block
abstract contract DepegSeniorPooledRedemptionPolicyBase is Test {
    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    IPooledRedemptionAccounting accounting;
    MockAprPairFeed feed;
    MockERC20 token;
    MockMTMStrategy strat;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address dave = makeAddr("dave");

    function _accountingImpl() internal virtual returns (address);
    function _epoch() internal pure virtual returns (uint256);

    /// @dev Junior 2,000 and Senior 1,000, then a de-peg to 0.5: Junior pledges 1,000 of its 1,999 headroom
    function setUp() public {
        vm.warp(1_790_000_000);
        token = new MockERC20("BASE", 18);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(IERC20Metadata(address(token)), ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche("JRT");
        srt = _tranche("SRT");
        feed = new MockAprPairFeed();
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(vm.getBlockTimestamp()));
        accounting = IPooledRedemptionAccounting(address(new ERC1967Proxy(_accountingImpl(), abi.encodeWithSignature(
            "initialize(address,address,address,address)", address(this), address(acm), address(cdo), address(feed)))));
        acm.grantRole(keccak256("PAUSER_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        acm.grantRole(keccak256("RESERVE_MANAGER_ROLE"), address(this));
        strat = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        strat.setEpochDuration(_epoch());
        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strat)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        accounting.setRiskModel(new RiskPremiumStatic(UD60x18.wrap(0.5e18)));
        cdo.setValuationKeeper(address(this));

        _deposit(jrt, alice, 2_000e18);
        _deposit(srt, bob, 1_000e18);

        cdo.setValuationPrice(0.5e18);
        assertEq(cdo.maxDeposit(address(srt)), 0, "entering the de-peg closes Senior deposits");
        assertApproxEqAbs(srt.totalAssets(), 2_000e18, 1e6, "Senior effective 2,000");
        assertApproxEqAbs(jrt.totalAssets(), 1_000e18, 1e6, "Junior effective 1,000");
    }

    /// @dev Pauser reopens Senior deposits, dave deposits `amount` and redeems every new share at once
    function _roundTrip(uint256 amount) internal returns (uint256 out) {
        cdo.setActionStates(address(srt), true, true);
        assertLe(amount, accounting.maxDeposit(false), "deposit fits the default Senior capacity");
        uint256 shares = _deposit(srt, dave, amount);
        vm.prank(dave);
        out = srt.redeem(shares, dave, dave);
    }

    function _assertRoundTripCrystallizesPooledBacking() internal {
        uint256 bobShares = srt.balanceOf(bob);
        uint256 snap = vm.snapshotState();

        // control: no round trip, the price returns to par
        cdo.setValuationPrice(1e18);
        uint256 bobControl = srt.previewRedeem(bobShares);
        uint256 jrtControl = jrt.totalAssets();
        assertApproxEqAbs(bobControl, 1_000e18, 1e6, "control Senior keeps its 1,000 principal");
        assertApproxEqAbs(jrtControl, 2_000e18, 1e6, "control Junior gets its whole pledge back");
        vm.revertToState(snap);

        // round trip of 5,000 at the same price
        uint256 seniorEffective = srt.totalAssets();
        cdo.setActionStates(address(srt), true, true);
        uint256 shares = _deposit(srt, dave, 5_000e18);
        assertEq(accounting.srtFundNav(), 2_500e18, "deposit self-funds 5,000 x (1 - 0.5)");
        assertEq(accounting.srtFundedGrossNav(), 5_000e18, "gross entry 5,000");
        assertApproxEqAbs(jrt.totalAssets(), 1_000e18, 1e6, "deposit leaves Junior's pledge at 1,000");
        vm.prank(dave);
        uint256 out = srt.redeem(shares, dave, dave);
        assertApproxEqAbs(out, 5_000e18, 1e6, "dave gets his deposit back");

        // effective NAVs are unchanged while the de-peg lasts
        assertApproxEqAbs(srt.totalAssets(), seniorEffective, 1e6, "Senior effective still 2,000");
        assertApproxEqAbs(jrt.totalAssets(), 1_000e18, 1e6, "Junior effective still 1,000");
        // Policy: the exit crystallizes 5,000 / 7,000 of Junior's pledge, regardless of share entry time.
        uint256 shift = uint256(1_000e18) * 5_000e18 / 7_000e18;
        assertApproxEqAbs(accounting.jrtBaseNav(), 2_000e18 - shift, 1e9, "Junior base charged 714.29");
        assertApproxEqAbs(accounting.srtBaseNav(), 1_000e18 + shift, 1e9, "Senior base kept 714.29 of dave's tokens");
        assertApproxEqAbs(accounting.srtFundNav(), 2_500e18 - uint256(2_500e18) * 5_000e18 / 7_000e18, 1e9, "self-fund 714.29 left");
        assertApproxEqAbs(accounting.srtFundedGrossNav(), 5_000e18 - uint256(5_000e18) * 5_000e18 / 7_000e18, 1e9, "gross 1,428.57 left");

        // Repeg clears the trackers; Junior recovers only unconsumed backing.
        cdo.setValuationPrice(1e18);
        assertEq(accounting.srtFundNav(), 0, "self-fund cleared");
        uint256 bobAfter = srt.previewRedeem(bobShares);
        uint256 jrtAfter = jrt.totalAssets();
        console2.log("bob at re-peg, control / round trip", bobControl, bobAfter);
        console2.log("Junior at re-peg, control / round trip", jrtControl, jrtAfter);
        assertApproxEqAbs(bobAfter - bobControl, shift, 1e9, "remaining Senior gains 714.29");
        assertApproxEqAbs(jrtControl - jrtAfter, shift, 1e9, "Junior recovery excludes 714.29 of crystallized backing");
    }

    function _tranche(string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(false)),
            abi.encodeWithSelector(
                Tranche.initialize.selector,
                address(this), address(acm), name, name, IERC20(address(token)), IStrataCDO(address(cdo))
            )
        )));
    }

    function _deposit(Tranche t, address user, uint256 amount) internal returns (uint256 shares) {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        shares = t.deposit(amount, user);
        vm.stopPrank();
    }
}

/// @notice DYS live pricing follows the pooled-redemption policy after Senior deposits reopen.
contract DYSDepegSeniorPooledRedemptionPolicyTest is DepegSeniorPooledRedemptionPolicyBase {
    function _accountingImpl() internal override returns (address) {
        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice
        return address(new DYSAccounting(18, false, true, false, true, false));
    }

    function _epoch() internal pure override returns (uint256) {
        return 3650 days;
    }

    function test_roundTripCrystallizesPooledBacking() public {
        _assertRoundTripCrystallizesPooledBacking();
    }

    /// @notice Repeated capacity-sized exits crystallize most of Junior's pledge under the accepted policy.
    function test_capacityRoundTripsCrystallizeMostOfPledge() public {
        uint256 bobShares = srt.balanceOf(bob);
        uint256 capacity = accounting.maxDeposit(false);
        assertApproxEqAbs(capacity, uint256(1_000e18) * 1e18 / 0.06e18 - 2_000e18, 1e6, "1,000 / 0.06 - 2,000");
        _roundTrip(capacity - 1e6);
        assertApproxEqAbs(accounting.jrtBaseNav(), 1_120e18, 1e9, "first trip crystallizes 880 of the 1,000 pledge");
        _roundTrip(accounting.maxDeposit(false) - 1e6);
        assertApproxEqAbs(accounting.jrtBaseNav(), 1_014.4e18, 1e9, "second trip crystallizes 105.6 more");

        cdo.setValuationPrice(1e18);
        uint256 bobAfter = srt.previewRedeem(bobShares);
        console2.log("bob at re-peg, control 1,000", bobAfter);
        console2.log("Junior at re-peg, control 2,000", jrt.totalAssets());
        assertApproxEqAbs(bobAfter, 1_985.6e18, 1e9, "remaining Senior recovers 985.6 of Junior's pledge");
        assertApproxEqAbs(jrt.totalAssets(), 1_014.4e18, 1e9, "Junior keeps 14.4 of its 1,000 pledge");
    }
}

/// @notice MTM live pricing follows the same pooled-redemption policy.
contract MTMDepegSeniorPooledRedemptionPolicyTest is DepegSeniorPooledRedemptionPolicyBase {
    function _accountingImpl() internal override returns (address) {
        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice, mtmProjection
        return address(new MTMAccounting(18, false, true, false, true, false, true));
    }

    function _epoch() internal pure override returns (uint256) {
        return 1 days;
    }

    function test_roundTripCrystallizesPooledBacking() public {
        _assertRoundTripCrystallizesPooledBacking();
    }
}

/// @notice Conservative pricing preserves pooled allocation when no projection has accrued.
contract DYSConservativePooledRedemptionPolicyTest is DepegSeniorPooledRedemptionPolicyBase {
    function _accountingImpl() internal override returns (address) {
        return address(new DYSAccounting(18, false, true, false, true, true));
    }
    function _epoch() internal pure override returns (uint256) { return 3650 days; }
    function test_conservativeRoundTripCrystallizesPooledBacking() public { _assertRoundTripCrystallizesPooledBacking(); }
}

/// @notice MTM conservative pricing also permits crystallization after Senior deposits reopen.
contract MTMConservativePooledRedemptionPolicyTest is DepegSeniorPooledRedemptionPolicyBase {
    function _accountingImpl() internal override returns (address) {
        return address(new MTMAccounting(18, false, true, false, true, true, true));
    }
    function _epoch() internal pure override returns (uint256) { return 1 days; }
    function test_conservativeRoundTripCrystallizesPooledBacking() public { _assertRoundTripCrystallizesPooledBacking(); }
}
