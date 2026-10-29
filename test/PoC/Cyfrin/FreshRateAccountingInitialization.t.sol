// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISharesCooldown} from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UD60x18} from "@prb/math/src/ud60x18/ValueType.sol";
import {StrataCDO} from "../../../contracts/tranches/StrataCDO.sol";
import {Tranche} from "../../../contracts/tranches/Tranche.sol";
import {DYSAccounting} from "../../../contracts/tranches/DYSAccounting.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {IAccounting} from "../../../contracts/tranches/interfaces/IAccounting.sol";
import {IStrategy} from "../../../contracts/tranches/interfaces/IStrategy.sol";
import {ITranche} from "../../../contracts/tranches/interfaces/ITranche.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IAprPairFeed} from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";
import {MockERC20} from "../../../contracts/test/MockERC20.sol";
import {MockMTMStrategy} from "../../../contracts/test/MockMTMStrategy.sol";

contract InitializationRateStrategy is MockMTMStrategy {
    uint256 private rate;
    constructor(IERC20 token_) MockMTMStrategy(token_) {}
    function setRate(uint256 value) external { rate = value; }
    function getRate() external view override returns (uint256) { return rate; }
}

/// @notice f-114: real CDO initialization precedes configure, then the first reconciliation seeds the rate.
contract FreshRateAccountingInitializationTest is Test {
    MockERC20 token;
    StrataCDO cdo;
    Tranche junior;
    Tranche senior;
    DYSAccounting accounting; // Shared getter/setter ABI for DYS and MTM.
    InitializationRateStrategy strategy;

    function _tranche(AccessControlManager acm) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(address(new Tranche(true)),
            abi.encodeWithSelector(Tranche.initialize.selector, address(this), address(acm),
                "Tranche", "TR", IERC20(address(token)), IStrataCDO(address(cdo))))));
    }

    function _deploy(uint8 mode) internal {
        vm.warp(10 days);
        token = new MockERC20("BASE", 18);
        AccessControlManager acm = new AccessControlManager(address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        acm.grantRole(keccak256("PAUSER_ROLE"), address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(address(new StrataCDO(token, ISharesCooldown(address(0)))),
            abi.encodeCall(StrataCDO.initialize, (address(this), address(acm))))));
        assertEq(address(cdo.strategy()), address(0));
        address implementation = mode == 0
            ? address(new DYSAccounting(18, false, true, true, false, true))
            : address(new MTMAccounting(18, false, true, true, false, true, mode == 2));
        accounting = DYSAccounting(address(new ERC1967Proxy(implementation,
            abi.encodeCall(DYSAccounting.initialize,
                (address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(0)))))));
        assertEq(accounting.strategyRate(), 0, "initialization succeeds before strategy exists");
        junior = _tranche(acm);
        senior = _tranche(acm);
        strategy = InitializationRateStrategy(address(new ERC1967Proxy(
            address(new InitializationRateStrategy(IERC20(address(token)))),
            abi.encodeCall(MockMTMStrategy.initialize,
                (address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0))))));
        strategy.setRate(1e18);
        // The mock exposes fresh NAV through different scheduling rules for DYS and MTM.
        strategy.setEpochDuration(mode == 0 ? 9 days : 1 days);
        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strategy)), ITranche(address(junior)), ITranche(address(senior)));
        cdo.setActionStates(address(0), true, true);
    }

    function _deposit(Tranche tranche, uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(tranche), amount);
        tranche.deposit(amount, address(this));
    }

    function _assertFirstFlow(uint8 mode, bool delayed) internal {
        _deploy(mode);
        if (delayed) {
            vm.warp(block.timestamp + 5 days);
        }
        strategy.setRate(1.5e18);
        uint256 initialEpochStart = accounting.epochStart();
        _deposit(junior, 500e18);
        assertEq(accounting.strategyRate(), 0, "deposits do not seed the rate");
        assertEq(accounting.epochStart(), initialEpochStart);
        _deposit(senior, 500e18);
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        assertEq(accounting.srtBaseNav(), 500e18);

        vm.warp(block.timestamp + 1 days + 1);
        strategy.setRate(1.65e18);
        strategy.setTotalAssets(1200e18);
        junior.burnSharesAsFee(0, address(this));
        assertApproxEqAbs(accounting.srtBaseNav(), 550e18, 1, "first epoch uses proportional allocation");
        assertEq(accounting.strategyRate(), 1.65e18);
        assertEq(accounting.epochStart(), block.timestamp);

        vm.warp(block.timestamp + 1 days + 1);
        strategy.setRate(1.98e18);
        strategy.setTotalAssets(1300e18);
        junior.burnSharesAsFee(0, address(this));
        assertApproxEqAbs(accounting.srtBaseNav(), 605e18, 1, "next epoch uses 20% rate growth at 50% premium");
        assertEq(accounting.strategyRate(), 1.98e18);
    }

    function _assertZeroRateFirstFlow(uint8 mode) internal {
        _deploy(mode);
        strategy.setRate(0);
        _deposit(junior, 500e18);
        _deposit(senior, 500e18);
        assertEq(accounting.strategyRate(), 0);
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        vm.warp(block.timestamp + 1 days + 1);
        strategy.setRate(1.5e18);
        strategy.setTotalAssets(1100e18);
        junior.burnSharesAsFee(0, address(this));
        assertEq(accounting.srtBaseNav(), 525e18, "funded zero-rate interval keeps f-53 proportional allocation");
        assertEq(accounting.strategyRate(), 1.5e18);
    }

    function test_DYSSameBlockFirstDeposit() public { _assertFirstFlow(0, false); }
    function test_MTMSameBlockFirstDeposit() public { _assertFirstFlow(1, false); }
    function test_MTMLiveSameBlockFirstDeposit() public { _assertFirstFlow(2, false); }
    function test_DYSDelayedFirstDeposit() public { _assertFirstFlow(0, true); }
    function test_MTMDelayedFirstDeposit() public { _assertFirstFlow(1, true); }
    function test_MTMLiveDelayedFirstDeposit() public { _assertFirstFlow(2, true); }
    function test_DYSZeroRateFirstDeposit() public { _assertZeroRateFirstFlow(0); }
    function test_MTMZeroRateFirstDeposit() public { _assertZeroRateFirstFlow(1); }
    function test_MTMLiveZeroRateFirstDeposit() public { _assertZeroRateFirstFlow(2); }
}
