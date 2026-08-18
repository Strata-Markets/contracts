// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAprSnapshotProvider
/// @notice Minimal interface for APR providers that support permissionless snapshot updates
/// @dev Implemented by NestAccountantAprProvider. Called by strategies on deposit/withdraw
///      to keep the APR feed up-to-date without requiring an external keeper.
interface IAprSnapshotProvider {
    function updateSnapshot() external;

    /// @notice Returns true if the given (rate, timestamp) would trigger a buffer entry
    /// @dev Used by the strategy's totalAssets(latestNav, timestamp) to skip reconciliation
    ///      when the accountant rate change is negligible.
    function isMeaningfulUpdate(uint96 rate, uint64 timestamp) external view returns (bool);

    /// @notice Returns true if the given rate is lower than the previous buffer entry
    /// @dev Used by the strategy to delay reconciliation of negative rate changes
    function isNegativeChange(uint96 rate) external view returns (bool);
}

/// @title INestAccountant
/// @notice Interface for the Nest Credit Accountant contract (Seven Seas BoringVault)
/// @dev Used to query the exchange rate of Nest vault shares (nALPHA, nOPAL, etc.) to a quote asset
///      and to read the accountant's state for staleness checks and APR computation.
interface INestAccountant {
    /// @notice Full accountant state — same struct as Seven Seas AccountantWithRateProviders
    struct AccountantState {
        address payoutAddress;
        uint128 feesOwedInBase;
        uint128 totalSharesLastUpdate;
        uint96 exchangeRate;
        uint16 allowedExchangeRateChangeUpper;
        uint16 allowedExchangeRateChangeLower;
        uint64 lastUpdateTimestamp;
        bool isPaused;
        uint32 minimumUpdateDelayInSeconds;
        uint16 managementFee;
    }

    /// @notice Returns the exchange rate for a given quote asset, or reverts if paused
    /// @param quote The address of the quote asset (e.g. USDC)
    /// @return rate The exchange rate in quote asset decimals (6 for USDC)
    function getRateInQuoteSafe(address quote) external view returns (uint256 rate);

    /// @notice Returns the full accountant state including exchange rate and last update timestamp
    function accountantState() external view returns (AccountantState memory);
}

/// @title PredicateMessage
/// @notice Predicate V1 compliance attestation struct (from @predicate/src/interfaces/IPredicateClient.sol)
/// @dev Verified against on-chain source at:
///      - nOPAL proxy:   0x6104fe10ca937a086ba7AdbD0910A4733d380cB6 (Etherscan)
///      - nFALCON proxy: 0xfC0c4222B3A0c9B060C0B959DEc62442036b9035 (Etherscan)
struct PredicateMessage {
    string taskId;
    uint256 expireByBlockNumber;
    address[] signerAddresses;
    bytes[] signatures;
}

/// @title INestVaultPredicateProxy
/// @notice Minimal interface for the NEW NestVaultPredicateProxy deposit entry point (used by nALPHA, nFALCON)
/// @dev 5-parameter deposit — no minimumMint parameter
///      On-chain selector: deposit(address,uint256,address,address,(string,uint256,address[],bytes[])) = 0xa46ea103
interface INestVaultPredicateProxy {
    /// @notice Deposit assets into a NestVault through the predicate-gated proxy
    /// @param depositAsset The address of the asset to deposit (e.g. USDC)
    /// @param depositAmount The amount of the deposit asset
    /// @param recipient The address that receives the minted shares
    /// @param nestVault The address of the NestVault to deposit into
    /// @param predicateMessage The compliance predicate attestation from the Predicate V1 API
    /// @return shares The amount of vault shares minted
    function deposit(
        address depositAsset,
        uint256 depositAmount,
        address recipient,
        address nestVault,
        PredicateMessage calldata predicateMessage
    ) external returns (uint256 shares);
}

/// @title INestPredicateProxy
/// @notice Minimal interface for the OLD PredicateProxy deposit entry point (used by nOPAL)
/// @dev 6-parameter deposit — includes minimumMint and routes via teller address
///      On-chain selector: deposit(address,uint256,uint256,address,address,(string,uint256,address[],bytes[])) = 0x0edb4e20
interface INestPredicateProxy {
    /// @notice Deposit assets through the predicate-gated proxy with minimum mint protection
    /// @param depositAsset The address of the asset to deposit (e.g. USDC)
    /// @param depositAmount The amount of the deposit asset
    /// @param minimumMint The minimum number of vault shares to accept (slippage protection)
    /// @param to The address that receives the minted shares
    /// @param teller The address of the Teller contract for this vault
    /// @param predicateMessage The compliance predicate attestation from the Predicate V1 API
    function deposit(
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        address teller,
        PredicateMessage calldata predicateMessage
    ) external;
}

