// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IErrors} from "../../interfaces/IErrors.sol";
import {IStrataCDO} from "../../interfaces/IStrataCDO.sol";
import {IERC20Cooldown, IUnstakeCooldown} from "../../interfaces/cooldown/ICooldown.sol";
import {Strategy} from "../../Strategy.sol";

contract sNUSDStrategy is Strategy {

    IERC4626 public immutable sNUSD;
    IERC20 public immutable NUSD;

    IERC20Cooldown public erc20Cooldown;
    IUnstakeCooldown public unstakeCooldown;

    /** configuration */

    uint256 public sNUSDCooldownJrt;
    uint256 public sNUSDCooldownSrt;

    event CooldownsChanged(uint256 jrt, uint256 srt);


    constructor(IERC4626 sNUSD_) Strategy(sNUSD_.asset(), address(sNUSD_)) {
        sNUSD = sNUSD_;
        NUSD = IERC20(sNUSD_.asset());
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

        SafeERC20.forceApprove(sNUSD, address(erc20Cooldown), type(uint256).max);
        SafeERC20.forceApprove(sNUSD, address(unstakeCooldown), type(uint256).max);
    }

    /**
     * @notice Processes asset deposits for the CDO contract.
     * @dev This method is called by the CDO contract to handle asset deposits.
     *      If the deposited token is NUSD, it will be staked to receive sNUSD.
     *      If the deposited token is already sNUSD, it will be accepted as is.
     * @param tranche The address of the tranche depositing assets (not used in this strategy)
     * @param token The address of the token being deposited
     * @param tokenAmount The amount of tokens being deposited
     * @param baseAssets The amount of base assets represented by the deposit (used for sNUSD deposits)
     * @param owner The address of the asset owner from whom to transfer tokens
     * @return The amount of base assets received after deposit
     */
    function deposit(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address owner
    ) public override onlyCDO returns (uint256) {
        SafeERC20.safeTransferFrom(IERC20(token), owner, address(this), tokenAmount);

        if (token == address(NUSD)) {
            SafeERC20.forceApprove(NUSD, address(sNUSD), tokenAmount);
            sNUSD.deposit(tokenAmount, address(this));
            return tokenAmount;
        }
        if (token == address(sNUSD)) {
            // already transferred in ↑
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Processes asset withdrawals for the CDO contract.
     * @dev This method is called by the CDO contract to handle asset withdrawals.
     *      If withdrawing sNUSD, a cooldown period is applied based on the tranche type.
     *      If withdrawing NUSD, the sNUSD is unstaked with a cooldown.
     * @param tranche The address of the tranche withdrawing assets
     * @param token The address of the token to be withdrawn
     * @param tokenAmount The amount of tokens to be withdrawn (not used in this implementation)
     * @param baseAssets The amount of base assets to be withdrawn
     * @param receiver The address that will receive the withdrawn assets
     * @param sender The account that initiated the withdrawal
     * @return The amount of tokens withdrawn (shares for sNUSD, baseAssets for NUSD)
     */
    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver
    ) public override onlyCDO returns (uint256) {
        return withdrawInner(tranche, token, tokenAmount, baseAssets, sender, receiver, false);
    }

    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver,
        bool shouldSkipCooldown
    ) public override onlyCDO returns (uint256) {
        return withdrawInner(tranche, token, tokenAmount, baseAssets, sender, receiver, shouldSkipCooldown);
    }

    function withdrawInner(address tranche, address token, uint256, uint256 baseAssets, address sender, address receiver, bool shouldSkipCooldown) internal returns (uint256) {
        uint256 shares = sNUSD.previewWithdraw(baseAssets);
        if (token == address(sNUSD)) {
            uint256 cooldownSeconds = shouldSkipCooldown ? 0 : (cdo.isJrt(tranche) ? sNUSDCooldownJrt : sNUSDCooldownSrt);
            erc20Cooldown.transfer(sNUSD, sender, receiver, shares, cooldownSeconds);
            return shares;
        }
        if (token == address(NUSD)) {
            unstakeCooldown.transfer(sNUSD, sender, receiver, shares);
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Allows the CDO to withdraw tokens from the strategy's reserve
     * @dev This function is part of the reserve reduction process and can only be called by the CDO.
     *      It handles both sNUSD and NUSD tokens, applying different transfer mechanisms for each.
     *      For sNUSD, it uses erc20Cooldown with no cooldown period.
     *      For NUSD, it uses unstakeCooldown to handle the unstaking process.
     * @param token The address of the token to be withdrawn (either sNUSD or NUSD)
     * @param tokenAmount The amount of tokens to be withdrawn
     * @param receiver The address that will receive the withdrawn tokens
     */
    function reduceReserve(address token, uint256 tokenAmount, address receiver) external onlyCDO {
        if (token == address(sNUSD)) {
            erc20Cooldown.transfer(sNUSD, receiver, receiver, tokenAmount, 0);
            return;
        }
        if (token == address(NUSD)) {
            // tokenAmount is in NUSD, convert to sNUSD shares (Rounding.Floor/in favor of protocol) and trigger unstaking
            uint256 shares = sNUSD.convertToShares(tokenAmount);
            if (shares == 0) {
                revert ZeroAmount();
            }
            unstakeCooldown.transfer(sNUSD, receiver, receiver, shares);
            return;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Calculates the total assets managed by this strategy
     * @dev This function returns the current value of the strategy's assets in NUSD.
     * @return baseAssets The total amount of NUSD managed by this strategy
     */
    function totalAssets() public view override(Strategy) returns (uint256 baseAssets) {
        uint256 shares = sNUSD.balanceOf(address(this));
        baseAssets = sNUSD.previewRedeem(shares);
        return baseAssets;
    }

    /**
     * @notice Calculates the total assets managed by this strategy
     * @dev The strategy vests rewards continuously, so it reports the current total assets.
     * @return baseAssets The total amount of NUSD managed by this strategy
     */
    function totalAssets(uint256, uint256) public view override(Strategy) returns (uint256 baseAssets) {
        return totalAssets();
    }

    /**
     * @notice Converts a given amount of supported tokens to their equivalent in NUSD
     * @dev This function handles conversion for both sNUSD and NUSD tokens.
     *      For sNUSD, it uses the vault's exchange rate, considering the rounding direction.
     *      For NUSD, it returns the input amount as is.
     * @param token The address of the token to convert (either sNUSD or NUSD)
     * @param tokenAmount The amount of tokens to convert
     * @param rounding The rounding direction to use for the conversion (floor or ceiling)
     * @return The equivalent amount in NUSD
     */
    function convertToAssets(address token, uint256 tokenAmount, Math.Rounding rounding) public view override returns (uint256) {
        if (token == address(sNUSD)) {
            return rounding == Math.Rounding.Floor
                ? sNUSD.previewRedeem(tokenAmount)  // aka convertToAssets(tokenAmount)
                : sNUSD.previewMint(tokenAmount);
        }
        if (token == address(NUSD)) {
            return tokenAmount;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Converts a given amount of base assets (NUSD) to the equivalent amount of supported tokens
     * @dev This function handles conversion for both sNUSD and NUSD tokens.
     *      For sNUSD, it uses the vault's exchange rate, considering the rounding direction.
     *      For NUSD, it returns the input amount as is.
     * @param token The address of the token to convert to (either sNUSD or NUSD)
     * @param baseAssets The amount of base assets (NUSD) to convert
     * @param rounding The rounding direction to use for the conversion (floor or ceiling)
     * @return The equivalent amount in the requested token (sNUSD shares or NUSD)
     */
    function convertToTokens(address token, uint256 baseAssets, Math.Rounding rounding) public view override returns (uint256) {
        if (token == address(sNUSD)) {
            return rounding == Math.Rounding.Floor
                ? sNUSD.previewDeposit(baseAssets) // aka convertToShares(baseAssets)
                : sNUSD.previewWithdraw(baseAssets);
        }
        if (token == address(NUSD)) {
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
        uint256 maxTokenToBaseAssetsWithdraw = sNUSD.maxWithdraw(caller);
        require(maxTokenToBaseAssetsWithdraw >= baseAssets, "MetaVaultExceededMaxWithdraw");
    }

     /**
     * @notice Returns an array of supported tokens: sNUSD and NUSD
     */
    function getSupportedTokens() external view returns (IERC20[] memory) {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(sNUSD));
        tokens[1] = NUSD;
        return tokens;
    }


     /**
     * @notice Updates the cooldown periods for sNUSD withdrawals (NUSD cooldown is already defined by Ethena's unstaking period)
     */
    function setCooldowns(uint256 sNUSDCooldownJrt_, uint256 sNUSDCooldownSrt_) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        uint256 WEEK = 7 days;
        if (sNUSDCooldownJrt_ > WEEK || sNUSDCooldownSrt_ > WEEK) {
            revert InvalidConfigCooldown();
        }
        sNUSDCooldownJrt = sNUSDCooldownJrt_;
        sNUSDCooldownSrt = sNUSDCooldownSrt_;

        bool isDisabled = sNUSDCooldownJrt_ == 0 && sNUSDCooldownSrt_ == 0;
        erc20Cooldown.setCooldownDisabled(sNUSD, isDisabled);
        emit CooldownsChanged(sNUSDCooldownJrt_, sNUSDCooldownSrt_);
    }

    function supportsToken(address token) external view returns (bool) {
        return token == address(sNUSD) || token == address(NUSD);
    }
}
