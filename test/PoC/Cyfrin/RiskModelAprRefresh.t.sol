// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UD60x18} from "@prb/math/src/ud60x18/ValueType.sol";
import {Accounting} from "../../../contracts/tranches/Accounting.sol";
import {DiscreteAccounting} from "../../../contracts/tranches/DiscreteAccounting.sol";
import {DYSAccounting} from "../../../contracts/tranches/DYSAccounting.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {IRiskPremiumModel} from "../../../contracts/tranches/accounting/premium/IRiskPremiumModel.sol";
import {IAprPairFeed} from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";

interface IRiskModelAccounting {
    function setRiskParameters(UD60x18 x, UD60x18 y, UD60x18 k) external;
    function setRiskModel(IRiskPremiumModel model) external;
    function updateBalanceFlow(uint256, uint256, uint256, uint256) external returns (uint256);
    function updateAccounting() external;
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

    function _checkModelChanges(address implementation) internal {
        AccessControlManager acm = new AccessControlManager(address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        IRiskModelAccounting a = IRiskModelAccounting(address(new ERC1967Proxy(
            implementation,
            abi.encodeWithSignature("initialize(address,address,address,address)",
                address(this), address(acm), address(this), address(this))
        )));
        a.updateBalanceFlow(1000e18, 0, 1000e18, 0);
        a.setRiskParameters(UD60x18.wrap(0.2e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
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
        assertEq(a.aprSrt(), 0.08e18, "removal restores built-in model APR");

        expectedIndex = _nextIndex(expectedIndex, 0.08e18);
        vm.warp(block.timestamp + 1 days);
        a.updateAccounting();
        assertEq(a.srtTargetIndex(), expectedIndex, "built-in model controls subsequent accrual");
    }

    function test_accounting() public {
        _checkModelChanges(address(new Accounting(18)));
    }
    function test_discrete() public {
        _checkModelChanges(address(new DiscreteAccounting(18, false)));
    }
    function test_dys() public {
        _checkModelChanges(address(new DYSAccounting(18, false, false, false, true, false)));
    }
    function test_mtm() public {
        _checkModelChanges(address(new MTMAccounting(18, false, true, false, true, false, true)));
    }
}
