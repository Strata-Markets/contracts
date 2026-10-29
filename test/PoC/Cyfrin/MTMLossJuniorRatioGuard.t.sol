// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISharesCooldown} from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

/// @notice Full Strata stack (StrataCDO + two conservative-price Tranches + MTMAccounting with MTM projection) on
///         MockMTMStrategy, whose snapshot holds navT1 at the accounting NAV during the epoch and reports navMTM live
contract MTMLossJuniorRatioGuardTest is Test {
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");
    bytes4 constant ERC4626_EXCEEDED_MAX_REDEEM = bytes4(keccak256("ERC4626ExceededMaxRedeem(address,uint256,uint256)"));

    uint256 constant JRT_DEP = 100e18;
    uint256 constant SRT_DEP = 900e18;
    uint256 constant MIN_SHARES = 0.1e18;
    uint256 constant MTM_LOSS = 80e18;
    uint256 constant FURTHER_LOSS = 10e18;

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

    function setUp() public {
        token = new MockERC20("BASE", 18);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(token, ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche("JRT");
        srt = _tranche("SRT");

        feed = new MockAprPairFeed();
        // 8% benchmark target, 10% base APR (SD7x12)
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp));

        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice, mtmProjection
        accounting = MTMAccounting(address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, true, false, false, true, true)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        )));

        acm.grantRole(PAUSER_ROLE, address(this));
        acm.grantRole(UPDATER_FEED_ROLE, address(this));
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, address(this));
        acm.grantRole(RESERVE_MANAGER_ROLE, address(this));

        mtmStrategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        mtmStrategy.setEpochDuration(1 days);

        cdo.configure(IAccounting(address(accounting)), IStrategy(address(mtmStrategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));

        _deposit(jrt, alice, JRT_DEP);
        _deposit(srt, bob, SRT_DEP);
    }

    /// @dev The 80 loss realized at the epoch boundary: the ratio guard binds and Juniors cannot exit
    function test_PoC_MTMLossJuniorRatioGuard_RealizedLossBlocksJuniorExit() public {
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        mtmStrategy.setTotalAssets(JRT_DEP + SRT_DEP - MTM_LOSS);
        // Both capacity views preview the pending reconciliation without writing storage.
        assertEq(accounting.jrtBaseNav(), JRT_DEP);
        assertEq(cdo.maxWithdraw(address(jrt)), 0);
        assertEq(srt.maxDeposit(bob), 0);
        assertEq(accounting.jrtBaseNav(), JRT_DEP);
        _poke();

        uint256 minJrt = accounting.srtBaseNav() * accounting.minimumJrtSrtRatio() / 1e18;
        console.log("Junior settled / minimum", accounting.jrtBaseNav(), minJrt);
        assertEq(accounting.jrtBaseNav(), JRT_DEP - MTM_LOSS, "settled Junior took the realized loss");
        assertLt(accounting.jrtBaseNav(), minJrt, "settled Junior below the minimum ratio");
        assertEq(cdo.maxWithdraw(address(jrt)), 0, "no Junior headroom");
        assertEq(srt.maxDeposit(bob), 0, "Senior deposits capped");

        uint256 shares = jrt.balanceOf(alice) - MIN_SHARES;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626_EXCEEDED_MAX_REDEEM, alice, shares, 0));
        jrt.redeem(shares, alice, alice);
    }

    /// @dev f-63: after a checkpoint the guards include the open loss without a fresh split.
    function test_OpenLossBlocksJuniorExitAndSeniorDeposit() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        mtmStrategy.setTotalAssets(920e18);
        _poke();
        assertEq(accounting.jrtBaseNav(), 100e18);
        assertEq(accounting.jrtNavProjected(), 20e18);
        assertEq(cdo.maxWithdraw(address(jrt)), 0);
        assertEq(srt.maxDeposit(bob), 0);
        uint256 shares = jrt.balanceOf(alice) - MIN_SHARES;
        vm.expectRevert(abi.encodeWithSelector(ERC4626_EXCEEDED_MAX_REDEEM, alice, shares, 0));
        vm.prank(alice);
        jrt.redeem(shares, alice, alice);
        _assertSeniorDepositBlocked();
    }

    function _assertSeniorDepositBlocked() internal {
        token.mint(bob, 1e18);
        vm.prank(bob);
        token.approve(address(srt), 1e18);
        vm.expectRevert(abi.encodeWithSignature("DepositCapReached(address)", address(srt)));
        vm.prank(bob);
        srt.deposit(1e18, bob);
    }

    function test_ExecutionRefreshesStaleGuard() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        mtmStrategy.setTotalAssets(920e18);
        // The lightweight view deliberately uses the last stored projection.
        assertGt(srt.maxDeposit(bob), 0);
        _assertSeniorDepositBlocked();
        uint256 shares = jrt.balanceOf(alice) - MIN_SHARES;
        vm.expectRevert(abi.encodeWithSelector(ERC4626_EXCEEDED_MAX_REDEEM, alice, shares, 0));
        vm.prank(alice);
        jrt.redeem(shares, alice, alice);
    }

    function test_SmallDipAllowsFlowsAndRecoveryRestoresCapacity() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        mtmStrategy.setTotalAssets(990e18);
        _poke();
        assertEq(cdo.maxWithdraw(address(jrt)), 45e18);
        assertEq(srt.maxDeposit(bob), 600e18);
        _deposit(srt, bob, 10e18);
        assertEq(accounting.srtBaseNav(), 910e18);
        assertEq(accounting.jrtBaseNav(), 100e18);
        assertEq(accounting.jrtNavProjected(), 90e18);
        mtmStrategy.setTotalAssets(1010e18);
        _poke();
        assertEq(accounting.jrtNavProjected(), 100e18);
        assertEq(cdo.maxWithdraw(address(jrt)), 100e18 - 910e18 * 5 / 100);
    }

    function test_CooldownExitUsesLiveJuniorNavWithoutRatioRestriction() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        mtmStrategy.setTotalAssets(920e18);
        _poke();
        assertEq(accounting.maxWithdraw(false), 900e18);
        assertEq(accounting.maxWithdraw(true, true), 20e18);
        assertEq(accounting.maxWithdraw(true), 0);
        assertEq(accounting.maxDeposit(true), type(uint256).max);
    }

    /// @dev Control: without the Junior exit the same further drop stays with Junior
    function test_PoC_MTMLossJuniorRatioGuard_ControlJuniorAbsorbsNextLoss() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        mtmStrategy.setTotalAssets(JRT_DEP + SRT_DEP - MTM_LOSS);
        _poke();

        mtmStrategy.setTotalAssets(JRT_DEP + SRT_DEP - MTM_LOSS - FURTHER_LOSS);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _poke();

        console.log("Senior / Junior settled after reconciliation", accounting.srtBaseNav(), accounting.jrtBaseNav());
        assertEq(accounting.srtBaseNav(), SRT_DEP, "Senior untouched");
        assertEq(accounting.jrtBaseNav(), JRT_DEP - MTM_LOSS - FURTHER_LOSS, "Junior absorbs both losses");
    }

    function test_ProjectedGainsDoNotIncreaseJuniorBacking() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        mtmStrategy.setTotalAssets(1010e18);
        _poke();
        uint256 juniorBase = accounting.jrtBaseNav();
        uint256 seniorBase = accounting.srtBaseNav();
        assertGt(accounting.jrtNavProjected(), juniorBase);
        assertEq(accounting.maxWithdraw(true), juniorBase - seniorBase * accounting.minimumJrtSrtRatio() / 1e18);
        assertEq(accounting.maxDeposit(false), juniorBase * 1e18 / accounting.minimumJrtSrtRatioBuffer() - seniorBase);
    }

    function test_ValuationAdjustmentStillAppliesToJuniorBacking() public {
        vm.prank(address(cdo));
        accounting.setValuationPrice(0.99e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        mtmStrategy.setTotalAssets(920e18);
        _poke();
        assertEq(accounting.maxWithdraw(true), 0);
        assertEq(accounting.maxDeposit(false), 0);
        assertEq(accounting.maxWithdraw(false), uint256(900e18) * 1e18 / 0.99e18);
    }

    function test_DepegSeniorCapUsesAvailableLiveJuniorBacking() public {
        vm.prank(address(cdo));
        accounting.setValuationPrice(0.95e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        mtmStrategy.setTotalAssets(920e18);
        _poke();
        assertEq(accounting.jrtBaseNav(), 100e18);
        assertEq(accounting.jrtNavProjected(), 20e18);
        assertEq(accounting.maxWithdraw(false), 919e18, "only 19 Junior assets above dust back Senior");
        assertEq(accounting.maxWithdraw(false, true), 919e18);
        assertEq(accounting.maxWithdraw(true, true), 1e18);
    }

    function _poke() internal {
        vm.prank(carol);
        jrt.burnSharesAsFee(0, carol); // permissionless accounting refresh
    }

    function _tranche(string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(true)),
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
