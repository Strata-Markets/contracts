// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IsUSDat
 * @notice Interface for the sUSDat V2 vault.
 *
 * V2 Changes (from V1):
 *   - Removed: claim(), claimBatch(), getStrcOracle()
 *   - Removed: vestingAmount(), vestingPeriod(), lastDistributionTimestamp(), getUnvestedAmount()
 *     (moved to STRCMirrorModule, retired after STRC→STRCon migration)
 *   - Removed: strcBalance() (replaced by module accounting)
 *   - Changed: requestRedeem second param renamed from minUsdatReceived to minSharePrice
 *     (same storage slot, different semantics — 6-decimal min net USDat per 1e18 shares)
 *   - Changed: depositFeeBps() now returns market-mode-dependent value
 *     (Regular=0, Elevated=elevatedDepositFeeBps, Restricted=deposits disabled)
 *   - Deposit fees stay in the vault (usdatBalance) for shareholders
 *   - Removed: feeRecipient() — retired as private storage, no public getter in V2
 *   - Added: getWithdrawalQueue() still available for getting the queue contract
 */
interface IsUSDat is IERC4626 {

    // ============ Fee State ============

    /// @notice Deposit fee in basis points (market-mode dependent in V2)
    function depositFeeBps () external view returns (uint256);

    // ============ Balance Tracking ============

    /// @notice Internally tracked USDat balance (6 decimals)
    function usdatBalance() external view returns (uint256);

    // ============ Surplus Vesting (V2 Distribution) ============

    /// @notice Amount of USDat still unvested in the current surplus tranche (6 decimals)
    function getUnvestedSurplus() external view returns (uint256);

    /// @notice Timestamp when the current surplus vesting started
    function surplusVestingStartTimestamp() external view returns (uint256);

    /// @notice Duration of the surplus vesting window (default 3 days)
    function surplusVestingPeriod() external view returns (uint256);

    // ============ Withdrawal Queue ============

    /// @notice Requests a withdrawal of the given shares via the async withdrawal queue
    /// @param shares The amount of sUSDat shares to redeem
    /// @param minSharePrice The minimum net USDat payout per 1e18 shares after redemption fee (6 decimals).
    ///        Pass 0 for no minimum price protection.
    /// @return requestId The ID of the withdrawal request (NFT token ID)
    function requestRedeem(uint256 shares, uint256 minSharePrice) external returns (uint256 requestId);

    /// @notice Returns the address of the WithdrawalQueueERC721 contract
    function getWithdrawalQueue() external view returns (address);
}

/**
 * @title ISaturnWithdrawalQueueV2
 * @notice Interface for Saturn's WithdrawalQueueERC721 in V2.
 *
 * V2 Changes (from V1):
 *   - Removed: lockRequests(), unlockRequests()
 *   - Removed: claimBatch(), claimAll(), claimBatchFor(), claimAllFor()
 *   - Changed: processRequests() simplified to just tokenIds (no batch totals)
 *   - Changed: Request.minUsdatReceived → minSharePrice (same storage slot)
 *   - Changed: RequestStatus.InProgress removed (settlement is atomic)
 *   - Added: claim(tokenId) — single request claim
 *   - Added: cancel(tokenId) — NFT owner can cancel open request
 *   - Added: updateMinSharePrice(tokenId, newMinSharePrice)
 */
interface ISaturnWithdrawalQueueV2 {

    /**
     * @notice The lifecycle status of a withdrawal request.
     * @dev InProgress is retained at index 2 for storage-layout compatibility with V1.
     *      V2 never sets InProgress (settlement is atomic), but existing storage slots
     *      may still contain this value for requests migrated during the upgrade.
     *      Cancelled is new in V2 (NFT owner can cancel open requests).
     */
    enum RequestStatus {
        NULL,
        Requested,
        InProgress,   // V1 legacy — never set in V2, kept for storage layout
        Processed,
        Claimed,
        Cancelled     // V2 new — NFT owner cancelled the request
    }

    struct Request {
        uint256 shares;
        uint256 usdatOwed;
        uint256 timestamp;
        uint256 minSharePrice;
        RequestStatus status;
    }

    /// @notice Claims a processed withdrawal request, burns the NFT, and transfers USDat to the caller.
    /// @dev Requires msg.sender == ownerOf(tokenId). Reverts with RequestNotProcessed if not yet processed.
    /// @param tokenId The NFT token ID of the withdrawal request
    /// @return amount The USDat amount claimed
    function claim(uint256 tokenId) external returns (uint256 amount);

    /// @notice Processes withdrawal requests at current NAV from the vault's USDat buffer
    /// @param tokenIds The NFT token IDs to process
    function processRequests(uint256[] calldata tokenIds) external;

    /// @notice Returns the withdrawal request data for a given token ID
    function requests(uint256 id) external view returns (uint256 shares, uint256 usdatOwed, uint256 timestamp, uint256 minSharePrice, RequestStatus status);
}

// ============ V1 Interface (kept for reference / test mocks) ============

interface ISaturnWithdrawalQueueERC721 {

     /**
     * @notice The lifecycle status of a withdrawal request (V1).
     */
    enum RequestStatus {
        NULL,
        Requested,
        InProgress,
        Processed,
        Claimed
    }
    struct Request {
        uint256 shares;
        uint256 usdatOwed;
        uint256 timestamp;
        uint256 minUsdatReceived;
        RequestStatus status;
    }

    function lockRequests(uint256[] calldata tokenIds) external;

    function processRequests(uint256[] calldata tokenIds,uint256 totalUsdatReceived,uint256 totalStrcSold,uint256 executionPrice) external;

    function requests(uint256 id) external view returns (Request memory);
}
