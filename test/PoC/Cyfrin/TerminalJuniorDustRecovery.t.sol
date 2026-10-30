// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";
import {AccountingRecovery} from "../../../contracts/tranches/accounting/recovery/AccountingRecovery.sol";
import {DiscreteAccountingRecovery} from "../../../contracts/tranches/accounting/recovery/DiscreteAccountingRecovery.sol";
import {DYSAccountingRecovery} from "../../../contracts/tranches/accounting/recovery/DYSAccountingRecovery.sol";
import {MTMAccountingRecovery} from "../../../contracts/tranches/accounting/recovery/MTMAccountingRecovery.sol";
import {ITerminalLossAccounting, TerminalAccounting, TerminalDiscrete, TerminalDYS, TerminalMTM} from "./ProtectedFeesTerminalLoss.t.sol";
import {MockInsurancePool} from "../../symbiotic/mocks/MockInsurancePool.sol";
import {IInsurancePool} from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";

interface ITerminalRecovery {
    function settleTerminalJuniorDust() external returns (uint256);
}

contract TerminalJuniorDustRecoveryTest is Test {
    bytes32 constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    ITerminalLossAccounting accounting;
    ProxyAdmin admin;
    address original;
    address recovery;
    MockInsurancePool pool;
    uint256 strategyNav;
    uint256 settledNav;

    function totalStrategyAssets() external view returns (uint256) { return strategyNav; }
    function totalStrategyAssets(uint256, uint256) external view returns (uint256) { return settledNav; }
    function totalStrategyAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        return (settledNav, block.timestamp, strategyNav, block.timestamp);
    }

    function _deploy(uint256 variant) internal {
        vm.warp(1_750_000_000);
        strategyNav = 0;
        settledNav = 0;
        if (variant == 0) {
            original = address(new TerminalAccounting());
            recovery = address(new AccountingRecovery(18));
        } else if (variant == 1) {
            original = address(new TerminalDiscrete());
            recovery = address(new DiscreteAccountingRecovery(18, false));
        } else if (variant == 2) {
            original = address(new TerminalDYS());
            recovery = address(new DYSAccountingRecovery(18, false, false, false, false, false));
        } else {
            original = address(new TerminalMTM());
            recovery = address(new MTMAccountingRecovery(18, false, false, false, false, false, false));
        }
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = ITerminalLossAccounting(address(new TransparentUpgradeableProxy(original, address(this),
            abi.encodeWithSignature("initialize(address,address,address,address)", address(this), address(acm), address(this), address(0)))));
        admin = ProxyAdmin(address(uint160(uint256(vm.load(address(accounting), ADMIN_SLOT)))));
        pool = new MockInsurancePool();
        accounting.setInsurancePool(IInsurancePool(address(pool)));
        // The reported persisted terminal state: Junior dust exceeds the surviving Senior principal.
        accounting.seed(1e18, 499e18, 500e18, 500e18, 0, 0, 0, 0.4e18);
    }

    function _upgrade(address implementation) internal {
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(accounting)), implementation, "");
    }

    /// @dev Models three owner/Safe calls executed atomically; failure rolls back both upgrade and repair.
    function recoverAtomically() external returns (uint256 amount) {
        require(msg.sender == address(this));
        _upgrade(recovery);
        amount = ITerminalRecovery(address(accounting)).settleTerminalJuniorDust();
        _upgrade(original);
    }

    function test_allVariantsAtomicRecoveryAndRestore() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i);
            vm.expectCall(address(pool), abi.encodeCall(IInsurancePool.syncInsuranceClaim, (address(this))));
            assertEq(this.recoverAtomically(), 1e18);
            assertEq(address(uint160(uint256(vm.load(address(accounting), IMPLEMENTATION_SLOT)))), original);
            assertEq(accounting.jrtBaseNav(), 0);
            assertEq(accounting.srtBaseNav(), 499e18);
            assertEq(accounting.insuranceAmount(), 499e18);
            assertEq(accounting.srtInsuranceFundNav(), 499e18);
            assertEq(accounting.nav(), 0);
            // The recovery selector is absent after restoring the ordinary implementation.
            (bool success,) = address(accounting).call(abi.encodeCall(ITerminalRecovery.settleTerminalJuniorDust, ()));
            assertFalse(success);
            accounting.setValuationPrice(1e18);
            assertEq(accounting.jrtBaseNav(), 0);
            assertEq(accounting.srtBaseNav(), 0);
            assertEq(accounting.insuranceAmount(), 0);
            assertEq(accounting.srtInsuranceFundNav(), 0);
        }
    }

    function test_allVariantsOwnerOnlyAndCannotRepeat() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i);
            _upgrade(recovery);
            vm.prank(address(0xBAD));
            vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
            ITerminalRecovery(address(accounting)).settleTerminalJuniorDust();
            assertEq(ITerminalRecovery(address(accounting)).settleTerminalJuniorDust(), 1e18);
            vm.expectRevert("InvalidTerminalState");
            ITerminalRecovery(address(accounting)).settleTerminalJuniorDust();
        }
    }

    function test_allVariantsPendingRecoveryGainPreserved() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i);
            strategyNav = 1e18;
            settledNav = strategyNav;
            assertEq(this.recoverAtomically(), 1e18);
            assertEq(accounting.jrtBaseNav(), 1e18);
            assertEq(accounting.nav(), 1e18);
            assertEq(accounting.srtBaseNav(), 499e18);
            assertEq(accounting.insuranceAmount(), 499e18);
            accounting.setValuationPrice(1e18);
            assertEq(accounting.jrtBaseNav(), 1e18);
            assertEq(accounting.srtBaseNav(), 0);
            assertEq(accounting.insuranceAmount(), 0);
        }
    }

    function test_allVariantsRecordedRecoveryGainPreserved() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i);
            // The gain was checkpointed before the temporary recovery upgrade.
            accounting.seed(11e18, 499e18, 500e18, 500e18, 0, 0, 0, 0.4e18);
            strategyNav = 10e18;
            settledNav = strategyNav;
            assertEq(this.recoverAtomically(), 1e18);
            assertEq(accounting.jrtBaseNav(), 10e18);
            assertEq(accounting.nav(), 10e18);
            assertEq(accounting.srtInsuranceFundNav(), 499e18);
            accounting.setValuationPrice(1e18);
            assertEq(accounting.jrtBaseNav(), 10e18);
            assertEq(accounting.srtBaseNav(), 0);
        }
    }

    function test_allVariantsPartialDustShortfallPreservesGain() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i);
            accounting.seed(2.25e18, 499.75e18, 500e18, 500e18, 0, 0, 0, 0.4e18);
            strategyNav = 2e18;
            settledNav = strategyNav;
            assertEq(this.recoverAtomically(), 0.25e18);
            assertEq(accounting.jrtBaseNav(), 2e18);
            assertEq(accounting.insuranceAmount(), 499.75e18);
            accounting.setValuationPrice(1e18);
            assertEq(accounting.jrtBaseNav(), 2e18);
            assertEq(accounting.srtBaseNav(), 0);
        }
    }

    function test_unsettledAssetsRejectAndRollbackUpgrade() public {
        for (uint256 i = 1; i < 4; ++i) {
            _deploy(i);
            strategyNav = 1e18;
            vm.expectRevert("UnsettledStrategyNav");
            this.recoverAtomically();
            assertEq(address(uint160(uint256(vm.load(address(accounting), IMPLEMENTATION_SLOT)))), original);
            assertEq(accounting.jrtBaseNav(), 1e18);
            assertEq(accounting.insuranceAmount(), 500e18);
            strategyNav = 0;
            settledNav = 1e18;
            vm.expectRevert("UnsettledStrategyNav");
            this.recoverAtomically();
        }
    }

    function test_allVariantsRejectLargerShortfallAndHealthyPrincipal() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i);
            accounting.seed(12e18, 498e18, 500e18, 500e18, 0, 0, 0, 0.4e18);
            strategyNav = 10e18;
            settledNav = strategyNav;
            vm.expectRevert("InvalidTerminalState");
            this.recoverAtomically();
            accounting.seed(1e18, 501e18, 500e18, 500e18, 0, 0, 0, 0.4e18);
            strategyNav = 2e18;
            settledNav = strategyNav;
            vm.expectRevert("InvalidTerminalState");
            this.recoverAtomically();
        }
    }

    function test_allVariantsRejectRealizedClaimsAndFees() public {
        for (uint256 i; i < 4; ++i) {
            _deploy(i);
            accounting.seed(1e18, 499e18, 500e18, 499e18, 0, 0, 0, 0.4e18);
            vm.expectRevert("InvalidTerminalState");
            this.recoverAtomically();
            assertEq(address(uint160(uint256(vm.load(address(accounting), IMPLEMENTATION_SLOT)))), original);
            accounting.seed(1e18, 499e18, 500e18, 500e18, 0, 0, 0, 0.4e18);
            accounting.seedFee(100e18);
            pool.setCapacity(200e18);
            vm.expectRevert("InvalidTerminalState");
            this.recoverAtomically();
            assertEq(accounting.underwriterFeeNav(), 100e18);
        }
    }

    function test_uncheckpointedTerminalLossCanRecover() public {
        for (uint256 i; i < 4; ++i) {
            if (i == 1) {
                // Discrete consumes all Junior NAV already and does not create this pending-loss state.
                continue;
            }
            _deploy(i);
            accounting.seed(1001e18, 1500e18, 500e18, 500e18, 0, 0, 0, 0.4e18);
            accounting.seedFee(100e18);
            assertEq(this.recoverAtomically(), 1e18);
            assertEq(accounting.jrtBaseNav(), 0);
            assertEq(accounting.srtBaseNav(), 499e18);
            assertEq(accounting.underwriterFeeNav(), 0);
            accounting.setValuationPrice(1e18);
            assertEq(accounting.srtBaseNav(), 0);
        }
    }
}
