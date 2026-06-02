// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrataCDO} from "../interfaces/IStrataCDO.sol";
import {IIsolatedStrategy} from "../interfaces/IIsolatedStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IRebalanceable} from "../interfaces/IRebalancer.sol";
import {MultiStrategy} from "./base/MultiStrategy.sol";

contract IsolatedStrategy is MultiStrategy, IIsolatedStrategy {
    IStrategy public juniorStrat;
    IStrategy public seniorStrat;

    event StratsSet(address indexed juniorStrat, address indexed seniorStrat);

    function initialize(
        address owner_,
        address acm_,
        IStrataCDO cdo_,
        IStrategy juniorStrat_,
        IStrategy seniorStrat_,
        uint256 liquidAllocationFloor_
    ) external initializer {
        AccessControlled_init(owner_, acm_);
        cdo = cdo_;
        liquidAllocationFloor = liquidAllocationFloor_;
        juniorStrat = juniorStrat_;
        seniorStrat = seniorStrat_;
        IStrategy[] memory strats_ = new IStrategy[](2);
        strats_[0] = juniorStrat_;
        strats_[1] = seniorStrat_;
        _setStrats(strats_);
        emit StratsSet(address(juniorStrat_), address(seniorStrat_));
    }

    function setLiquidAllocationFloor(uint256 floor_) external onlyOwner {
        liquidAllocationFloor = floor_;
    }

    function setStrats(IStrategy juniorStrat_, IStrategy seniorStrat_) external onlyOwner {
        juniorStrat = juniorStrat_;
        seniorStrat = seniorStrat_;
        IStrategy[] memory strats_ = new IStrategy[](2);
        strats_[0] = juniorStrat_;
        strats_[1] = seniorStrat_;
        _setStrats(strats_);
        emit StratsSet(address(juniorStrat_), address(seniorStrat_));
    }

    // JRT deposits go to junior strat (index 0), SRT to senior strat (index 1).
    function _depositStratIndex(address tranche) internal view override returns (uint256) {
        return cdo.isJrt(tranche) ? 0 : 1;
    }

    function _depositStratIndex(address tranche, address token, uint256 baseAssets) internal view override returns (uint256) {
        (uint256 toJunior, uint256 toSenior) = debts();

        if (toJunior > 0 && baseAssets <= toJunior && perStrategyTokens[address(juniorStrat)][token]) {
            return 0;
        }
        if (toSenior > 0 && baseAssets <= toSenior && perStrategyTokens[address(seniorStrat)][token]) {
            return 1;
        }

        return _depositStratIndex(tranche);
    }

    // JRT redemptions borrow from senior first (index 1); SRT borrows from junior first (index 0).
    function _primaryWithdrawStratIndex(address tranche) internal view override returns (uint256) {
        return cdo.isJrt(tranche) ? 1 : 0;
    }

    function totalAssetsByTranche() public view returns (uint256 jrtAssets, uint256 srtAssets) {
        return (juniorStrat.totalAssets(), seniorStrat.totalAssets());
    }

    /// @notice Returns the net amount of assets that need to move between strategies.
    /// @dev JR allocation ratio is derived from accounting NAV; liquidAllocationFloor may raise it.
    ///      In-flight Rebalancer assets are credited to their destination strategy so that an
    ///      ongoing rebalance zeroes out the corresponding debt without querying pending state.
    ///      toSenior takes priority: if both would be non-zero (e.g. unreconciled losses),
    ///      toJunior is zeroed.
    function debts() public view override(IIsolatedStrategy, IRebalanceable) returns (uint256 toJunior, uint256 toSenior) {
        require(address(accounting) != address(0), "Accounting not set");
        (uint256 jrtNavT0, uint256 srtNavT0,) = accounting.totalAssetsT0();

        uint256 navTotal = jrtNavT0 + srtNavT0;
        if (navTotal == 0) return (0, 0);

        uint256 strat1Ratio = Math.mulDiv(jrtNavT0, 1e18, navTotal);

        uint256 jrtAssets = juniorStrat.totalAssets();
        uint256 srtAssets = seniorStrat.totalAssets();
        if (address(rebalancer) != address(0)) {
            (uint256 pendingToJunior, uint256 pendingToSenior) = rebalancer.pendingToStrats();
            jrtAssets += pendingToJunior;
            srtAssets += pendingToSenior;
        }

        return _compute2StratsDebts(strat1Ratio, jrtAssets, srtAssets);
    }

    function shareToken() external view returns (address) {
        return juniorStrat.shareToken();
    }
}
