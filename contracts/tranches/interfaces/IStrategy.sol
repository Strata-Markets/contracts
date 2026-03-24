// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ICDOComponent } from "./ICDOComponent.sol";

interface IStrategy is ICDOComponent {

    function deposit (address tranche, address token, uint256 tokenAmount, uint256 baseAssets, address owner) external returns (uint256);
    function withdraw (address tranche, address token, uint256 tokenAmount, uint256 baseAssets, address sender, address receiver) external returns (uint256);
    function withdraw (address tranche, address token, uint256 tokenAmount, uint256 baseAssets, address sender, address receiver, bool shouldSkipCooldown) external returns (uint256);
    function totalAssets () external view returns (uint256);
    function totalAssets (uint256 latestNav, uint256 timestamp) external view returns (uint256);
    function reduceReserve (address token, uint256 tokenAmount, address receiver) external;

    function convertToAssets (address token, uint256 tokenAmount, Math.Rounding rounding) external view returns (uint256 baseAssets);
    function convertToTokens (address token, uint256 baseAssets, Math.Rounding rounding) external view returns (uint256 tokenAmount);

    function getSupportedTokens () external view returns (IERC20[] memory);
    function ensureRedeemable(address caller, address metaToken, uint256 baseAssets) external view;

    function depositFeeBps(address tokenIn) external view returns (uint256 feeBps);

    function maxWithdraw(address tranche, address tokenIn, uint256 tokenAmount) external view returns (uint256 assets);
    function maxDeposit(address tranche, address tokenIn, uint256 tokenAmount) external view returns (uint256 assets);

    function supportsToken(address token) external view returns (bool);
    // Returns the protocol share token (e.g. mHYPER for Midas, spVault shares for Spark).
    function shareToken() external view returns (address);
}
