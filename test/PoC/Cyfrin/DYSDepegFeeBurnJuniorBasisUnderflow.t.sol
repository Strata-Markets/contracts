// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RiskPremiumStatic} from "../../../contracts/tranches/accounting/premium/RiskPremiumStatic.sol";

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
contract DYSFeeBurnMockVault {
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
///      MockInsurancePool sets the underwriter fee; pool capacity 0 means no insurance claim is booked
contract DYSDepegFeeBurnJuniorBasisUnderflowTest is Test {
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
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(new DYSFeeBurnMockVault())));
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

    /// @dev Junior 60k, Senior 1M, Senior target 200%, base APR 0%, underwriter share 20%, 11 days of flat
    ///      strategy NAV (DYS stays in projection), then a de-peg to 0.5 with no pool capacity (no claim booked)
    function _setUpState() internal {
        _deploy(2_000_000_000_000, 0, 0, 0.2e18);
        _deposit(jrt, alice, 60_000e18);
        _deposit(srt, bob, 1_000_000e18);
        vm.warp(block.timestamp + 11 days);
        _poke();
        cdo.setValuationPrice(0.5e18);

        console.log("jrtBaseNav     ", accounting.jrtBaseNav());
        console.log("jrtNavProjected", accounting.jrtNavProjected());
        console.log("srtBaseNav     ", accounting.srtBaseNav());
        // Live Junior far below settled Junior, no claim open
        assertLt(accounting.jrtNavProjected(), accounting.jrtBaseNav(), "live Junior below settled Junior");
        assertEq(accounting.insuranceAmount(), 0, "no claim booked");
        // The de-peg forces 100% Senior fee retention
        assertEq(accounting.feeSrtRetentionBps(), 1e18, "forced 100% Senior retention");
    }

    /// @dev Regression from the auditor PoC: restoring reserve fees must not debit unavailable Junior backing.
    function test_RestoredRetentionFeeBurnUsesAvailableJuniorBacking() public {
        _setUpState();
        accounting.setFeeRetentionBps(1e18, 0.5e18);

        uint256 feeShares = srt.balanceOf(bob) / 200; // 0.5% of Senior shares.
        uint256 reserveBefore = accounting.reserveNav();
        uint256 seniorBefore = accounting.srtBaseNav();
        uint256 juniorBefore = accounting.jrtBaseNav();
        uint256 juniorProjectedBefore = accounting.jrtNavProjected();
        uint256 sharesBefore = srt.balanceOf(bob);
        assertEq(juniorProjectedBefore, 1e18, "projected Junior has no backing above its floor");
        assertGt(juniorBefore, juniorProjectedBefore, "settled Junior would overstate available backing");

        vm.prank(bob);
        uint256 feeAssets = srt.burnSharesAsFee(feeShares, bob);
        uint256 reserveFee = feeAssets / 2;
        assertGt(reserveFee, 0, "reserve allocation exercised");
        assertEq(accounting.reserveNav(), reserveBefore + reserveFee, "half of the fee reaches reserve");
        assertEq(accounting.srtBaseNav(), seniorBefore - reserveFee, "Senior funds the reserve fee");
        assertEq(accounting.jrtBaseNav(), juniorBefore, "no settled Junior backing consumed");
        assertEq(accounting.jrtNavProjected(), juniorProjectedBefore, "projected Junior floor preserved");
        assertEq(srt.balanceOf(bob), sharesBefore - feeShares, "fee shares burned");
    }

    /// Control: with the default forced 100% retention nothing goes to the reserve and the same burn passes
    function test_ForcedRetentionFeeBurnPasses() public {
        _setUpState();
        uint256 feeShares = srt.balanceOf(bob) / 200;
        uint256 reserve0 = accounting.reserveNav();
        vm.prank(bob);
        srt.burnSharesAsFee(feeShares, bob);
        assertEq(accounting.reserveNav(), reserve0, "whole fee retained");
    }
}
