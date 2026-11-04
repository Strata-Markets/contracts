// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UD60x18, pow} from "@prb/math/src/ud60x18/Math.sol";
import {Accounting} from "../../../contracts/tranches/Accounting.sol";
import {DiscreteAccounting} from "../../../contracts/tranches/DiscreteAccounting.sol";
import {DYSAccounting} from "../../../contracts/tranches/DYSAccounting.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {IRiskPremiumModel} from "../../../contracts/tranches/accounting/premium/IRiskPremiumModel.sol";
import {RiskPremiumStatic} from "../../../contracts/tranches/accounting/premium/RiskPremiumStatic.sol";
import {RiskPremiumPower} from "../../../contracts/tranches/accounting/premium/RiskPremiumPower.sol";
import {IAprPairFeed} from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";

interface IRiskModelAccounting {
    function setRiskParameters(UD60x18 x, UD60x18 y, UD60x18 k) external;
    function setRiskModel(IRiskPremiumModel model) external;
    function updateBalanceFlow(uint256, uint256, uint256, uint256) external returns (uint256);
    function updateAccounting() external;
    function onAprChanged() external;
    function aprSrt() external view returns (uint256);
    function srtTargetIndex() external view returns (uint256);
}

contract ConstantRiskPremium is IRiskPremiumModel {
    uint256 immutable premium;

    constructor(uint256 premium_) { premium = premium_; }

    function riskPremium(UD60x18) external view returns (UD60x18) {
        return UD60x18.wrap(premium);
    }
}

/// @notice Model changes checkpoint the old APR and immediately activate the new APR in every variant.
contract RiskModelAprRefreshTest is Test {
    function totalStrategyAssets() external pure returns (uint256) { return 2000e18; }
    function totalStrategyAssets(uint256, uint256) external pure returns (uint256) { return 2000e18; }
    function totalStrategyAssetsSnapshot(uint256, uint256)
        external view returns (uint256, uint256, uint256, uint256)
    {
        return (2000e18, block.timestamp, 2000e18, block.timestamp);
    }
    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound({
            aprTarget: 0, aprBase: 100_000_000_000,
            updatedAt: uint64(block.timestamp), answeredInRound: 1
        });
    }

    function _nextIndex(uint256 index, uint256 apr) internal pure returns (uint256) {
        return index * (1e18 + apr * 1 days / 365 days) / 1e18;
    }

    function _deploy(address implementation) internal returns (IRiskModelAccounting a) {
        AccessControlManager acm = new AccessControlManager(address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), address(this));
        a = IRiskModelAccounting(address(new ERC1967Proxy(
            implementation,
            abi.encodeWithSignature("initialize(address,address,address,address)",
                address(this), address(acm), address(this), address(this))
        )));
    }

    /// @dev Sets a constant `x` premium: built-in parameters, or a RiskPremiumPower model for DYS and MTM
    function _setConstantPremium(IRiskModelAccounting a, bool builtIn, uint256 x) internal {
        if (builtIn) {
            a.setRiskParameters(UD60x18.wrap(x), UD60x18.wrap(0), UD60x18.wrap(1e18));
        } else {
            a.setRiskModel(new RiskPremiumPower(UD60x18.wrap(x), UD60x18.wrap(0), UD60x18.wrap(1e18)));
        }
    }

    function _checkModelChanges(address implementation, bool builtIn) internal {
        IRiskModelAccounting a = _deploy(implementation);
        if (!builtIn) {
            // DYS and MTM have no built-in premium, so a model is installed before the first flow
            a.setRiskModel(new RiskPremiumPower(UD60x18.wrap(0.2e18), UD60x18.wrap(0.2e18), UD60x18.wrap(0.3e18)));
        }
        a.updateBalanceFlow(1000e18, 0, 1000e18, 0);
        _setConstantPremium(a, builtIn, 0.2e18);
        assertEq(a.aprSrt(), 0.08e18);

        uint256 expectedIndex = _nextIndex(a.srtTargetIndex(), 0.08e18);
        vm.warp(block.timestamp + 1 days);
        a.setRiskModel(new ConstantRiskPremium(0.4e18));
        assertEq(a.srtTargetIndex(), expectedIndex, "install checkpoints old APR");
        assertEq(a.aprSrt(), 0.06e18, "install refreshes APR immediately");

        expectedIndex = _nextIndex(expectedIndex, 0.06e18);
        vm.warp(block.timestamp + 1 days);
        a.setRiskModel(new ConstantRiskPremium(0.6e18));
        assertEq(a.srtTargetIndex(), expectedIndex, "installed model controls elapsed accrual");
        assertEq(a.aprSrt(), 0.04e18, "replacement refreshes APR immediately");

        expectedIndex = _nextIndex(expectedIndex, 0.04e18);
        vm.warp(block.timestamp + 1 days);
        a.setRiskModel(IRiskPremiumModel(address(0)));
        assertEq(a.srtTargetIndex(), expectedIndex, "removal checkpoints external model APR");
        // Built-in accountings fall back to the 20% parameters; DYS and MTM charge no premium
        uint256 aprAfterRemoval = builtIn ? 0.08e18 : 0.1e18;
        assertEq(a.aprSrt(), aprAfterRemoval, "removal refreshes APR immediately");

        expectedIndex = _nextIndex(expectedIndex, aprAfterRemoval);
        vm.warp(block.timestamp + 1 days);
        a.updateAccounting();
        assertEq(a.srtTargetIndex(), expectedIndex, "fallback premium controls subsequent accrual");
        a.setRiskModel(new RiskPremiumStatic(UD60x18.wrap(1e18)));
        assertEq(a.aprSrt(), 0, "all variants accept full premium");
        IRiskPremiumModel excessive = new ConstantRiskPremium(1e18 + 1);
        vm.expectRevert(">100%");
        a.setRiskModel(excessive);
    }

    /// @dev DYS and MTM charge no premium until a model is set, and validate the model at install
    function _checkNoModel(address implementation) internal {
        IRiskModelAccounting a = _deploy(implementation);
        a.onAprChanged();
        assertEq(a.aprSrt(), 0.1e18, "no model: Senior earns the full base APR");

        a.setRiskModel(new RiskPremiumStatic(UD60x18.wrap(1e18)));
        assertEq(a.aprSrt(), 0, "100% premium excludes the base APR");
        IRiskPremiumModel excessivePremium = new ConstantRiskPremium(1e18 + 1);
        vm.expectRevert(">100%");
        a.setRiskModel(excessivePremium);

        a.setRiskModel(new RiskPremiumPower(UD60x18.wrap(0.2e18), UD60x18.wrap(0), UD60x18.wrap(1e18)));
        assertEq(a.aprSrt(), 0.08e18, "install refreshes APR immediately");
    }

    function test_accounting() public {
        _checkModelChanges(address(new Accounting(18)), true);
    }
    function test_discrete() public {
        _checkModelChanges(address(new DiscreteAccounting(18, false)), true);
    }
    function test_dys() public {
        _checkModelChanges(address(new DYSAccounting(18, false, false, false, true, false)), false);
    }
    function test_mtm() public {
        _checkModelChanges(address(new MTMAccounting(18, false, true, false, true, false, true)), false);
    }
    function test_dysNoModelZeroPremium() public {
        _checkNoModel(address(new DYSAccounting(18, false, false, false, true, false)));
    }
    function test_mtmNoModelZeroPremium() public {
        _checkNoModel(address(new MTMAccounting(18, false, true, false, true, false, true)));
    }
}

/// @notice RiskPremiumPower reproduces the former built-in `x + y * tvlRatio^k` premium.
contract RiskPremiumPowerTest is Test {
    function test_formula() public {
        RiskPremiumPower model = new RiskPremiumPower(UD60x18.wrap(0.2e18), UD60x18.wrap(0.2e18), UD60x18.wrap(0.3e18));
        assertEq(model.x().unwrap(), 0.2e18);
        assertEq(model.y().unwrap(), 0.2e18);
        assertEq(model.k().unwrap(), 0.3e18);
        assertEq(model.riskPremium(UD60x18.wrap(0)).unwrap(), 0.2e18, "x at an empty Senior");
        assertEq(model.riskPremium(UD60x18.wrap(1e18)).unwrap(), 0.4e18, "x + y at ratio 1");
        assertEq(
            model.riskPremium(UD60x18.wrap(0.5e18)).unwrap(),
            (UD60x18.wrap(0.2e18) + UD60x18.wrap(0.2e18) * pow(UD60x18.wrap(0.5e18), UD60x18.wrap(0.3e18))).unwrap()
        );
    }

    function test_rejectsMaxPremiumAtOrAbove100Percent() public {
        vm.expectRevert(">=100%");
        new RiskPremiumPower(UD60x18.wrap(0.5e18), UD60x18.wrap(0.5e18), UD60x18.wrap(1e18));
        vm.expectRevert(">=100%");
        new RiskPremiumPower(UD60x18.wrap(1e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        new RiskPremiumPower(UD60x18.wrap(0.999e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
    }
}

contract RiskPremiumStaticTest is Test {
    function test_fullPremiumAtEveryRatio(uint256 ratio) public {
        RiskPremiumStatic model = new RiskPremiumStatic(UD60x18.wrap(1e18));
        assertEq(model.premium().unwrap(), 1e18);
        assertEq(model.riskPremium(UD60x18.wrap(ratio)).unwrap(), 1e18);
    }
    function test_zeroAndPartialPremium() public {
        assertEq(new RiskPremiumStatic(UD60x18.wrap(0)).riskPremium(UD60x18.wrap(1e18)).unwrap(), 0);
        assertEq(new RiskPremiumStatic(UD60x18.wrap(0.2e18)).riskPremium(UD60x18.wrap(0)).unwrap(), 0.2e18);
    }
    function test_rejectsPremiumAbove100Percent() public {
        vm.expectRevert(">100%");
        new RiskPremiumStatic(UD60x18.wrap(1e18 + 1));
    }
}
