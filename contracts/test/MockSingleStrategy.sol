// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IStrategy } from "../tranches/interfaces/IStrategy.sol";

contract MockSingleStrategy is IStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public cdo;
    uint256 public totalAssetsValue;

    constructor(IERC20 token_, address cdo_) {
        token = token_;
        cdo = cdo_;
    }

    function deposit (
        address /*tranche*/,
        address /*token*/,
        uint256 /*tokenAmount*/,
        uint256 /*baseAssets*/,
        address /*owner*/,
        bytes memory /*options*/
    ) external virtual returns (uint256) {
        revert ("NotImplemented");
    }

    function withdraw (
        address /*tranche*/,
        address /*token*/,
        uint256 /*tokenAmount*/,
        uint256 /*baseAssets*/,
        address /*sender*/,
        address /*receiver*/,
        bool /*shouldSkipCooldown*/,
        bytes memory /*options*/
    ) external virtual returns (uint256) {
        revert ("NotImplemented");
    }

    function deposit(address, address token_, uint256 tokenAmount, uint256 baseAssets, address owner) external returns (uint256) {
        require(token_ == address(token), "UnsupportedToken");
        token.safeTransferFrom(owner, address(this), tokenAmount);
        totalAssetsValue += baseAssets;
        return baseAssets;
    }

    function withdraw(address, address token_, uint256 tokenAmount, uint256 baseAssets, address, address receiver) external returns (uint256) {
        return _mockWithdraw(token_, tokenAmount, baseAssets, receiver);
    }

    function withdraw(address, address token_, uint256 tokenAmount, uint256 baseAssets, address, address receiver, bool) external returns (uint256) {
        return _mockWithdraw(token_, tokenAmount, baseAssets, receiver);
    }

    function _mockWithdraw(address token_, uint256 tokenAmount, uint256 baseAssets, address receiver) internal returns (uint256) {
        require(token_ == address(token), "UnsupportedToken");
        totalAssetsValue -= baseAssets;
        token.safeTransfer(receiver, tokenAmount);
        return tokenAmount;
    }

    function totalAssets() external view override returns (uint256) {
        return totalAssetsValue;
    }

    function totalAssets(uint256, uint256) public view override returns (uint256) {
        return totalAssetsValue;
    }

    function totalAssetsSnapshot(
        uint256 latestNav,
        uint256 timestamp
    )
        external
        view
        override
        returns (
            uint256 navT1,
            uint256 navT1Time,
            uint256 navMTM,
            uint256 navMTMTime
        )
    {
        navT1 = totalAssets(latestNav, timestamp);
        navMTM = totalAssetsValue;
        navT1Time = block.timestamp;
        navMTMTime = block.timestamp;
    }

    function reduceReserve(address token_, uint256 tokenAmount, address receiver) external {
        require(token_ == address(token), "UnsupportedToken");
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

    function convertToAssets(address token_, uint256 tokenAmount, Math.Rounding) external view returns (uint256) {
        require(token_ == address(token), "UnsupportedToken");
        return tokenAmount;
    }

    function convertToTokens(address token_, uint256 baseAssets, Math.Rounding) external view returns (uint256) {
        require(token_ == address(token), "UnsupportedToken");
        return baseAssets;
    }

    function ensureRedeemable(address, address token_, uint256) external view {
        require(token_ == address(token), "UnsupportedToken");
    }

    function shareToken() external view returns (address) {
        return address(token);
    }

    function depositFeeBps(address) external pure returns (uint256) { return 0; }
    function depositFeeBps(address,address,uint256) external pure returns (uint256) { return 0; }

    function getCDOAddress() external view returns (address) { return cdo; }

    function maxDeposit(address, address, uint256 tokenAmount) external pure returns (uint256) { return tokenAmount; }

    function maxWithdraw(address, address, uint256 tokenAmount) external pure returns (uint256) { return tokenAmount; }

    function getRate() external pure returns (uint256) { return 0; }

    function setTotalAssets(uint256 assets) external {
        totalAssetsValue = assets;
    }
    function configure () external {

    }
}
