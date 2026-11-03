// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @notice Accounting getters backed by public state variables in AccountingStorage.
interface IAccountingState {
    /// @notice Settled strategy NAV, excluding insurance claims.
    function nav () external view returns (uint256);
    function valuationPrice () external view returns (uint128);
    function underwriterFeeBps() external view returns (uint256);
}
