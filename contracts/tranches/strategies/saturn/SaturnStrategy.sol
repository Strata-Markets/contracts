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
import { IsUSDat } from "./IsUSDat.sol";

/**
 * @title SaturnStrategy
 * @notice Strategy for the Saturn sUSDat vault (ERC4626 with STRC-based yield).
 *
 * Architecture:
 *   - Deposits: USDat is deposited into sUSDat (0.1% deposit fee applies).
 *     sUSDat shares can also be deposited directly.
 *   - Withdrawals: sUSDat shares via erc20Cooldown (instant with configurable cooldown).
 *     USDat via unstakeCooldown → SaturnCooldownRequestImpl (async via WithdrawalQueueERC721).
 *   - totalAssets: Reports real spot NAV via sUSDat.previewRedeem (no smoothing).
 *     Junior tranche absorbs STRC price volatility. Senior earns a fixed benchmark.
 *
 * @dev Follows the same patterns as sUSDeStrategy. Key differences:
 *   - deposit() returns actual post-fee base value (sUSDat.previewRedeem(sharesReceived))
 *   - ensureRedeemable() uses balance check (sUSDat.maxWithdraw always returns 0)
 *   - convertToAssets/convertToTokens use raw ERC4626 conversion (avoids sUSDat deposit fee in previewMint/previewDeposit)
 */
contract SaturnStrategy is Strategy {

    /// @notice sUSDat vault (ERC4626 with _decimalsOffset=12, 18 decimal shares, 6 decimal asset)
    IsUSDat public immutable sUSDat;

    /// @notice USDat base asset (6 decimals)
    IERC20 public immutable USDat;

    IERC20Cooldown public erc20Cooldown;
    IUnstakeCooldown public unstakeCooldown;

    /** configuration */

    uint256 public sUSDatCooldownJrt;
    uint256 public sUSDatCooldownSrt;

    struct TTokenConfig {
        bool jrtDepositsPaused;
        bool jrtWithdrawalsPaused;
        bool srtDepositsPaused;
        bool srtWithdrawalsPaused;
    }

    mapping(address token => TTokenConfig) public tokenConfigs;

    /// @dev sUSDat._decimalsOffset() = 12, used for manual ceil conversion
    uint256 private constant DECIMALS_OFFSET = 1e12;

    event CooldownsChanged(uint256 jrt, uint256 srt);
    event TokenConfigChanged(address token, TTokenConfig config);

    error TokenDepositPaused(address tranche, address token);
    error TokenWithdrawalPaused(address tranche, address token);

    constructor (IsUSDat sUSDat_) Strategy(sUSDat_.asset(), address(sUSDat_)) {
        sUSDat = sUSDat_;
        USDat = IERC20(sUSDat_.asset());
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

        SafeERC20.forceApprove(IERC20(address(sUSDat)), address(erc20Cooldown), type(uint256).max);
        SafeERC20.forceApprove(IERC20(address(sUSDat)), address(unstakeCooldown), type(uint256).max);
    }

    /**
     * @notice Processes asset deposits for the CDO contract.
     * @dev If the deposited token is USDat, it will be deposited into sUSDat.
     *      sUSDat charges a deposit fee (depositFeeBps=10, 0.1%), so the returned
     *      base value reflects the actual post-fee amount.
     *      If the deposited token is already sUSDat, it is accepted as-is.
     * @param token The address of the token being deposited (USDat or sUSDat)
     * @param tokenAmount The amount of tokens being deposited
     * @param baseAssets The amount of base assets represented by the deposit (used for sUSDat deposits)
     * @param owner The address of the asset owner from whom to transfer tokens
     * @return The amount of base assets received after deposit
     */
    function deposit (
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address owner
    ) public override onlyCDO returns (uint256) {

        bool isDepositEnabled = isTokenEnabledForDeposit(tranche, token);
        if (!isDepositEnabled) {
            revert TokenDepositPaused(tranche, token);
        }

        SafeERC20.safeTransferFrom(IERC20(token), owner, address(this), tokenAmount);

        if (token == address(USDat)) {
            SafeERC20.forceApprove(USDat, address(sUSDat), tokenAmount);
            uint256 sharesReceived = sUSDat.deposit(tokenAmount, address(this));
            // Return actual base value after sUSDat's deposit fee
            uint256 baseAssetsNet = sUSDat.convertToAssets(sharesReceived);
            return baseAssetsNet;
        }
        if (token == address(sUSDat)) {
            // already transferred in ↑
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Processes asset withdrawals for the CDO contract.
     * @dev If withdrawing sUSDat, a cooldown period is applied based on the tranche type.
     *      If withdrawing USDat, sUSDat shares are sent to UnstakeCooldown which triggers
     *      the async withdrawal via SaturnCooldownRequestImpl.
     * @param tranche The address of the tranche withdrawing assets
     * @param token The address of the token to be withdrawn (sUSDat or USDat)
     * @param baseAssets The amount of base assets to be withdrawn
     * @param receiver The address that will receive the withdrawn assets
     * @param sender The account that initiated the withdrawal
     * @return The amount of tokens withdrawn
     */
    function withdraw (
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver
    ) public override onlyCDO returns (uint256) {
        return withdrawInner(tranche, token, tokenAmount, baseAssets, sender, receiver, false);
    }

    function withdraw (
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

    function withdrawInner (address tranche, address token, uint256 /* tokenAmount */, uint256 baseAssets, address sender, address receiver, bool shouldSkipCooldown) internal returns (uint256) {
        bool isWithdrawalEnabled = isTokenEnabledForWithdrawal(tranche, token);
        if (!isWithdrawalEnabled) {
            revert TokenWithdrawalPaused(tranche, token);
        }

        // Convert base assets to sUSDat shares needed (ceil rounding, favors protocol)
        // previewWithdraw is standard OZ (no fee override) — returns shares needed for given assets
        uint256 shares = sUSDat.previewWithdraw(baseAssets);
        if (token == address(sUSDat)) {
            uint256 cooldownSeconds = shouldSkipCooldown ? 0 : (cdo.isJrt(tranche) ? sUSDatCooldownJrt : sUSDatCooldownSrt);
            erc20Cooldown.transfer(IERC20(address(sUSDat)), sender, receiver, shares, cooldownSeconds);
            return shares;
        }
        if (token == address(USDat)) {
            unstakeCooldown.transfer(IERC20(address(sUSDat)), sender, receiver, shares);
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Allows the CDO to withdraw tokens from the strategy's reserve
     * @dev For sUSDat: uses erc20Cooldown with no cooldown period.
     *      For USDat: converts to sUSDat shares and triggers async unstaking.
     * @param token The address of the token to be withdrawn (sUSDat or USDat)
     * @param tokenAmount The amount of tokens to be withdrawn
     * @param receiver The address that will receive the withdrawn tokens
     */
    function reduceReserve (address token, uint256 tokenAmount, address receiver) external onlyCDO {
        if (token == address(sUSDat)) {
            erc20Cooldown.transfer(IERC20(address(sUSDat)), receiver, receiver, tokenAmount, 0);
            return;
        }
        if (token == address(USDat)) {
            // tokenAmount is in USDat, convert to sUSDat shares (Floor/in favor of protocol)
            uint256 shares = sUSDat.convertToShares(tokenAmount);
            if (shares == 0) {
                revert ZeroAmount();
            }
            unstakeCooldown.transfer(IERC20(address(sUSDat)), receiver, receiver, shares);
            return;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Calculates the total assets managed by this strategy
     * @dev Returns the real spot value of all sUSDat shares held, including STRC price component.
     *      No smoothing applied — Junior tranche absorbs STRC price volatility.
     * @return baseAssets The total amount of USDat managed by this strategy
     */
    function totalAssets () public view override(Strategy) returns (uint256 baseAssets) {
        uint256 shares = sUSDat.balanceOf(address(this));
        baseAssets = sUSDat.convertToAssets(shares);
        return baseAssets;
    }

    /**
     * @notice Calculates the total assets managed by this strategy
     * @dev sUSDat vests rewards continuously (STRC vesting + oracle price), so it
     *      reports the current total assets regardless of parameters.
     * @return baseAssets The total amount of USDat managed by this strategy
     */
    function totalAssets (uint256, uint256) public view override(Strategy) returns (uint256 baseAssets) {
        return totalAssets();
    }

    /**
     * @notice Converts a given amount of supported tokens to their equivalent in USDat
     * @dev Uses raw ERC4626 conversion to avoid sUSDat deposit fee in previewMint.
     *      For sUSDat Floor: convertToAssets (standard OZ, no fee).
     *      For sUSDat Ceil: manual mulDiv replicating OZ _convertToAssets with Ceil rounding.
     * @param token The address of the token to convert (sUSDat or USDat)
     * @param tokenAmount The amount of tokens to convert
     * @param rounding The rounding direction
     * @return The equivalent amount in USDat
     */
    function convertToAssets (address token, uint256 tokenAmount, Math.Rounding rounding) public view override returns (uint256) {
        if (token == address(sUSDat)) {
            if (rounding == Math.Rounding.Floor) {
                return sUSDat.convertToAssets(tokenAmount);
            }
            // Ceil: replicate OZ ERC4626._convertToAssets(shares, Ceil) with _decimalsOffset=12
            // Cannot use sUSDat.previewMint() as it includes the deposit fee
            return Math.mulDiv(
                tokenAmount,
                sUSDat.totalAssets() + 1,
                sUSDat.totalSupply() + DECIMALS_OFFSET,
                Math.Rounding.Ceil
            );
        }
        if (token == address(USDat)) {
            return tokenAmount;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Converts a given amount of base assets (USDat) to the equivalent amount of supported tokens
     * @dev Uses raw ERC4626 conversion to avoid sUSDat deposit fee in previewDeposit.
     *      For sUSDat Floor: convertToShares (standard OZ, no fee).
     *      For sUSDat Ceil: manual mulDiv replicating OZ _convertToShares with Ceil rounding.
     * @param token The address of the token to convert to (sUSDat or USDat)
     * @param baseAssets The amount of base assets (USDat) to convert
     * @param rounding The rounding direction
     * @return The equivalent amount in the requested token
     */
    function convertToTokens (address token, uint256 baseAssets, Math.Rounding rounding) public view override returns (uint256) {
        if (token == address(sUSDat)) {
            if (rounding == Math.Rounding.Floor) {
                return sUSDat.convertToShares(baseAssets);
            }
            // Ceil: replicate OZ ERC4626._convertToShares(assets, Ceil) with _decimalsOffset=12
            // Cannot use sUSDat.previewWithdraw() here as we want pure conversion
            return Math.mulDiv(
                baseAssets,
                sUSDat.totalSupply() + DECIMALS_OFFSET,
                sUSDat.totalAssets() + 1,
                Math.Rounding.Ceil
            );
        }
        if (token == address(USDat)) {
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Ensures that the caller can withdraw the deposited tokenAssets amount
     * @dev sUSDat.maxWithdraw() always returns 0 (withdrawals go through the queue),
     *      so we check the caller's sUSDat share balance instead.
     * @param caller The address of the caller
     * @param baseAssets The amount of base assets to check against
     */
    function ensureRedeemable(address caller, address /* token */, uint256 baseAssets) external view {
        uint256 callerShares = sUSDat.balanceOf(caller);
        uint256 callerBaseAssets = sUSDat.convertToAssets(callerShares);
        require(callerBaseAssets >= baseAssets, "MetaVaultExceededMaxWithdraw");
    }

    /**
     * @notice Returns an array of supported tokens: sUSDat and USDat
     */
    function getSupportedTokens () external view returns (IERC20[] memory) {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(sUSDat));
        tokens[1] = USDat;
        return tokens;
    }

    /**
     * @notice Checks if withdrawals are enabled for a specific token and tranche combination
     * @dev Does not validate if the token is supported by the strategy - caller must ensure token validity.
     *      Returns true if withdrawals are not paused for the given tranche type (JRT/SRT).
     * @param tranche The address of the tranche (JRT or SRT)
     * @param token The address of the token to check (not validated against supported tokens)
     * @return True if withdrawals are enabled (not paused), false otherwise
     */
    function isTokenEnabledForWithdrawal (address tranche, address token) public view returns (bool) {
        bool isWithdrawalPaused = cdo.isJrt(tranche)
            ? tokenConfigs[token].jrtWithdrawalsPaused
            : tokenConfigs[token].srtWithdrawalsPaused;
        return isWithdrawalPaused != true;
    }

    /**
     * @notice Checks if deposits are enabled for a specific token and tranche combination
     * @dev Does not validate if the token is supported by the strategy - caller must ensure token validity.
     *      Returns true if deposits are not paused for the given tranche type (JRT/SRT).
     * @param tranche The address of the tranche (JRT or SRT)
     * @param token The address of the token to check (not validated against supported tokens)
     * @return True if deposits are enabled (not paused), false otherwise
     */
    function isTokenEnabledForDeposit (address tranche, address token) public view returns (bool) {
        bool isDepositPaused = cdo.isJrt(tranche)
            ? tokenConfigs[token].jrtDepositsPaused
            : tokenConfigs[token].srtDepositsPaused;
        return isDepositPaused != true;
    }

    /**
     * @notice Updates the cooldown periods for sUSDat withdrawals
     * @dev USDat cooldown is handled by Saturn's WithdrawalQueueERC721 (~7 days).
     *      These cooldowns only apply to direct sUSDat share withdrawals via erc20Cooldown.
     */
    function setCooldowns (uint256 sUSDatCooldownJrt_, uint256 sUSDatCooldownSrt_) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        uint256 WEEK = 7 days;
        if (sUSDatCooldownJrt_ > WEEK || sUSDatCooldownSrt_ > WEEK) {
            revert InvalidConfigCooldown();
        }
        sUSDatCooldownJrt = sUSDatCooldownJrt_;
        sUSDatCooldownSrt = sUSDatCooldownSrt_;

        bool isDisabled = sUSDatCooldownJrt_ == 0 && sUSDatCooldownSrt_ == 0;
        erc20Cooldown.setCooldownDisabled(IERC20(address(sUSDat)), isDisabled);
        emit CooldownsChanged(sUSDatCooldownJrt_, sUSDatCooldownSrt_);
    }

    /**
    * @notice Updates the configuration for a supported token
    * @dev Controls whether deposits/withdrawals are paused for junior (jrt) and/or senior (srt) tranches.
    *      By default (false), all tokens and actions are allowed. Set to true to pause specific actions.
    *      Only callable by accounts with PAUSER_ROLE.
    * @param token The address of the token to configure (sUSDat or USDat)
    * @param config The token configuration with pause flags
    */
    function setTokenConfig (address token, TTokenConfig calldata config) external onlyRole(PAUSER_ROLE) {
        if (token != address(sUSDat) && token != address(USDat)) {
            revert UnsupportedToken(token);
        }
        tokenConfigs[token] = config;
        emit TokenConfigChanged(token, config);
    }

    /**
     * @notice Returns the deposit fee percentage for the underlying protocol
     * @return feeBps The deposit fee in basis points (e.g., 10 = 0.1%)
     */
    function depositFeeBps (address tokenIn) public view returns (uint256 feeBps) {
        if (tokenIn == address(sUSDat)) {
            return 0;
        }
        if (sUSDat.feeRecipient() == address(0)) {
            return 0;
        }
        return sUSDat.depositFeeBps();
    }

    /**
     * @notice Returns the deposit fee percentage for the underlying protocol
     * @return feeBps The deposit fee in basis points (e.g., 10 = 0.1%)
     */
    function depositFeeBps (address /*tranche*/, address tokenIn, uint256 /*tokenAmount*/) external override view returns (uint256 feeBps) {
        return depositFeeBps(tokenIn);
    }



    function supportsToken(address token) external view returns (bool) {
        return token == address(sUSDat) || token == address(USDat);
    }
}
