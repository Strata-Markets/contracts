// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMultiStrategy} from "../../interfaces/IMultiStrategy.sol";
import {IStrategy} from "../../interfaces/IStrategy.sol";
import {IRebalancer, IRebalanceable} from "../../interfaces/IRebalancer.sol";
import {Strategy} from "../../Strategy.sol";

abstract contract MultiStrategy is Strategy, IMultiStrategy, IRebalanceable {
    IStrategy[] public strats;
    uint256[] public lastStratNavs;

    IRebalancer public rebalancer;

    event StratNavSnapshot(uint256[] navs);
    event RebalancerSet(address indexed rebalancer);

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

    // Hook called when a cross-strat borrow occurs during withdrawal.
    // primaryIdx: strat borrowed from; secondaryIdx: tranche's own strat.
    function _onCrossStratWithdraw(uint256 primaryIdx, uint256 secondaryIdx, uint256 borrowedAssets) internal virtual {}

    // Hook called when a deposit is routed to a non-natural strat (cross-strat deposit).
    // depositedIdx: strat that received the deposit; naturalIdx: tranche's own strat.
    function _onCrossStratDeposit(uint256 depositedIdx, uint256 naturalIdx, uint256 baseAssets) internal virtual {}

    function deposit(address tranche, address token, uint256 tokenAmount, uint256 baseAssets, address owner)
        external
        onlyCDO
        returns (uint256)
    {
        uint256 naturalIdx = _depositStratIndex(tranche);
        uint256 idx = _depositStratIndex(tranche, token, baseAssets);
        IStrategy strat = strats[idx];
        SafeERC20.safeTransferFrom(IERC20(token), owner, address(this), tokenAmount);
        SafeERC20.forceApprove(IERC20(token), address(strat), tokenAmount);
        uint256 out = strat.deposit(address(0), token, tokenAmount, baseAssets, address(this));
        if (idx != naturalIdx) _onCrossStratDeposit(idx, naturalIdx, baseAssets);
        _snapshotStratNav();
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

    function notifyRebalanceComplete(uint256 fromStratIdx, uint256 toStratIdx, uint256 baseAssets) external onlyRebalancer {
        _onRebalanceComplete(fromStratIdx, toStratIdx, baseAssets);
    }

    function getStratShareToken(uint256 stratIdx) external view returns (address) {
        return strats[stratIdx].shareToken();
    }

    function _onRebalanceComplete(uint256 fromStratIdx, uint256 toStratIdx, uint256 baseAssets) internal virtual {}

    function _snapshotStratNav() internal {
        uint256 len = strats.length;
        uint256[] memory navs = new uint256[](len);
        for (uint256 i; i < len;) {
            uint256 nav = strats[i].totalAssets();
            lastStratNavs[i] = nav;
            navs[i] = nav;
            unchecked { ++i; }
        }
        emit StratNavSnapshot(navs);
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

    function ensureRedeemable(address tranche, address caller, address token, uint256 baseAssets) external view {
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
            _onCrossStratWithdraw(primaryIdx, secondaryIdx, borrowedAssets);
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
        _snapshotStratNav();
    }

    function _setStrats(IStrategy[] memory strats_) internal {
        require(strats_.length >= 2, "MinTwoStrats");
        for (uint256 i; i < strats_.length;) {
            require(address(strats_[i]) != address(0), "ZeroAddress");
            unchecked { ++i; }
        }
        delete strats;
        delete lastStratNavs;
        for (uint256 i; i < strats_.length;) {
            strats.push(strats_[i]);
            lastStratNavs.push(0);
            unchecked { ++i; }
        }
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
