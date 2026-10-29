// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import { IInsuranceMiddleware } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import { IInsuranceVault } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";
import { MockInsurancePool } from "../../symbiotic/mocks/MockInsurancePool.sol";

/// @dev Getters shared by DYSAccounting and MTMAccounting
interface IEpochAccounting {
    function nav() external view returns (uint256);
    function jrtBaseNav() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
    function srtPaidProjected() external view returns (uint256);
    function underwriterFeeNav() external view returns (uint256);
    function reserveNav() external view returns (uint256);
    function insuranceAmount() external view returns (uint256);
}

/// @notice Cyfrin's paid-projection fee PoC adapted into regressions for DYS and MTM.
/// Junior reimbursement must not be charged as Senior yield; actual gain remains feeable.
abstract contract PaidProjectionUnderwriterFeeBase is Test {
    uint256 constant DEP = 1_000_000e18;
    uint256 constant HALF = 500_000e18;

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    IEpochAccounting accounting;
    MockMTMStrategy strategy;
    MockERC20 token;
    MockInsurancePool pool;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    bool benchmarkProjection;

    function _accountingImpl() internal virtual returns (address impl, bytes4 initSelector);
    function _epochDuration() internal pure virtual returns (uint256);

    function setUp() public {
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
        feed.updateRoundData(100_000_000_000, 100_000_000_000, uint64(block.timestamp)); // 10% target, 10% base
        (address impl, bytes4 initSelector) = _accountingImpl();
        accounting = IEpochAccounting(address(new ERC1967Proxy(impl, abi.encodeWithSelector(
            initSelector, address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
        ))));

        strategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector, address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        strategy.setEpochDuration(_epochDuration());

        acm.grantRole(keccak256("PAUSER_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);

        pool = new MockInsurancePool();
        pool.setCapacity(10_000_000e18);
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(0)));

        _deposit(jrt, alice, DEP);
        _deposit(srt, bob, HALF);
        _deposit(srt, carol, HALF);
    }

    function _tranche(string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(false)),
            abi.encodeWithSelector(
                Tranche.initialize.selector, address(this), address(acm), name, name, IERC20(address(token)), IStrataCDO(address(cdo))
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

    function _setFeeBps(uint256 bps) internal {
        vm.prank(address(pool));
        cdo.setUnderwriterFeeBps(bps);
    }

    /// @dev Flat 7-day epoch: projection poke, optional Senior exit, then a 1 wei realized gain reconciles
    function _runEpoch(bool carolExits) internal returns (uint256 paid) {
        return _runEpoch(carolExits, 1);
    }

    function _runEpoch(bool carolExits, int256 gain) internal returns (uint256 paid) {
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(address(jrt));
        cdo.updateAccounting(); // permissionless refresh persists the APR projection

        if (carolExits) {
            uint256 shares = srt.balanceOf(carol);
            vm.prank(carol);
            srt.redeem(shares, carol, carol);
        }
        paid = accounting.srtPaidProjected();

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        strategy.setTotalAssets(uint256(int256(strategy.totalAssets()) + gain));
        vm.prank(address(jrt));
        cdo.updateAccounting(); // reconciliation
        assertEq(
            accounting.jrtBaseNav() + accounting.srtBaseNav() + accounting.reserveNav() + accounting.underwriterFeeNav(),
            accounting.nav() + accounting.insuranceAmount(),
            "NAV and claims conserved"
        );
    }

    function test_flatEpochDoesNotChargeFeeOnJuniorCover() public {
        _setFeeBps(0.1e18);
        uint256 paid = _runEpoch(true);
        uint256 fee = accounting.underwriterFeeNav();
        uint256 bobNav = accounting.srtBaseNav();


        assertGt(paid, 800e18, "the exited Senior took its share of the net projection");
        assertEq(fee, 0, "no fee on Junior reimbursement");
        assertApproxEqAbs(bobNav, HALF, 1e6, "remaining Senior principal restored");
        assertApproxEqAbs(accounting.jrtBaseNav(), DEP - paid, 1e6, "Junior pays only the net restitution");
    }

    function test_controlNoFee() public {
        _runEpoch(true);
        assertEq(accounting.underwriterFeeNav(), 0);
        assertApproxEqAbs(accounting.srtBaseNav(), HALF, 1e6, "no fee: remaining Senior back at principal");
    }

    function test_controlNoExit() public {
        _setFeeBps(0.1e18);
        _runEpoch(false);
        assertEq(accounting.underwriterFeeNav(), 0, "no exit: flat epoch books no fee");
        assertApproxEqAbs(accounting.srtBaseNav(), DEP, 1e6, "no exit: Seniors at principal");
    }
    function test_losingEpochDoesNotChargeFeeOnJuniorCover() public {
        _setFeeBps(0.1e18);
        uint256 paid = _runEpoch(true, -100e18);
        assertGt(paid, 800e18);
        assertEq(accounting.underwriterFeeNav(), 0);
        assertApproxEqAbs(accounting.srtBaseNav(), HALF, 1e6);
        assertApproxEqAbs(accounting.jrtBaseNav(), DEP - paid - 100e18, 1e6);
    }

    function test_partialGainFeeExcludesJuniorCover() public {
        _setFeeBps(0.1e18);
        uint256 snapshot = vm.snapshotState();
        uint256 paid = _runEpoch(true, 1000e18);
        uint256 partialFee = accounting.underwriterFeeNav();
        assertGt(partialFee, 0, "actual gain remains feeable");
        assertApproxEqAbs(accounting.srtBaseNav() + partialFee, HALF, 1e6, "Junior covers the gap to paid projection");
        assertApproxEqAbs(accounting.jrtBaseNav(), DEP + 1000e18 - paid, 1e6);

        vm.revertToState(snapshot);
        _runEpoch(true, 10_000e18);
        uint256 fullFee = accounting.underwriterFeeNav();
        assertGt(accounting.srtBaseNav(), HALF, "large gain fully covers paid projection");
        // Same asset-time and risk premium; ten times the realized gain yields ten times the fee.
        assertApproxEqAbs(partialFee, fullFee / 10, 10);
    }

    function test_benchmarkYieldRemainsFeeable() public {
        benchmarkProjection = true;
        setUp();
        _setFeeBps(0.1e18);
        _runEpoch(false);
        assertGt(accounting.underwriterFeeNav(), 0);
        assertGt(accounting.srtBaseNav(), DEP);
    }

}

contract PaidProjectionUnderwriterFeeDYSTest is PaidProjectionUnderwriterFeeBase {
    function _accountingImpl() internal override returns (address, bytes4) {
        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection,
        // conservativePrice (deployment defaults)
        return (address(new DYSAccounting(18, benchmarkProjection, false, false, true, false)), DYSAccounting.initialize.selector);
    }

    /// @dev Long window: the strategy NAV is read live, so only the test moves it
    function _epochDuration() internal pure override returns (uint256) { return 3650 days; }
}

contract PaidProjectionUnderwriterFeeMTMTest is PaidProjectionUnderwriterFeeBase {
    function _accountingImpl() internal override returns (address, bytes4) {
        // deployment defaults, including APR projection (useMTMProjection false)
        return (address(new MTMAccounting(18, benchmarkProjection, false, false, true, false, false)), MTMAccounting.initialize.selector);
    }

    /// @dev Zero window: the snapshot reports the live strategy NAV as settled
    function _epochDuration() internal pure override returns (uint256) { return 0; }
}

