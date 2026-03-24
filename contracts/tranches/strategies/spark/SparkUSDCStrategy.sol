// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrataCDO} from "../../interfaces/IStrataCDO.sol";
import {IERC20Cooldown} from "../../interfaces/cooldown/ICooldown.sol";
import {Strategy} from "../../Strategy.sol";
import {ISparkVault} from "./ISparkVault.sol";

contract SparkUSDCStrategy is Strategy {
    uint256 public constant VESTING_PERIOD = 24 hours;

    ISparkVault public immutable spVault;
    IERC20 public immutable USDC;
    address public immutable shareToken;

    IERC20Cooldown public erc20Cooldown;

    uint256 public usdcCooldownJrt;
    uint256 public usdcCooldownSrt;

    // vesting state
    uint256 public vestingAmount;
    uint256 public lastDistributionTimestamp;
    uint256 public lastReportedAssets;

    event CooldownsChanged(uint256 jrt, uint256 srt);
    event Dripped(uint256 gain, uint256 lastReportedAssets, uint256 timestamp);

    constructor(ISparkVault spVault_) {
        spVault = spVault_;
        shareToken = address(spVault_);
        USDC = IERC20(spVault_.asset());
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

        lastDistributionTimestamp = block.timestamp;

        SafeERC20.forceApprove(USDC, address(erc20Cooldown_), type(uint256).max);
    }

    function deposit(
        address,
        /* tranche */
        address token,
        uint256 tokenAmount,
        uint256,
        /* baseAssets */
        address owner
    )
        external
        onlyCDO
        returns (uint256)
    {
        if (token != address(USDC)) revert UnsupportedToken(token);

        _drip();

        SafeERC20.safeTransferFrom(USDC, owner, address(this), tokenAmount);
        SafeERC20.forceApprove(USDC, address(spVault), tokenAmount);
        spVault.deposit(tokenAmount, address(this));
        lastReportedAssets += tokenAmount;

        return tokenAmount;
    }

    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver
    ) external onlyCDO returns (uint256) {
        return _withdrawInner(tranche, token, tokenAmount, baseAssets, sender, receiver, false);
    }

    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver,
        bool shouldSkipCooldown
    ) external onlyCDO returns (uint256) {
        return _withdrawInner(
            tranche, token, tokenAmount, baseAssets, sender, receiver, shouldSkipCooldown
        );
    }

    function _withdrawInner(
        address tranche,
        address token,
        uint256,
        /* tokenAmount */
        uint256 baseAssets,
        address sender,
        address receiver,
        bool shouldSkipCooldown
    ) internal returns (uint256) {
        if (token != address(USDC)) revert UnsupportedToken(token);

        _drip();

        uint256 shares = spVault.previewWithdraw(baseAssets);
        spVault.redeem(shares, address(this), address(this));
        _debitRecognized(baseAssets);

        uint256 cooldownSeconds = 0;
        if (!shouldSkipCooldown && (usdcCooldownJrt != 0 || usdcCooldownSrt != 0)) {
            cooldownSeconds = cdo.isJrt(tranche) ? usdcCooldownJrt : usdcCooldownSrt;
        }
        erc20Cooldown.transfer(USDC, sender, receiver, baseAssets, cooldownSeconds);

        return baseAssets;
    }

    function reduceReserve(address token, uint256 tokenAmount, address receiver) external onlyCDO {
        if (token != address(USDC)) revert UnsupportedToken(token);

        _drip();

        uint256 shares = spVault.previewWithdraw(tokenAmount);
        if (shares == 0) revert ZeroAmount();

        spVault.redeem(shares, receiver, address(this));
        _debitRecognized(tokenAmount);
    }

    function _debitRecognized(uint256 amount) internal {
        uint256 vested = vestingAmount - getUnvestedAmount();
        require(amount <= lastReportedAssets + vested, "ExceedsRecognized");

        if (amount <= lastReportedAssets) {
            lastReportedAssets -= amount;
        } else {
            uint256 fromVesting = amount - lastReportedAssets;
            lastReportedAssets = 0;
            vestingAmount -= fromVesting;
        }
    }

    function totalAssets() public view returns (uint256) {
        return lastReportedAssets + vestingAmount - getUnvestedAmount();
    }

    function totalAssets(uint256, uint256) public view returns (uint256) {
        return totalAssets();
    }

    function getUnvestedAmount() public view returns (uint256) {
        uint256 deltaT = block.timestamp - lastDistributionTimestamp;
        if (deltaT >= VESTING_PERIOD) return 0;
        return vestingAmount * (VESTING_PERIOD - deltaT) / VESTING_PERIOD;
    }

    function vestingPeriod() external pure returns (uint256) {
        return VESTING_PERIOD;
    }

    function drip() external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        _drip();
    }

    function _drip() internal {
        if (getUnvestedAmount() > 0) return;

        uint256 actual = spVault.previewRedeem(spVault.balanceOf(address(this)));
        uint256 currentlyVested = lastReportedAssets + vestingAmount;

        if (actual >= currentlyVested) {
            vestingAmount = actual - currentlyVested;
            lastReportedAssets = currentlyVested;
        } else {
            vestingAmount = 0;
            lastReportedAssets = actual;
        }
        lastDistributionTimestamp = block.timestamp;

        emit Dripped(vestingAmount, lastReportedAssets, block.timestamp);
    }

    function convertToAssets(
        address token,
        uint256 tokenAmount,
        Math.Rounding /* rounding */
    )
        external
        view
        returns (uint256)
    {
        if (token != address(USDC)) revert UnsupportedToken(token);
        return tokenAmount;
    }

    function convertToTokens(
        address token,
        uint256 baseAssets,
        Math.Rounding /* rounding */
    )
        external
        view
        returns (uint256)
    {
        if (token != address(USDC)) revert UnsupportedToken(token);
        return baseAssets;
    }

    function ensureRedeemable(address caller, address token, uint256 baseAssets) external view {
        if (token != address(USDC)) revert UnsupportedToken(token);
        uint256 maxTokenToBaseAssetsWithdraw = spVault.maxWithdraw(caller);
        require(maxTokenToBaseAssetsWithdraw >= baseAssets, "MetaVaultExceededMaxWithdraw");
    }

    function getSupportedTokens() external view returns (IERC20[] memory) {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = USDC;
        return tokens;
    }

    function setCooldowns(uint256 usdcCooldownJrt_, uint256 usdcCooldownSrt_)
        external
        onlyRole(UPDATER_STRAT_CONFIG_ROLE)
    {
        uint256 WEEK = 7 days;
        if (usdcCooldownJrt_ > WEEK || usdcCooldownSrt_ > WEEK) {
            revert InvalidConfigCooldown();
        }
        usdcCooldownJrt = usdcCooldownJrt_;
        usdcCooldownSrt = usdcCooldownSrt_;

        bool isDisabled = usdcCooldownJrt_ == 0 && usdcCooldownSrt_ == 0;
        erc20Cooldown.setCooldownDisabled(USDC, isDisabled);
        emit CooldownsChanged(usdcCooldownJrt_, usdcCooldownSrt_);
    }

    function supportsToken(address token) external view returns (bool) {
        return token == address(USDC);
    }
}
