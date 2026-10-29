// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISharesCooldown} from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
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
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";

interface IProjectedAccounting {
    function jrtNavProjected() external view returns (uint256);
    function jrtBaseNav() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
    function srtPnLProjected() external view returns (int256);
    function setRiskParameters(UD60x18 x, UD60x18 y, UD60x18 k) external;
}

/// @notice Real StrataCDO + two conservative-price Tranches + conservative APR-projection accounting
///         Junior 1,000, Senior 9,000, base APR 10%, Senior target 5%, 30 days of projection, then a 0.95 de-peg
/// @dev Auditor PoC adapted to assert the fix: Senior exits pay Junior backing without forfeiting Junior projection.
///      The signed getter also decodes DYS's nonnegative projection in this fixture.
abstract contract SeniorDepegExitJuniorUnwindBase is Test {
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    IProjectedAccounting accounting;
    MockAprPairFeed feed;
    MockMTMStrategy strategy;
    MockERC20 token;

    address alice = makeAddr("alice");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");

    uint256 constant SENIOR_EXIT = 4_500e18;
    uint256 constant ERIN_DEPOSIT = 1_000e18;

    // State read after the pre-exit refresh
    uint256 p0;
    uint256 b0;
    uint256 s0;
    uint256 ls0;
    uint256 jrtSupply0;

    function _deployAccounting() internal virtual returns (address);

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
        // 5% Senior target, 10% base APR (SD7x12)
        feed.updateRoundData(50_000_000_000, 100_000_000_000, uint64(block.timestamp));

        accounting = IProjectedAccounting(_deployAccounting());

        strategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        // Strategy NAV stays flat so every update is an APR projection, no reconciliation
        strategy.setEpochDuration(3650 days);

        acm.grantRole(PAUSER_ROLE, address(this));
        acm.grantRole(UPDATER_FEED_ROLE, address(this));
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, address(this));

        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        cdo.setValuationKeeper(address(this));
        // Risk premium 50%: aprSrt = max(5%, 10% * 0.5) = 5%
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));

        _deposit(jrt, alice, 1_000e18);
        _deposit(srt, dave, 9_000e18);

        // 30 days of APR projection, refreshed by an ordinary Junior deposit
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _deposit(jrt, carol, 1e18);
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

    function _snapshotPreExit() internal {
        p0 = accounting.jrtNavProjected();
        b0 = accounting.jrtBaseNav();
        s0 = accounting.srtBaseNav();
        ls0 = uint256(accounting.srtPnLProjected());
        jrtSupply0 = jrt.totalSupply();
    }

    function _seniorExit() internal {
        vm.prank(dave);
        srt.withdraw(SENIOR_EXIT, dave, dave);
    }

    /// Junior coverage and the Senior projection moved to Junior real NAV by the conservative Senior unwind
    function _expectedCoverageAndSeniorUnwind(uint256 price) internal view returns (uint256 coverage, uint256 srtUnwind) {
        coverage = SENIOR_EXIT - SENIOR_EXIT * price / 1e18;
        srtUnwind = (SENIOR_EXIT - coverage) * ls0 / (s0 - ls0);
    }

    function test_SeniorDepegExitPreservesJuniorProjection() public {
        cdo.setValuationPrice(0.95e18);
        _snapshotPreExit();
        assertGt(p0, b0, "Junior has live projection before the exit");

        (uint256 coverage, uint256 srtUnwind) = _expectedCoverageAndSeniorUnwind(0.95e18);
        uint256 jrtBaseAfterSrtUnwind = b0 + srtUnwind;
        // Counterfactual cut made by the old implementation without a Junior redemption.
        uint256 cut = coverage * (p0 - jrtBaseAfterSrtUnwind) / jrtBaseAfterSrtUnwind;

        _seniorExit();

        uint256 p1 = accounting.jrtNavProjected();
        assertEq(jrt.totalSupply(), jrtSupply0, "no Junior share redeemed");
        // The shared withdrawal split rounds each backing component down independently.
        assertApproxEqAbs(accounting.jrtBaseNav(), jrtBaseAfterSrtUnwind - coverage, 2, "Junior real NAV pays the coverage");
        // Only coverage leaves Junior projected NAV; no Junior shares were redeemed.
        assertApproxEqAbs(p0 - p1, coverage, 2, "only coverage leaves Junior projected NAV");
        assertGt(cut, 14e18, "fixture reproduces a material historical cut");
        console.log("Junior coverage", coverage);
        console.log("Junior projection before / cut", p0 - b0, cut);

        // Price the entrant independently from the projected NAV that should remain after coverage.
        uint256 seniorLiveAfter = s0 - srtUnwind - (SENIOR_EXIT - coverage);
        uint256 seniorTopUpAfter = seniorLiveAfter * 1e18 / 0.95e18 - seniorLiveAfter;
        uint256 fairJuniorLive = p0 - coverage - seniorTopUpAfter;
        uint256 jrtLive = cdo.totalAssets(address(jrt));
        assertApproxEqAbs(jrtLive, fairJuniorLive, 3, "live NAV contains no phantom projection cut");
        assertEq(cdo.totalAssetsDepositable(address(jrt)), jrtLive, "live NAV is the deposit price");
        uint256 supply = jrt.totalSupply();
        uint256 fairShares = ERIN_DEPOSIT * supply / fairJuniorLive;
        uint256 erinShares = _deposit(jrt, erin, ERIN_DEPOSIT);
        console.log("Erin shares minted / fair shares", erinShares, fairShares);
        assertApproxEqAbs(erinShares, fairShares, 10, "entrant cannot mint excess shares");
    }

    function test_ParSeniorExitKeepsJuniorProjection() public {
        _snapshotPreExit();
        _seniorExit();
        // At par the Senior exit leaves jrtAssetsOut at zero and live Junior NAV unchanged
        assertEq(accounting.jrtNavProjected(), p0, "live Junior NAV unchanged at par");
    }
}

contract SeniorDepegExitUnwindsJuniorProjectionDYSTest is SeniorDepegExitJuniorUnwindBase {
    function _deployAccounting() internal override returns (address) {
        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice
        return address(new ERC1967Proxy(
            address(new DYSAccounting(18, false, false, false, true, true)),
            abi.encodeWithSelector(
                DYSAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        ));
    }
}

contract SeniorDepegExitUnwindsJuniorProjectionMTMTest is SeniorDepegExitJuniorUnwindBase {
    function _deployAccounting() internal override returns (address) {
        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice, MTM projection off (APR projection)
        return address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, false, false, true, true, false)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        ));
    }
}
