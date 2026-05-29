// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMultiStrategy} from "./IMultiStrategy.sol";

interface IIsolatedStrategy is IMultiStrategy {
    function totalAssetsByTranche() external view returns (uint256 jrtAssets, uint256 srtAssets);
    function debts() external view returns (uint256 toJunior, uint256 toSenior);
}
