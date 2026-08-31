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

/// @title NestOpalStrategy
/// @notice Strategy that holds nOPAL (Nest BlackOpal LiquidStone II Vault) shares
/// @dev Deposits receive nOPAL from the TrancheDepositor via the NestOpalDepositAdapter.
///      Withdrawals output nOPAL via erc20Cooldown — users redeem nOPAL→USDC independently.
///      NAV is computed using the Nest Accountant exchange rate.
///      Structurally identical to NestAlphaStrategy — same BoringVault architecture, same
///      6-decimal token, same Accountant interface, same NAV formula.
contract NestOpalStrategy is Strategy {

    /// @notice nOPAL share token (BoringVault ERC-20, 6 decimals)
    IERC20 public immutable nOPAL;

    /// @notice USDC token — the base asset for NAV calculation
    IERC20 public immutable USDC;

    /// @notice Nest Credit Accountant — provides the nOPAL/USDC exchange rate
    INestAccountant public immutable accountant;

    /// @notice Cooldown contract for ERC-20 token transfers with time locks
    IERC20Cooldown public erc20Cooldown;

    /// @notice Cooldown period for JRT (Junior Tranche) withdrawals
    uint256 public nOpalCooldownJrt;

    /// @notice Cooldown period for SRT (Senior Tranche) withdrawals
    uint256 public nOpalCooldownSrt;

    /// @notice APR snapshot provider — called on deposit/withdraw to keep APR feed fresh
    IAprSnapshotProvider public aprProvider;

    event CooldownsChanged(uint256 jrt, uint256 srt);
    event AprProviderChanged(address indexed provider);

    constructor(
        IERC20 nOPAL_,
        IERC20 USDC_,
        INestAccountant accountant_
    ) Strategy(address(USDC_), address(nOPAL_)) {
        nOPAL = nOPAL_;
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

        SafeERC20.forceApprove(nOPAL, address(erc20Cooldown_), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Deposit
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Accepts nOPAL deposits from the CDO (transferred from the Tranche)
    /// @param token Must be nOPAL
    /// @param tokenAmount The amount of nOPAL shares being deposited
    /// @param baseAssets The USDC-equivalent value as calculated by the CDO
    /// @param owner The address holding the nOPAL (the Tranche contract)
    function deposit(
        address /* tranche */,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address owner
    ) public override onlyCDO returns (uint256) {
        if (token != address(nOPAL)) revert UnsupportedToken(token);

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
        if (token != address(nOPAL)) revert UnsupportedToken(token);

        uint256 cooldownSeconds = shouldSkipCooldown
            ? 0
            : (cdo.isJrt(tranche) ? nOpalCooldownJrt : nOpalCooldownSrt);

        erc20Cooldown.transfer(nOPAL, sender, receiver, tokenAmount, cooldownSeconds);
        _updateAprSnapshot();
        return tokenAmount;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Reserve reduction
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Allows the CDO to withdraw nOPAL from the strategy's reserve
    function reduceReserve(
        address token,
        uint256 tokenAmount,
        address receiver
    ) external onlyCDO {
        if (token != address(nOPAL)) revert UnsupportedToken(token);

        erc20Cooldown.transfer(nOPAL, receiver, receiver, tokenAmount, 0);
        _updateAprSnapshot();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  NAV / Accounting
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the total USDC-equivalent value of nOPAL held by this strategy
    /// @dev NAV = nOPAL.balanceOf(this) * rate / 1e6
    ///      Both nOPAL and the Accountant use 6 decimals, verified on-chain.
    function totalAssets() public view returns (uint256 baseAssets) {
        uint256 shares = nOPAL.balanceOf(address(this));
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
            // Negative rate change: only reconcile after 24h cooldown since last reconciliation.
            // Positive changes reconcile immediately. This gives temporary dips time to recover
            // before realizing losses in the Senior/Junior split.
            // Note: `timestamp` carries `lastReconciliation` from DYSAccounting when
            // useNavAtReconciliation is enabled.
            if (provider.isNegativeChange(state.exchangeRate)) {
                if (block.timestamp - timestamp < 24 hours) {
                    return latestNav;
                }
            }
        }

        return totalAssets();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Conversions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Converts nOPAL token amount to USDC-equivalent base assets
    function convertToAssets(
        address token,
        uint256 tokenAmount,
        Math.Rounding rounding
    ) public view override returns (uint256) {
        if (token == address(nOPAL)) {
            uint256 rate = accountant.getRateInQuoteSafe(address(USDC));
            return Math.mulDiv(tokenAmount, rate, 1e6, rounding);
        }
        if (token == address(USDC)) {
            return tokenAmount;
        }

        revert UnsupportedToken(token);
    }

    /// @notice Converts USDC-equivalent base assets to nOPAL token amount
    function convertToTokens(
        address token,
        uint256 baseAssets,
        Math.Rounding rounding
    ) public view override returns (uint256) {
        if (token == address(nOPAL)) {
            uint256 rate = accountant.getRateInQuoteSafe(address(USDC));
            return Math.mulDiv(baseAssets, 1e6, rate, rounding);
        }
        if (token == address(USDC)) {
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Query helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice nOPAL is always redeemable from the strategy's perspective
    function ensureRedeemable(address, address, uint256) external pure {
        // no-op: nOPAL can always be transferred out via erc20Cooldown
    }

    /// @notice Returns the single supported token: nOPAL
    function getSupportedTokens() external view returns (IERC20[] memory) {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = nOPAL;
        return tokens;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Updates the cooldown periods for nOPAL withdrawals
    function setCooldowns(
        uint256 nOpalCooldownJrt_,
        uint256 nOpalCooldownSrt_
    ) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        uint256 WEEK = 7 days;
        if (nOpalCooldownJrt_ > WEEK || nOpalCooldownSrt_ > WEEK) {
            revert InvalidConfigCooldown();
        }
        nOpalCooldownJrt = nOpalCooldownJrt_;
        nOpalCooldownSrt = nOpalCooldownSrt_;

        bool isDisabled = nOpalCooldownJrt_ == 0 && nOpalCooldownSrt_ == 0;
        erc20Cooldown.setCooldownDisabled(nOPAL, isDisabled);
        emit CooldownsChanged(nOpalCooldownJrt_, nOpalCooldownSrt_);
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
        return token == address(nOPAL);
    }
}
