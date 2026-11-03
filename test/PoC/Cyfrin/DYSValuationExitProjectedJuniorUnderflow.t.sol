// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { RiskPremiumPower } from "../../../contracts/tranches/accounting/premium/RiskPremiumPower.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { IInsuranceMiddleware } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import { IInsuranceVault } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";
import { MockInsurancePool } from "../../symbiotic/mocks/MockInsurancePool.sol";

/// @notice Live pricing, Junior 1,000 and Senior 1,000, flat strategy NAV, zero base APR, 10% Senior target,
///         constant 50% risk premium and a 20% underwriter fee share. A year of APR projection leaves projected
///         Junior 10 below real Junior (the deferred expected underwriter fee). A de-peg to 0.5 with an exhausted
///         insurance pool must use projected Junior backing for both pricing and the withdrawal split.
abstract contract ValuationExitProjectedJuniorBase is Test {
    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    DYSAccounting accounting; // MTMAccounting exposes the same getters and setters used here
    MockAprPairFeed feed;
    MockMTMStrategy strategy;
    MockERC20 token;
    MockInsurancePool pool;

    address alice = makeAddr("alice"); // Junior
    address bob = makeAddr("bob"); // sole Senior

    uint256 constant TOL = 0.001e18;

    function _implementation() internal virtual returns (address);
    function _strategyEpoch() internal pure virtual returns (uint256);

    function _setUpDepeg(uint256 underwriterFeeBps) internal {
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
        // 10% Senior target, zero base APR (SD7x12)
        feed.updateRoundData(100_000_000_000, 0, uint64(block.timestamp));
        accounting = DYSAccounting(address(new ERC1967Proxy(
            _implementation(),
            abi.encodeWithSelector(
                DYSAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        )));

        strategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        strategy.setEpochDuration(_strategyEpoch());

        acm.grantRole(keccak256("PAUSER_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        // Constant 50% risk premium: aprSrt = max(10%, 0) = 10%
        accounting.setRiskModel(new RiskPremiumPower(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18)));

        _deposit(jrt, alice, 1_000e18);
        _deposit(srt, bob, 1_000e18);

        // Symbiotic market whose pool has no capacity left; the middleware relays the underwriter fee share
        pool = new MockInsurancePool();
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(0)));
        if (underwriterFeeBps > 0) {
            vm.prank(address(pool));
            cdo.setUnderwriterFeeBps(underwriterFeeBps);
        }
        cdo.setValuationKeeper(address(this));

        // One year of projection with no strategy NAV change, then a de-peg to 0.5 with zero grace period
        vm.warp(vm.getBlockTimestamp() + 365 days);
        cdo.setValuationPrice(0.5e18);
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
}

contract DYSValuationExitProjectedJuniorUnderflowTest is ValuationExitProjectedJuniorBase {
    function _implementation() internal override returns (address) {
        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice
        return address(new DYSAccounting(18, false, false, false, false, false));
    }

    function _strategyEpoch() internal pure override returns (uint256) { return 30 days; }

    function test_DYSValuationExitPreservesDeferredFee() public {
        _setUpDepeg(0.2e18);

        uint256 jrtProjected = accounting.jrtNavProjected();
        uint256 jrtReal = accounting.jrtBaseNav();
        uint256 srtNav = accounting.srtBaseNav();
        // Gross Senior gain 100 debited from projected Junior, net gain 90 from real Junior
        assertApproxEqAbs(jrtProjected, 900e18, TOL, "projected Junior excludes the expected fee");
        assertApproxEqAbs(jrtReal, 910e18, TOL, "real Junior still holds the expected fee");
        assertApproxEqAbs(srtNav, 1_090e18, TOL, "Senior NAV carries the net projection");
        assertEq(accounting.insuranceAmount(), 0, "exhausted pool covers nothing");

        // Senior is priced with projected Junior backing: 1,090 + 899
        assertApproxEqAbs(cdo.totalAssets(address(srt)), 1_989e18, TOL, "live Senior effective NAV");

        uint256 amount = srt.maxWithdraw(bob) - 1e18;
        assertGt(amount, 1_987e18, "the withdrawal is within the advertised maximum");
        uint256 juniorDebit = amount * (jrtProjected - 1e18) / (srtNav + jrtProjected - 1e18);
        uint256 deferredFee = jrtReal - jrtProjected;

        vm.prank(bob);
        srt.withdraw(amount, bob, bob);
        assertEq(token.balanceOf(bob), amount, "Senior exit paid");
        assertEq(accounting.jrtNavProjected(), jrtProjected - juniorDebit, "projected backing debited");
        assertEq(accounting.jrtBaseNav(), jrtReal - juniorDebit, "real backing debited");
        assertEq(accounting.jrtBaseNav() - accounting.jrtNavProjected(), deferredFee, "deferred fee preserved");
        assertGe(accounting.jrtNavProjected(), 1e18, "Junior floor preserved");
    }

    /// Control: without the deferred fee both Junior balances agree and the same exit settles
    function test_PoC_DYSZeroFeeValuationExitSettles() public {
        _setUpDepeg(0);
        assertEq(accounting.jrtNavProjected(), accounting.jrtBaseNav(), "no fee divergence");

        uint256 amount = srt.maxWithdraw(bob) - 1e18;
        vm.prank(bob);
        srt.withdraw(amount, bob, bob);
        assertEq(token.balanceOf(bob), amount, "Senior exit paid");
    }
}

contract MTMValuationExitProjectedJuniorTest is ValuationExitProjectedJuniorBase {
    function _implementation() internal override returns (address) {
        // as above, plus mtmProjection off (APR projection)
        return address(new MTMAccounting(18, false, false, false, false, false, false));
    }

    /// @dev `totalAssetsSnapshot(nav, navTimestamp)` reads the live, unchanged value in any later block
    function _strategyEpoch() internal pure override returns (uint256) { return 0; }

    /// Control: MTM caps the Junior backing of the split by projected Junior, so the same exit settles
    function test_PoC_MTMValuationExitWithFeeSettles() public {
        _setUpDepeg(0.2e18);
        assertLt(accounting.jrtNavProjected(), accounting.jrtBaseNav(), "same fee divergence as DYS");

        uint256 amount = srt.maxWithdraw(bob) - 1e18;
        vm.prank(bob);
        srt.withdraw(amount, bob, bob);
        assertEq(token.balanceOf(bob), amount, "Senior exit paid");
    }
}
