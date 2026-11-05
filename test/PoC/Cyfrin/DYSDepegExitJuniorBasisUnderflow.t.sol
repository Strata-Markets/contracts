// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
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

/// @dev Minimal funded vault mock standing in for the insurance vault: pays nothing and never reverts
contract DYSBasisMockVault {
    function coverageToken() external pure returns (address) { return address(0); }
    function coverageTokenDecimals() external pure returns (uint8) { return 18; }
    function fundedCoverage() external pure returns (uint256) { return type(uint128).max; }
    function surplusCoverage() external pure returns (uint256) { return 0; }
    function withdrawSurplus(uint256, address) external {}
    function payCoverage(uint256, address) external {}
    function recordFunding(address, uint256) external {}
}

/// @dev Full DYS stack with the deployment defaults of the live DYS markets:
///      DYSAccounting(18, false, true, false, true, false) i.e. non-conservative price, and Tranche(false)
///      MockMTMStrategy is used as a flat-NAV strategy: while its value does not change, DYS stays in projection
///      MockInsurancePool sets the underwriter fee; pool capacity 0 means no insurance credit is booked
import {RiskPremiumStatic} from "../../../contracts/tranches/accounting/premium/RiskPremiumStatic.sol";

contract DYSDepegExitJuniorBasisUnderflowTest is Test {
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    DYSAccounting accounting;
    MockAprPairFeed feed;
    MockERC20 token;
    MockMTMStrategy strat;
    MockInsurancePool pool;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    /// @param aprTarget SD7x12 (1e12 = 100%)
    /// @param aprBase SD7x12
    function _deploy(int64 aprTarget, int64 aprBase, uint256 poolCapacity, uint256 uwBps) internal {
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
        feed.updateRoundData(aprTarget, aprBase, uint64(block.timestamp));
        accounting = DYSAccounting(address(new ERC1967Proxy(
            address(new DYSAccounting(18, false, true, false, true, false)),
            abi.encodeWithSelector(
                DYSAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        )));
        acm.grantRole(PAUSER_ROLE, address(this));
        acm.grantRole(UPDATER_FEED_ROLE, address(this));
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, address(this));
        acm.grantRole(RESERVE_MANAGER_ROLE, address(this));

        strat = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        // Always serve the fresh strategy value; NAV stays flat unless the test changes it
        strat.setEpochDuration(3650 days);
        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strat)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        // Constant 50% risk premium
        accounting.setRiskModel(new RiskPremiumStatic(UD60x18.wrap(0.5e18)));
        cdo.setValuationKeeper(address(this));
        cdo.setTwoStepConfigManager(address(this));

        pool = new MockInsurancePool();
        pool.setCapacity(poolCapacity);
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(new DYSBasisMockVault())));
        if (uwBps > 0) {
            vm.prank(address(pool));
            cdo.setUnderwriterFeeBps(uwBps);
        }
        cdo.setManualUnderwriterFeeDistribution(true);
        cdo.setUnderwriterFeeRewardSafe(makeAddr("feeSafe"));
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

    function _deposit(Tranche t, address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        t.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Permissionless zero-share fee burn that triggers the accounting update
    function _poke() internal {
        address poker = makeAddr("poker");
        vm.prank(poker);
        jrt.burnSharesAsFee(0, poker);
    }

    /// @dev Junior 100k, bob and carol 450k Senior each, Senior target 8%, base APR 0%, underwriter share 10%,
    ///      one day of flat strategy NAV (DYS stays in projection), optionally followed by a de-peg to 0.85
    function _setUp1Day(uint256 poolCapacity, bool depeg) internal {
        _deploy(80_000_000_000, 0, poolCapacity, 0.1e18);
        _deposit(jrt, alice, 100_000e18);
        _deposit(srt, bob, 450_000e18);
        _deposit(srt, carol, 450_000e18);
        vm.warp(block.timestamp + 1 days);
        _poke();
        if (depeg) cdo.setValuationPrice(0.85e18);
    }

    /// One day of flat-NAV projection leaves live Junior (jrtNavProjected) below settled Junior (jrtBaseNav):
    /// projection debits live Junior by Senior's gross target gain but settled Junior only net of the expected
    /// underwriter fee, and a 0% base APR adds nothing back to live Junior
    function test_LiveJuniorBelowSettled() public {
        _setUp1Day(0, false);
        uint256 jb = accounting.jrtBaseNav();
        uint256 jp = accounting.jrtNavProjected();
        console.log("jrtBaseNav     ", jb);
        console.log("jrtNavProjected", jp);
        console.log("settled - live ", jb - jp);
        assertLt(jp, jb, "live Junior below settled Junior");
        assertApproxEqAbs(jb - jp, 9.86e18, 0.01e18, "gap ~9.86 tokens after 1 day");
    }

    /// @dev Junior is charged on live backing and the last Senior exits without underflow.
    function test_LastSeniorExitSucceeds() public {
        _setUp1Day(0, true);
        uint256 jb0 = accounting.jrtBaseNav();
        uint256 jp0 = accounting.jrtNavProjected();
        (, uint256 srtLive0,) = accounting.totalAssets();

        uint256 b = srt.balanceOf(bob);
        vm.prank(bob);
        uint256 outB = srt.redeem(b, bob, bob);
        uint256 juniorCharge = jb0 - accounting.jrtBaseNav();
        // Junior's part sized on live Junior headroom (live Senior effective NAV = srtBaseNav + jrtNavProjected - 1)
        uint256 liveConsistent = outB * (jp0 - 1e18) / srtLive0;
        console.log("bob paid                       ", outB);
        console.log("Junior charged (capped basis) ", juniorCharge);
        console.log("Junior charge on live basis    ", liveConsistent);
        console.log("Junior over-charge             ", juniorCharge - liveConsistent);
        assertEq(juniorCharge, liveConsistent, "Junior charge matches live backing");

        uint256 c = srt.balanceOf(carol);
        console.log("carol live value               ", srt.convertToAssets(c));
        // The full exit is advertised as available
        assertEq(srt.maxRedeem(carol), c, "maxRedeem advertises the full position");
        vm.prank(carol);
        assertGt(srt.redeem(c - 0.1e18, carol, carol), 0, "near-total exit succeeds without reconciliation");


    }

    /// @dev The same exit succeeds with an open claim; the vault mock isolates accounting arithmetic.
    function test_LastSeniorExitSucceedsInsured() public {
        _setUp1Day(10_000_000e18, true);
        console.log("insuranceAmount", accounting.insuranceAmount());
        assertGt(accounting.insuranceAmount(), 0, "claim open");

        uint256 b = srt.balanceOf(bob);
        vm.prank(bob);
        srt.redeem(b, bob, bob);

        uint256 c = srt.balanceOf(carol);
        vm.prank(carol);
        assertGt(srt.redeem(c - 0.1e18, carol, carol), 0, "near-total exit succeeds without reconciliation");
    }

    /// @dev Reconciliation is not required to unblock the exit.
    function test_ExitSucceedsBeforeAndAfterReconciliation() public {
        _setUp1Day(0, true);
        uint256 b = srt.balanceOf(bob);
        vm.prank(bob);
        srt.redeem(b, bob, bob);

        uint256 c = srt.balanceOf(carol);
        uint256 snap = vm.snapshotState();
        vm.prank(carol);
        assertGt(srt.redeem(c - 0.1e18, carol, carol), 0, "near-total exit succeeds without reconciliation");

        vm.revertToState(snap);

        // Strategy NAV moves, DYS reconciles on the next update
        strat.updateTotalAssets(strat.totalAssets() + 1e18);
        _poke();
        assertEq(accounting.jrtNavProjected(), accounting.jrtBaseNav(), "reconciled");

        vm.prank(carol);
        uint256 outC = srt.redeem(c - 0.1e18, carol, carol);
        console.log("carol exit after reconciliation", outC);
        assertGt(outC, 0, "near-total exit succeeds after reconciliation");
    }
}
