// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IErrors} from "../../interfaces/IErrors.sol";
import {IStrataCDO} from "../../interfaces/IStrataCDO.sol";
import {IERC20Cooldown} from "../../interfaces/cooldown/ICooldown.sol";
import {Strategy} from "../../Strategy.sol";
import {INestAccountant, IAprSnapshotProvider} from "./interfaces/INestContracts.sol";

/// @title NestAlphaStrategy
/// @notice Strategy that holds nALPHA (Nest Credit Alpha Vault) shares
/// @dev Deposits receive nALPHA from the TrancheDepositor via the NestDepositAdapter.
///      Withdrawals output nALPHA via erc20Cooldown — users redeem nALPHA→USDC independently.
///      NAV is computed using the Nest Accountant exchange rate.
contract NestAlphaStrategy is Strategy {

    /// @notice nALPHA share token (BoringVault ERC-20)
    IERC20 public immutable nALPHA;

    /// @notice USDC token — the base asset for NAV calculation
    IERC20 public immutable USDC;

    /// @notice Nest Credit Accountant — provides the nALPHA/USDC exchange rate
    INestAccountant public immutable accountant;

    /// @notice Cooldown contract for ERC-20 token transfers with time locks
    IERC20Cooldown public erc20Cooldown;

    /// @notice Cooldown period for JRT (Junior Tranche) withdrawals
    uint256 public nAlphaCooldownJrt;

    /// @notice Cooldown period for SRT (Senior Tranche) withdrawals
    uint256 public nAlphaCooldownSrt;

    /// @notice APR snapshot provider — called on deposit/withdraw to keep APR feed fresh
    IAprSnapshotProvider public aprProvider;

    event CooldownsChanged(uint256 jrt, uint256 srt);
    event AprProviderChanged(address indexed provider);

    constructor(
        IERC20 nALPHA_,
        IERC20 USDC_,
        INestAccountant accountant_
    ) Strategy(address(USDC_), address(nALPHA_)) {
        nALPHA = nALPHA_;
        USDC = USDC_;
        accountant = accountant_;
    }

    function initialize(
        address owner_,
        address acm_,
        IStrataCDO cdo_,
        IERC20Cooldown erc20Cooldown_
    ) public virtual initializer {
        AccessControlled_init(owner_, acm_);

        cdo = cdo_;
        erc20Cooldown = erc20Cooldown_;

        SafeERC20.forceApprove(nALPHA, address(erc20Cooldown_), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Deposit
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Accepts nALPHA deposits from the CDO (transferred from the Tranche)
    /// @param token Must be nALPHA
    /// @param tokenAmount The amount of nALPHA shares being deposited
    /// @param baseAssets The USDC-equivalent value as calculated by the CDO
    /// @param owner The address holding the nALPHA (the Tranche contract)
    function deposit(
        address /* tranche */,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address owner
    ) public override onlyCDO returns (uint256) {
        if (token != address(nALPHA)) revert UnsupportedToken(token);

        SafeERC20.safeTransferFrom(IERC20(token), owner, address(this), tokenAmount);
        _updateAprSnapshot();
        return baseAssets;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Withdraw
    // ═══════════════════════════════════════════════════════════════════════

    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver
    ) public override onlyCDO returns (uint256) {
        return _withdraw(tranche, token, tokenAmount, baseAssets, sender, receiver, false);
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
        return _withdraw(tranche, token, tokenAmount, baseAssets, sender, receiver, shouldSkipCooldown);
    }

    function _withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 /* baseAssets */,
        address sender,
        address receiver,
        bool shouldSkipCooldown
    ) internal returns (uint256) {
        if (token != address(nALPHA)) revert UnsupportedToken(token);

        uint256 cooldownSeconds = shouldSkipCooldown
            ? 0
            : (cdo.isJrt(tranche) ? nAlphaCooldownJrt : nAlphaCooldownSrt);

        erc20Cooldown.transfer(nALPHA, sender, receiver, tokenAmount, cooldownSeconds);
        _updateAprSnapshot();
        return tokenAmount;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Reserve reduction
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Allows the CDO to withdraw nALPHA from the strategy's reserve
    function reduceReserve(
        address token,
        uint256 tokenAmount,
        address receiver
    ) external onlyCDO {
        if (token != address(nALPHA)) revert UnsupportedToken(token);

        erc20Cooldown.transfer(nALPHA, receiver, receiver, tokenAmount, 0);
        _updateAprSnapshot();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  NAV / Accounting
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the total USDC-equivalent value of nALPHA held by this strategy
    /// @dev NAV = nALPHA.balanceOf(this) * rate / 1e6
    function totalAssets() public view returns (uint256 baseAssets) {
        uint256 shares = nALPHA.balanceOf(address(this));
        if (shares == 0) return 0;
        uint256 rate = accountant.getRateInQuoteSafe(address(USDC));
        return Math.mulDiv(shares, rate, 1e6);
    }

    /// @notice Returns fresh NAV only if the accountant rate change is meaningful
    /// @dev Used by DiscreteAccounting to detect new gains. If the accountant exchange rate
    ///      has not been updated since the last checkpoint, or the update is negligible
    ///      (as determined by the APR provider), returns the previous NAV to avoid
    ///      premature true-ups from noise in the Nest batch-harvesting pattern.
    /// @param latestNav The NAV from the last accounting checkpoint
    /// @param timestamp The timestamp of the last accounting checkpoint
    function totalAssets(uint256 latestNav, uint256 timestamp) public view override returns (uint256) {
        INestAccountant.AccountantState memory state = accountant.accountantState();

        // No update since last checkpoint — return stale NAV
        if (state.lastUpdateTimestamp < timestamp) return latestNav;

        // If an APR provider is configured, ask it whether this rate change is meaningful.
        // This filters out negligible rate tweaks (< 0.5% APR AND < 2 days) that would
        // otherwise trigger unnecessary reconciliation.
        IAprSnapshotProvider provider = aprProvider;
        if (address(provider) != address(0)) {
            if (!provider.isMeaningfulUpdate(state.exchangeRate, state.lastUpdateTimestamp)) {
                return latestNav;
            }
        }

        return totalAssets();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Conversions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Converts nALPHA token amount to USDC-equivalent base assets
    function convertToAssets(
        address token,
        uint256 tokenAmount,
        Math.Rounding rounding
    ) public view override returns (uint256) {
        if (token != address(nALPHA)) revert UnsupportedToken(token);

        uint256 rate = accountant.getRateInQuoteSafe(address(USDC));
        return Math.mulDiv(tokenAmount, rate, 1e6, rounding);
    }

    /// @notice Converts USDC-equivalent base assets to nALPHA token amount
    function convertToTokens(
        address token,
        uint256 baseAssets,
        Math.Rounding rounding
    ) public view override returns (uint256) {
        if (token != address(nALPHA)) revert UnsupportedToken(token);

        uint256 rate = accountant.getRateInQuoteSafe(address(USDC));
        return Math.mulDiv(baseAssets, 1e6, rate, rounding);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Query helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice nALPHA is always redeemable from the strategy's perspective
    function ensureRedeemable(address, address, uint256) external pure {
        // no-op: nALPHA can always be transferred out via erc20Cooldown
    }

    /// @notice Returns the single supported token: nALPHA
    function getSupportedTokens() external view returns (IERC20[] memory) {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = nALPHA;
        return tokens;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Updates the cooldown periods for nALPHA withdrawals
    function setCooldowns(
        uint256 nAlphaCooldownJrt_,
        uint256 nAlphaCooldownSrt_
    ) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        uint256 WEEK = 7 days;
        if (nAlphaCooldownJrt_ > WEEK || nAlphaCooldownSrt_ > WEEK) {
            revert InvalidConfigCooldown();
        }
        nAlphaCooldownJrt = nAlphaCooldownJrt_;
        nAlphaCooldownSrt = nAlphaCooldownSrt_;

        bool isDisabled = nAlphaCooldownJrt_ == 0 && nAlphaCooldownSrt_ == 0;
        erc20Cooldown.setCooldownDisabled(nALPHA, isDisabled);
        emit CooldownsChanged(nAlphaCooldownJrt_, nAlphaCooldownSrt_);
    }

    /// @notice Sets the APR snapshot provider called on deposit/withdraw
    /// @param aprProvider_ The provider address, or address(0) to disable
    function setAprProvider(
        IAprSnapshotProvider aprProvider_
    ) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        aprProvider = aprProvider_;
        emit AprProviderChanged(address(aprProvider_));
    }

    /// @dev Calls updateSnapshot() on the APR provider if one is set.
    ///      No-op when aprProvider is address(0).
    function _updateAprSnapshot() internal {
        IAprSnapshotProvider provider = aprProvider;
        if (address(provider) != address(0)) {
            provider.updateSnapshot();
        }
    }

    function supportsToken(address token) external view returns (bool) {
        return token == address(nALPHA);
    }
}
