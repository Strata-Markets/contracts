// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BoughtProjectionTestLib} from "../../utils/BoughtProjectionTestLib.sol";

import { console } from "forge-std/console.sol";
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
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";

/// @notice Full StrataCDO + Tranches + MTMAccounting on MockMTMStrategy (the mock stands in for a real MTM strategy
///         and simply reports the NAV the test sets) with deployment-default flags: live pricing,
///         useJuniorCoversPaidSrtProjection and MTM projection, no benchmark, zero fees, 1%/day floor.
///         Adapted from the auditor PoC to require flow-neutral signed purchase matching.
import {RiskPremiumStatic} from "../../../contracts/tranches/accounting/premium/RiskPremiumStatic.sol";

contract SignedBoughtProjectionPhantomPaidTest is Test {
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
    address dave = makeAddr("dave");
    address eve = makeAddr("eve");

    function setUp() public {
        vm.warp(1_750_000_000);
        token = new MockERC20("BASE", 18);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(IERC20Metadata(address(token)), ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche("JRT");
        srt = _tranche("SRT");
        feed = new MockAprPairFeed();
        // 8% target, 10% base APR (SD7x12)
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp));
        // decimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection,
        // conservativePrice, mtmProjection
        accounting = MTMAccounting(address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, true, false, true, false, true)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        )));
        acm.grantRole(keccak256("PAUSER_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        acm.grantRole(keccak256("RESERVE_MANAGER_ROLE"), address(this));
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
        accounting.setRiskModel(new RiskPremiumStatic(UD60x18.wrap(0.5e18)));

        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
        accounting.setFloorRate(0.01e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
    }

    /// @notice Negative bought projection (deposit during a dip) followed by a recovery above settled: a same-price
    ///         Senior deposit+redeem must not book phantom srtPaidProjected at Junior's expense
    function test_PoC_SignedBoughtProjectionPhantomPaid() public {
        // dip: Senior marked 995 with projection -5
        mtmStrategy.setTotalAssets(1980e18);
        _poke();
        assertEq(accounting.srtBaseNav(), 995e18, "Senior marked 995");
        assertEq(accounting.srtPnLProjected(), -5e18, "Senior projection -5");

        // Senior deposit of 995 during the dip buys -5 of projection
        _deposit(srt, dave, 995e18);
        assertEq(BoughtProjectionTestLib.read(address(accounting)).net, -5e18, "bought projection -5");

        // mark recovers above settled: Senior projection turns +10 while bought stays -5
        mtmStrategy.setTotalAssets(3035e18);
        _poke();
        assertEq(accounting.srtPnLProjected(), 10e18, "Senior projection +10");
        assertEq(BoughtProjectionTestLib.read(address(accounting)).net, -5e18, "bought projection still -5");
        assertEq(accounting.srtPaidProjected(), 0, "nothing paid yet");

        uint256 snap = vm.snapshotState();

        // control: no round trip, pull back to settled and reconcile flat
        (uint256 srtControl, uint256 jrtControl) = _settleFlat();
        console.log("control   Senior / Junior", srtControl, jrtControl);

        vm.revertToState(snap);

        // same-price deposit + immediate redeem of the full Senior NAV
        uint256 seniorLive = accounting.srtBaseNav();
        uint256 shares = _deposit(srt, eve, seniorLive);
        uint256 out = _redeem(srt, eve, shares);
        console.log("round trip in / out", seniorLive, out);
        console.log("srtPaidProjected after round trip", accounting.srtPaidProjected());
        assertEq(seniorLive, 2005e18, "round trip size 2005");
        assertApproxEqAbs(out, seniorLive, 2, "same-price round trip returns the deposit");
        // A net-zero round trip must not book paid projection.
        assertApproxEqAbs(accounting.srtPaidProjected(), 0, 2, "no phantom paid projection");
        assertApproxEqAbs(BoughtProjectionTestLib.read(address(accounting)).net, -5e18, 2, "net purchased projection restored");
        assertEq(BoughtProjectionTestLib.read(address(accounting)).losses, 5e18, "purchased losses preserved");

        (uint256 srtRT, uint256 jrtRT) = _settleFlat();
        console.log("roundtrip Senior / Junior", srtRT, jrtRT);

        // The round trip must preserve the control allocation.
        assertApproxEqAbs(jrtControl, 1000e18, 1e6, "control Junior 1000");
        assertApproxEqAbs(srtControl, 1995e18, 1e6, "control Senior 1995");
        assertApproxEqAbs(jrtRT, jrtControl, 2, "Junior unchanged by round trip");
        assertApproxEqAbs(srtRT, srtControl, 2, "Senior unchanged by round trip");
    }

    /// @notice Mirrored case: positive bought projection (deposit after a gain) followed by a dip below settled;
    ///         a same-price Senior deposit+redeem must preserve the remaining Seniors' recovery
    function test_PoC_SignedBoughtProjectionMirrorForfeitsRecovery() public {
        // gain: Senior projection positive, then a deposit buys positive projection
        mtmStrategy.setTotalAssets(2040e18);
        _poke();
        _deposit(srt, dave, accounting.srtBaseNav());
        console.log("bought projection", BoughtProjectionTestLib.read(address(accounting)).net);
        assertGt(BoughtProjectionTestLib.read(address(accounting)).net, 0, "bought projection positive");

        // dip below settled: live Senior projection negative
        mtmStrategy.setTotalAssets(accounting.nav() - 80e18);
        _poke();
        assertLt(accounting.srtPnLProjected(), 0, "Senior projection negative");

        uint256 snap = vm.snapshotState();
        (uint256 srtControl, uint256 jrtControl) = _settleFlat();
        console.log("control   Senior / Junior", srtControl, jrtControl);
        vm.revertToState(snap);

        uint256 seniorLive = accounting.srtBaseNav();
        uint256 shares = _deposit(srt, eve, seniorLive);
        uint256 out = _redeem(srt, eve, shares);
        console.log("round trip in / out", seniorLive, out);
        assertApproxEqAbs(out, seniorLive, 2, "same-price round trip returns the deposit");

        (uint256 srtRT, uint256 jrtRT) = _settleFlat();
        console.log("roundtrip Senior / Junior", srtRT, jrtRT);

        // The mirrored round trip must also preserve the control allocation.
        assertApproxEqAbs(jrtRT, jrtControl, 2, "Junior unchanged by mirrored round trip");
        assertApproxEqAbs(srtRT, srtControl, 2, "Senior unchanged by mirrored round trip");
    }

    function testFuzz_oppositePurchasesPreserveRoundTrips(uint96 amountSeed, bool startWithLoss) public {
        mtmStrategy.setTotalAssets(startWithLoss ? 1980e18 : 2040e18);
        _poke();
        _deposit(srt, dave, accounting.srtBaseNav());
        mtmStrategy.setTotalAssets(startWithLoss ? 3035e18 : accounting.nav() - 80e18);
        _poke();

        int256 boughtBefore = BoughtProjectionTestLib.read(address(accounting)).net;
        uint256 boughtLossBefore = BoughtProjectionTestLib.read(address(accounting)).losses;
        int256 projectionBefore = accounting.srtPnLProjected();
        uint256 amount = bound(uint256(amountSeed), 1e18, 10_000e18);
        uint256 snap = vm.snapshotState();
        (uint256 seniorControl, uint256 juniorControl) = _settleFlat();
        vm.revertToState(snap);

        for (uint256 i; i < 3; i++) {
            uint256 shares = _deposit(srt, eve, amount);
            assertApproxEqAbs(_redeem(srt, eve, shares), amount, 2);
            assertApproxEqAbs(BoughtProjectionTestLib.read(address(accounting)).net, boughtBefore, 100);
            assertApproxEqAbs(BoughtProjectionTestLib.read(address(accounting)).losses, boughtLossBefore, 100);
            assertApproxEqAbs(accounting.srtPnLProjected(), projectionBefore, 100);
            assertApproxEqAbs(accounting.srtPaidProjected(), 0, 100);
        }
        (uint256 senior, uint256 junior) = _settleFlat();
        assertApproxEqAbs(senior, seniorControl, 100);
        assertApproxEqAbs(junior, juniorControl, 100);
    }

    /// @dev pull the mark back to settled, then reconcile flat (+1 wei) after the epoch ends
    function _settleFlat() internal returns (uint256 srtNav, uint256 jrtNav) {
        mtmStrategy.setTotalAssets(accounting.nav());
        _poke();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        mtmStrategy.setTotalAssets(accounting.nav() + 1);
        _poke();
        assertEq(BoughtProjectionTestLib.read(address(accounting)).losses, 0, "purchased loss resets at reconciliation");
        srtNav = accounting.srtBaseNav();
        jrtNav = accounting.jrtBaseNav();
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

    function _redeem(Tranche t, address user, uint256 shares) internal returns (uint256 assets) {
        vm.prank(user);
        assets = t.redeem(shares, user, user);
    }

    /// @dev zero-amount fee burn triggers an accounting update
    function _poke() internal {
        vm.prank(carol);
        jrt.burnSharesAsFee(0, carol);
    }
}
