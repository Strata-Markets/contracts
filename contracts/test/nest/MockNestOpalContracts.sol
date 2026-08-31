// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockNestAccountant} from "./MockNestContracts.sol";
import {PredicateMessage} from "../../tranches/strategies/nest/interfaces/INestContracts.sol";

/// @title MockNOpal
/// @notice Mock nOPAL BoringVault token with 6 decimals (matching mainnet)
contract MockNOpal is ERC20 {
    constructor() ERC20("Nest BlackOpal LiquidStone II Vault", "nOPAL") {}

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

/// @title MockNestPredicateProxy
/// @notice Mock old-style PredicateProxy that simulates the 6-parameter deposit flow
/// @dev Uses the Accountant rate to calculate shares minted. Validates predicate message.
///      Key difference from MockNestVaultPredicateProxy: takes minimumMint and teller params.
contract MockNestPredicateProxy {
    using SafeERC20 for IERC20;

    MockNOpal public immutable nOpalToken;
    MockNestAccountant public immutable accountant;
    bool public rejectDeposits;

    error DepositRejected();
    error InvalidPredicateMessage();
    error MinimumMintNotMet(uint256 shares, uint256 minimumMint);

    constructor(MockNOpal nOpalToken_, MockNestAccountant accountant_) {
        nOpalToken = nOpalToken_;
        accountant = accountant_;
    }

    /// @notice Simulates the old-style PredicateProxy deposit flow
    /// @dev shares = depositAmount * 1e6 / exchangeRate (since both are 6 dec)
    function deposit(
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        address /* teller */,
        PredicateMessage calldata predicateMessage
    ) external {
        if (rejectDeposits) revert DepositRejected();

        // Predicate message must have a non-empty taskId (simulates compliance check)
        if (bytes(predicateMessage.taskId).length == 0) revert InvalidPredicateMessage();

        // Pull deposit asset from caller
        IERC20(depositAsset).safeTransferFrom(msg.sender, address(this), depositAmount);

        // Calculate shares using the Accountant rate
        uint256 rate = accountant.exchangeRate();
        uint256 shares = (depositAmount * 1e6) / rate;

        // Enforce minimumMint
        if (shares < minimumMint) revert MinimumMintNotMet(shares, minimumMint);

        // Mint nOPAL to recipient
        nOpalToken.mint(to, shares);
    }

    // ═══════ Test helpers ═══════

    function setRejectDeposits(bool reject) external {
        rejectDeposits = reject;
    }
}
