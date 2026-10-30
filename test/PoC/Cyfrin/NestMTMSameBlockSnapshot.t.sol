// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MTMStackBase} from "./StrategyDepositMaximum.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Tranche} from "../../../contracts/tranches/Tranche.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {IStrategy} from "../../../contracts/tranches/interfaces/IStrategy.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IERC20Cooldown} from "../../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import {NestOpalStrategy} from "../../../contracts/tranches/strategies/nest/NestOpalStrategy.sol";
import {INestAccountant} from "../../../contracts/tranches/strategies/nest/interfaces/INestContracts.sol";
import {ERC20Cooldown} from "../../../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import {CooldownBase} from "../../../contracts/tranches/base/cooldown/CooldownBase.sol";
import {MockNestAccountant} from "../../../contracts/test/nest/MockNestContracts.sol";
import {MockNOpal} from "../../../contracts/test/nest/MockNestOpalContracts.sol";
import {MockERC20} from "../../../contracts/test/MockERC20.sol";

/// @notice Cyfrin's same-block Nest PoC adapted to require both flows to succeed.
contract NestMTMSameBlockSnapshotTest is MTMStackBase {
    MockNOpal nOpal;
    MockNestAccountant nestAccountant;
    NestOpalStrategy nest;
    uint256 constant RATE0 = 1_099_083;

    function setUp() public {
        MockERC20 usdc = new MockERC20("USDC", 6);
        nOpal = new MockNOpal();
        nestAccountant = new MockNestAccountant(address(usdc), RATE0);
        _deployCore(IERC20Metadata(address(nOpal)), 6, AccFlags({benchmark: false, mtmProjection: true}));
        address cooldown = address(new ERC1967Proxy(address(new ERC20Cooldown()),
            abi.encodeWithSelector(CooldownBase.initialize.selector, address(this), address(acm))));
        nest = NestOpalStrategy(address(new ERC1967Proxy(
            address(new NestOpalStrategy(IERC20(address(nOpal)), IERC20(address(usdc)), INestAccountant(address(nestAccountant)))),
            abi.encodeWithSelector(NestOpalStrategy.initialize.selector, address(this), address(acm), IStrataCDO(address(cdo)), IERC20Cooldown(cooldown))
        )));
        acm.grantRole(keccak256("COOLDOWN_WORKER_ROLE"), address(nest));
        _finishCore(IStrategy(address(nest)));
        _depositN(jrt, alice, 400_000_123_457);
        _depositN(srt, bob, 600_000_654_321);
    }

    function _depositN(Tranche tranche, address user, uint256 amount) internal {
        nOpal.mint(user, amount);
        vm.startPrank(user);
        IERC20(address(nOpal)).approve(address(tranche), amount);
        tranche.deposit(address(nOpal), amount, user);
        vm.stopPrank();
    }

    function _firstFlow(uint256 amount) internal {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        nestAccountant.setExchangeRate(nestAccountant.exchangeRate() + 37);
        vm.warp(vm.getBlockTimestamp() + 12);
        vm.roll(block.number + 1);
        _depositN(jrt, carol, amount);
        assertEq(accounting.lastReconciliation(), vm.getBlockTimestamp());
    }

    function test_auditorTwoDepositsSucceedAcrossAllSizes() public {
        uint256 roundingDifferences;
        address dave = makeAddr("dave");
        for (uint256 i; i < 200; ++i) {
            uint256 snap = vm.snapshotState();
            _firstFlow(1_000_000_000 + i * 7_919);
            if (nest.totalAssets() != nest.totalAssets(accounting.nav(), accounting.lastReconciliation())) {
                roundingDifferences++;
            }
            _depositN(jrt, dave, 5_000_000_000);
            assertGt(jrt.balanceOf(dave), 0);
            vm.revertToState(snap);
        }
        assertGt(roundingDifferences, 60, "covers the auditor's conflicting raw NAV cases");
    }

    function test_sameBlockRedemptionAfterReconciliation() public {
        _firstFlow(1_000_000_000);
        uint256 shares = jrt.balanceOf(alice) / 10;
        vm.prank(alice);
        jrt.redeem(address(nOpal), shares, alice, alice);
        vm.prank(address(jrt));
        cdo.updateAccounting();
    }

    function _assertSameBlockThenFreshSnapshot() internal {
        uint256 storedNav = accounting.nav();
        uint256 anchor = accounting.lastReconciliation();
        uint256 live = nest.totalAssets();
        assertTrue(live != storedNav);
        (uint256 settled, uint256 settledTime, uint256 mark, uint256 markTime) = nest.totalAssetsSnapshot(storedNav, anchor);
        assertEq(settled, storedNav);
        assertEq(mark, storedNav);
        assertEq(settledTime, markTime);
        vm.warp(vm.getBlockTimestamp() + 1);
        (settled, settledTime, mark, markTime) = nest.totalAssetsSnapshot(storedNav, anchor);
        assertEq(settled, storedNav);
        assertEq(mark, live);
        assertLt(settledTime, markTime);
        vm.prank(address(jrt));
        cdo.updateAccounting();
    }

    function test_sameBlockDonationAppearsWhenTimeAdvances() public {
        _firstFlow(1_000_000_000);
        nOpal.mint(address(nest), 1_000_000);
        _assertSameBlockThenFreshSnapshot();
    }

    function test_sameBlockLossAppearsWhenTimeAdvances() public {
        _firstFlow(1_000_000_000);
        nOpal.burn(address(nest), 1_000_000);
        _assertSameBlockThenFreshSnapshot();
    }

    function test_accountingStillRejectsInconsistentCustomSnapshot() public {
        _firstFlow(1_000_000_000);
        uint256 t = vm.getBlockTimestamp();
        uint256 storedNav = accounting.nav();
        vm.mockCall(address(nest), abi.encodeWithSelector(IStrategy.totalAssetsSnapshot.selector),
            abi.encode(storedNav, t, storedNav + 1, t));
        vm.expectPartialRevert(MTMAccounting.InvalidAssetsSnapshot.selector);
        vm.prank(address(jrt));
        cdo.updateAccounting();
    }
}
