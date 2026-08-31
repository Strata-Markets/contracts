// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAdapter
/// @notice Generic adapter interface for token conversion in TrancheDepositor
interface IAdapter {
    /// @notice Swap tokenIn for tokenOut
    /// @param tokenIn The input token address
    /// @param tokenOut The output token address
    /// @param amountIn The amount of tokenIn to swap
    /// @param minAmountOut The minimum acceptable output amount
    /// @param recipient The address that receives tokenOut
    /// @param data Arbitrary data passed to the adapter (e.g., predicate signature)
    /// @return amountOut The actual amount of tokenOut received
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata data
    ) external returns (uint256 amountOut);
}
