// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PredicateMessage} from "../../tranches/strategies/nest/interfaces/INestContracts.sol";

/// @title MockNAlpha
/// @notice Mock nALPHA BoringVault token with 6 decimals (matching mainnet)
contract MockNAlpha is ERC20 {
    constructor() ERC20("Nest Alpha Vault", "nALPHA") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @title MockNestAccountant
/// @notice Mock Nest Credit Accountant with configurable exchange rate and state
/// @dev Simulates getRateInQuoteSafe and accountantState with pause functionality
contract MockNestAccountant {
    uint256 public exchangeRate;
    uint64 public lastUpdateTimestamp;
    bool public isPaused;
    address public immutable base; // USDC

    error AccountantWithRateProviders__Paused();

    event ExchangeRateUpdated(
        uint96 oldRate,
        uint96 newRate,
        uint64 currentTime
    );

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

    constructor(address base_, uint256 initialRate_) {
        base = base_;
        exchangeRate = initialRate_;
        lastUpdateTimestamp = uint64(block.timestamp);
    }

    /// @notice Simulates the Nest Accountant's rate query
    /// @dev Returns the exchange rate in quote asset decimals (6 for USDC)
    /// @param /* quote */ The quote asset address (ignored in mock, always returns USDC rate)
    function getRateInQuoteSafe(address /* quote */) external view returns (uint256) {
        if (isPaused) revert AccountantWithRateProviders__Paused();
        return exchangeRate;
    }

    /// @notice Returns the full accountant state matching Seven Seas struct
    function accountantState() external view returns (AccountantState memory) {
        return AccountantState({
            payoutAddress: address(0),
            feesOwedInBase: 0,
            totalSharesLastUpdate: 0,
            exchangeRate: uint96(exchangeRate),
            allowedExchangeRateChangeUpper: 10005,
            allowedExchangeRateChangeLower: 9995,
            lastUpdateTimestamp: lastUpdateTimestamp,
            isPaused: isPaused,
            minimumUpdateDelayInSeconds: 3600,
            managementFee: 0
        });
    }

    // ═══════ Test helpers ═══════

    function setExchangeRate(uint256 newRate) external {
        exchangeRate = newRate;
        lastUpdateTimestamp = uint64(block.timestamp);
    }

    /// @notice Set rate without updating timestamp (for testing staleness)
    function setExchangeRateNoTimestamp(uint256 newRate) external {
        exchangeRate = newRate;
    }

    /// @notice Manually set the last update timestamp (for testing)
    function setLastUpdateTimestamp(uint64 ts) external {
        lastUpdateTimestamp = ts;
    }

    function setPaused(bool paused_) external {
        isPaused = paused_;
    }

    // fork compatibility
    function updateExchangeRate(uint96 newExchangeRate) external {
        exchangeRate = newExchangeRate;
        lastUpdateTimestamp = uint64(block.timestamp);
    }
}

/// @title MockNestVaultPredicateProxy
/// @notice Mock predicate proxy that simulates the deposit flow: USDC in → nALPHA out
/// @dev Uses the Accountant rate to calculate shares minted. Validates predicate message.
contract MockNestVaultPredicateProxy {
    using SafeERC20 for IERC20;

    MockNAlpha public immutable nAlphaToken;
    MockNestAccountant public immutable accountant;
    bool public rejectDeposits;

    error DepositRejected();
    error InvalidPredicateMessage();

    constructor(MockNAlpha nAlphaToken_, MockNestAccountant accountant_) {
        nAlphaToken = nAlphaToken_;
        accountant = accountant_;
    }

    /// @notice Simulates the deposit flow: pull USDC, mint nALPHA to recipient
    /// @dev shares = depositAmount * 1e6 / exchangeRate (since both are 6 dec)
    function deposit(
        address depositAsset,
        uint256 depositAmount,
        address recipient,
        address /* nestVault */,
        PredicateMessage calldata predicateMessage
    ) external returns (uint256 shares) {
        if (rejectDeposits) revert DepositRejected();

        // Predicate message must have a non-empty taskId (simulates compliance check)
        if (bytes(predicateMessage.taskId).length == 0) revert InvalidPredicateMessage();

        // Pull deposit asset from caller
        IERC20(depositAsset).safeTransferFrom(msg.sender, address(this), depositAmount);

        // Calculate shares using the Accountant rate
        uint256 rate = accountant.exchangeRate();
        shares = (depositAmount * 1e6) / rate;

        // Mint nALPHA to recipient
        nAlphaToken.mint(recipient, shares);
    }

    // ═══════ Test helpers ═══════

    function setRejectDeposits(bool reject) external {
        rejectDeposits = reject;
    }
}
