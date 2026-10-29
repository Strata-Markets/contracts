// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { SharesCooldown } from "../../../contracts/tranches/base/cooldown/SharesCooldown.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";
import { CooldownBase } from "../../../contracts/tranches/base/cooldown/CooldownBase.sol";
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";

/// @notice Full stack with conservative tranches, MTM accounting and a real shares cooldown.
abstract contract UnlockedCoverageBase is Test {
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");

    SharesCooldown cooldown;
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

    struct AccFlags {
        bool benchmark;
        bool mtmProjection;
    }

    function _deployCore(IERC20Metadata asset, uint256 navDecimals, AccFlags memory f) internal {
        acm = new AccessControlManager(address(this));
        cooldown = SharesCooldown(address(new ERC1967Proxy(
            address(new SharesCooldown()),
            abi.encodeWithSelector(CooldownBase.initialize.selector, address(this), address(acm))
        )));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(asset, ISharesCooldown(address(cooldown)))),
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
            address(new MTMAccounting(navDecimals, f.benchmark, true, false, false, true, f.mtmProjection)),
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

    /// @dev Stored identity gap: (jrt + srt + reserve + uwFee) - (nav + insuranceAmount)
    function _identityGap() internal view returns (int256) {
        uint256 lhs = accounting.jrtBaseNav() + accounting.srtBaseNav() + accounting.reserveNav()
            + accounting.underwriterFeeNav();
        uint256 rhs = accounting.nav() + accounting.insuranceAmount();
        return int256(lhs) - int256(rhs);
    }
}

/// @notice Regressions adapted from Cyfrin's mixed-basis unlocked coverage finding.
contract UnlockedCoverageTest is UnlockedCoverageBase {
    Tranche queuedTranche;
    address queuedOwner;
    function setUp() public {
        _deployMTMStack(AccFlags({benchmark: false, mtmProjection: true}));
        acm.grantRole(keccak256("COOLDOWN_WORKER_ROLE"), address(this));
        cooldown.setTwoStepConfigManager(address(this));
    }

    function _seed() internal {
        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
    }

    function _mark(uint256 assets) internal {
        vm.warp(block.timestamp + 1 hours);
        mtmStrategy.setTotalAssets(assets);
    }

    function _checkUnlocked(uint256 liveAssets) internal {
        _seed();
        vm.prank(alice);
        jrt.transfer(address(cooldown), 100e18);
        vm.prank(bob);
        srt.transfer(address(cooldown), 200e18);
        _mark(liveAssets);
        (uint256 junior, uint256 senior) = cdo.totalAssetsUnlocked();
        assertEq(junior, 900e18);
        assertEq(senior, 800e18);
        assertEq(cdo.coverage(), 1_125_000);
        (uint256 j0, uint256 s0,) = accounting.totalAssetsT0();
        assertEq(j0, 1000e18);
        assertEq(s0, 1000e18);
    }

    function test_openGainUsesStoredBasisForBothTranches() public { _checkUnlocked(2400e18); }
    function test_openLossUsesStoredBasisForBothTranches() public { _checkUnlocked(1800e18); }

    function test_emptySupplyDoesNotRevert() public view {
        (uint256 junior, uint256 senior) = cdo.totalAssetsUnlocked();
        assertEq(junior, 0);
        assertEq(senior, 0);
    }

    function test_gainDoesNotSelectStricterExitBand() public {
        _seed();
        vm.prank(alice);
        jrt.transfer(address(cooldown), 100e18);
        cooldown.setVaultExitBounds(address(jrt), ISharesCooldown.TExitUpperBounds({
            p0: 880_000, p1: 950_000,
            r0: ISharesCooldown.TExitParams(10_000, 7 days),
            r1: ISharesCooldown.TExitParams(0, 1 days),
            r2: ISharesCooldown.TExitParams(0, 0)
        }));
        _mark(2400e18);
        (IStrataCDO.TExitMode mode, uint256 fee, uint32 lockTime) = cdo.calculateExitMode(address(jrt), alice);
        assertEq(uint256(mode), uint256(IStrataCDO.TExitMode.SharesLock));
        assertEq(fee, 0);
        assertEq(lockTime, 1 days);
    }

    function _queue(uint256 shares, uint256 fee, bool senior) internal {
        _seed();
        queuedTranche = senior ? srt : jrt;
        queuedOwner = senior ? bob : alice;
        vm.prank(queuedOwner);
        queuedTranche.transfer(address(cooldown), shares);
        cooldown.requestRedeem(ITranche(address(queuedTranche)), address(token), queuedOwner, queuedOwner, shares, 0, 2 days);
        cooldown.setVaultEarlyExitFee(address(queuedTranche), fee);
        _mark(2400e18);
    }

    function _finalize() internal returns (uint256) {
        vm.prank(queuedOwner);
        return cooldown.finalizeWithFee(ITranche(address(queuedTranche)), address(0), queuedOwner, 0,
            ISharesCooldown.TFinalizeWithFeeGuard(0, 0), "");
    }

    function _checkEarlyExit(uint256 fee) internal {
        _queue(950e18, fee, true);
        uint256 oldMax = srt.convertToShares(cdo.maxWithdraw(address(srt)));
        assertLt(oldMax, 940e18, "old live conversion rejects this exit");
        assertEq(srt.maxRedeem(address(cooldown)), 950e18);
        uint256 beforeBalance = token.balanceOf(bob);
        uint256 redeemed = _finalize();
        assertGt(redeemed, oldMax);
        assertEq(srt.balanceOf(address(cooldown)), 0);
        assertEq(token.balanceOf(bob) - beforeBalance, redeemed);
    }

    function test_earlyExitUsesRedeemablePrice() public { _checkEarlyExit(0.001e18); }
    function test_earlyExitWithLargerFeeUsesRedeemablePrice() public { _checkEarlyExit(0.005e18); }

    function test_earlyExitStillEnforcesAccountingLimit() public {
        _queue(990e18, 0.001e18, false);
        vm.expectRevert(bytes("MaxRedemptionLimitReached"));
        _finalize();
    }

    function test_earlyExitStillEnforcesPause() public {
        _queue(900e18, 0.001e18, false);
        cdo.setActionStates(address(jrt), true, false);
        // The fee-share burn already rejects a paused redemption.
        vm.expectRevert(abi.encodeWithSignature(
            "ERC4626ExceededMaxRedeem(address,uint256,uint256)", address(cooldown), 1.8e18, 0
        ));
        _finalize();
    }
}
