// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategy} from "./IStrategy.sol";

interface IMultiStrategy is IStrategy {
    function stratOf(address tranche) external view returns (address);
    function getSupportedTokens(address tranche) external view returns (IERC20[] memory);
    function convertToAssets(address tranche, address token, uint256 tokenAmount, Math.Rounding rounding) external view returns (uint256);
    function convertToTokens(address tranche, address token, uint256 baseAssets, Math.Rounding rounding) external view returns (uint256);
}
