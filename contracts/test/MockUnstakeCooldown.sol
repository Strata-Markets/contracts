// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUnstakeCooldown, ICooldown} from "../tranches/interfaces/cooldown/ICooldown.sol";

// Instant mock: pulls the vault shares from the caller, redeems them, and sends the
// underlying asset directly to the receiver — no cooldown delay.
contract MockUnstakeCooldown is IUnstakeCooldown {
    using SafeERC20 for IERC20;

    function transfer(IERC20 token, address, address to, uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
        IERC4626(address(token)).redeem(amount, to, address(this));
    }

    function finalize(IERC20, address) external pure returns (uint256) { return 0; }
    function finalize(IERC20, address, uint256) external pure returns (uint256) { return 0; }

    function balanceOf(IERC20, address) external pure returns (ICooldown.TBalanceState memory) {
        return ICooldown.TBalanceState(0, 0, 0, 0, 0);
    }
    function balanceOf(IERC20, address, uint256) external pure returns (ICooldown.TBalanceState memory) {
        return ICooldown.TBalanceState(0, 0, 0, 0, 0);
    }
}
