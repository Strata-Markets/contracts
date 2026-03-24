// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrataCDO} from "../interfaces/IStrataCDO.sol";
import {IIsolatedStrategy} from "../interfaces/IIsolatedStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {MultiStrategy} from "./base/MultiStrategy.sol";

contract IsolatedStrategy is MultiStrategy, IIsolatedStrategy {
    uint256 public seniorDebtToJunior;
    uint256 public juniorDebtToSenior;
    // When > 0, SRT deposits are routed to strat[0] if Junior's share of total TVL is below this floor.
    // WAD ratio 1e18 = 100%
    uint256 public juniorAllocationFloor;

    event StratsSet(address indexed juniorStrat, address indexed seniorStrat);
    event SeniorBorrowedJuniorLiquidity(uint256 baseAssets);
    event JuniorBorrowedSeniorLiquidity(uint256 baseAssets);
    event SeniorDebtRepaid(uint256 baseAssets);
    event JuniorDebtRepaid(uint256 baseAssets);

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
            // Senior has outstanding debt to Junior — repay it via deposit routing.
            if (seniorDebtToJunior > 0) {
                return 0;
            }
            // Junior's share of total TVL is below the configured floor — restore target allocation.
            if (juniorAllocationFloor > 0) {
                uint256 jrtAssets = strats[0].totalAssets();
                uint256 total = jrtAssets + strats[1].totalAssets();
                if (total > 0 && jrtAssets * 1e18 / total < juniorAllocationFloor) {
                    return 0;
                }
            }
        }
        return _depositStratIndex(tranche);
    }

    // JRT redemptions borrow from senior first (index 1); SRT borrows from junior first (index 0).
    function _primaryWithdrawStratIndex(address tranche) internal view override returns (uint256) {
        return cdo.isJrt(tranche) ? 1 : 0;
    }

    function _onCrossStratWithdraw(uint256 primaryIdx, uint256, uint256 borrowedAssets) internal override {
        if (primaryIdx == 0) {
            seniorDebtToJunior += borrowedAssets;
            emit SeniorBorrowedJuniorLiquidity(borrowedAssets);
        } else {
            juniorDebtToSenior += borrowedAssets;
            emit JuniorBorrowedSeniorLiquidity(borrowedAssets);
        }
    }

    function _onCrossStratDeposit(uint256 depositedIdx, uint256 naturalIdx, uint256 baseAssets) internal override {
        if (depositedIdx == 0 && naturalIdx == 1) {
            uint256 repaid = Math.min(baseAssets, seniorDebtToJunior);
            seniorDebtToJunior -= repaid;
            emit SeniorDebtRepaid(repaid);
        }
    }

    function totalAssetsByTranche() public view returns (uint256 jrtAssets, uint256 srtAssets) {
        return (strats[0].totalAssets(), strats[1].totalAssets());
    }

    function _onRebalanceComplete(uint256 fromStratIdx, uint256, uint256 baseAssets) internal override {
        if (fromStratIdx == 1) {
            seniorDebtToJunior -= baseAssets;
            emit SeniorDebtRepaid(baseAssets);
        } else {
            juniorDebtToSenior -= baseAssets;
            emit JuniorDebtRepaid(baseAssets);
        }
    }

    function shareToken() external view returns (address) {
        return strats[0].shareToken();
    }

    function supportsToken(address token) external view returns (bool) {
        return strats[0].supportsToken(token) || strats[1].supportsToken(token);
    }
}
