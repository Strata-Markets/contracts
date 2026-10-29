// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISharesCooldown} from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { console } from "forge-std/console.sol";
import { IErrors } from "../../../contracts/tranches/interfaces/IErrors.sol";
import { SaturnStrategy } from "../../../contracts/tranches/strategies/saturn/SaturnStrategy.sol";
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { IInsuranceMiddleware } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import { IInsuranceVault } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import { IERC20Cooldown, IUnstakeCooldown } from "../../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";
import { MockStakedUSDat } from "../../../contracts/test/MockStakedUSDat.sol";
import { IsUSDat } from "../../../contracts/tranches/strategies/saturn/IsUSDat.sol";
import { MockInsurancePool } from "../../symbiotic/mocks/MockInsurancePool.sol";
import { ERC20Cooldown } from "../../../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import { UnstakeCooldown } from "../../../contracts/tranches/base/cooldown/UnstakeCooldown.sol";
import { CooldownBase } from "../../../contracts/tranches/base/cooldown/CooldownBase.sol";

/// @notice Full Strata stack (StrataCDO + two conservative-price Tranches + MTMAccounting) on either
///         MockMTMStrategy (epoch snapshot: navT1 held at the accounting NAV, navMTM live) or the real
///         SaturnStrategy on MockStakedUSDat (inherited default snapshot)
contract MTMStackBase is Test {
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
    MockMTMStrategy mtmStrategy;
    SaturnStrategy saturn;
    MockStakedUSDat sUSDat;
    MockInsurancePool pool;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address feeSafe = makeAddr("feeSafe");

    struct AccFlags {
        bool benchmark;
        bool mtmProjection;
    }

    function _deployCore(IERC20Metadata asset, uint256 navDecimals, AccFlags memory f) internal {
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(asset, ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche(asset, "JRT");
        srt = _tranche(asset, "SRT");

        feed = new MockAprPairFeed();
        // 8% benchmark target, 10% base APR (SD7x12)
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp));

        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice, mtmProjection
        accounting = MTMAccounting(address(new ERC1967Proxy(
            address(new MTMAccounting(navDecimals, f.benchmark, true, false, false, true, f.mtmProjection)),
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
    }

    function _finishCore(IStrategy strategy_) internal {
        cdo.configure(IAccounting(address(accounting)), strategy_, ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
    }

    function _tranche(IERC20Metadata asset, string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(true)),
            abi.encodeWithSelector(
                Tranche.initialize.selector,
                address(this), address(acm), name, name, IERC20(address(asset)), IStrataCDO(address(cdo))
            )
        )));
    }

    /// @dev MockMTMStrategy stack, 18 decimals, epoch = 1 day
    function _deployMTMStack(AccFlags memory f) internal {
        token = new MockERC20("BASE", 18);
        _deployCore(IERC20Metadata(address(token)), 18, f);
        mtmStrategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0)
            )
        )));
        mtmStrategy.setEpochDuration(1 days);
        _finishCore(IStrategy(address(mtmStrategy)));
    }

    /// @dev SaturnStrategy on MockStakedUSDat (USDat 6 decimals, no sUSDat deposit fee)
    function _deploySaturnStack(AccFlags memory f) internal {
        token = new MockERC20("USDat", 6);
        sUSDat = new MockStakedUSDat(IERC20(address(token)), address(this));
        sUSDat.setDepositFeeBps(0);
        _deployCore(IERC20Metadata(address(token)), 6, f);
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
        _finishCore(IStrategy(address(saturn)));
    }

    function _enableInsurance(uint256 capacity, uint256 underwriterFeeBps) internal {
        pool = new MockInsurancePool();
        pool.setCapacity(capacity);
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(0)));
        if (underwriterFeeBps > 0) {
            vm.prank(address(pool));
            cdo.setUnderwriterFeeBps(underwriterFeeBps);
        }
        cdo.setManualUnderwriterFeeDistribution(true);
        cdo.setUnderwriterFeeRewardSafe(feeSafe);
    }

    function _deposit(Tranche t, address user, uint256 amount) internal returns (uint256 shares) {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        shares = t.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Stored identity gap: (jrt + srt + reserve + uwFee) - (nav + insuranceAmount)
    function _identityGap() internal view returns (int256) {
        uint256 lhs = accounting.jrtBaseNav() + accounting.srtBaseNav() + accounting.reserveNav()
            + accounting.underwriterFeeNav();
        uint256 rhs = accounting.nav() + accounting.insuranceAmount();
        return int256(lhs) - int256(rhs);
    }
}

/// @notice Strategy deposit-pause regressions adapted from Cyfrin f-76.
contract StrategyDepositMaximumTest is MTMStackBase {
    function _setupSaturn() internal {
        _deploySaturnStack(AccFlags({ benchmark: false, mtmProjection: true }));
        _deposit(jrt, alice, 1000e6);
        _deposit(srt, bob, 1000e6);
    }

    function test_basePauseReflectedInMaxDepositAndMint() public {
        _setupSaturn();
        saturn.setTokenConfig(address(token), SaturnStrategy.TTokenConfig(true, false, true, false));
        assertEq(jrt.maxDeposit(carol), 0);
        assertEq(srt.maxDeposit(carol), 0);
        assertEq(jrt.maxMint(carol), 0);
        assertEq(srt.maxMint(carol), 0);
        assertEq(jrt.maxDeposit(address(token), carol), 0);
        assertEq(srt.maxDeposit(address(token), carol), 0);
        assertEq(jrt.maxDeposit(address(sUSDat), carol), type(uint256).max);
        assertGt(srt.maxDeposit(address(sUSDat), carol), 0);
        token.mint(carol, 10e6);
        vm.startPrank(carol);
        token.approve(address(jrt), 10e6);
        vm.expectRevert(abi.encodeWithSelector(IErrors.DepositRejectedByStrategy.selector, address(jrt), address(token)));
        jrt.deposit(10e6, carol);
        vm.stopPrank();

        saturn.setTokenConfig(address(token), SaturnStrategy.TTokenConfig(false, false, false, false));
        assertEq(jrt.maxDeposit(carol), type(uint256).max);
        assertGt(srt.maxDeposit(carol), 0);
        _deposit(jrt, carol, 10e6);
    }

    function test_metaPauseIsTrancheAndTokenSpecific() public {
        _setupSaturn();
        saturn.setTokenConfig(address(sUSDat), SaturnStrategy.TTokenConfig(false, false, true, false));
        assertEq(srt.maxDeposit(address(sUSDat), carol), 0);
        assertEq(jrt.maxDeposit(address(sUSDat), carol), type(uint256).max);
        assertGt(srt.maxDeposit(carol), 0);
        assertGt(srt.maxMint(carol), 0);
        assertEq(saturn.maxDeposit(address(jrt), address(0xBAD), 0), 0);
        assertEq(jrt.maxDeposit(address(0xBAD), carol), 0);
    }

    function test_finiteLimitIsConvertedFromBaseToTokenUnits() public {
        _setupSaturn();
        vm.mockCall(address(saturn), abi.encodeWithSelector(IStrategy.maxDeposit.selector), abi.encode(uint256(42e6)));
        assertEq(jrt.maxDeposit(carol), 42e6);
        assertEq(srt.maxDeposit(carol), 42e6);
        assertEq(jrt.maxDeposit(address(sUSDat), carol), 42e18);
        assertEq(jrt.maxMint(carol), jrt.previewDeposit(42e6));
        _deposit(jrt, carol, 42e6);
    }

    function test_protocolPauseStillOverridesStrategyCapacity() public {
        _setupSaturn();
        cdo.setActionStates(address(jrt), false, true);
        assertEq(jrt.maxDeposit(carol), 0);
        assertEq(jrt.maxDeposit(address(sUSDat), carol), 0);
        assertGt(srt.maxDeposit(carol), 0);
    }
}
