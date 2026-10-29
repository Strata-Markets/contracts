// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";

import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { DiscreteAccounting } from "../../../contracts/tranches/DiscreteAccounting.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";

/// @dev Shared accounting ABI
interface IProjAccounting {
    function setReserveBps(uint256) external;
    function setUnderwriterFeeBps(uint256) external;
    function setRiskParameters(UD60x18, UD60x18, UD60x18) external;
    function nav() external view returns (uint256);
    function feeWatermarkNav() external view returns (uint256);
}

/// @notice Adapted from Cyfrin f-115. The projected NAV estimate should substantially reduce
///         reserve-fee cadence differences without promising exact gross-gain tracking.
/// @dev Compare against a zero-reserve-fee control to isolate ordinary index compounding.
abstract contract ProjectedReserveFeeCadenceBase is Test {
    uint256 constant JRT_DEP = 2_000_000e18;
    uint256 constant SRT_DEP = 8_000_000e18;
    uint256 constant LOSS = 10_000e18;
    uint256 constant EPOCH = 7 days;
    uint256 constant STEPS = 168;
    uint256 constant RESERVE_BPS = 0.1e18;

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    IProjAccounting accounting;
    MockMTMStrategy strategy;
    MockERC20 token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function _deployAccounting(IAprPairFeed feed) internal virtual returns (address);
    function _strategyEpoch() internal pure virtual returns (uint256);

    bool conservative;

    function setUp() public {
        _deployMarket(false);
    }

    function _deployMarket(bool conservative_) internal {
        conservative = conservative_;
        vm.warp(1_790_000_000);
        token = new MockERC20("BASE", 18);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(token, ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche("JRT");
        srt = _tranche("SRT");

        MockAprPairFeed feed = new MockAprPairFeed();
        feed.updateRoundData(50_000_000_000, 100_000_000_000, uint64(block.timestamp)); // 5% target, 10% base
        accounting = IProjAccounting(_deployAccounting(IAprPairFeed(address(feed))));

        strategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        strategy.setEpochDuration(_strategyEpoch());

        acm.grantRole(keccak256("PAUSER_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        // flat 50% risk premium, so the Senior APR is the 5% target throughout
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        accounting.setReserveBps(RESERVE_BPS);

        _deposit(jrt, alice, JRT_DEP);
        _deposit(srt, bob, SRT_DEP);

        // realized loss: reconciliation lowers NAV, the watermark stays
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        strategy.setTotalAssets(strategy.totalAssetsValue() - LOSS);
        _poke();
    }

    function _tranche(string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(conservative)),
            abi.encodeWithSelector(
                Tranche.initialize.selector,
                address(this), address(acm), name, name, IERC20(address(token)), IStrataCDO(address(cdo))
            )
        )));
    }

    function _deposit(Tranche t, address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        t.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Checkpoint through the authorized tranche-to-CDO path used by user flows
    function _poke() internal {
        vm.prank(address(jrt));
        cdo.updateAccounting();
    }

    /// @dev Projects one epoch in `steps` equal refreshes and returns the Junior tranche's assets
    function _project(uint256 steps) internal returns (uint256) {
        for (uint256 i; i < steps; ++i) {
            vm.warp(vm.getBlockTimestamp() + EPOCH / steps);
            _poke();
        }
        return jrt.totalAssets();
    }

    /// @dev Junior assets after many refreshes minus after one refresh, from the current state
    function _cadenceGap() internal returns (int256 gap) {
        uint256 snap = vm.snapshotState();
        int256 juniorOne = int256(_project(1));
        vm.revertToState(snap);
        gap = int256(_project(STEPS)) - juniorOne;
        vm.revertToState(snap);
    }

    /// @dev Projects with `steps` refreshes, then the strategy reports `realizedGain` and the next refresh
    ///      reconciles; returns the Junior assets drop at reconciliation
    function _dropAtReconciliation(uint256 steps, uint256 realizedGain) internal returns (int256 drop) {
        uint256 snap = vm.snapshotState();
        _project(steps);
        vm.warp(vm.getBlockTimestamp() + 1);
        int256 projected = int256(jrt.totalAssets());
        strategy.setTotalAssets(strategy.totalAssetsValue() + realizedGain);
        _poke();
        drop = projected - int256(jrt.totalAssets());
        vm.revertToState(snap);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// @dev Base gain the one-refresh projection books over the epoch on the settled NAV
    function _epochGain() internal view returns (uint256) {
        return accounting.nav() * (0.1e18 * EPOCH / 365 days) / 1e18;
    }

    function _flow(uint256 kind) internal {
        if (kind == 1) {
            _deposit(jrt, alice, 500_000e18);
        } else if (kind == 2) {
            _deposit(srt, bob, 500_000e18);
        } else if (kind == 3) {
            uint256 shares = jrt.balanceOf(alice) / 2;
            vm.prank(alice);
            jrt.redeem(shares, alice, alice);
        } else if (kind == 4) {
            uint256 shares = srt.balanceOf(bob) / 2;
            vm.prank(bob);
            srt.redeem(shares, bob, bob);
        }
    }

    function _runPath(uint256 steps, uint256 kind) internal returns (uint256) {
        uint256 start = block.timestamp;
        for (uint256 i; i < steps; ++i) {
            vm.warp(start + (i + 1) * EPOCH / 2 / steps);
            _poke();
        }
        _flow(kind);
        for (uint256 i; i < steps; ++i) {
            vm.warp(start + EPOCH / 2 + (i + 1) * EPOCH / 2 / steps);
            _poke();
        }
        return jrt.totalAssets();
    }

    function _flowGap(uint256 kind) internal returns (int256 gap, uint256 juniorFrequent) {
        uint256 snap = vm.snapshotState();
        uint256 sparse = _runPath(1, kind);
        vm.revertToState(snap);
        uint256 frequent = _runPath(84, kind);
        vm.revertToState(snap);
        return (int256(frequent) - int256(sparse), frequent);
    }

    function _measure(uint256 kind, bool underwriter) internal {
        if (underwriter) {
            vm.prank(address(cdo));
            accounting.setUnderwriterFeeBps(0.2e18);
        }
        (int256 withFee, uint256 juniorWithFee) = _flowGap(kind);
        accounting.setReserveBps(0);
        (int256 withoutFee, uint256 juniorWithoutFee) = _flowGap(kind);
        // All these paths recover above the watermark: frequent updates must not omit the fee.
        assertGt(juniorWithoutFee - juniorWithFee, 100e18, "hourly projection includes reserve fees");
        // Expected underwriter fees and forfeitures reduce the inferred gross projection.
        uint256 tolerance = underwriter ? 4e18 : 0.1e18;
        assertLe(_abs(withFee - withoutFee), tolerance, "bounded fee-related cadence difference");
    }

    function test_AuditorScenario() public {
        assertEq(accounting.feeWatermarkNav() - accounting.nav(), LOSS);
        uint256 gain = _epochGain();
        int256 withFee = _cadenceGap();
        accounting.setReserveBps(0);
        int256 withoutFee = _cadenceGap();
        accounting.setReserveBps(RESERVE_BPS);
        assertLe(_abs(withFee - withoutFee), 1e12, "original projected-fee gap removed");
        // Reconciliation may still differ through ordinary compounding and Senior allocation.
        assertLt(_abs(_dropAtReconciliation(1, gain)), 30e18);
        assertLt(_abs(_dropAtReconciliation(STEPS, gain)), 30e18);
    }

    function test_JuniorDeposit() public { _measure(1, false); }
    function test_SeniorDeposit() public { _measure(2, false); }
    function test_JuniorExit() public { _measure(3, false); }
    function test_SeniorExit() public { _measure(4, false); }
    function test_UnderwriterFee() public { _measure(0, true); }

}

abstract contract ConservativeProjectedReserveFeeCadenceBase is ProjectedReserveFeeCadenceBase {
    function test_ConservativeJuniorExit() public { _deployMarket(true); _measure(3, false); }
    function test_ConservativeSeniorExit() public { _deployMarket(true); _measure(4, false); }
}

contract ProjectedReserveFeeCadenceDiscreteTest is ProjectedReserveFeeCadenceBase {
    /// @dev `totalAssets(nav, navTimestamp)` reads the live value while the anchor is within the window
    function _strategyEpoch() internal pure override returns (uint256) { return 30 days; }

    function _deployAccounting(IAprPairFeed feed) internal override returns (address) {
        return address(new ERC1967Proxy(address(new DiscreteAccounting(18, false)), abi.encodeWithSelector(
            DiscreteAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(cdo)), feed
        )));
    }
}

contract ProjectedReserveFeeCadenceDYSTest is ConservativeProjectedReserveFeeCadenceBase {
    function _strategyEpoch() internal pure override returns (uint256) { return 30 days; }

    function _deployAccounting(IAprPairFeed feed) internal override returns (address) {
        return address(new ERC1967Proxy(address(new DYSAccounting(18, false, false, false, false, conservative)), abi.encodeWithSelector(
            DYSAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(cdo)), feed
        )));
    }
}

contract ProjectedReserveFeeCadenceMTMTest is ConservativeProjectedReserveFeeCadenceBase {
    /// @dev `totalAssetsSnapshot(nav, navTimestamp)` reads the live value in any later block
    function _strategyEpoch() internal pure override returns (uint256) { return 0; }

    function _deployAccounting(IAprPairFeed feed) internal override returns (address) {
        return address(new ERC1967Proxy(address(new MTMAccounting(18, false, false, false, false, conservative, false)), abi.encodeWithSelector(
            MTMAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(cdo)), feed
        )));
    }
}
