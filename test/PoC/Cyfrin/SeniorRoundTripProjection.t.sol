// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UD60x18} from "@prb/math/src/ud60x18/ValueType.sol";
import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";
import {StrataCDO} from "../../../contracts/tranches/StrataCDO.sol";
import {Tranche} from "../../../contracts/tranches/Tranche.sol";
import {DYSAccounting} from "../../../contracts/tranches/DYSAccounting.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {IAccounting} from "../../../contracts/tranches/interfaces/IAccounting.sol";
import {IStrategy} from "../../../contracts/tranches/interfaces/IStrategy.sol";
import {ITranche} from "../../../contracts/tranches/interfaces/ITranche.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {MockERC20} from "../../../contracts/test/MockERC20.sol";
import {MockAprPairFeed} from "../../../contracts/test/MockAprPairFeed.sol";
import {MockMTMStrategy} from "../../../contracts/test/MockMTMStrategy.sol";

/// @notice Real StrataCDO, live-priced Tranches and the accounting under test behind a proxy. MockMTMStrategy stands
///         in for the strategy so the tests can set its NAV
abstract contract RoundTripStackBase is Test {
    MockERC20 token;
    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    MockMTMStrategy strategy;

    address alice = makeAddr("alice"); // Junior
    address bob = makeAddr("bob"); // Senior
    address carol = makeAddr("carol"); // anyone: refreshes the accounting, newcomer in the churn case

    /// @dev `aprTarget` / `aprBase` in SD7x12; `epoch` is the strategy's MTM epoch
    function _deploy(address accountingImpl, int64 aprTarget, int64 aprBase, uint256 epoch)
        internal
        returns (address accounting)
    {
        token = new MockERC20("BASE", 18);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(
            address(
                new ERC1967Proxy(
                    address(new StrataCDO(IERC20Metadata(address(token)))),
                    abi.encodeWithSelector(
                        StrataCDO.initialize.selector, address(this), address(acm)
                    )
                )
            )
        );
        jrt = _liveTranche("JRT");
        srt = _liveTranche("SRT");

        MockAprPairFeed feed = new MockAprPairFeed();
        feed.updateRoundData(aprTarget, aprBase, uint64(block.timestamp));
        accounting = address(
            new ERC1967Proxy(
                accountingImpl,
                abi.encodeWithSelector(
                    DYSAccounting.initialize.selector,
                    address(this),
                    address(acm),
                    address(cdo),
                    address(feed)
                )
            )
        );

        strategy = MockMTMStrategy(
            address(
                new ERC1967Proxy(
                    address(new MockMTMStrategy(IERC20(address(token)))),
                    abi.encodeWithSelector(
                        MockMTMStrategy.initialize.selector,
                        address(this),
                        address(acm),
                        IStrataCDO(address(cdo)),
                        address(0),
                        address(0)
                    )
                )
            )
        );
        strategy.setEpochDuration(epoch);

        acm.grantRole(keccak256("PAUSER_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        cdo.configure(
            IAccounting(accounting),
            IStrategy(address(strategy)),
            ITranche(address(jrt)),
            ITranche(address(srt))
        );
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
    }

    function _liveTranche(string memory name) internal returns (Tranche) {
        return Tranche(
            address(
                new ERC1967Proxy(
                    address(new Tranche(false)),
                    abi.encodeWithSelector(
                        Tranche.initialize.selector,
                        address(this),
                        address(acm),
                        name,
                        name,
                        IERC20(address(token)),
                        IStrataCDO(address(cdo))
                    )
                )
            )
        );
    }

    function _deposit(Tranche t, address who, uint256 amount) internal returns (uint256 shares) {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(t), amount);
        shares = t.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Senior deposit, then redemption of the same shares at the same price
    function _roundTrip(address who, uint256 amount) internal returns (uint256 received) {
        uint256 shares = _deposit(srt, who, amount);
        vm.prank(who);
        received = srt.redeem(shares, who, who);
    }

    /// @dev Permissionless accounting refresh, the same path as any user flow
    function _poke() internal {
        vm.prank(carol);
        jrt.burnSharesAsFee(0, carol);
    }
}

/// @notice Regression adapted from Cyfrin: live-priced round trips must not charge Junior.
contract DYSSeniorRoundTripProjectionTest is RoundTripStackBase {
    uint256 constant ROUND_TRIP = 4_725e18;

    DYSAccounting a;

    function setUp() public {
        vm.warp(1_750_000_000);
        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection,
        // conservativePrice; 5% target, 10% base APR; an epoch long enough that the strategy reads live
        a = DYSAccounting(
            _deploy(
                address(new DYSAccounting(18, false, false, false, true, false)),
                50_000_000_000,
                100_000_000_000,
                3650 days
            )
        );
        a.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        _deposit(jrt, alice, 500e18);
        _deposit(srt, bob, 500e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _poke();
        assertApproxEqAbs(a.srtBaseNav(), 525e18, 0.5e18, "Senior projection ~25");
        assertEq(a.srtPaidProjected(), 0);
    }

    /// @dev Strategy NAV move backed by real tokens; any change triggers a reconciliation
    function _setStrategyNav(uint256 newNav) internal {
        uint256 cur = strategy.totalAssets();
        if (newNav > cur) token.mint(address(strategy), newNav - cur);
        strategy.updateTotalAssets(newNav);
    }

    /// Strategy reports nav + 1001 wei, i.e. a reconciliation with no realized gain
    function _reconcileFlat() internal {
        _setStrategyNav(strategy.totalAssets() + 1001);
        _poke();
        assertEq(a.srtPnLProjected(), 0, "reconciled");
    }

    function test_DYSSeniorRoundTripProjection() public {
        uint256 srtBefore = a.srtBaseNav();
        uint256 received = _roundTrip(bob, ROUND_TRIP);
        assertApproxEqAbs(received, ROUND_TRIP, 1e6, "round trip returns the capital");
        assertApproxEqAbs(a.srtBaseNav(), srtBefore, 1e6, "tranche NAV unchanged");
        assertApproxEqAbs(a.srtPaidProjected(), 0, 1e6, "round trip has no net paid projection");
        assertApproxEqAbs(a.srtBoughtProjected(), 0, 1e6, "purchase credit cleared");
        console2.log("srtPaidProjected after one round trip", a.srtPaidProjected());

        _reconcileFlat();
        console2.log("srtBaseNav / jrtBaseNav after reconciliation", a.srtBaseNav(), a.jrtBaseNav());
        assertApproxEqRel(a.srtBaseNav(), 500e18, 0.001e18, "no unearned Senior gain");
        assertApproxEqRel(a.jrtBaseNav(), 500e18, 0.001e18, "Junior does not fund the round trip");
    }

    /// A second round trip must remain neutral.
    function test_DYSSeniorRoundTripProjection_Repeated() public {
        _roundTrip(bob, ROUND_TRIP);
        _roundTrip(bob, ROUND_TRIP);
        console2.log("srtPaidProjected after two round trips", a.srtPaidProjected());
        assertApproxEqAbs(a.srtPaidProjected(), 0, 1e6, "repeated round trips remain neutral");
        _reconcileFlat();
        assertApproxEqRel(a.jrtBaseNav(), 500e18, 0.001e18, "Junior retains its capital");
    }

    /// A new entry offsets projection paid to an incumbent exiting at the same price.
    function test_DYSSeniorRoundTripProjection_Churn() public {
        uint256 incumbentShares = srt.balanceOf(bob);
        _deposit(srt, carol, 262.5e18);
        vm.prank(bob);
        srt.redeem(incumbentShares / 2, bob, bob);
        assertApproxEqAbs(a.srtBaseNav(), 525e18, 1e6, "tranche NAV unchanged");
        assertApproxEqAbs(a.srtPaidProjected(), 0, 1e6, "entry premium offsets the exit");
        _reconcileFlat();
        assertApproxEqRel(a.jrtBaseNav(), 500e18, 0.001e18, "churn does not charge Junior");
    }

    /// Positive realized gains must also match the no-round-trip control.
    function test_DYSSeniorRoundTripProjection_RealizedGainSweep() public {
        uint256[4] memory gains = [uint256(10e18), 25e18, 50e18, 100e18];
        uint256[4] memory expectedLoss;
        for (uint256 i; i < gains.length; i++) {
            uint256 snap = vm.snapshotState();
            _setStrategyNav(strategy.totalAssets() + gains[i]);
            _poke();
            uint256 jrtControl = a.jrtBaseNav();
            vm.revertToState(snap);

            _roundTrip(bob, ROUND_TRIP);
            _setStrategyNav(strategy.totalAssets() + gains[i]);
            _poke();
            uint256 juniorLoss = jrtControl > a.jrtBaseNav() ? jrtControl - a.jrtBaseNav() : 0;
            vm.revertToState(snap);

            console2.log("realized gain / Junior loss vs no round trip", gains[i], juniorLoss);
            assertApproxEqAbs(juniorLoss, expectedLoss[i], 1e6, "Junior loss");
        }
    }

    /// Control: no round trip, Junior and Senior both end at 500
    function test_DYSSeniorRoundTripProjection_Control() public {
        _reconcileFlat();
        assertApproxEqAbs(a.srtBaseNav(), 500e18, 1e15, "Senior 500");
        assertApproxEqAbs(a.jrtBaseNav(), 500e18, 1e15, "Junior 500");
    }

    /// A round trip remains unprofitable with a 5 bps exit fee, half retained in the tranche.
    function test_DYSSeniorRoundTripProjection_NetOfExitFee() public {
        cdo.setTwoStepConfigManager(address(this));
        cdo.setExitFees(0, 0.0005e18);
        a.setFeeRetentionBps(0, 0.5e18);

        uint256 received = _roundTrip(bob, ROUND_TRIP);
        _reconcileFlat();
        uint256 srtValue = srt.previewRedeem(srt.balanceOf(bob));
        int256 net = int256(srtValue + received) - int256(ROUND_TRIP) - int256(500e18);
        console2.log("exit fee paid", ROUND_TRIP - received);
        console2.log("Senior value after reconciliation", srtValue);
        console2.logInt(net);
        assertLe(net, 0, "fees cannot turn the round trip into a profit");
    }
}

/// @notice The same regression across MTM pullback and reconciliation.
contract MTMSeniorRoundTripProjectionTest is RoundTripStackBase {
    MTMAccounting accounting;

    /// Junior 1,000, Senior 1,000, MTM +100 after 1 h (Senior projection 25), optional Senior round trip of 9,225,
    /// MTM back to settled, then a flat reconciliation
    function _run(bool roundTrip)
        internal
        returns (uint256 srtAfterPullback, uint256 srtAfterReconcile)
    {
        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection,
        // conservativePrice, mtmProjection; 8% target, 10% base APR; 1 day MTM epoch
        accounting = MTMAccounting(
            _deploy(
                address(new MTMAccounting(18, false, true, false, true, false, true)),
                80_000_000_000,
                100_000_000_000,
                1 days
            )
        );
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        strategy.setTotalAssets(2100e18);
        _poke();
        assertEq(accounting.srtBaseNav(), 1025e18);

        if (roundTrip) {
            _roundTrip(bob, 9_225e18);
            assertApproxEqAbs(accounting.srtBaseNav(), 1025e18, 1e6, "tranche NAV unchanged");
            assertApproxEqAbs(accounting.srtPaidProjected(), 0, 1e6, "no net paid projection");
            assertApproxEqAbs(accounting.srtBoughtProjected(), 0, 1e6, "purchase credit cleared");
        }

        strategy.setTotalAssets(accounting.nav());
        _poke();
        srtAfterPullback = accounting.srtBaseNav();

        vm.warp(vm.getBlockTimestamp() + 1 days);
        strategy.setTotalAssets(accounting.nav() + 1);
        _poke();
        srtAfterReconcile = accounting.srtBaseNav();
        // NAV identity: jrt + srt + reserve + underwriter fee == nav + insuranceAmount
        assertEq(
            accounting.jrtBaseNav() + accounting.srtBaseNav() + accounting.reserveNav()
                + accounting.underwriterFeeNav(),
            accounting.nav() + accounting.insuranceAmount()
        );
    }

    function test_MTMSeniorRoundTripProjection() public {
        (uint256 srtPullback, uint256 srtSettled) = _run(true);
        console2.log("Senior after pullback / after reconciliation", srtPullback, srtSettled);
        assertApproxEqAbs(
            srtPullback, 1000e18, 1e6, "pullback does not charge Junior for a round trip"
        );
        assertApproxEqAbs(srtSettled, 1000e18, 1e6, "reconciliation remains neutral");
        assertApproxEqAbs(accounting.jrtBaseNav(), 1000e18, 1e6, "Junior retains its capital");
    }

    function test_MTMSeniorRoundTripProjection_Control() public {
        (uint256 srtPullback, uint256 srtSettled) = _run(false);
        assertEq(srtPullback, 1000e18, "no round trip: MTM pullback returns Senior to 1,000");
        assertEq(srtSettled, 1000e18);
    }
}
