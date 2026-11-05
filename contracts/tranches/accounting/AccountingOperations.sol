// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title AccountingOperations
/// @notice Operation ids AccountingOperationalModule passes to the accounting's selfCall to run accounting math.
/// @dev Constants only, so inheriting this contract does not affect the storage layout.
abstract contract AccountingOperations {
    /// @dev Checkpoints accounting against the current strategy NAV.
    uint256 internal constant OP_CHECKPOINT = 0;
    /// @dev Recomputes aprSrt from the current aprTarget and aprBase.
    uint256 internal constant OP_UPDATE_APR_SRT = 1;
    /// @dev Fetches APRs from the feed and updates aprSrt.
    uint256 internal constant OP_SYNC_APRS = 2;
    /// @dev Anchors the floor window at the settled Senior NAV.
    uint256 internal constant OP_RESET_FLOOR_WINDOW = 3;
    /// @dev Releases excess valuation credit at the stored valuation price.
    uint256 internal constant OP_RESYNC_INSURANCE_FUND = 4;
    /// @dev Scales entry trackers from arg0 Senior NAV to arg1 Senior NAV.
    uint256 internal constant OP_SCALE_SRT_FUND = 5;
    /// @dev Synchronizes the reduced claim with the insurance pool.
    uint256 internal constant OP_SYNC_INSURANCE_CLAIM = 6;
}
