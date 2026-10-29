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
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";

abstract contract SeniorDepegLiveBackingBase is Test {
    function _conservative() internal pure virtual returns (bool) {
        return true;
    }

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

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    struct AccFlags {
        bool benchmark;
        bool mtmProjection;
    }

    function _deployCore(IERC20Metadata asset, uint256 navDecimals, AccFlags memory f) internal {
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

        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice, mtmProjection
        accounting = MTMAccounting(address(new ERC1967Proxy(
            address(new MTMAccounting(navDecimals, f.benchmark, true, false, false, _conservative(), f.mtmProjection)),
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

    function _deposit(Tranche t, address user, uint256 amount) internal returns (uint256 shares) {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        shares = t.deposit(amount, user);
        vm.stopPrank();
    }


}

/// @notice Regression adapted from f-71: Senior exits must consume the same live Junior backing used for pricing.
contract SeniorDepegLiveBackingTest is SeniorDepegLiveBackingBase {

    uint256 constant JRT_DEP = 100e18;
    uint256 constant SRT_DEP = 900e18;
    uint128 constant PRICE = 0.95e18;

    function _setUp(bool mtmLoss) internal {
        _deployMTMStack(AccFlags({ benchmark: false, mtmProjection: true }));
        _deposit(jrt, alice, JRT_DEP);
        _deposit(srt, bob, SRT_DEP);
        cdo.setValuationKeeper(address(this));

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        if (mtmLoss) {
            mtmStrategy.setTotalAssets(920e18); // MTM -80 inside the 1 day epoch
        }
        _poke();
        cdo.setValuationPrice(PRICE); // grace period 0
    }

    function _poke() internal {
        vm.prank(carol);
        jrt.burnSharesAsFee(0, carol); // permissionless accounting refresh
    }

    function test_openLossSequentialExits() public {
        _setUp(true);
        assertEq(accounting.jrtBaseNav(), 100e18);
        assertEq(accounting.jrtNavProjected(), 20e18);
        uint256 shares = srt.balanceOf(bob);
        assertApproxEqAbs(srt.previewRedeem(shares), 919e18, 1e12);
        vm.prank(bob);
        uint256 first = srt.redeem(shares / 2, bob, bob);
        assertApproxEqAbs(first, 459.5e18, 1e12);
        assertApproxEqAbs(accounting.jrtBaseNav(), 90.5e18, 1e12);
        // Conservative exits reset stored projection; refresh the live mark before checking it.
        _poke();
        assertApproxEqAbs(accounting.jrtNavProjected(), 10.5e18, 1e12);
        vm.prank(bob);
        uint256 rest = srt.redeem(shares / 4, bob, bob);
        assertApproxEqAbs(first + rest, 689.25e18, 1e12);
        _poke();
        assertApproxEqAbs(accounting.jrtNavProjected(), 5.75e18, 1e12);
        assertApproxEqAbs(accounting.jrtBaseNav(), 85.75e18, 1e12);
        assertEq(srt.balanceOf(bob), shares / 4);
    }

    function test_openLossLargeExit() public {
        _setUp(true);
        // Leave one share token to respect the tranche's minimum supply.
        uint256 shares = srt.balanceOf(bob) - 1e18;
        vm.prank(bob);
        uint256 out = srt.redeem(shares, bob, bob);
        assertApproxEqAbs(out, 919e18 * shares / 900e18, 1e12);
        uint256 juniorBackingOut = 19e18 * shares / 900e18;
        assertApproxEqAbs(accounting.jrtBaseNav(), 100e18 - juniorBackingOut, 1e12);
        _poke();
        assertApproxEqAbs(accounting.jrtNavProjected(), 20e18 - juniorBackingOut, 1e12);
    }

    /// @dev Once the epoch reconciles the loss into jrtBaseNav, the same half exit succeeds
    function test_reconciledExitSucceeds() public {
        _setUp(true);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _poke();
        assertEq(accounting.jrtBaseNav(), accounting.jrtNavProjected(), "loss settled");

        uint256 half = srt.balanceOf(bob) / 2;
        vm.prank(bob);
        uint256 out = srt.redeem(half, bob, bob);
        assertGt(out, 450e18);
    }

    /// @dev Control: without the MTM loss the same half exit succeeds
    function test_noMTMLossControl() public {
        _setUp(false);
        uint256 half = srt.balanceOf(bob) / 2;
        vm.prank(bob);
        uint256 out = srt.redeem(half, bob, bob);
        assertApproxEqAbs(out, 473.68e18, 0.01e18);
    }
}

contract SeniorDepegLiveBackingNonConservativeTest is SeniorDepegLiveBackingTest {
    function _conservative() internal pure override returns (bool) {
        return false;
    }
}
