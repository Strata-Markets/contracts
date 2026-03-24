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
import {IYieldVault} from "./interfaces/IYieldVault.sol";
import {IStakingVault} from "./interfaces/IStakingVault.sol";

contract FigureStrategy is Strategy {
    using SafeERC20 for IERC20;

    // ──────────────────── Immutables ────────────────────

    /// @notice The YieldVault wrapping USDC into wYLDS (1:1, non-rebasing)
    IYieldVault public immutable yieldVault;

    /// @notice The StakingVault wrapping wYLDS into PRIME (NAV-priced)
    IStakingVault public immutable stakingVault;

    /// @notice The base asset — USDC
    IERC20 public immutable usdc;

    // ──────────────────── Mutable state ────────────────────

    /// @notice ERC-20 cooldown for synchronous token transfers (PRIME, wYLDS)
    IERC20Cooldown public erc20Cooldown;

    /// @notice Unstake cooldown for async redemptions (USDC path via FigureCooldownRequestImpl)
    IUnstakeCooldown public unstakeCooldown;

    /// @notice Cooldown period for PRIME token withdrawals from JRT tranche (seconds)
    uint256 public primeCooldownJrt;

    /// @notice Cooldown period for PRIME token withdrawals from SRT tranche (seconds)
    uint256 public primeCooldownSrt;

    // ──────────────────── Events ────────────────────

    event CooldownsChanged(uint256 jrt, uint256 srt);

    // ──────────────────── Constructor ────────────────────

    constructor(
        IStakingVault stakingVault_,
        IYieldVault yieldVault_,
        IERC20 usdc_
    ) {
        stakingVault = stakingVault_;
        yieldVault = yieldVault_;
        usdc = usdc_;
    }

    // ──────────────────── Initializer ────────────────────

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

        SafeERC20.forceApprove(stakingVault, address(erc20Cooldown), type(uint256).max);
        SafeERC20.forceApprove(stakingVault, address(unstakeCooldown), type(uint256).max);

        SafeERC20.forceApprove(yieldVault, address(erc20Cooldown), type(uint256).max);
        SafeERC20.forceApprove(yieldVault, address(unstakeCooldown), type(uint256).max);
    }

    /**
     * @notice Processes asset deposits for the CDO contract.
     * @dev Handles three deposit tokens:
     *      • USDC   -> deposit into YieldVault (get wYLDS) -> deposit into StakingVault (get PRIME)
     *      • wYLDS  -> deposit into StakingVault (get PRIME)
     *      • PRIME  -> accept as-is
     *
     * @param tranche The address of the tranche depositing assets (unused)
     * @param token The address of the token being deposited
     * @param tokenAmount The amount of tokens being deposited
     * @param baseAssets The amount of base assets (USDC) represented by the deposit
     * @param owner The address of the asset owner from whom to transfer tokens
     * @return The amount of base assets (USDC-denominated) received after deposit
     */
    function deposit(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address owner
    ) external onlyCDO returns (uint256) {
        SafeERC20.safeTransferFrom(IERC20(token), owner, address(this), tokenAmount);

        if (token == address(usdc)) {
            // USDC -> YieldVault (wYLDS) -> StakingVault (PRIME)
            SafeERC20.forceApprove(usdc, address(yieldVault), tokenAmount);
            uint256 wYLDSReceived = yieldVault.deposit(tokenAmount, address(this));
            // wYLDS received = tokenAmount (1:1)

            SafeERC20.forceApprove(yieldVault, address(stakingVault), wYLDSReceived);
            uint256 primeReceived = stakingVault.deposit(wYLDSReceived, address(this));
            return convertToAssets(address(stakingVault), primeReceived, Math.Rounding.Floor);
        }
        if (token == address(yieldVault)) {
            // wYLDS -> StakingVault (PRIME)
            SafeERC20.forceApprove(yieldVault, address(stakingVault), tokenAmount);
            uint256 primeReceived = stakingVault.deposit(tokenAmount, address(this));
            return convertToAssets(address(stakingVault), primeReceived, Math.Rounding.Floor);
        }
        if (token == address(stakingVault)) {
            // already transferred in ↑
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Processes asset withdrawals for the CDO contract.
     * @dev See withdrawInner for the full logic. This overload applies the default cooldown.
     */
    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver
    ) external onlyCDO returns (uint256) {
        return withdrawInner(tranche, token, tokenAmount, baseAssets, sender, receiver, false);
    }

    /**
     * @notice Processes asset withdrawals with optional cooldown skip.
     */
    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver,
        bool shouldSkipCooldown
    ) external onlyCDO returns (uint256) {
        return withdrawInner(tranche, token, tokenAmount, baseAssets, sender, receiver, shouldSkipCooldown);
    }

    /**
     * @dev Core withdrawal logic
     *
     * @param tranche The address of the tranche withdrawing
     * @param token The desired output token
     * @param tokenAmount The amount of tokens (unused, calculated from baseAssets)
     * @param baseAssets The USDC-denominated amount to withdraw
     * @param sender The account that initiated the withdrawal
     * @param receiver The address that will receive the withdrawn assets
     * @param shouldSkipCooldown If true, bypasses the ERC-20 cooldown period
     * @return The amount of tokens transferred (shares for PRIME/wYLDS, baseAssets for USDC)
     */
    function withdrawInner(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver,
        bool shouldSkipCooldown
    ) internal returns (uint256) {
        // PRIME just transfered through cooldown.
        uint256 cooldownSeconds = shouldSkipCooldown
            ? 0
            : (cdo.isJrt(tranche) ? primeCooldownJrt : primeCooldownSrt);
        if (token == address(stakingVault)) {

            uint256 shares = stakingVault.previewWithdraw(baseAssets);
            erc20Cooldown.transfer(stakingVault, sender, receiver, shares, cooldownSeconds);
            return shares;
        }

        // stakingVault.withdraw(baseAssets) converts USDC-amount -> PRIME shares via NAV,
        // burns those PRIME shares, and returns wYLDS to this contract.
        uint256 wYLDSBefore = yieldVault.balanceOf(address(this));
        stakingVault.withdraw(baseAssets, address(this), address(this));
        uint256 wYLDSReceived = yieldVault.balanceOf(address(this)) - wYLDSBefore;

        // withdraw as wYLDS
        if (token == address(yieldVault)) {
            erc20Cooldown.transfer(yieldVault, sender, receiver, wYLDSReceived, cooldownSeconds);
            return wYLDSReceived;
        }

        // Send wYLDS to a FigureCooldownRequestImpl clone via UnstakeCooldown.
        if (token == address(usdc)) {
            unstakeCooldown.transfer(yieldVault, sender, receiver, wYLDSReceived);
            return baseAssets;
        }

        revert UnsupportedToken(token);
    }

    /**
     * @notice Allows the CDO to withdraw tokens from the strategy's reserve.
     * @dev Part of the reserve reduction process. Handles three token types:
     *      • PRIME -> erc20Cooldown with zero cooldown
     *      • wYLDS -> unstake PRIME, erc20Cooldown with zero cooldown
     *      • USDC  -> unstake PRIME, unstakeCooldown (async YieldVault redemption)
     *
     * @param token The token to withdraw
     * @param tokenAmount The amount (PRIME shares for PRIME, USDC-denominated for wYLDS/USDC)
     * @param receiver The address that will receive the withdrawn tokens
     */
    function reduceReserve(address token, uint256 tokenAmount, address receiver) external onlyCDO {
        if (token == address(stakingVault)) {
            erc20Cooldown.transfer(stakingVault, receiver, receiver, tokenAmount, 0);
            return;
        }
        if (token == address(yieldVault)) {
            uint256 shares = stakingVault.previewWithdraw(tokenAmount);
            if (shares == 0) {
                revert ZeroAmount();
            }
            stakingVault.withdraw(tokenAmount, address(this), address(this));
            erc20Cooldown.transfer(yieldVault, receiver, receiver, tokenAmount, 0);
            return;
        }
        if (token == address(usdc)) {
            uint256 shares = stakingVault.previewWithdraw(tokenAmount);
            if (shares == 0) {
                revert ZeroAmount();
            }
            stakingVault.withdraw(tokenAmount, address(this), address(this));
            unstakeCooldown.transfer(yieldVault, receiver, receiver, tokenAmount);
            return;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Calculates the total assets managed by this strategy in USDC terms.
     * @dev Returns the current value of the strategy's Prime holdings in base asset terms.
     * @return baseAssets The total USDC value managed by this strategy
     */
    function totalAssets() public view returns (uint256 baseAssets) {
        uint256 primeShares = stakingVault.balanceOf(address(this));

        baseAssets = stakingVault.previewRedeem(primeShares);
        return baseAssets;
    }

    /**
     * @notice Calculates the total assets, returning live value only when rewards changed.
     * @param latestNav The previous NAV value from the accounting
     * @param timestamp The timestamp of the previous NAV update
     * @return baseAssets The total USDC value managed by this strategy
     */
    function totalAssets(uint256 latestNav, uint256 timestamp) public view returns (uint256 baseAssets) {
        if (stakingVault.lastRewardDistributedAt() >= timestamp) {
            return totalAssets();
        }
        return latestNav;
    }

    /**
     * @notice Converts a given amount of supported tokens to their USDC equivalent.
     * @dev For PRIME converts with previewRedeem/previewMint based on rounding -> wYLDS -> USDC (1:1)
     *      For wYLDS -> USDC = 1:1
     *      For USDC  -> USDC
     *
     * @param token The token to convert from
     * @param tokenAmount The amount of tokens to convert
     * @param rounding The rounding direction
     * @return The equivalent USDC amount
     */
    function convertToAssets(
        address token,
        uint256 tokenAmount,
        Math.Rounding rounding
    ) public view returns (uint256) {
        if (token == address(stakingVault)) {
            // PRIME -> wYLDS
            return rounding == Math.Rounding.Floor
                ? stakingVault.previewRedeem(tokenAmount)
                : stakingVault.previewMint(tokenAmount);
        }
        if (token == address(yieldVault)) {
            // wYLDS = USDC (1:1)
            return tokenAmount;
        }
        if (token == address(usdc)) {
            return tokenAmount;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Converts a given amount of USDC to the equivalent amount of supported tokens.
     * @dev For PRIME converts with previewDeposit / previewWithdraw vased on rounding
     *      For wYLDS -> USDC = 1:1
     *      For USDC  -> USDC
     *
     * @param token The token to convert to
     * @param baseAssets The amount of USDC to convert
     * @param rounding The rounding direction
     * @return The equivalent token amount
     */
    function convertToTokens(
        address token,
        uint256 baseAssets,
        Math.Rounding rounding
    ) public view returns (uint256) {
        if (token == address(stakingVault)) {
            // USDC (= wYLDS) -> PRIME
            return rounding == Math.Rounding.Floor
                ? stakingVault.previewDeposit(baseAssets)
                : stakingVault.previewWithdraw(baseAssets);
        }
        if (token == address(yieldVault)) {
            // USDC = wYLDS (1:1)
            return baseAssets;
        }
        if (token == address(usdc)) {
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Ensures that the strategy can withdraw the requested amount.
     * @dev Checks against the StakingVault's and YieldVault's maxWithdraw for this strategy.
     *      This does NOT guarantee instant USDC availability, as the YieldVault
     *      redemption is always async.
     *
     * @param caller The address of the caller (unused — check is against strategy's position)
     * @param baseAssets The amount to validate
     */
    function ensureRedeemable(
        address caller,
        address token,
        uint256 baseAssets
    ) external view {
        if (token == address(stakingVault)) {
            uint256 maxWithdrawable = stakingVault.maxWithdraw(caller);
            require(maxWithdrawable >= baseAssets, "StakingMetaVaultExceededMaxWithdraw");
            return;
        }
        if (token == address(yieldVault)) {
            uint256 maxWithdrawable = yieldVault.maxWithdraw(caller);
            require(maxWithdrawable >= baseAssets, "YieldMetaVaultExceededMaxWithdraw");
            return;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Returns an array of supported tokens: PRIME, wYLDS, USDC
     */
    function getSupportedTokens() external view returns (IERC20[] memory) {
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = stakingVault; // PRIME
        tokens[1] = yieldVault;   // wYLDS
        tokens[2] = usdc;         // USDC
        return tokens;
    }

    /**
     * @notice Updates the cooldown periods for PRIME/wYLDS withdrawals.
     * @dev This only affects the ERC-20 cooldown for PRIME and wYLDS withdrawals.
     *
     * @param primeCooldownJrt_ Cooldown seconds for JRT tranche (max 7 days)
     * @param primeCooldownSrt_ Cooldown seconds for SRT tranche (max 7 days)
     */
    function setCooldowns(
        uint256 primeCooldownJrt_,
        uint256 primeCooldownSrt_
    ) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        uint256 WEEK = 7 days;
        if (primeCooldownJrt_ > WEEK || primeCooldownSrt_ > WEEK) {
            revert InvalidConfigCooldown();
        }
        primeCooldownJrt = primeCooldownJrt_;
        primeCooldownSrt = primeCooldownSrt_;

        bool isDisabled = primeCooldownJrt_ == 0 && primeCooldownSrt_ == 0;
        erc20Cooldown.setCooldownDisabled(stakingVault, isDisabled);
        emit CooldownsChanged(primeCooldownJrt_, primeCooldownSrt_);
    }

    function shareToken() external view returns (address) {
        return address(stakingVault);
    }

    function supportsToken(address token) external override view returns (bool) {
        return token == address(stakingVault) || token == address(yieldVault) || token == address(usdc);
    }
}
