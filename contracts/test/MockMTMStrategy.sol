// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IStrataCDO} from '../tranches/interfaces/IStrataCDO.sol';
import {Strategy} from '../tranches/Strategy.sol';

contract MockMTMStrategy is Strategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    uint256 public totalAssetsValue;
    uint256 public totalAssetsTimestamp;
    uint256 public epochDuration;

    constructor(IERC20 token_) Strategy(address(token_), address(token_)) {
        token = token_;
    }

    function initialize(address owner_, address acm_, IStrataCDO cdo_, address, address) public virtual initializer {
        AccessControlled_init(owner_, acm_);
        cdo = cdo_;
    }

    function setEpochDuration(uint256 epochDuration_) external {
        epochDuration = epochDuration_;
    }

    function deposit(
        address,
        address token_,
        uint256 tokenAmount,
        uint256 baseAssets,
        address owner
    ) public override returns (uint256) {
        require(token_ == address(token), 'UnsupportedToken');
        token.safeTransferFrom(owner, address(this), tokenAmount);
        totalAssetsValue += baseAssets;
        return baseAssets;
    }

    function withdraw(
        address,
        address token_,
        uint256 tokenAmount,
        uint256 baseAssets,
        address,
        address receiver
    ) public override returns (uint256) {
        return _mockWithdraw(token_, tokenAmount, baseAssets, receiver);
    }

    function withdraw(
        address,
        address token_,
        uint256 tokenAmount,
        uint256 baseAssets,
        address,
        address receiver,
        bool
    ) public override returns (uint256) {
        return _mockWithdraw(token_, tokenAmount, baseAssets, receiver);
    }

    function _mockWithdraw(
        address token_,
        uint256 tokenAmount,
        uint256 baseAssets,
        address receiver
    ) internal returns (uint256) {
        require(token_ == address(token), 'UnsupportedToken');
        totalAssetsValue -= baseAssets;
        token.safeTransfer(receiver, tokenAmount);
        return tokenAmount;
    }

    function updateTotalAssets(uint256 totalAssetsValue_) external {
        totalAssetsTimestamp = block.timestamp;
        totalAssetsValue = totalAssetsValue_;
    }

    function totalAssets() public view override returns (uint256) {
        return totalAssetsValue;
    }

    function totalAssets(uint256 accountingNav, uint256 lastReconciliation) public view override returns (uint256) {
        if (lastReconciliation > block.timestamp - epochDuration) {
            // return fresh assets for next epoch
            return totalAssetsValue;
        }
        return accountingNav;
    }

    function totalAssetsSnapshot(
        uint256 accountingNav,
        uint256 lastReconciliation
    ) external view override returns (uint256 navT1, uint256 navT1Time, uint256 navMTM, uint256 navMTMTime) {
        if (block.timestamp > lastReconciliation + epochDuration) {
            navT1 = totalAssetsValue;
            navT1Time = block.timestamp;
        } else {
            navT1 = accountingNav;
            navT1Time = lastReconciliation;
        }

        navMTM = totalAssetsValue;
        navMTMTime = block.timestamp;
    }

    function reduceReserve(address token_, uint256 tokenAmount, address receiver) external {
        require(token_ == address(token), 'UnsupportedToken');
        totalAssetsValue -= tokenAmount;
        token.safeTransfer(receiver, tokenAmount);
    }

    function supportsToken(address token_) external view returns (bool) {
        return token_ == address(token);
    }

    function getSupportedTokens() external view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = token;
    }

    function convertToAssets(address token_, uint256 tokenAmount, Math.Rounding) public view override returns (uint256) {
        require(token_ == address(token), 'UnsupportedToken');
        return tokenAmount;
    }

    function convertToTokens(address token_, uint256 baseAssets, Math.Rounding) public view override returns (uint256) {
        require(token_ == address(token), 'UnsupportedToken');
        return baseAssets;
    }

    function setTotalAssets(uint256 assets) external {
        totalAssetsValue = assets;
    }

    function ensureRedeemable(address caller, address token_, uint256 baseAssets) external view {

    }
}
