// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UD60x18} from "@prb/math/src/ud60x18/ValueType.sol";
import {DYSAccounting} from "../../../contracts/tranches/DYSAccounting.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IStrategy} from "../../../contracts/tranches/interfaces/IStrategy.sol";
import {IAprPairFeed} from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";

interface IRateAccounting {
    function setRiskParameters(UD60x18 x, UD60x18 y, UD60x18 k) external;
    function updateBalanceFlow(uint256 jIn, uint256 jOut, uint256 sIn, uint256 sOut) external returns (uint256);
    function updateAccounting() external;
    function totalAssets() external view returns (uint256, uint256, uint256);
    function strategyRate() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
    function jrtBaseNav() external view returns (uint256);
    function initializeV3() external;
}

/// @notice f-53: a migrated non-rate proxy can reconcile after enabling rate mode with no starting rate.
/// @dev The test contract supplies the CDO/strategy boundary. Production accounting runs behind real proxies.
contract ZeroStrategyRateFallbackTest is Test {
    bytes32 constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    uint256 mockNav;
    uint256 mockRate;

    function strategy() external view returns (IStrategy) { return IStrategy(address(this)); }
    function getRate() external view returns (uint256) { return mockRate; }
    function totalStrategyAssets() external view returns (uint256) { return mockNav; }
    function totalStrategyAssets(uint256, uint256) external view returns (uint256) { return mockNav; }
    function totalStrategyAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        return (mockNav, block.timestamp, mockNav, block.timestamp);
    }

    // 0 = DYS, 1 = MTM without live projection, 2 = MTM with live projection.
    function _implementation(uint8 mode, bool rates) internal returns (address) {
        if (mode == 0) {
            return address(new DYSAccounting(18, false, true, rates, false, true));
        }
        return address(new MTMAccounting(18, false, true, rates, false, true, mode == 2));
    }

    function _deploy(uint8 mode) internal returns (IRateAccounting accounting) {
        mockNav = 0;
        AccessControlManager acm = new AccessControlManager(address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        accounting = IRateAccounting(address(new ERC1967Proxy(
            _implementation(mode, false),
            abi.encodeWithSelector(DYSAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(0)))
        )));
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        mockNav = 1000e18;
        accounting.updateBalanceFlow(500e18, 0, 500e18, 0);
    }

    function _upgraded(uint8 mode) internal returns (IRateAccounting accounting) {
        vm.warp(10 days);
        mockRate = 1e18;
        accounting = _deploy(mode);
        // Model an implementation upgrade without rerunning the already-consumed V3 initializer.
        vm.store(address(accounting), IMPLEMENTATION_SLOT, bytes32(uint256(uint160(_implementation(mode, true)))));
        assertEq(accounting.strategyRate(), 0);
        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        accounting.initializeV3();
    }

    function _assertFallbackAndResume(uint8 mode) internal {
        IRateAccounting accounting = _upgraded(mode);
        vm.warp(block.timestamp + 1 days);
        mockNav = 1100e18;
        mockRate = 1.2e18;
        (uint256 junior, uint256 senior,) = accounting.totalAssets();
        assertEq(senior, 525e18, "first epoch uses proportional allocation");
        assertEq(junior, 575e18);
        assertEq(accounting.strategyRate(), 0, "view does not seed storage");
        accounting.updateAccounting();
        assertEq(accounting.srtBaseNav(), senior);
        assertEq(accounting.strategyRate(), 1.2e18);

        vm.warp(block.timestamp + 1 days);
        mockNav = 1200e18;
        mockRate = 1.44e18;
        accounting.updateAccounting();
        // 525 * 20% rate growth * 50% Senior factor = 52.5, rather than proportional NAV gain.
        assertApproxEqAbs(accounting.srtBaseNav(), 577.5e18, 1);
        assertEq(accounting.strategyRate(), 1.44e18);
        assertEq(accounting.jrtBaseNav() + accounting.srtBaseNav(), mockNav);
    }

    function _assertZeroRatePersists(uint8 mode) internal {
        IRateAccounting accounting = _upgraded(mode);
        IRateAccounting proportional = _deploy(mode);
        mockRate = 0;
        vm.warp(block.timestamp + 1 days);
        mockNav = 900e18;
        accounting.updateAccounting();
        proportional.updateAccounting();
        assertEq(accounting.srtBaseNav(), proportional.srtBaseNav(), "same loss allocation and floor as proportional mode");
        assertEq(accounting.jrtBaseNav(), proportional.jrtBaseNav());
        uint256 seniorAfterLoss = accounting.srtBaseNav();
        assertEq(accounting.strategyRate(), 0);
        vm.warp(block.timestamp + 1 days);
        mockNav = 1000e18;
        accounting.updateAccounting();
        proportional.updateAccounting();
        assertEq(accounting.srtBaseNav(), proportional.srtBaseNav());
        assertEq(accounting.jrtBaseNav(), proportional.jrtBaseNav());
        assertGt(accounting.srtBaseNav(), seniorAfterLoss, "later epochs still reconcile with zero rate");
        assertEq(accounting.strategyRate(), 0);
        assertEq(accounting.jrtBaseNav() + accounting.srtBaseNav(), mockNav);
    }

    function test_DYSFallbackThenRateAllocation() public { _assertFallbackAndResume(0); }
    function test_MTMFallbackThenRateAllocation() public { _assertFallbackAndResume(1); }
    function test_MTMLiveFallbackThenRateAllocation() public { _assertFallbackAndResume(2); }
    function test_DYSLossAndRepeatedZeroRate() public { _assertZeroRatePersists(0); }
    function test_MTMLossAndRepeatedZeroRate() public { _assertZeroRatePersists(1); }
    function test_MTMLiveLossAndRepeatedZeroRate() public { _assertZeroRatePersists(2); }
}
