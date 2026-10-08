// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockNestAccountant} from "./MockNestContracts.sol";

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
/// @notice Mock NestVaultPredicateProxy (V2) for nOPAL, matching what NestOpalDepositAdapter calls
/// @dev Uses the Accountant rate to calculate shares minted. Rejects an empty predicate payload.
///      Same deposit flow as MockNestVaultPredicateProxy, but mints nOPAL.
contract MockNestPredicateProxy {
    using SafeERC20 for IERC20;

    MockNOpal public immutable nOpalToken;
    MockNestAccountant public immutable accountant;
    bool public rejectDeposits;

    error DepositRejected();
    error InvalidPredicateMessage();

    constructor(MockNOpal nOpalToken_, MockNestAccountant accountant_) {
        nOpalToken = nOpalToken_;
        accountant = accountant_;
    }

    /// @notice Simulates the V2 NestVaultPredicateProxy deposit flow: pull USDC, mint nOPAL to recipient
    /// @dev shares = depositAmount * 1e6 / exchangeRate (since both are 6 dec)
    function deposit(
        address depositAsset,
        uint256 depositAmount,
        address recipient,
        address /* nestVault */,
        bytes calldata predicateMessage
    ) external returns (uint256 shares) {
        if (rejectDeposits) revert DepositRejected();

        // Predicate payload must be non-empty (simulates compliance check)
        if (predicateMessage.length == 0) revert InvalidPredicateMessage();

        // Pull deposit asset from caller
        IERC20(depositAsset).safeTransferFrom(msg.sender, address(this), depositAmount);

        // Calculate shares using the Accountant rate
        uint256 rate = accountant.exchangeRate();
        shares = (depositAmount * 1e6) / rate;

        // Mint nOPAL to recipient
        nOpalToken.mint(recipient, shares);
    }

    // ═══════ Test helpers ═══════

    function setRejectDeposits(bool reject) external {
        rejectDeposits = reject;
    }
}
