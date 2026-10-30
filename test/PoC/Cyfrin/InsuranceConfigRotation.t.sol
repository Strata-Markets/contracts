// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MTMStackBase} from "./StrategyDepositMaximum.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StrataCDO} from "../../../contracts/tranches/StrataCDO.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {InsuranceVault} from "../../../contracts/tranches/symbiotic/InsuranceVault.sol";
import {IInsuranceVault} from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import {IInsuranceMiddleware} from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import {IInsurancePool} from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import {MockInsurancePool} from "../../symbiotic/mocks/MockInsurancePool.sol";

contract RotationBindingPool is IInsurancePool {
    address public expectedVault;
    uint256 public totalSlashed;

    constructor(address vault) { expectedVault = vault; }

    function request(address market, uint256 loss) external view returns (uint256) {
        require(address(StrataCDO(market).insuranceMiddleware()) == address(this), "MixedMiddleware");
        require(address(StrataCDO(market).insuranceVault()) == expectedVault, "MixedVault");
        return loss;
    }

    function coverAndSlash(address market, uint256 loss) external returns (uint256) {
        require(address(StrataCDO(market).insuranceMiddleware()) == address(this), "MixedMiddleware");
        require(address(StrataCDO(market).insuranceVault()) == expectedVault, "MixedVault");
        totalSlashed += loss;
        return loss;
    }

    function syncInsuranceClaim(address) external {}
}

contract InsuranceConfigRotationTest is MTMStackBase {
    InsuranceVault oldVault;
    InsuranceVault newVault;
    MockInsurancePool newPool;

    function setUp() public {
        _deployMTMStack(AccFlags({benchmark: false, mtmProjection: false}));
        _enableInsurance(1_000_000e18, 0.2e18);
        oldVault = _vault();
        newVault = _vault();
        newPool = new MockInsurancePool();
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(oldVault)));
        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
    }

    function _vault() internal returns (InsuranceVault) {
        return InsuranceVault(address(new ERC1967Proxy(address(new InsuranceVault()),
            abi.encodeCall(InsuranceVault.initialize, (address(this), address(acm), IStrataCDO(address(cdo)), address(token))))));
    }

    function _rotate() internal {
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(newPool)), IInsuranceVault(address(newVault)));
    }

    function _loss() internal {
        vm.warp(block.timestamp + 1 days + 1);
        mtmStrategy.setTotalAssets(500e18);
    }

    function _assertOldBindings() internal view {
        assertEq(address(cdo.insuranceMiddleware()), address(pool));
        assertEq(address(cdo.insuranceVault()), address(oldVault));
        assertEq(address(accounting.insurancePool()), address(pool));
    }

    function test_emptyRotationAndDisableRemainSupported() public {
        _rotate();
        assertEq(address(cdo.insuranceMiddleware()), address(newPool));
        assertEq(address(cdo.insuranceVault()), address(newVault));
        assertEq(address(accounting.insurancePool()), address(newPool));
        assertEq(accounting.underwriterFeeBps(), 0.2e18);
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(0)), IInsuranceVault(address(0)));
        assertEq(address(accounting.insurancePool()), address(0));
        assertEq(accounting.underwriterFeeBps(), 0);
    }

    function test_existingClaimBlocksRotationAndDisable() public {
        _loss();
        vm.prank(address(jrt));
        cdo.updateAccounting();
        uint256 claim = accounting.insuranceAmount();
        assertGt(claim, 0);
        vm.expectRevert("OpenInsuranceObligations");
        _rotate();
        _assertOldBindings();
        vm.expectRevert("OpenInsuranceObligations");
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(0)), IInsuranceVault(address(0)));
        assertEq(accounting.underwriterFeeBps(), 0.2e18);
        assertEq(accounting.insuranceAmount(), claim);
        _assertOldBindings();
    }

    function test_checkpointClaimAndSlashRollBack() public {
        _loss();
        uint256 oldNav = accounting.nav();
        uint256 capacity = pool.capacity();
        assertEq(accounting.insuranceAmount(), 0);
        vm.expectRevert("OpenInsuranceObligations");
        _rotate();
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(accounting.nav(), oldNav);
        assertEq(pool.capacity(), capacity);
        _assertOldBindings();
    }

    function test_disablingWithPendingLossRollsBackFeeShutdown() public {
        _loss();
        uint256 capacity = pool.capacity();
        vm.expectRevert("OpenInsuranceObligations");
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(0)), IInsuranceVault(address(0)));
        assertEq(accounting.underwriterFeeBps(), 0.2e18);
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(pool.capacity(), capacity);
        _assertOldBindings();
    }

    function test_fundedOldVaultBlocksUntilSurplusWithdrawn() public {
        token.mint(address(this), 100e18);
        token.approve(address(cdo), 100e18);
        cdo.fundInsuranceClaim(address(token), 100e18);
        assertEq(accounting.insuranceAmount(), 0);
        vm.expectRevert("OpenInsuranceObligations");
        _rotate();
        _assertOldBindings();
        assertEq(oldVault.fundedCoverage(), 100e18);
        oldVault.withdrawSurplus(100e18, address(this));
        _rotate();
        assertEq(address(cdo.insuranceVault()), address(newVault));
    }

    function test_checkpointSeesOldMiddlewareAndVault() public {
        RotationBindingPool observingPool = new RotationBindingPool(address(oldVault));
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(observingPool)), IInsuranceVault(address(oldVault)));
        _loss();
        vm.expectRevert("OpenInsuranceObligations");
        _rotate();
        assertEq(observingPool.totalSlashed(), 0);
        assertEq(address(cdo.insuranceMiddleware()), address(observingPool));
        assertEq(address(accounting.insurancePool()), address(observingPool));
        assertEq(address(cdo.insuranceVault()), address(oldVault));
    }
}
