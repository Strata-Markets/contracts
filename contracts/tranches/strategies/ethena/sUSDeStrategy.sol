// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IErrors } from "../../interfaces/IErrors.sol";
import { IStrataCDO } from "../../interfaces/IStrataCDO.sol";
import { IERC20Cooldown, IUnstakeCooldown } from "../../interfaces/cooldown/ICooldown.sol";
import { Strategy } from "../../Strategy.sol";

contract sUSDeStrategy is Strategy {

    IERC4626 public immutable sUSDe;
    IERC20 public immutable USDe;

    IERC20Cooldown public erc20Cooldown;
    IUnstakeCooldown public unstakeCooldown;

    /** configuration */

    uint256 public sUSDeCooldownJrt;
    uint256 public sUSDeCooldownSrt;


    event CooldownsChanged(uint256 jrt, uint256 srt);


    constructor (IERC4626 sUSDe_) {
        sUSDe = sUSDe_;
        USDe = IERC20(sUSDe_.asset());
    }

    function initialize(
        address owner_,
        address acm_,
        IStrataCDO cdo_,
        IERC20Cooldown erc20Cooldown_,
        IUnstakeCooldown unstakeCooldown_
    ) public virtual initializer {
        AccessControlled_init(owner_, acm_);

        cdo = cdo_;
        erc20Cooldown = erc20Cooldown_;
        unstakeCooldown = unstakeCooldown_;

        SafeERC20.forceApprove(sUSDe, address(erc20Cooldown), type(uint256).max);
        SafeERC20.forceApprove(sUSDe, address(unstakeCooldown), type(uint256).max);
    }

    /**
     * @notice Processes asset deposits for the CDO contract.
     * @dev This method is called by the CDO contract to handle asset deposits.
     *      If the deposited token is USDe, it will be staked to receive sUSDe.
     *      If the deposited token is already sUSDe, it will be accepted as is.
     * @param tranche The address of the tranche depositing assets (not used in this strategy)
     * @param token The address of the token being deposited
     * @param tokenAmount The amount of tokens being deposited
     * @param baseAssets The amount of base assets represented by the deposit (used for sUSDe deposits)
     * @param owner The address of the asset owner from whom to transfer tokens
     * @return The amount of base assets received after deposit
     */
    function deposit (address tranche, address token, uint256 tokenAmount, uint256 baseAssets, address owner) external onlyCDO returns (uint256) {
        SafeERC20.safeTransferFrom(IERC20(token), owner, address(this), tokenAmount);

        if (token == address(USDe)) {
            SafeERC20.forceApprove(USDe, address(sUSDe), tokenAmount);
            sUSDe.deposit(tokenAmount, address(this));
            return tokenAmount;
        }
        if (token == address(sUSDe)) {
            // already transferred in ↑
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Processes asset withdrawals for the CDO contract.
     * @dev This method is called by the CDO contract to handle asset withdrawals.
     *      If withdrawing sUSDe, a cooldown period is applied based on the tranche type.
     *      If withdrawing USDe, the sUSDe is unstaked with a cooldown.
     * @param tranche The address of the tranche withdrawing assets
     * @param token The address of the token to be withdrawn
     * @param tokenAmount The amount of tokens to be withdrawn (not used in this implementation)
     * @param baseAssets The amount of base assets to be withdrawn
     * @param receiver The address that will receive the withdrawn assets
     * @param sender The account that initiated the withdrawal
     * @return The amount of tokens withdrawn (shares for sUSDe, baseAssets for USDe)
     */
    function withdraw (address tranche, address token, uint256 tokenAmount, uint256 baseAssets, address sender, address receiver) external onlyCDO returns (uint256) {
        return withdrawInner(tranche, token, tokenAmount, baseAssets, sender, receiver, false);
    }

    function withdraw (address tranche, address token, uint256 tokenAmount, uint256 baseAssets, address sender, address receiver, bool shouldSkipCooldown) external onlyCDO returns (uint256) {
        return withdrawInner(tranche, token, tokenAmount, baseAssets, sender, receiver, shouldSkipCooldown);
    }

    function withdrawInner (address tranche, address token, uint256 tokenAmount, uint256 baseAssets, address sender, address receiver, bool shouldSkipCooldown) internal returns (uint256) {
        uint256 shares = sUSDe.previewWithdraw(baseAssets);
        if (token == address(sUSDe)) {
            uint256 cooldownSeconds = shouldSkipCooldown ? 0 : (cdo.isJrt (tranche) ? sUSDeCooldownJrt : sUSDeCooldownSrt);
            erc20Cooldown.transfer(sUSDe, sender, receiver, shares, cooldownSeconds);
            return shares;
        }
        if (token == address(USDe)) {
            unstakeCooldown.transfer(sUSDe, sender, receiver, shares);
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Allows the CDO to withdraw tokens from the strategy's reserve
     * @dev This function is part of the reserve reduction process and can only be called by the CDO.
     *      It handles both sUSDe and USDe tokens, applying different transfer mechanisms for each.
     *      For sUSDe, it uses erc20Cooldown with no cooldown period.
     *      For USDe, it uses unstakeCooldown to handle the unstaking process.
     * @param token The address of the token to be withdrawn (either sUSDe or USDe)
     * @param tokenAmount The amount of tokens to be withdrawn
     * @param receiver The address that will receive the withdrawn tokens
     */
    function reduceReserve (address token, uint256 tokenAmount, address receiver) external onlyCDO {
        if (token == address(sUSDe)) {
            erc20Cooldown.transfer(sUSDe, receiver, receiver, tokenAmount, 0);
            return;
        }
        if (token == address(USDe)) {
            // tokenAmount is in USDe, convert to sUSDe shares (Rounding.Floor/in favor of protocol) and trigger unstaking
            uint256 shares = sUSDe.convertToShares(tokenAmount);
            if (shares == 0) {
                revert ZeroAmount();
            }
            unstakeCooldown.transfer(sUSDe, receiver, receiver, shares);
            return;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Calculates the total assets managed by this strategy
     * @dev This function returns the current value of the strategy's assets in USDe.
     * @return baseAssets The total amount of USDe managed by this strategy
     */
    function totalAssets () public view returns (uint256 baseAssets) {
        uint256 shares = sUSDe.balanceOf(address(this));
        baseAssets = sUSDe.previewRedeem(shares);
        return baseAssets;
    }

    /**
     * @notice Calculates the total assets managed by this strategy
     * @dev The strategy vests rewards continuously, so it reports the current total assets.
     * @return baseAssets The total amount of USDe managed by this strategy
     */
    function totalAssets (uint256, uint256) public view returns (uint256 baseAssets) {
        return totalAssets();
    }

    /**
     * @notice Converts a given amount of supported tokens to their equivalent in USDe
     * @dev This function handles conversion for both sUSDe and USDe tokens.
     *      For sUSDe, it uses the vault's exchange rate, considering the rounding direction.
     *      For USDe, it returns the input amount as is.
     * @param token The address of the token to convert (either sUSDe or USDe)
     * @param tokenAmount The amount of tokens to convert
     * @param rounding The rounding direction to use for the conversion (floor or ceiling)
     * @return The equivalent amount in USDe
     */
    function convertToAssets (address token, uint256 tokenAmount, Math.Rounding rounding) external view returns (uint256) {
        if (token == address(sUSDe)) {
            return rounding == Math.Rounding.Floor
                ? sUSDe.previewRedeem(tokenAmount) // aka convertToAssets(tokenAmount)
                : sUSDe.previewMint(tokenAmount);
        }
        if (token == address(USDe)) {
            return tokenAmount;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Converts a given amount of base assets (USDe) to the equivalent amount of supported tokens
     * @dev This function handles conversion for both sUSDe and USDe tokens.
     *      For sUSDe, it uses the vault's exchange rate, considering the rounding direction.
     *      For USDe, it returns the input amount as is.
     * @param token The address of the token to convert to (either sUSDe or USDe)
     * @param baseAssets The amount of base assets (USDe) to convert
     * @param rounding The rounding direction to use for the conversion (floor or ceiling)
     * @return The equivalent amount in the requested token (sUSDe shares or USDe)
     */
    function convertToTokens (address token, uint256 baseAssets, Math.Rounding rounding) external view returns (uint256) {
        if (token == address(sUSDe)) {
            return rounding == Math.Rounding.Floor
                ? sUSDe.previewDeposit(baseAssets) // aka convertToShares(baseAssets)
                : sUSDe.previewWithdraw(baseAssets);
        }
        if (token == address(USDe)) {
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Ensures that the caller can withdraw the deposited tokenAssets amount
     * @param caller The address of the caller
     * @param baseAssets The amount of base assets to check against
     */
    function ensureRedeemable(address caller, address /* token */, uint256 baseAssets) external view {
        uint256 maxTokenToBaseAssetsWithdraw = sUSDe.maxWithdraw(caller);
        require(maxTokenToBaseAssetsWithdraw >= baseAssets, "MetaVaultExceededMaxWithdraw");
    }

     /**
     * @notice Returns an array of supported tokens: sUSDe and USDe
     */
    function getSupportedTokens () external view returns (IERC20[] memory) {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(sUSDe));
        tokens[1] = USDe;
        return tokens;
    }

     /**
     * @notice Updates the cooldown periods for sUSDe withdrawals (USDe cooldown is already defined by Ethena's unstaking period)
     */
    function setCooldowns (uint256 sUSDeCooldownJrt_, uint256 sUSDeCooldownSrt_) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        uint256 WEEK = 7 days;
        if (sUSDeCooldownJrt_ > WEEK || sUSDeCooldownSrt_ > WEEK) {
            revert InvalidConfigCooldown();
        }
        sUSDeCooldownJrt = sUSDeCooldownJrt_;
        sUSDeCooldownSrt = sUSDeCooldownSrt_;

        bool isDisabled = sUSDeCooldownJrt_ == 0 && sUSDeCooldownSrt_ == 0;
        erc20Cooldown.setCooldownDisabled(sUSDe, isDisabled);
        emit CooldownsChanged(sUSDeCooldownJrt_, sUSDeCooldownSrt_);
    }

    function shareToken() external view returns (address) {
        return address(sUSDe);
    }

    function supportsToken(address token) external view returns (bool) {
        return token == address(sUSDe) || token == address(USDe);
    }
}
