// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISharesCooldown} from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { IInsurancePool } from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
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
import { InsuranceVault } from "../../../contracts/tranches/symbiotic/InsuranceVault.sol";
import { MockInsurancePool } from "../../symbiotic/mocks/MockInsurancePool.sol";

interface IProjectionAccounting {
    function onAprChanged() external;
    function setRiskParameters(UD60x18, UD60x18, UD60x18) external;
    function nav() external view returns (uint256);
    function insuranceAmount() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
}

/// @notice Regression adapted from the auditor PoC: zero strategy NAV-time must not block accounting or flows.
/// @dev Full stack: StrataCDO + Tranches + MTMAccounting on MockMTMStrategy (1-day epochs), with a
///      MockInsurancePool that covers the Senior-bound loss
contract MTMZeroNetNavTimeDivByZeroTest is Test {
    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    IProjectionAccounting accounting;
    MockERC20 token;
    MockMTMStrategy strategy;
    InsuranceVault vault;

    function _deploy() internal {
        token = new MockERC20("BASE", 18);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(token, ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche("JRT");
        srt = _tranche("SRT");

        MockAprPairFeed feed = new MockAprPairFeed();
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp)); // 8% target, 10% base
        address impl = address(new MTMAccounting(18, false, true, false, false, true, true));
        accounting = IProjectionAccounting(address(new ERC1967Proxy(impl, abi.encodeWithSelector(
            MTMAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))
        ))));
        acm.grantRole(keccak256("PAUSER_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));

        strategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector, address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        strategy.setEpochDuration(1 days);
        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));

        MockInsurancePool pool = new MockInsurancePool();
        pool.setCapacity(type(uint128).max);
        vault = InsuranceVault(address(new ERC1967Proxy(
            address(new InsuranceVault()),
            abi.encodeCall(InsuranceVault.initialize, (address(this), address(acm), IStrataCDO(address(cdo)), address(token)))
        )));
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(vault)));
    }

    function _tranche(string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(true)),
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

    /// @dev Junior 1000 + Senior 1000, then a total strategy wipeout settled at the next epoch, covered by insurance
    function _wipeout() internal {
        _deploy();
        _deposit(jrt, makeAddr("alice"), 1000e18);
        _deposit(srt, makeAddr("bob"), 1000e18);
        strategy.setTotalAssets(2000e18);

        vm.warp(block.timestamp + 2 days);
        strategy.setTotalAssets(0);
        accounting.onAprChanged();
        assertEq(accounting.nav(), 0, "strategy wiped out");
        assertGt(accounting.insuranceAmount(), 0, "Senior-bound loss booked to insurance");
    }

    function test_MTMZeroNetNavTimeAllowsProjectionAndRecovery() public {
        _wipeout();
        uint256 claim = accounting.insuranceAmount();
        uint256 senior = accounting.srtBaseNav();
        vm.warp(block.timestamp + 1 hours);
        accounting.onAprChanged();
        assertEq(accounting.nav(), 0);
        assertEq(accounting.insuranceAmount(), claim);
        assertEq(accounting.srtBaseNav(), senior);

        vm.warp(block.timestamp + 2 days);
        strategy.setTotalAssets(500e18);
        accounting.onAprChanged();
        assertEq(accounting.nav(), 500e18);
        assertEq(accounting.insuranceAmount(), claim - 500e18, "recovery repays the claim first");
        assertEq(accounting.srtBaseNav(), senior, "no additional Senior PnL without strategy capital-time");
    }

    function test_MTMFundedSeniorExitAndRecapitalization() public {
        _wipeout();
        uint256 claim = accounting.insuranceAmount();
        acm.grantRole(keccak256("RESERVE_MANAGER_ROLE"), address(this));
        token.mint(address(this), claim);
        token.approve(address(cdo), claim);
        cdo.fundInsuranceClaim(address(token), claim);
        vm.warp(block.timestamp + 1 hours);

        address bob = makeAddr("bob");
        uint256 shares = srt.balanceOf(bob) / 2;
        // The claim includes Junior dust, but Senior receives at most its withdrawal amount.
        vm.prank(bob);
        uint256 redeemed = srt.redeem(shares, bob, bob);
        assertGt(redeemed, 0);
        assertEq(token.balanceOf(bob), redeemed, "funded insurance pays the exit");
        assertEq(vault.fundedCoverage(), claim - redeemed);
        assertEq(accounting.insuranceAmount(), claim - redeemed);
        assertEq(accounting.nav(), 0, "fully insured exit does not consume strategy assets");

        // The operator permits recapitalization below the normal Junior price threshold.
        cdo.setJrtShortfallPausePrice(0);
        // Restore Junior coverage before attempting a Senior deposit.
        _deposit(jrt, makeAddr("newJunior"), 100e18);
        _deposit(srt, makeAddr("newSenior"), 100e18);
        assertGt(srt.balanceOf(makeAddr("newSenior")), 0);
    }

}

/// @notice DYS recovery must reconcile even when the entire preceding interval had zero strategy assets.
/// @dev The test contract plays the CDO, the strategy and the APR feed
contract DYSZeroNetNavTimeDivByZeroTest is Test {
    DYSAccounting accounting;
    uint256 mockStrategyTvl;

    function totalStrategyAssets() external view returns (uint256) { return mockStrategyTvl; }
    function totalStrategyAssets(uint256, uint256) external view returns (uint256) { return mockStrategyTvl; }
    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound({ aprTarget: 80_000_000_000, aprBase: 100_000_000_000, updatedAt: uint64(block.timestamp), answeredInRound: 1 });
    }

    function test_DYSRecoveryRepaysClaim() public { _checkRecovery(500e18); }
    function test_DYSRecoveryBeyondClaimGoesToJunior() public { _checkRecovery(1500e18); }

    function _checkRecovery(uint256 recovery) internal {
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = DYSAccounting(address(new ERC1967Proxy(
            address(new DYSAccounting(18, false, false, false, true, false)),
            abi.encodeWithSelector(
                DYSAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        )));
        MockInsurancePool pool = new MockInsurancePool();
        pool.setCapacity(type(uint128).max);
        accounting.setInsurancePool(IInsurancePool(address(pool)));

        // Junior 1000 + Senior 1000, then a total strategy wipeout covered by insurance
        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
        vm.warp(block.timestamp + 1 days);
        mockStrategyTvl = 0;
        accounting.updateAccounting();
        assertEq(accounting.nav(), 0, "strategy wiped out");
        assertGt(accounting.insuranceAmount(), 0, "Senior-bound loss booked to insurance");

        uint256 claim = accounting.insuranceAmount();
        uint256 senior = accounting.srtBaseNav();
        uint256 junior = accounting.jrtBaseNav();
        vm.warp(block.timestamp + 1 days);
        mockStrategyTvl = recovery;
        accounting.updateAccounting();
        uint256 repaid = recovery < claim ? recovery : claim;
        assertEq(accounting.nav(), recovery);
        assertEq(accounting.insuranceAmount(), claim - repaid);
        assertEq(accounting.srtBaseNav(), senior);
        assertEq(accounting.jrtBaseNav(), junior + recovery - repaid);

    }

    /// A dust recovery must not freeze the market after an elapsed zero-NAV interval.
    function test_DYSOneWeiRecoveryDoesNotFreezeAccounting() public {
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = DYSAccounting(address(new ERC1967Proxy(
            address(new DYSAccounting(18, false, false, false, true, false)),
            abi.encodeWithSelector(
                DYSAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        )));
        MockInsurancePool pool = new MockInsurancePool();
        pool.setCapacity(type(uint128).max);
        accounting.setInsurancePool(IInsurancePool(address(pool)));

        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
        vm.warp(block.timestamp + 1 days);
        mockStrategyTvl = 0;
        accounting.updateAccounting();
        assertEq(accounting.nav(), 0, "strategy wiped out");
        assertEq(accounting.srtBaseNav(), 1000e18, "Senior held whole by the claim");
        assertEq(accounting.insuranceAmount(), 1001e18, "claim covers Senior and Junior's dust");

        // Still at 0: the update goes through
        vm.warp(block.timestamp + 1 days);
        accounting.updateAccounting();

        // 1 wei appears in the strategy: reconciliation reduces the claim by that amount
        vm.warp(block.timestamp + 1 days);
        mockStrategyTvl = 1;
        accounting.updateAccounting();
        assertEq(accounting.nav(), 1);
        assertEq(accounting.insuranceAmount(), 1001e18 - 1);
        assertEq(accounting.srtBaseNav(), 1000e18);
        accounting.updateAccounting();
    }
}
