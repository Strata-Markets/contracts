// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
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

interface IProjectionAccounting {
    function srtBaseNav() external view returns (uint256);
    function jrtBaseNav() external view returns (uint256);
    function reserveNav() external view returns (uint256);
    function srtPnLProjected() external view returns (uint256);
    function setRiskParameters(UD60x18, UD60x18, UD60x18) external;
}

/// @notice Policy regression adapted from Cyfrin f-111: conservative exits retain pooled realized-yield allocation.
///         Scenario of test/tranches/accounting/dys/ConservativePrice.spec.ts 'redeem': Junior 1,000, Senior 1,000
///         split between an exiter and a holder, base APR 10%, risk premium 50%, half the Senior redeems after half
///         a year, the strategy earns 150 by year end. A conservative exit forfeits its 12.5 of projection, which
///         the exit books to Junior real NAV, but the exiter's asset-time stays in the Senior tracker, so the
///         reconciliation hands the exiter's share of the Senior PnL to the remaining Senior
abstract contract ConservativeSeniorExitPooledYieldBase is Test {
    uint256 constant HALF_YEAR = 15_768_000;

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    IProjectionAccounting accounting;
    MockAprPairFeed feed;
    MockMTMStrategy strategy;
    MockERC20 token;

    address alice = makeAddr("alice"); // Junior
    address bob = makeAddr("bob"); // exiting Senior
    address dave = makeAddr("dave"); // remaining Senior

    struct Outcome {
        uint256 exiterOut;
        uint256 remainingSenior;
        uint256 junior;
    }

    function _deployAccounting(bool conservative) internal virtual returns (address);

    function _epochDuration() internal pure virtual returns (uint256);

    function _deploy(bool conservative) internal {
        token = new MockERC20("BASE", 18);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(IERC20Metadata(address(token)), ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche("JRT", conservative);
        srt = _tranche("SRT", conservative);

        feed = new MockAprPairFeed();
        // 0% Senior target, 10% base APR (SD7x12), as in the client test
        feed.updateRoundData(0, 100_000_000_000, uint64(block.timestamp));

        accounting = IProjectionAccounting(_deployAccounting(conservative));

        strategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        strategy.setEpochDuration(_epochDuration());

        acm.grantRole(keccak256("PAUSER_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));

        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        // Risk premium 50%: Senior APR 5%
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
    }

    function _tranche(string memory name, bool conservative) internal returns (Tranche) {
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

    function _poke() internal {
        vm.prank(address(jrt));
        cdo.updateAccounting();
    }

    function _run(bool conservative) internal returns (Outcome memory o) {
        vm.warp(1_750_000_000);
        _deploy(conservative);
        _deposit(jrt, alice, 1_000e18);
        _deposit(srt, bob, 500e18);
        _deposit(srt, dave, 500e18);

        // Half a year: Senior projection 1,000 x 5% x 0.5 = 25
        vm.warp(vm.getBlockTimestamp() + HALF_YEAR);
        uint256 bobShares = srt.balanceOf(bob);
        vm.prank(bob);
        o.exiterOut = srt.redeem(bobShares, bob, bob);

        // Year end: the strategy earns 150, the poke reconciles
        vm.warp(vm.getBlockTimestamp() + HALF_YEAR);
        strategy.setTotalAssets(strategy.totalAssets() + 150e18);
        _poke();
        assertEq(accounting.srtPnLProjected(), 0, "reconciled");
        assertEq(accounting.reserveNav(), 0);

        o.remainingSenior = accounting.srtBaseNav();
        o.junior = accounting.jrtBaseNav();
        assertApproxEqAbs(srt.previewRedeem(srt.balanceOf(dave)), o.remainingSenior, 1e6, "dave holds all Senior NAV");
    }

    function test_ConservativeExitRetainsPooledRealizedYield() public {
        uint256 snap = vm.snapshotState();
        Outcome memory live = _run(false);
        vm.revertToState(snap);
        Outcome memory cons = _run(true);

        console.log("exiter out, live / conservative       ", live.exiterOut, cons.exiterOut);
        console.log("remaining Senior, live / conservative ", live.remainingSenior, cons.remainingSenior);
        console.log("Junior, live / conservative           ", live.junior, cons.junior);

        // Exits: live pays settled + projection, conservative pays settled and forfeits 12.5
        assertApproxEqAbs(live.exiterOut, 512.5e18, 0.001e18, "live exit takes its projection");
        assertApproxEqAbs(cons.exiterOut, 500e18, 0.001e18, "conservative exit forfeits it");
        uint256 forfeited = live.exiterOut - cons.exiterOut;

        // Client test values for the conservative run: Senior 500 x 1.0643, Junior 1,117.86
        assertApproxEqAbs(cons.remainingSenior, 532.142857e18, 0.001e18, "client asserted Senior NAV");
        assertApproxEqAbs(cons.junior, 1_117.857143e18, 0.001e18, "client asserted Junior NAV");

        // Of the 12.5 forfeited, Junior keeps 0.12 and the remaining Senior receives 12.38
        uint256 juniorGain = cons.junior - live.junior;
        uint256 seniorGain = cons.remainingSenior - live.remainingSenior;
        console.log("forfeited / Junior gain / remaining Senior gain", forfeited, juniorGain, seniorGain);
        assertApproxEqAbs(juniorGain + seniorGain, forfeited, 0.001e18);
        assertApproxEqAbs(juniorGain, 0.115207e18, 0.001e18, "Junior keeps under 1% of the forfeiture");
        assertApproxEqAbs(seniorGain, 12.384793e18, 0.001e18, "remaining Senior receives over 99%");
    }

    /// A sole Senior keeps 0.1 shares when it exits, and the dust collects the exiter's share of the Senior PnL at reconciliation
    function test_ResidualPositionReceivesRealizedSeniorYield() public {
        vm.warp(1_750_000_000);
        _deploy(true);
        _deposit(jrt, alice, 1_000e18);
        _deposit(srt, bob, 1_000e18);

        vm.warp(vm.getBlockTimestamp() + HALF_YEAR);
        assertApproxEqAbs(cdo.pricePerShare(address(srt)), 1.025e18, 0.0001e18, "live price carries 25 of projection");
        vm.prank(bob);
        uint256 out = srt.redeem(999.9e18, bob, bob);
        assertApproxEqAbs(out, 999.9e18, 0.001e18, "exit forfeits the projection");

        vm.warp(vm.getBlockTimestamp() + HALF_YEAR);
        strategy.setTotalAssets(strategy.totalAssets() + 150e18);
        _poke();

        uint256 dust = srt.previewRedeem(srt.balanceOf(bob));
        console.log("exit / dust value", out, dust);
        assertApproxEqAbs(dust, 25.1e18, 0.01e18, "0.1 shares hold 25.1");
        assertApproxEqAbs(out + dust, 1_025e18, 0.01e18, "exiter ends with the live-priced exit value");
        assertApproxEqAbs(accounting.jrtBaseNav(), 1_125e18, 0.01e18, "Junior gets 125 of the 150");
    }
}

contract ConservativeSeniorExitPooledYieldDYSTest is ConservativeSeniorExitPooledYieldBase {
    function _deployAccounting(bool conservative) internal override returns (address) {
        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection, conservativePrice
        return address(new ERC1967Proxy(
            address(new DYSAccounting(18, false, false, false, true, conservative)),
            abi.encodeWithSelector(
                DYSAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        ));
    }

    function _epochDuration() internal pure override returns (uint256) {
        // MockMTMStrategy returns its fresh NAV to DYS while inside this window
        return 3650 days;
    }
}

contract ConservativeSeniorExitPooledYieldMTMTest is ConservativeSeniorExitPooledYieldBase {
    function _deployAccounting(bool conservative) internal override returns (address) {
        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection,
        // conservativePrice, mtmProjection
        return address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, false, false, true, conservative, false)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        ));
    }

    function _epochDuration() internal pure override returns (uint256) {
        // MockMTMStrategy reports its fresh NAV as navT1 on every snapshot
        return 0;
    }
}
