// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IErrors } from "../../../contracts/tranches/interfaces/IErrors.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { IERC20Cooldown, IUnstakeCooldown } from "../../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import { SaturnStrategy } from "../../../contracts/tranches/strategies/saturn/SaturnStrategy.sol";
import { IsUSDat } from "../../../contracts/tranches/strategies/saturn/IsUSDat.sol";
import { ERC20Cooldown } from "../../../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import { UnstakeCooldown } from "../../../contracts/tranches/base/cooldown/UnstakeCooldown.sol";
import { CooldownBase } from "../../../contracts/tranches/base/cooldown/CooldownBase.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockStakedUSDat } from "../../../contracts/test/MockStakedUSDat.sol";

/// @notice Full Strata stack (StrataCDO + two conservative-price Tranches + MTMAccounting) on the real
///         SaturnStrategy over MockStakedUSDat (USDat 6 decimals, no sUSDat deposit fee)
contract SaturnRoutePauseStackBase is Test {
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    MTMAccounting accounting;
    MockAprPairFeed feed;
    MockERC20 token;
    SaturnStrategy saturn;
    MockStakedUSDat sUSDat;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function _tranche(IERC20Metadata asset, string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(true)),
            abi.encodeWithSelector(
                Tranche.initialize.selector,
                address(this), address(acm), name, name, IERC20(address(asset)), IStrataCDO(address(cdo))
            )
        )));
    }

    function _deploySaturnStack() internal {
        token = new MockERC20("USDat", 6);
        sUSDat = new MockStakedUSDat(IERC20(address(token)), address(this));
        sUSDat.setDepositFeeBps(0);

        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(IERC20Metadata(address(token)), ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche(IERC20Metadata(address(token)), "JRT");
        srt = _tranche(IERC20Metadata(address(token)), "SRT");

        feed = new MockAprPairFeed();
        // 8% benchmark target, 10% base APR (SD7x12)
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp));

        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice, mtmProjection
        accounting = MTMAccounting(address(new ERC1967Proxy(
            address(new MTMAccounting(6, false, true, false, false, true, true)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector,
                address(this),
                address(acm),
                IStrataCDO(address(cdo)),
                IAprPairFeed(address(feed))
            )
        )));

        acm.grantRole(PAUSER_ROLE, address(this));
        acm.grantRole(UPDATER_FEED_ROLE, address(this));
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, address(this));
        acm.grantRole(RESERVE_MANAGER_ROLE, address(this));

        address erc20Cd = address(new ERC1967Proxy(
            address(new ERC20Cooldown()),
            abi.encodeWithSelector(CooldownBase.initialize.selector, address(this), address(acm))
        ));
        address unstakeCd = address(new ERC1967Proxy(
            address(new UnstakeCooldown()),
            abi.encodeWithSelector(CooldownBase.initialize.selector, address(this), address(acm))
        ));
        saturn = SaturnStrategy(address(new ERC1967Proxy(
            address(new SaturnStrategy(IsUSDat(address(sUSDat)))),
            abi.encodeWithSelector(
                SaturnStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)),
                IERC20Cooldown(erc20Cd), IUnstakeCooldown(unstakeCd)
            )
        )));
        acm.grantRole(keccak256("COOLDOWN_WORKER_ROLE"), address(saturn));

        cdo.configure(IAccounting(address(accounting)), IStrategy(address(saturn)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
    }

    function _deposit(Tranche t, address user, uint256 amount) internal returns (uint256 shares) {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        shares = t.deposit(amount, user);
        vm.stopPrank();
    }
}

/// @notice Saturn per-route pauses against the tranche max views: deposit pauses are now reported as zero
///         capacity, and token-aware withdrawal maxima respect each route pause
contract TrancheMaxViewsSaturnRoutePausesTest is SaturnRoutePauseStackBase {

    function setUp() public {
        _deploySaturnStack();
        _deposit(jrt, alice, 1000e6);
        _deposit(srt, bob, 1000e6);
    }

    /// Fixed: a paused Saturn deposit route reports no deposit capacity
    function test_PoC_StrategyDepositPauseReflected() public {
        saturn.setTokenConfig(address(token), SaturnStrategy.TTokenConfig({
            jrtDepositsPaused: true,
            jrtWithdrawalsPaused: false,
            srtDepositsPaused: true,
            srtWithdrawalsPaused: false
        }));

        assertEq(jrt.maxDeposit(carol), 0, "Junior reports no USDat deposit capacity");
        assertEq(srt.maxDeposit(carol), 0, "Senior reports no USDat deposit capacity");
        assertEq(jrt.maxMint(carol), 0);
        assertEq(jrt.maxDeposit(address(token), carol), 0);
    }

    /// Standard maxima remain token-independent; token-aware maxima reflect the paused route.
    function test_strategyWithdrawalPauseReflectedInTokenMaximum() public {
        saturn.setTokenConfig(address(token), SaturnStrategy.TTokenConfig({
            jrtDepositsPaused: false,
            jrtWithdrawalsPaused: true,
            srtDepositsPaused: false,
            srtWithdrawalsPaused: true
        }));

        assertGt(jrt.maxWithdraw(alice), 0, "standard maximum remains token-independent");
        assertGt(jrt.maxRedeem(alice), 0);
        assertEq(jrt.maxWithdraw(address(token), alice), 0);
        assertEq(srt.maxWithdraw(address(token), bob), 0);
        assertEq(saturn.maxWithdraw(address(jrt), address(token), 0), 0);
        assertEq(saturn.maxWithdraw(address(srt), address(token), 10e6), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            IErrors.WithdrawalRejectedByStrategy.selector, address(jrt), address(token)
        ));
        jrt.withdraw(address(token), 10e6, alice, alice);
    }

    function test_withdrawalPauseIsSpecificToTrancheAndToken() public {
        saturn.setTokenConfig(address(token), SaturnStrategy.TTokenConfig({
            jrtDepositsPaused: false,
            jrtWithdrawalsPaused: true,
            srtDepositsPaused: false,
            srtWithdrawalsPaused: false
        }));
        assertEq(jrt.maxWithdraw(address(token), alice), 0);
        assertGt(srt.maxWithdraw(address(token), bob), 0);
        assertGt(jrt.maxWithdraw(address(sUSDat), alice), 0);
        assertEq(saturn.maxWithdraw(address(srt), address(token), 0), type(uint256).max);
        assertEq(saturn.maxWithdraw(address(jrt), address(sUSDat), 0), type(uint256).max);

        // Pausing USDat must not block the enabled sUSDat exit route.
        uint256 tokensOut = sUSDat.convertToShares(10e6);
        vm.prank(alice);
        jrt.withdraw(address(sUSDat), tokensOut, alice, alice);
    }

    function test_stakedTokenWithdrawalPauseAndReopening() public {
        saturn.setTokenConfig(address(sUSDat), SaturnStrategy.TTokenConfig({
            jrtDepositsPaused: false,
            jrtWithdrawalsPaused: true,
            srtDepositsPaused: false,
            srtWithdrawalsPaused: true
        }));
        assertEq(jrt.maxWithdraw(address(sUSDat), alice), 0);
        assertEq(srt.maxWithdraw(address(sUSDat), bob), 0);
        assertGt(jrt.maxWithdraw(address(token), alice), 0);
        saturn.setTokenConfig(address(sUSDat), SaturnStrategy.TTokenConfig(false, false, false, false));
        assertGt(jrt.maxWithdraw(address(sUSDat), alice), 0);
        assertGt(srt.maxWithdraw(address(sUSDat), bob), 0);
    }

    function test_unsupportedWithdrawalRouteHasNoCapacity() public view {
        address unsupported = address(0x1234);
        assertEq(saturn.maxWithdraw(address(jrt), unsupported, 0), 0);
        assertEq(saturn.maxWithdraw(address(srt), unsupported, 1), 0);
        assertEq(jrt.maxWithdraw(unsupported, alice), 0);
        assertEq(srt.maxWithdraw(unsupported, bob), 0);
    }
}
