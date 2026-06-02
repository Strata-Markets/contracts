// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMultiStrategy} from "../../interfaces/IMultiStrategy.sol";
import {IStrategy} from "../../interfaces/IStrategy.sol";
import {IRebalancer, IRebalanceable} from "../../interfaces/IRebalancer.sol";
import {IAccounting} from "../../interfaces/IAccounting.sol";
import {Strategy} from "../../Strategy.sol";

abstract contract MultiStrategy is Strategy, IMultiStrategy, IRebalanceable {
    IStrategy[] public strats;

    IRebalancer public rebalancer;
    IAccounting public accounting;

    // WAD ratio (1e18 = 100%). When > 0, junior target is raised to at least this share of total assets.
    uint256 public juniorAllocationFloor;

    event StratNavSnapshot(uint256[] navs);
    event RebalancerSet(address indexed rebalancer);
    event AccountingSet(address indexed accounting);

    modifier onlyRebalancer() {
        if (msg.sender != address(rebalancer)) revert InvalidCaller(msg.sender);
        _;
    }

    function _depositStratIndex(address tranche) internal view virtual returns (uint256);
    function _primaryWithdrawStratIndex(address tranche) internal view virtual returns (uint256);

    // Override to route deposits based on token/amount (e.g. debt-aware routing).
    // Defaults to the tranche→strat mapping so existing impls need no change.
    function _depositStratIndex(address tranche, address token, uint256 baseAssets) internal view virtual returns (uint256) {
        return _depositStratIndex(tranche);
    }


    function deposit(address tranche, address token, uint256 tokenAmount, uint256 baseAssets, address owner)
        external
        onlyCDO
        returns (uint256)
    {
        uint256 idx = _depositStratIndex(tranche, token, baseAssets);
        IStrategy strat = strats[idx];
        SafeERC20.safeTransferFrom(IERC20(token), owner, address(this), tokenAmount);
        SafeERC20.forceApprove(IERC20(token), address(strat), tokenAmount);
        uint256 out = strat.deposit(address(0), token, tokenAmount, baseAssets, address(this));
        return out;
    }

    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver
    ) external onlyCDO returns (uint256) {
        return _withdraw(tranche, token, tokenAmount, baseAssets, sender, receiver, false);
    }

    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver,
        bool shouldSkipCooldown
    ) external onlyCDO returns (uint256) {
        return _withdraw(tranche, token, tokenAmount, baseAssets, sender, receiver, shouldSkipCooldown);
    }

    function totalAssets() public view returns (uint256 total) {
        for (uint256 i; i < strats.length;) {
            total += strats[i].totalAssets();
            unchecked { ++i; }
        }
        if (address(rebalancer) != address(0)) total += rebalancer.totalAssets();
    }

    function totalAssets(uint256 navT0, uint256 timestamp) public view returns (uint256 total) {
        for (uint256 i; i < strats.length;) {
            uint256 nav = strats[i].totalAssets(0, timestamp);
            if (nav == 0) return navT0;
            total += nav;
            unchecked { ++i; }
        }
        if (address(rebalancer) != address(0)) total += rebalancer.totalAssets();
    }

    function setRebalancer(IRebalancer rebalancer_) external onlyOwner {
        rebalancer = rebalancer_;
        emit RebalancerSet(address(rebalancer_));
    }

    function setAccounting(IAccounting accounting_) external onlyOwner {
        accounting = accounting_;
        emit AccountingSet(address(accounting_));
    }

    function withdrawForRebalance(uint256 stratIdx, address token, uint256 baseAssets, address receiver) external onlyRebalancer {
        IStrategy strat = strats[stratIdx];
        uint256 tokenAmount = strat.convertToTokens(token, baseAssets, Math.Rounding.Ceil);
        strat.withdraw(address(0), token, tokenAmount, baseAssets, receiver, receiver, false);
    }

    function depositForRebalance(uint256 stratIdx, address token, uint256 tokenAmount, uint256 baseAssets) external onlyRebalancer {
        IStrategy strat = strats[stratIdx];
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), tokenAmount);
        SafeERC20.forceApprove(IERC20(token), address(strat), tokenAmount);
        strat.deposit(address(0), token, tokenAmount, baseAssets, address(this));
    }

    function getStratShareToken(uint256 stratIdx) external view returns (address) {
        return strats[stratIdx].shareToken();
    }

    function reduceReserve(address token, uint256 tokenAmount, address receiver) external onlyCDO {
        uint256 len = strats.length;
        for (uint256 i; i < len;) {
            if (strats[i].supportsToken(token)) {
                uint256 baseAssets = strats[i].convertToAssets(token, tokenAmount, Math.Rounding.Floor);
                if (strats[i].totalAssets() >= baseAssets) {
                    strats[i].reduceReserve(token, tokenAmount, receiver);
                    return;
                }
            }
            unchecked { ++i; }
        }
        for (uint256 i; i < len;) {
            if (strats[i].supportsToken(token)) {
                strats[i].reduceReserve(token, tokenAmount, receiver);
                return;
            }
            unchecked { ++i; }
        }
        revert UnsupportedToken(token);
    }

    function stratOf(address tranche) external view returns (address) {
        return address(strats[_depositStratIndex(tranche)]);
    }

    function getSupportedTokens() external view returns (IERC20[] memory tokens) {
        uint256 len = strats.length;
        IERC20[][] memory allTokens = new IERC20[][](len);
        uint256 totalLen = 0;
        for (uint256 i; i < len;) {
            allTokens[i] = strats[i].getSupportedTokens();
            totalLen += allTokens[i].length;
            unchecked { ++i; }
        }
        tokens = new IERC20[](totalLen);
        uint256 count = 0;
        for (uint256 i; i < len;) {
            for (uint256 j; j < allTokens[i].length;) {
                bool exists = false;
                for (uint256 k; k < count;) {
                    if (address(tokens[k]) == address(allTokens[i][j])) {
                        exists = true;
                        break;
                    }
                    unchecked { ++k; }
                }
                if (!exists) {
                    tokens[count++] = allTokens[i][j];
                }
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }
        assembly { mstore(tokens, count) }
    }

    function getSupportedTokens(address tranche) external view returns (IERC20[] memory) {
        return strats[_depositStratIndex(tranche)].getSupportedTokens();
    }

    function convertToAssets(address token, uint256 tokenAmount, Math.Rounding rounding)
        external
        view
        returns (uint256)
    {
        return _resolveStratByToken(token).convertToAssets(token, tokenAmount, rounding);
    }

    function convertToTokens(address token, uint256 baseAssets, Math.Rounding rounding)
        external
        view
        returns (uint256)
    {
        return _resolveStratByToken(token).convertToTokens(token, baseAssets, rounding);
    }

    function convertToAssets(address tranche, address token, uint256 tokenAmount, Math.Rounding rounding)
        external
        view
        returns (uint256)
    {
        return strats[_depositStratIndex(tranche)].convertToAssets(token, tokenAmount, rounding);
    }

    function convertToTokens(address tranche, address token, uint256 baseAssets, Math.Rounding rounding)
        external
        view
        returns (uint256)
    {
        return strats[_depositStratIndex(tranche)].convertToTokens(token, baseAssets, rounding);
    }

    function ensureRedeemable(address caller, address token, uint256 baseAssets) external view {
        _resolveStratByToken(token).ensureRedeemable(caller, token, baseAssets);
    }

    function _withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver,
        bool shouldSkipCooldown
    ) internal returns (uint256 tokenAmountOut) {
        uint256 primaryIdx = _primaryWithdrawStratIndex(tranche);
        uint256 secondaryIdx = _depositStratIndex(tranche);
        IStrategy primaryStrat = strats[primaryIdx];
        IStrategy secondaryStrat = strats[secondaryIdx];

        uint256 borrowedAssets = 0;
        if (primaryStrat.supportsToken(token)) {
            borrowedAssets = Math.min(baseAssets, primaryStrat.totalAssets());
        }

        if (borrowedAssets > 0) {
            uint256 primaryTokenAmount = primaryStrat.convertToTokens(token, borrowedAssets, Math.Rounding.Ceil);
            tokenAmountOut += primaryStrat.withdraw(tranche, token, primaryTokenAmount, borrowedAssets, sender, receiver, true);
        }

        uint256 secondaryAssets = baseAssets - borrowedAssets;
        if (secondaryAssets > 0) {
            uint256 secondaryTokenAmount = tokenAmountOut < tokenAmount
                ? tokenAmount - tokenAmountOut
                : secondaryStrat.convertToTokens(token, secondaryAssets, Math.Rounding.Ceil);
            tokenAmountOut += secondaryStrat.withdraw(
                tranche, token, secondaryTokenAmount, secondaryAssets, sender, receiver, shouldSkipCooldown
            );
        }
    }

    function _setStrats(IStrategy[] memory strats_) internal {
        require(strats_.length >= 2, "MinTwoStrats");
        for (uint256 i; i < strats_.length;) {
            require(address(strats_[i]) != address(0), "ZeroAddress");
            unchecked { ++i; }
        }
        delete strats;
        for (uint256 i; i < strats_.length;) {
            strats.push(strats_[i]);
            unchecked { ++i; }
        }
    }

    /// @dev Computes rebalance debts given junior's accounting entitlement and actual strategy assets.
    ///      juniorTarget must be the raw accounting value (jrtNavT0), not a pre-divided ratio —
    ///      converting to a WAD ratio and back loses precision due to integer truncation.
    ///      navTotal is used only for the floor comparison and the senior target remainder.
    ///      Raises the junior target to juniorAllocationFloor * navTotal when the floor exceeds the
    ///      natural entitlement.
    function _computeDebts(
        uint256 juniorTarget,
        uint256 navTotal,
        uint256 jrtAssets,
        uint256 srtAssets
    ) internal view returns (uint256 toJunior, uint256 toSenior) {
        uint256 floor = juniorAllocationFloor;
        uint256 jrTarget = juniorTarget;
        if (floor > 0) {
            uint256 floorTarget = Math.mulDiv(navTotal, floor, 1e18);
            if (floorTarget > jrTarget) jrTarget = floorTarget;
        }
        uint256 srTarget = navTotal - Math.min(jrTarget, navTotal);
        toJunior = Math.saturatingSub(jrTarget, jrtAssets);
        toSenior = Math.saturatingSub(srTarget, srtAssets);
        if (toSenior > 0) toJunior = 0;
    }

    function _resolveStratByToken(address token) internal view returns (IStrategy) {
        for (uint256 i; i < strats.length;) {
            if (strats[i].supportsToken(token)) {
                return strats[i];
            }
            unchecked { ++i; }
        }
        revert UnsupportedToken(token);
    }
}
