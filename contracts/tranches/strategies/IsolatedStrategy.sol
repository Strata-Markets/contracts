// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrataCDO} from "../interfaces/IStrataCDO.sol";
import {IIsolatedStrategy} from "../interfaces/IIsolatedStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {MultiStrategy} from "./base/MultiStrategy.sol";

contract IsolatedStrategy is MultiStrategy, IIsolatedStrategy {
    // When > 0, SRT deposits are routed to strat[0] if Junior's share of total TVL is below this floor.
    // WAD ratio 1e18 = 100%
    uint256 public juniorAllocationFloor;

    event StratsSet(address indexed juniorStrat, address indexed seniorStrat);

    function initialize(
        address owner_,
        address acm_,
        IStrataCDO cdo_,
        IStrategy juniorStrat_,
        IStrategy seniorStrat_,
        uint256 juniorAllocationFloor_
    ) external initializer {
        AccessControlled_init(owner_, acm_);
        cdo = cdo_;
        juniorAllocationFloor = juniorAllocationFloor_;
        IStrategy[] memory strats_ = new IStrategy[](2);
        strats_[0] = juniorStrat_;
        strats_[1] = seniorStrat_;
        _setStrats(strats_);
        emit StratsSet(address(juniorStrat_), address(seniorStrat_));
    }

    function setJuniorAllocationFloor(uint256 floor_) external onlyOwner {
        juniorAllocationFloor = floor_;
    }

    function setStrats(IStrategy juniorStrat_, IStrategy seniorStrat_) external onlyOwner {
        IStrategy[] memory strats_ = new IStrategy[](2);
        strats_[0] = juniorStrat_;
        strats_[1] = seniorStrat_;
        _setStrats(strats_);
        emit StratsSet(address(juniorStrat_), address(seniorStrat_));
    }

    function juniorStrat() external view returns (IStrategy) {
        return strats[0];
    }

    function seniorStrat() external view returns (IStrategy) {
        return strats[1];
    }

    // JRT deposits go to junior strat (index 0), SRT to senior strat (index 1).
    function _depositStratIndex(address tranche) internal view override returns (uint256) {
        return cdo.isJrt(tranche) ? 0 : 1;
    }

    function _depositStratIndex(address tranche, address token, uint256 baseAssets) internal view override returns (uint256) {
        if (!cdo.isJrt(tranche) && strats[0].supportsToken(token)) {
            (uint256 toJunior,) = debts();
            if (toJunior > 0) return 0;
        }
        return _depositStratIndex(tranche);
    }

    // JRT redemptions borrow from senior first (index 1); SRT borrows from junior first (index 0).
    function _primaryWithdrawStratIndex(address tranche) internal view override returns (uint256) {
        return cdo.isJrt(tranche) ? 1 : 0;
    }

    function totalAssetsByTranche() public view returns (uint256 jrtAssets, uint256 srtAssets) {
        return (strats[0].totalAssets(), strats[1].totalAssets());
    }

    /// @notice Returns the net amount of assets that need to be moved into each tranche's strategy.
    /// @dev toJunior is the larger of: (a) actual cross-strat debt — senior borrowed junior liquidity,
    ///      and (b) floor shortfall — junior's share of TVL is below juniorAllocationFloor.
    ///      toSenior reflects the symmetric case where junior borrowed senior liquidity.
    ///      Both values are zero when each strategy holds exactly its accounting entitlement
    ///      and junior's allocation is at or above the configured floor.
    function debts() public view returns (uint256 toJunior, uint256 toSenior) {
        require(address(accounting) != address(0), "Accounting not set");
        (uint256 jrtNavT0, uint256 srtNavT0,) = accounting.totalAssetsT0();
        uint256 jrtAssets = strats[0].totalAssets();
        uint256 srtAssets = strats[1].totalAssets();
        toJunior = Math.saturatingSub(jrtNavT0, jrtAssets);
        toSenior = Math.saturatingSub(srtNavT0, srtAssets);
        if (juniorAllocationFloor > 0) {
            uint256 total = jrtAssets + srtAssets;
            if (total > 0) {
                uint256 floorShortfall = Math.saturatingSub(juniorAllocationFloor * total / 1e18, jrtAssets);
                if (floorShortfall > toJunior) toJunior = floorShortfall;
            }
        }
    }

    function shareToken() external view returns (address) {
        return strats[0].shareToken();
    }

    function supportsToken(address token) external view returns (bool) {
        return strats[0].supportsToken(token) || strats[1].supportsToken(token);
    }
}
