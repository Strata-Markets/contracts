// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter} from "../../interfaces/IAdapter.sol";
import {INestVaultPredicateProxy, PredicateMessage} from "./interfaces/INestContracts.sol";

/// @title NestOpalDepositAdapter
/// @notice Adapter that converts USDC to nOPAL via the NestVaultPredicateProxy
/// @dev Called by TrancheDepositor._deposit_viaAdapter. Stateless except immutable config.
///      The compliance PredicateMessage is ABI-encoded into the `data` parameter.
///      Uses the same NestVaultPredicateProxy as NestDepositAdapter (nALPHA).
contract NestOpalDepositAdapter is IAdapter {

    /// @notice The NestVaultPredicateProxy that gates deposits with compliance checks
    INestVaultPredicateProxy public immutable predicateProxy;

    /// @notice The NestVault address for nOPAL deposits
    address public immutable nestVault;

    /// @notice The nOPAL share token address
    address public immutable nOPAL;

    error UnexpectedTokenOut(address token);
    error InsufficientOutput(uint256 received, uint256 minimum);

    constructor(
        INestVaultPredicateProxy predicateProxy_,
        address nestVault_,
        address nOPAL_
    ) {
        predicateProxy = predicateProxy_;
        nestVault = nestVault_;
        nOPAL = nOPAL_;
    }

    /// @inheritdoc IAdapter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata data
    ) external returns (uint256 amountOut) {
        if (tokenOut != nOPAL) revert UnexpectedTokenOut(tokenOut);

        // Transfer USDC from caller (TrancheDepositor) to this adapter
        SafeERC20.safeTransferFrom(IERC20(tokenIn), msg.sender, address(this), amountIn);

        // Approve the PredicateProxy to spend the deposit asset
        SafeERC20.forceApprove(IERC20(tokenIn), address(predicateProxy), amountIn);

        // Decode the PredicateMessage struct from data
        // data = abi.encode(PredicateMessage({taskId, expireByBlockNumber, signerAddresses, signatures}))
        PredicateMessage memory predicateMessage = abi.decode(data, (PredicateMessage));

        uint256 sharesBefore = IERC20(nOPAL).balanceOf(address(this));

        predicateProxy.deposit(
            tokenIn,
            amountIn,
            address(this),   // to: adapter receives shares, then forwards
            nestVault,
            predicateMessage
        );

        amountOut = IERC20(nOPAL).balanceOf(address(this)) - sharesBefore;
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        // Transfer nOPAL shares to the recipient (TrancheDepositor)
        SafeERC20.safeTransfer(IERC20(nOPAL), recipient, amountOut);
    }
}
