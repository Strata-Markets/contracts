// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IRebalancer {
    function totalAssets() external view returns (uint256);
    function pendingToStrat(uint256 stratIdx) external view returns (uint256);
}

// Subset of MultiStrategy that the Rebalancer calls back into.
interface IRebalanceable {
    function withdrawForRebalance(uint256 stratIdx, address token, uint256 baseAssets, address receiver) external;
    function depositForRebalance(uint256 stratIdx, address token, uint256 tokenAmount, uint256 baseAssets) external;
    function getStratShareToken(uint256 stratIdx) external view returns (address);
    function debts() external view returns (uint256 toJunior, uint256 toSenior);
}
