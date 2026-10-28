// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";

import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { DiscreteAccounting } from "../../../contracts/tranches/DiscreteAccounting.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { InsuranceMiddleware } from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { InsuranceVault } from "../../../contracts/tranches/symbiotic/InsuranceVault.sol";
import { IInsuranceMiddleware } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import { IInsuranceVault } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import { IStrataAccounting } from "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";
import { MockOracleAdapter } from "../../../contracts/test/MockOracleAdapter.sol";
import { MockAppAdapter } from "../../symbiotic/NetworkMiddleware.t.sol";

interface ISelfFundAccounting {
    function srtFundNav() external view returns (uint256);
    function srtInsuranceFundNav() external view returns (uint256);
    function insuranceAmount() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
    function jrtBaseNav() external view returns (uint256);
    function reserveNav() external view returns (uint256);
    function setReserveBps(uint256 bps) external;
    function setRiskParameters(UD60x18, UD60x18, UD60x18) external;
    function onAprChanged() external;
}

/// @notice Regression adapted from the auditor's stale self-fund resync PoC.
///         Recovery must use capped self-funding when sizing retained insurance, preserving existing credit.
/// @dev Real StrataCDO, Tranches, accounting variant, InsuranceMiddleware and InsuranceVault. The strategy,
///      the Symbiotic AppAdapter and the collateral oracle ($1) are the repo mocks
abstract contract StaleSelfFundResyncReslashesCreditBase is Test {
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");

    uint256 constant ONE_ASSET = 1e18;
    uint256 constant SLASHABLE = 1_000_000e18;
    uint256 constant FIRST_CLAIM = 100e18;
    uint256 constant RESERVE_CREDIT = 1_000e18;
    uint128 constant DEPEG_PRICE = 0.4e18;
    uint128 constant RECOVERY_PRICE = 0.45e18;

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    ISelfFundAccounting accounting;
    MockAprPairFeed feed;
    MockMTMStrategy strategy;
    MockERC20 token;
    MockERC20 collateral;
    MockAppAdapter adapter;
    InsuranceMiddleware middleware;
    InsuranceVault vault;

    address alice = makeAddr("alice"); // Junior
    address bob = makeAddr("bob"); // Senior
    address keeper = makeAddr("keeper"); // UPDATER_FEED_ROLE and valuation keeper
    address multisig = makeAddr("multisig"); // RESERVE_MANAGER_ROLE

    uint256 creditBefore;
    uint256 slashedBefore;
    uint256 fundBefore;

    function _deployAccounting() internal virtual returns (address);

    function _epochDuration() internal pure virtual returns (uint256);

    function setUp() public {
        vm.warp(1_750_000_000);
        _deployMarket();
        _deployInsurance();

        // A larger market earns 20% and most holders leave at par: Junior 1,000, Senior 1,000, reserve 1,000
        _deposit(jrt, alice, 25_000e18);
        _deposit(srt, bob, 25_000e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        token.mint(address(strategy), 10_000e18);
        strategy.setTotalAssets(strategy.totalAssets() + 10_000e18);
        _sync();
        _exitDownTo(srt, bob, accounting.srtBaseNav());
        _exitDownTo(jrt, alice, accounting.jrtBaseNav());

        assertApproxEqAbs(accounting.jrtBaseNav(), 1_000e18, 1e6, "Junior 1000");
        assertApproxEqAbs(accounting.srtBaseNav(), 1_000e18, 1e6, "Senior 1000");
        assertEq(accounting.reserveNav(), RESERVE_CREDIT, "reserve 1000");
    }

    function _deployMarket() internal {
        token = new MockERC20("BASE", 18);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(IERC20Metadata(address(token)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche("JRT");
        srt = _tranche("SRT");

        feed = new MockAprPairFeed();
        feed.updateRoundData(0, 0, uint64(block.timestamp));

        acm.grantRole(PAUSER_ROLE, address(this));
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, address(this));
        acm.grantRole(UPDATER_FEED_ROLE, keeper);
        acm.grantRole(RESERVE_MANAGER_ROLE, multisig);

        accounting = ISelfFundAccounting(_deployAccounting());

        strategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        strategy.setEpochDuration(_epochDuration());

        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        cdo.setValuationKeeper(keeper);
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        accounting.setReserveBps(0.1e18);
    }

    function _deployInsurance() internal {
        collateral = new MockERC20("COLL", 18);
        adapter = new MockAppAdapter(address(collateral));
        adapter.setSlashable(SLASHABLE);
        MockOracleAdapter oracle = new MockOracleAdapter();
        middleware = InsuranceMiddleware(address(new ERC1967Proxy(
            address(new InsuranceMiddleware(address(adapter))),
            abi.encodeCall(InsuranceMiddleware.initialize, (address(this), address(acm), address(oracle)))
        )));
        middleware.setMarket(address(cdo), IStrataAccounting(address(accounting)), address(token), 0, true);
        vault = InsuranceVault(address(new ERC1967Proxy(
            address(new InsuranceVault()),
            abi.encodeCall(InsuranceVault.initialize, (address(this), address(acm), IStrataCDO(address(cdo)), address(new MockERC20("USDC", 6))))
        )));
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(middleware)), IInsuranceVault(address(vault)));
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

    function _exitDownTo(Tranche t, address user, uint256 nav) internal {
        uint256 amount = nav - 1_000e18;
        vm.prank(user);
        t.withdraw(amount, user, user);
    }

    function _sync() internal {
        vm.prank(keeper);
        accounting.onAprChanged();
    }

    function _push(uint128 price) internal {
        vm.prank(keeper);
        cdo.setValuationPrice(price);
    }

    function _totalSlashed() internal view returns (uint256 total) {
        (,, total,,,) = middleware.markets(address(cdo));
    }

    /// @dev De-peg to 0.4 with only $40 of stake (100 base tokens of coverage), optional reserve credit to Senior at 0.4, stake topped up afterwards
    function _setupState(bool reserveCredit) internal {
        adapter.setSlashable(FIRST_CLAIM * DEPEG_PRICE / 1e18);
        _push(DEPEG_PRICE);
        assertEq(accounting.srtInsuranceFundNav(), FIRST_CLAIM, "stake caps the first credit at 100");

        if (reserveCredit) {
            // The reserve manager credits 1000 of reserve to Senior at 0.4, it self-funds 1000 x 0.6 / 0.4
            vm.prank(multisig);
            cdo.distributeReserve(0, RESERVE_CREDIT);
            assertApproxEqAbs(accounting.srtFundNav(), 1_500e18, 1, "self-fund booked at 0.4");
        }

        // Underwriters add stake, enough for any correct top-up
        adapter.setSlashable(SLASHABLE);

        creditBefore = accounting.srtInsuranceFundNav();
        slashedBefore = _totalSlashed();
        fundBefore = accounting.srtFundNav();
    }

    /// @dev Remaining credit need at 0.45 for 1000 of own principal and 999 of Junior headroom, the reserve
    ///      credit self-funds its own need exactly, so it is the same with or without it
    function _needAtRecovery() internal pure returns (uint256) {
        return Math.mulDiv(1_000e18, 1e18, RECOVERY_PRICE) - 1_000e18 - 999e18;
    }

    /// @dev Same need formula as the resync but measured against own principal only, with the self-fund
    ///      stored before the push, it shows the stale self-fund alone already zeroes the need
    function _needWithStaleFundOnPrincipal() internal view returns (uint256) {
        uint256 principal = accounting.srtBaseNav() - accounting.srtInsuranceFundNav();
        uint256 extra = Math.saturatingSub(Math.mulDiv(principal, 1e18, RECOVERY_PRICE), principal);
        extra = Math.saturatingSub(extra, fundBefore);
        return Math.saturatingSub(extra, accounting.jrtBaseNav() - ONE_ASSET);
    }

    function test_recoveryPreservesCreditAndSlashesOnlyNewNeed() public {
        _setupState(true);
        assertEq(_needWithStaleFundOnPrincipal(), 0, "stale self-fund alone hides the whole need");

        _push(RECOVERY_PRICE);

        uint256 need = _needAtRecovery();
        uint256 slashed = _totalSlashed() - slashedBefore;
        uint256 newClaim = need - creditBefore;
        uint256 correctSlash = newClaim * RECOVERY_PRICE / 1e18;

        assertEq(accounting.srtFundNav(), fundBefore, "entry self-funding retained; cap applied when sizing coverage");
        assertApproxEqAbs(accounting.insuranceAmount(), need, 1e6, "final claim equals the need");
        assertApproxEqAbs(newClaim, 123.222222222222222222e18, 1e6, "only 123.22 of the need is new");
        assertApproxEqAbs(slashed, correctSlash, 1e6, "only the additional coverage is slashed");
        assertApproxEqAbs(accounting.srtInsuranceFundNav(), creditBefore + newClaim, 1e6, "existing credit is retained");

        console.log("need at 0.45         ", need);
        console.log("credit held before   ", creditBefore);
        console.log("slashed on the push  ", slashed);
        console.log("correct slash        ", correctSlash);
    }

    /// Control: same credit, same need, no reserve credit, the push keeps the credit and slashes only the delta
    function test_PoC_StaleSelfFundResyncReslashesCredit_ControlNoSelfFund() public {
        _setupState(false);

        _push(RECOVERY_PRICE);

        uint256 need = _needAtRecovery();
        uint256 slashed = _totalSlashed() - slashedBefore;

        assertApproxEqAbs(accounting.insuranceAmount(), need, 1e6, "final claim equals the need");
        assertApproxEqAbs(slashed, (need - creditBefore) * RECOVERY_PRICE / 1e18, 1e6, "only the new claim is slashed at $0.45");
    }
}

contract StaleSelfFundResyncReslashesCreditAccountingTest is StaleSelfFundResyncReslashesCreditBase {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new Accounting(18)),
            abi.encodeWithSelector(
                Accounting.initialize.selector, address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        ));
    }

    function _epochDuration() internal pure override returns (uint256) {
        return 0;
    }
}

contract StaleSelfFundResyncReslashesCreditDiscreteTest is StaleSelfFundResyncReslashesCreditBase {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new DiscreteAccounting(18, false)),
            abi.encodeWithSelector(
                DiscreteAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        ));
    }

    function _epochDuration() internal pure override returns (uint256) {
        // MockMTMStrategy returns its fresh NAV while inside this window
        return 3650 days;
    }
}

contract StaleSelfFundResyncReslashesCreditDYSTest is StaleSelfFundResyncReslashesCreditBase {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new DYSAccounting(18, false, false, false, false, false)),
            abi.encodeWithSelector(
                DYSAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        ));
    }

    function _epochDuration() internal pure override returns (uint256) {
        // MockMTMStrategy returns its fresh NAV while inside this window
        return 3650 days;
    }
}

contract StaleSelfFundResyncReslashesCreditMTMTest is StaleSelfFundResyncReslashesCreditBase {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, false, false, false, false, false)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
            )
        ));
    }

    function _epochDuration() internal pure override returns (uint256) {
        // MockMTMStrategy reports its fresh NAV as navT1 on every snapshot
        return 0;
    }
}
