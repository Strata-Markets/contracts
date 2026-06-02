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

    // WAD ratio (1e18 = 100%). When > 0, strat1 target is raised to at least this share of total assets.
    uint256 public liquidAllocationFloor;

    mapping(address => bool) private _supportedTokens;
    IERC20[] private _supportedTokenList;
    mapping(address strat => mapping(address token => bool)) public perStrategyTokens;
    mapping(address token => IStrategy) public converters;

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
        for (uint256 i; i < strats.length; i++) {
            total += strats[i].totalAssets();
        }
        if (address(rebalancer) != address(0)) total += rebalancer.totalAssets();
    }

    function totalAssets(uint256 navT0, uint256 timestamp) public view returns (uint256 total) {
        for (uint256 i; i < strats.length; i++) {
            uint256 nav = strats[i].totalAssets(0, timestamp);
            if (nav == 0) return navT0;
            total += nav;
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
        for (uint256 i; i < len; i++) {
            if (perStrategyTokens[address(strats[i])][token]) {
                uint256 baseAssets = strats[i].convertToAssets(token, tokenAmount, Math.Rounding.Floor);
                if (strats[i].totalAssets() >= baseAssets) {
                    strats[i].reduceReserve(token, tokenAmount, receiver);
                    return;
                }
            }
        }
        for (uint256 i; i < len; i++) {
            if (perStrategyTokens[address(strats[i])][token]) {
                strats[i].reduceReserve(token, tokenAmount, receiver);
                return;
            }
        }
        revert UnsupportedToken(token);
    }

    function stratOf(address tranche) external view returns (address) {
        return address(strats[_depositStratIndex(tranche)]);
    }

    function getSupportedTokens() external view returns (IERC20[] memory) {
        return _supportedTokenList;
    }

    function getSupportedTokens(address tranche) external view returns (IERC20[] memory) {
        return strats[_depositStratIndex(tranche)].getSupportedTokens();
    }

    function convertToAssets(address token, uint256 tokenAmount, Math.Rounding rounding)
        external
        view
        returns (uint256)
    {
        return converters[token].convertToAssets(token, tokenAmount, rounding);
    }

    function convertToTokens(address token, uint256 baseAssets, Math.Rounding rounding)
        external
        view
        returns (uint256)
    {
        return converters[token].convertToTokens(token, baseAssets, rounding);
    }

    function ensureRedeemable(address caller, address token, uint256 baseAssets) external view {
        converters[token].ensureRedeemable(caller, token, baseAssets);
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
        if (perStrategyTokens[address(primaryStrat)][token]) {
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
        for (uint256 i; i < strats.length; i++) {
            address strat = address(strats[i]);
            IERC20[] memory old = strats[i].getSupportedTokens();
            for (uint256 j; j < old.length; j++) {
                address token = address(old[j]);
                _supportedTokens[token] = false;
                perStrategyTokens[strat][token] = false;
                delete converters[token];
            }
        }

        delete strats;
        delete _supportedTokenList;

        for (uint256 i; i < strats_.length; i++) {
            require(address(strats_[i]) != address(0), "ZeroAddress");
            strats.push(strats_[i]);
            address strat = address(strats_[i]);
            IERC20[] memory tokens = strats_[i].getSupportedTokens();
            for (uint256 j; j < tokens.length; j++) {
                address token = address(tokens[j]);
                if (!_supportedTokens[token]) {
                    _supportedTokens[token] = true;
                    _supportedTokenList.push(tokens[j]);
                    converters[token] = strats_[i];
                }
                perStrategyTokens[strat][token] = true;
            }
        }
    }

    /// @dev Computes rebalance debts given strat1's WAD allocation ratio and actual strategy assets.
    ///      strat1Ratio is a WAD proportion (1e18 = 100%) of total assets that strat1 should hold.
    ///      Raises strat1Ratio to liquidAllocationFloor when the floor exceeds the natural ratio.
    ///      toStrat2 takes priority: if both would be non-zero (e.g. unreconciled losses), toStrat1 is zeroed.
    function _compute2StratsDebts(
        uint256 strat1Ratio,
        uint256 strat1Assets,
        uint256 strat2Assets
    ) internal view returns (uint256 toStrat1, uint256 toStrat2) {
        uint256 floor = liquidAllocationFloor;
        uint256 s1Ratio = strat1Ratio;

        if (floor > 0 && s1Ratio < floor) s1Ratio = floor;

        uint256 navTotal = strat1Assets + strat2Assets;
        uint256 strat1Target = Math.mulDiv(navTotal, s1Ratio, 1e18);
        uint256 strat2Target = navTotal - Math.min(strat1Target, navTotal);
        toStrat1 = Math.saturatingSub(strat1Target, strat1Assets);
        toStrat2 = Math.saturatingSub(strat2Target, strat2Assets);

        if (toStrat2 > 0) toStrat1 = 0;
    }

    function supportsToken(address token) external view returns (bool) {
        return _supportedTokens[token];
    }
}
