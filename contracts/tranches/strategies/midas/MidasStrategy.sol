// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMToken} from "./interfaces/IMToken.sol";
import {IDepositVault} from "./interfaces/IDepositVault.sol";
import {IRedemptionVault} from "./interfaces/IRedemptionVault.sol";
import {IErrors} from "../../interfaces/IErrors.sol";
import {IStrataCDO} from "../../interfaces/IStrataCDO.sol";
import {
    IERC20Cooldown,
    IUnstakeCooldown
} from "../../interfaces/cooldown/ICooldown.sol";
import {Strategy} from "../../Strategy.sol";
import {IRoundDataOracle} from "./AaveOracleAprPairProvider.sol";

contract MidasStrategy is Strategy {
    // e.g. mHYPER 0x9b5528528656DBC094765E2abB79F293c21191B9
    IMToken public immutable mToken;

    // e.g. 0xbA9FD2850965053Ffab368Df8AA7eD2486f11024
    IDepositVault public immutable depositVault;

    // e.g. 0x570c15bc5faf98531a8b351d69e22e41e3505e47
    IRedemptionVault public immutable redemptionVault;

    // Chainlink-style oracle for mToken price (e.g. 0x43881B05C3BE68B2d33eb70aDdF9F666C5005f68)
    IRoundDataOracle public immutable oracle;


    // Additional supported tokens to deposit, beyond the base asset and mToken
    mapping(address token => bool isSupported) public depositTokensDict;
    mapping(address token => uint8 decimals) public depositTokenDecimals;
    address[] public depositTokens;

    IERC20Cooldown public erc20Cooldown;
    IUnstakeCooldown public unstakeCooldown;

    /**
     * configuration
     */
    uint256 public mTokenCooldownJrt;
    uint256 public mTokenCooldownSrt;

    /// @notice Referrer ID for Midas deposit tracking
    bytes32 public referrerId;

    /// @notice Maximum slippage tolerance for Midas deposits in basis points (100 = 1%)
    uint256 public maxDepositSlippageBps;

    event CooldownsChanged(uint256 jrt, uint256 srt);
    event ReferrerIdChanged(bytes32 referrerId);
    event MaxDepositSlippageBpsChanged(uint256 bps);

    constructor(
        IERC20 baseAsset_,
        IMToken mToken_,
        IDepositVault depositVault_,
        IRedemptionVault redemptionVault_,
        IRoundDataOracle oracle_
    ) Strategy(address(baseAsset_), address(mToken_)) {
        mToken = mToken_;
        depositVault = depositVault_;
        redemptionVault = redemptionVault_;
        oracle = oracle_;
    }

    function initialize(
        address owner_,
        address acm_,
        IStrataCDO cdo_,
        IERC20Cooldown erc20Cooldown_,
        IUnstakeCooldown unstakeCooldown_,
        address[] memory depositTokens_
    ) public virtual initializer {
        AccessControlled_init(owner_, acm_);

        cdo = cdo_;
        erc20Cooldown = erc20Cooldown_;
        unstakeCooldown = unstakeCooldown_;

        depositTokens = depositTokens_;
        for (uint256 i = 0; i < depositTokens_.length; i++) {
            address dt = depositTokens_[i];
            depositTokensDict[dt] = true;
            depositTokenDecimals[dt] = IERC20Metadata(dt).decimals();
        }

        SafeERC20.forceApprove(
            mToken,
            address(erc20Cooldown),
            type(uint256).max
        );
        SafeERC20.forceApprove(
            mToken,
            address(unstakeCooldown),
            type(uint256).max
        );
    }

    /**
     * @notice Processes asset deposits for the CDO contract.
     * @dev This method is called by the CDO contract to handle asset deposits.
     *      If the deposited token is the base asset (or a deposit token like DAI/USDS),
     *      it will be deposited into the Midas vault to receive mToken.
     *      If the deposited token is already mToken, it will be accepted as is.
     * @param tranche The address of the tranche depositing assets (not used in this strategy)
     * @param token The address of the token being deposited
     * @param tokenAmount The amount of tokens being deposited
     * @param baseAssets The amount of base assets represented by the deposit (used for Midas deposits)
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
        SafeERC20.safeTransferFrom(
            IERC20(token),
            owner,
            address(this),
            tokenAmount
        );

        if (token == baseAsset || depositTokensDict[token] == true) {
            SafeERC20.forceApprove(
                IERC20(token),
                address(depositVault),
                tokenAmount
            );

            // Scale tokenAmount to base18 — Midas expects all amounts in 18 decimals
            uint8 tokenDec = token == baseAsset
                ? baseAssetDecimals
                : depositTokenDecimals[token];
            uint256 amountBase18 = tokenAmount * 10 ** (18 - tokenDec);

            // Measure actual mToken received (accounts for Midas fees)
            uint256 mTokenBefore = mToken.balanceOf(address(this));

            // Calculate minimum acceptable mToken output
            uint256 minReceiveAmount = maxDepositSlippageBps > 0
                ? (convertToTokens(
                    address(mToken),
                    baseAssets,
                    Math.Rounding.Floor
                ) * (10_000 - maxDepositSlippageBps)) / 10_000
                : 0;
            depositVault.depositInstant(
                token,
                amountBase18,
                minReceiveAmount,
                referrerId
            );
            uint256 mTokenReceived = mToken.balanceOf(address(this)) - mTokenBefore;
            return
                convertToAssets(
                    address(mToken),
                    mTokenReceived,
                    Math.Rounding.Floor
                );
        }
        if (token == address(mToken)) {
            // already transferred in ↑
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Processes asset withdrawals for the CDO contract.
     * @dev This method is called by the CDO contract to handle asset withdrawals.
     *      If withdrawing Midas, a cooldown period is applied based on the tranche type.
     *      If withdrawing USDe, the Midas is unstaked with a cooldown.
     * @param tranche The address of the tranche withdrawing assets
     * @param token The address of the token to be withdrawn
     * @param tokenAmount The amount of tokens to be withdrawn (not used in this implementation)
     * @param baseAssets The amount of base assets to be withdrawn
     * @param receiver The address that will receive the withdrawn assets
     * @param sender The account that initiated the withdrawal
     * @return The amount of tokens withdrawn (shares for Midas, baseAssets for USDe)
     */
    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver
    ) public override onlyCDO returns (uint256) {
        return
            withdrawInner(
                tranche,
                token,
                tokenAmount,
                baseAssets,
                sender,
                receiver,
                false
            );
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
        return
            withdrawInner(
                tranche,
                token,
                tokenAmount,
                baseAssets,
                sender,
                receiver,
                shouldSkipCooldown
            );
    }

    function withdrawInner(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver,
        bool shouldSkipCooldown
    ) internal returns (uint256) {
        uint256 shares = convertToTokens(
            address(mToken),
            baseAssets,
            Math.Rounding.Ceil
        ); // aka IERC4626::previewWithdraw
        if (token == address(mToken)) {
            uint256 cooldownSeconds = shouldSkipCooldown
                ? 0
                : (cdo.isJrt(tranche) ? mTokenCooldownJrt : mTokenCooldownSrt);
            erc20Cooldown.transfer(
                mToken,
                sender,
                receiver,
                shares,
                cooldownSeconds
            );
            return shares;
        }
        if (token == baseAsset) {
            unstakeCooldown.transfer(mToken, sender, receiver, shares);
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Allows the CDO to withdraw tokens from the strategy's reserve
     * @dev This function is part of the reserve reduction process and can only be called by the CDO.
     *      It handles both mToken and base asset tokens, applying different transfer mechanisms for each.
     *      For mToken, it uses erc20Cooldown with no cooldown period.
     *      For base asset, it uses unstakeCooldown to handle the unstaking process.
     * @param token The address of the token to be withdrawn (either mToken or base asset)
     * @param tokenAmount The amount of tokens to be withdrawn
     * @param receiver The address that will receive the withdrawn tokens
     */
    function reduceReserve(
        address token,
        uint256 tokenAmount,
        address receiver
    ) external onlyCDO {
        if (token == address(mToken)) {
            erc20Cooldown.transfer(mToken, receiver, receiver, tokenAmount, 0);
            return;
        }
        if (token == baseAsset) {
            // tokenAmount is in baseAssets, convert to MTokens (Rounding.Floor/in favor of protocol) and trigger unstaking
            uint256 shares = convertToTokens(
                address(mToken),
                tokenAmount,
                Math.Rounding.Floor
            );
            if (shares == 0) {
                revert ZeroAmount();
            }
            unstakeCooldown.transfer(mToken, receiver, receiver, shares);
            return;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Calculates the total assets managed by this strategy
     * @dev Returns the current value of the strategy's mToken holdings in base asset terms.
     * @return baseAssets_ The total base asset value managed by this strategy
     */
    function totalAssets() public view override(Strategy) returns (uint256 baseAssets_) {
        uint256 shares = mToken.balanceOf(address(this));
        baseAssets_ = convertToAssets(
            address(mToken),
            shares,
            Math.Rounding.Floor
        );
        return baseAssets_;
    }

    /**
     * @notice Calculates the total assets, returning fresh value only if the oracle has updated since last nav
     * @dev Used by DiscreteAccounting to detect new gains. If the oracle has not updated since the
     *      last accounting checkpoint, we return the previous NAV to avoid premature true-ups.
     * @param latestNav The NAV from the last accounting checkpoint
     * @param timestamp The timestamp of the last accounting checkpoint
     * @return baseAssets_ The total base asset value managed by this strategy
     */
    function totalAssets(
        uint256 latestNav,
        uint256 timestamp
    ) public view override(Strategy) returns (uint256 baseAssets_) {
        (, , , uint256 updatedAt, ) = oracle.latestRoundData();
        if (updatedAt >= timestamp) {
            return totalAssets();
        }
        return latestNav;
    }

    /**
     * @notice Converts a given amount of supported tokens to their equivalent in base asset
     * @dev For mToken, uses the oracle exchange rate with the appropriate rounding.
     *      For baseAsset, returns the input amount as is.
     * @param token The address of the token to convert (either mToken or baseAsset)
     * @param tokenAmount The amount of tokens to convert
     * @param rounding The rounding direction to use for the conversion (floor or ceiling)
     * @return The equivalent amount in base asset
     */
    function convertToAssets(
        address token,
        uint256 tokenAmount,
        Math.Rounding rounding
    ) public view override  returns (uint256) {
        if (token == address(mToken)) {
            uint256 rate = getOracleRate();
            return Math.mulDiv(tokenAmount, rate, 10 ** (18 + shareTokenDecimals - baseAssetDecimals), rounding);
        }
        if (token == baseAsset) {
            return tokenAmount;
        }
        if (depositTokensDict[token]) {
            // 1:1 rate, just scale decimals (e.g. DAI 18→USDC 6)
            uint8 tokenDec = depositTokenDecimals[token];
            if (tokenDec > baseAssetDecimals) {
                return tokenAmount / (10 ** (tokenDec - baseAssetDecimals));
            } else if (tokenDec < baseAssetDecimals) {
                return tokenAmount * (10 ** (baseAssetDecimals - tokenDec));
            }
            return tokenAmount;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Converts a given amount of base assets to the equivalent amount of supported tokens
     * @dev For mToken, uses the oracle exchange rate with the appropriate rounding.
     *      For baseAsset, returns the input amount as is.
     * @param token The address of the token to convert to (either mToken or baseAsset)
     * @param baseAssets The amount of base assets to convert
     * @param rounding The rounding direction to use for the conversion (floor or ceiling)
     * @return The equivalent amount in the requested token (mToken or baseAsset)
     */
    function convertToTokens(
        address token,
        uint256 baseAssets,
        Math.Rounding rounding
    ) public view override returns (uint256) {
        if (token == address(mToken)) {
            uint256 rate = getOracleRate();
            return Math.mulDiv(baseAssets, 10 ** (18 + shareTokenDecimals - baseAssetDecimals), rate, rounding);
        }
        if (token == baseAsset) {
            return baseAssets;
        }
        if (depositTokensDict[token]) {
            // 1:1 rate, just scale decimals (e.g. USDC 6→DAI 18)
            uint8 tokenDec = depositTokenDecimals[token];
            if (tokenDec > baseAssetDecimals) {
                return baseAssets * (10 ** (tokenDec - baseAssetDecimals));
            }
            if (tokenDec < baseAssetDecimals) {
                return baseAssets / (10 ** (baseAssetDecimals - tokenDec));
            }
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Reads the mToken price from the oracle, scaled to base18
     * @dev Validates that the oracle answer is positive
     * @return rate The mToken price in 18 decimal precision
     */
    function getOracleRate() public view returns (uint256 rate) {
        (, int256 answer, , , ) = oracle.latestRoundData();
        require(answer > 0, "InvalidRate");

        uint8 decimals = 8; // Chainlink standard
        // Scale to base18: answer * 10^(18 - decimals)
        rate = uint256(answer) * 10 ** (18 - decimals);
    }

    /**
     * @notice Ensures that the caller can withdraw the deposited tokenAssets amount
     * @param caller The address of the caller
     * @param baseAssets The amount of base assets to check against
     */
    function ensureRedeemable(
        address caller,
        address /* token */,
        uint256 baseAssets
    ) external view {}

    /**
     * @notice Returns an array of supported tokens: mToken, base asset, and deposit tokens
     */
    function getSupportedTokens() external view returns (IERC20[] memory) {
        IERC20[] memory tokens = new IERC20[](2 + depositTokens.length);
        tokens[0] = IERC20(address(mToken));
        tokens[1] = IERC20(baseAsset);
        for (uint256 i = 0; i < depositTokens.length; i++) {
            tokens[2 + i] = IERC20(depositTokens[i]);
        }
        return tokens;
    }

    /**
     * @notice Updates the cooldown periods for Midas withdrawals (USDe cooldown is already defined by Ethena's unstaking period)
     */
    function setCooldowns(
        uint256 mTokenCooldownJrt_,
        uint256 mTokenCooldownSrt_
    ) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        uint256 WEEK = 7 days;
        if (mTokenCooldownJrt_ > WEEK || mTokenCooldownSrt_ > WEEK) {
            revert InvalidConfigCooldown();
        }
        mTokenCooldownJrt = mTokenCooldownJrt_;
        mTokenCooldownSrt = mTokenCooldownSrt_;

        bool isDisabled = mTokenCooldownJrt_ == 0 && mTokenCooldownSrt_ == 0;
        erc20Cooldown.setCooldownDisabled(mToken, isDisabled);
        emit CooldownsChanged(mTokenCooldownJrt_, mTokenCooldownSrt_);
    }

    /**
     * @notice Updates the referrer ID used for Midas deposits
     */
    function setReferrerId(
        bytes32 referrerId_
    ) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        referrerId = referrerId_;
        emit ReferrerIdChanged(referrerId_);
    }

    /**
     * @notice Updates the maximum slippage tolerance for Midas deposits
     * @param bps_ Slippage in basis points (100 = 1%, max 1000 = 10%)
     */
    function setMaxDepositSlippageBps(
        uint256 bps_
    ) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        require(bps_ <= 1000, "SlippageTooHigh");
        maxDepositSlippageBps = bps_;
        emit MaxDepositSlippageBpsChanged(bps_);
    }

    function supportsToken(address token) external override view returns (bool) {
        return token == address(mToken) || token == baseAsset || depositTokensDict[token];
    }

    function getRate() external view override returns (uint256) {
        return getOracleRate();
    }
}
