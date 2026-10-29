// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ICDOComponent } from "./ICDOComponent.sol";
import { IMetaVault } from "./IMetaVault.sol";
import { IStrataCDO } from "./IStrataCDO.sol";

interface ITranche is ICDOComponent, IMetaVault {

    /// @dev Used for backward compatibility and when no strategy options are needed
    struct TRedemptionExitParams {
        /// @dev Reverts when user-specified redemption parameters don't match current exit mode settings,
        ///      protecting against mode slippage before transaction execution
        IStrataCDO.TExitMode exitMode;
        uint256 exitFee;
        uint32 cooldownSeconds;
    }
    struct TRedemptionParams {
        /// @dev Reverts when user-specified redemption parameters don't match current exit mode settings,
        ///      protecting against mode slippage before transaction execution
        IStrataCDO.TExitMode exitMode;
        uint256 exitFee;
        uint32 cooldownSeconds;
        /// @dev Strategy-specific encoded options
        ///      Format depends on the underlying strategy implementation.
        bytes strategyOptions;
    }

    struct TDepositParams {
        /// @dev Strategy-specific encoded options
        ///      Format depends on the underlying strategy implementation.
        bytes strategyOptions;
    }

    error RedemptionParamsMismatch(TRedemptionParams requested, TRedemptionExitParams current);

    /// @notice Quotes redeemable assets using the supplied exit fee.
    function quoteRedeem(uint256 sharesGross, uint256 fee) external view returns (uint256 assetsNet);

    function configure () external;
    function burnSharesAsFee(uint256 shares, address owner) external returns (uint256);

    function deposit(address token, uint256 tokenAssets, address receiver, TDepositParams memory params) external returns (uint256);
    function mint(address token, uint256 shares, address receiver, TDepositParams memory params) external returns (uint256);
    function withdraw(address token, uint256 tokenAssets, address receiver, address owner, TRedemptionParams memory params) external returns (uint256);
    function redeem(address token, uint256 shares, address receiver, address owner, TRedemptionParams memory params) external returns (uint256);
}
