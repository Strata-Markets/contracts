// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { IStrataCDO }  from "./interfaces/IStrataCDO.sol";
import { IStrategy } from "./interfaces/IStrategy.sol";
import { ITranche } from "./interfaces/ITranche.sol";
import { CDOComponent }  from "./base/CDOComponent.sol";

contract Tranche is ITranche, CDOComponent, ERC4626Upgradeable, ERC20PermitUpgradeable {

    /// @notice Minimum non-zero shares amount to prevent donation attack
    uint256 private constant MIN_SHARES = 0.1 ether;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice When true, deposits use depositable NAV and redemptions use redeemable NAV.
    bool public immutable useConservativePrice;

    event OnMetaDeposit(address indexed owner, address indexed token, uint256 tokenAssets, uint256 shares);
    event OnMetaWithdraw(address indexed receiver, address indexed token, uint256 tokenAssets, uint256 shares);
    event OnExit(
        address indexed owner,
        address indexed token,
        uint256 tokenAssets,
        uint256 shares,
        IStrataCDO.TExitMode exitMode,
        uint256 exitFee,
        uint32 cooldownSeconds
    );

    constructor(bool useConservativePrice_) {
        useConservativePrice = useConservativePrice_;
    }

    function initialize(
        address owner_,
        address acm_,
        string memory name,
        string memory symbol,
        IERC20 baseAsset,
        IStrataCDO cdo_
    ) public virtual initializer {
        __ERC20_init_unchained(name, symbol);
        __ERC4626_init_unchained(baseAsset);
        __ERC20Permit_init(name);
        AccessControlled_init(owner_, acm_);

        cdo = cdo_;
    }


    /// @return uint256 The total assets for this tranche
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return cdo.totalAssets(address(this));
    }

    /// @return uint256 The total assets for this tranche, excluding projection when available
    function totalAssetsSettled() public view returns (uint256) {
        return cdo.totalAssetsSettled(address(this));
    }

    /// @return uint256 The depositable NAV for this tranche:
    ///         live NAV, or max(live NAV, epoch NAV) if useConservativePrice is enabled
    function totalAssetsDepositable() public view returns (uint256) {
        return useConservativePrice
            ? cdo.totalAssetsDepositable(address(this))
            : cdo.totalAssets(address(this));
    }

    /// @return uint256 The redeemable NAV for this tranche:
    ///         live NAV, or min(live NAV, epoch NAV) if useConservativePrice is enabled
    function totalAssetsRedeemable() public view returns (uint256) {
        return useConservativePrice
            ? cdo.totalAssetsRedeemable(address(this))
            : cdo.totalAssets(address(this));
    }

    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable, IERC20Metadata) returns (uint8) {
        return super.decimals();
    }

    /**
     * ============================================
     *              ERC4626 max*|preview* methods
     * ============================================
     */

    /** @dev Extends {IERC4626-maxDeposit} to handle the paused state and the TVL ratio */
    function maxDeposit(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return cdo.maxDeposit(address(this));
    }

    /** @dev Extends {IERC4626-maxMint} to handle the paused state and the TVL ratio */
    function maxMint(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 assets = cdo.maxDeposit(address(this));
        if (assets == type(uint256).max) {
            // No mint-cap
            return type(uint256).max;
        }
        return previewDeposit(assets);
    }

    /**
     * @dev Extends {IERC4626-maxWithdraw} to handle the paused state and the TVL ratio
     *      For public use (includes actual fee calculation).
     */
    function maxWithdraw(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 assetsNet) {
        uint256 sharesGross = balanceOf(owner);
        assetsNet = Math.min(previewRedeem(sharesGross), cdo.maxWithdraw(address(this), owner));
    }

    /** @dev Extends {IERC4626-maxRedeem} to handle the paused state and the TVL ratio */
    function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 sharesGross) {
        uint256 assetsProtocolMax = cdo.maxWithdraw(address(this), owner);
        uint256 sharesProtocolMax = _convertToShares(
            totalAssetsRedeemable(),
            assetsProtocolMax,
            Math.Rounding.Floor
        );
        sharesGross = Math.min(super.maxRedeem(owner), sharesProtocolMax);
    }

    /// @inheritdoc IERC4626
    /// @dev Accounts for the underlying strategy's deposit fees by deducting them from the gross assets before calculating shares.
    ///      The tranche itself charges no additional deposit fees.
    ///      Returns the net shares the user will receive after the strategy fees are applied.
    function previewDeposit(uint256 assetsGross) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 sharesNet) {
        uint256 feeBps = cdo.strategy().depositFeeBps(address(this), asset(), assetsGross);
        sharesNet = quoteDeposit(assetsGross, feeBps);
    }
    function quoteDeposit(uint256 assetsGross, uint256 feeBps) public view returns (uint256 sharesNet) {
        uint256 fee = Math.mulDiv(assetsGross, feeBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
        sharesNet = _convertToShares(
            totalAssetsDepositable(),
            assetsGross - fee,
            Math.Rounding.Floor
        );
    }

    /// @inheritdoc IERC4626
    /// @dev Accounts for the underlying strategy's deposit fees when calculating required assets.
    ///      The tranche itself charges no additional deposit fees.
    ///      Returns the gross assets required to mint the specified shares after the strategy fees are applied.
    function previewMint(uint256 sharesNet) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 assetsGross) {
        uint256 feeBps = cdo.strategy().depositFeeBps(
            address(this),
            asset(),
            _convertToAssets(
                totalAssetsDepositable(),
                sharesNet,
                Math.Rounding.Ceil
            )
        );
        assetsGross = quoteMint(sharesNet, feeBps);
    }
    function quoteMint(uint256 sharesNet, uint256 feeBps) public view returns (uint256 assetsGross) {
        uint256 assetsNet = _convertToAssets(
            totalAssetsDepositable(),
            sharesNet,
            Math.Rounding.Ceil
        );
        assetsGross = Math.mulDiv(assetsNet, BPS_DENOMINATOR, BPS_DENOMINATOR - feeBps, Math.Rounding.Ceil);
    }

    /** @dev Extends {IERC4626-previewRedeem} to handle fee calculation. Public and owner-unaware;
     *       For public use (includes actual fee calculation).
     */
    function previewRedeem(uint256 sharesGross) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 assetsNet) {
        (, uint256 fee, ) = cdo.calculateExitMode(address(this), address(0));
        assetsNet = quoteRedeem(sharesGross, fee);
    }
    function quoteRedeem(uint256 sharesGross, uint256 fee) public view returns (uint256 assetsNet) {
        uint256 sharesFee = fee > 0 ? calculateExitFee(sharesGross, fee, /*isGross*/true) : 0;
        assetsNet = _convertToAssets(
            totalAssetsRedeemable(),
            sharesGross - sharesFee,
            Math.Rounding.Floor
        );
    }

    /** @dev Extends {IERC4626-previewWithdraw} to handle fee calculation */
    function previewWithdraw(uint256 assetsNet) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 sharesGross) {
        (, uint256 exitFee, ) = cdo.calculateExitMode(address(this), address(0));
        sharesGross = quoteWithdraw(assetsNet, exitFee);
    }

    function quoteWithdraw(uint256 assetsNet, uint256 fee) public view returns (uint256 sharesGross) {
        uint256 sharesNet = _convertToShares(
            totalAssetsRedeemable(),
            assetsNet,
            Math.Rounding.Ceil
        );
        uint256 sharesFee = fee > 0 ? calculateExitFee(sharesNet, fee, /*isGross*/false) : 0;
        sharesGross = sharesNet + sharesFee;
    }

    /**
     * ============================================
     *              MetaVault max*|preview* methods
     * ============================================
     */

    /** @dev Overloads {IERC4626-maxWithdraw} to return the withdrawable amount denominated in the specified Meta Token. */
    function maxWithdraw(address token, address owner) public view returns (uint256) {
        uint256 baseAssets = maxWithdraw(owner);
        uint256 tokenAssets = cdo.strategy().convertToTokens(token, baseAssets, Math.Rounding.Ceil);
        return tokenAssets;
    }

    /** @dev Overloads {IERC4626-maxDeposit} to return the maximum deposit amount denominated in the specified Meta Token. */
    function maxDeposit(address token, address owner) public view returns (uint256) {
        uint256 baseAssets = maxDeposit(owner);
        uint256 tokenAssets = cdo.strategy().convertToTokens(token, baseAssets, Math.Rounding.Floor);
        return tokenAssets;
    }

    /** @dev Overloads {IERC4626-previewDeposit} to calculate the shares for a given Meta Token deposit amount. */
    function previewDeposit(address token, uint256 tokenAmount) public view returns (uint256) {
        IStrategy strategy = cdo.strategy();
        uint256 baseAssets = strategy.convertToAssets(token, tokenAmount, Math.Rounding.Floor);
        uint256 feeBps = strategy.depositFeeBps(address(this), token, tokenAmount);
        uint256 shares = quoteDeposit(baseAssets, feeBps);
        return shares;
    }

    /** @dev Overloads {IERC4626-previewMint} to return the required Meta Token amount for minting the given number of shares. */
    function previewMint(address token, uint256 shares) public view returns (uint256) {
        IStrategy strategy = cdo.strategy();
        uint256 feeBps = strategy.depositFeeBps(
            address(this),
            token,
            // pre-fee net amount for mint quotes
            strategy.convertToTokens(token, quoteMint(shares, 0), Math.Rounding.Ceil)
        );
        uint256 baseAssets = quoteMint(shares, feeBps);
        uint256 tokenAssets = strategy.convertToTokens(token, baseAssets, Math.Rounding.Ceil);
        return tokenAssets;
    }

    /** @dev Overloads {IERC4626-previewRedeem} to return the redeemable Meta Token amount for the given number of shares. */
    function previewRedeem(address token, uint256 shares) public view returns (uint256) {
        uint256 baseAssets = previewRedeem(shares);
        uint256 tokenAssets = cdo.strategy().convertToTokens(token, baseAssets, Math.Rounding.Ceil);
        return tokenAssets;
    }

    /** @dev Overloads {IERC4626-previewWithdraw} to calculate the shares required to withdraw the given Meta Token amount. */
    function previewWithdraw(address token, uint256 tokenAmount) public view returns (uint256) {
        uint256 baseAssets = cdo.strategy().convertToAssets(token, tokenAmount, Math.Rounding.Floor);
        uint256 shares = previewWithdraw(baseAssets);
        return shares;
    }

    /**
     * ============================================
     *        ERC4626 and Meta deposit/mint methods
     * ============================================
     */

    /** @dev See {IERC4626-deposit}. */
    function deposit(uint256 tokenAssets, address receiver) public override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return deposit(asset(), tokenAssets, receiver, TDepositParams(bytes("")));
    }
    function deposit(uint256 tokenAssets, address receiver, TDepositParams memory params) public virtual returns (uint256) {
        return deposit(asset(), tokenAssets, receiver, params);
    }
    function deposit(address token, uint256 tokenAmount, address receiver) public virtual returns (uint256) {
        return deposit(token, tokenAmount, receiver, TDepositParams(bytes("")));
    }
    function deposit(address token, uint256 tokenAmount, address receiver, TDepositParams memory params) public virtual returns (uint256) {
        cdo.updateAccounting();
        // {Optimistic path} Reverts if token is not supported
        IStrategy strategy = cdo.strategy();
        uint256 baseAssets = strategy.convertToAssets(token, tokenAmount, Math.Rounding.Floor);
        uint256 feeBps = strategy.depositFeeBps(address(this), token, tokenAmount);
        uint256 shares = quoteDeposit(baseAssets, feeBps);
        _deposit(token, _msgSender(), receiver, baseAssets, tokenAmount, shares, params.strategyOptions);
        return shares;
    }
    /** @dev See {IERC4626-mint}. */
    function mint(uint256 shares, address receiver) public override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return mint(asset(), shares, receiver, TDepositParams(bytes("")));
    }
    function mint(uint256 shares, address receiver, TDepositParams memory params) public returns (uint256) {
        return mint(asset(), shares, receiver, params);
    }
    function mint(address token, uint256 shares, address receiver) public virtual returns (uint256) {
        return mint(token, shares, receiver, TDepositParams(bytes("")));
    }
    function mint(address token, uint256 shares, address receiver, TDepositParams memory params) public virtual returns (uint256) {
        cdo.updateAccounting();

        IStrategy strategy = cdo.strategy();
        uint256 feeBps = strategy.depositFeeBps(
            address(this),
            token,
            // pre-fee net amount for mint quotes
            strategy.convertToTokens(token, quoteMint(shares, 0), Math.Rounding.Ceil)
        );
        uint256 baseAssets = quoteMint(shares, feeBps);
        // {Optimistic path} Reverts if token is not supported
        uint256 tokenAssets = strategy.convertToTokens(token, baseAssets, Math.Rounding.Ceil);
        _deposit(token, _msgSender(), receiver, baseAssets, tokenAssets, shares, params.strategyOptions);
        return tokenAssets;
    }

    /**
     * @dev Deposit/mint common workflow for meta token
     */
    function _deposit(
        address token,
        address caller,
        address receiver,
        uint256 baseAssets,
        uint256 tokenAssets,
        uint256 shares,
        bytes memory strategyOptions
    ) internal virtual {
        if (token != asset()) {
            // Ensure the caller can withdraw the deposited tokenAssets amount
            cdo.strategy().ensureRedeemable(caller, token, baseAssets);
        }

        SafeERC20.safeTransferFrom(IERC20(token), caller, address(this), tokenAssets);
        _mint(receiver, shares);

        cdo.deposit(address(this), token, tokenAssets, baseAssets, strategyOptions);
        emit Deposit(caller, receiver, baseAssets, shares);
        emit OnMetaDeposit(receiver, token, tokenAssets, shares);
    }

    /**
     * ============================================
     *     ERC4626 and Meta withdraw/redeem methods
     * ============================================
     */

    /** @dev See {IERC4626-withdraw}. */
    function withdraw(uint256 assets, address receiver, address owner) public override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return withdraw(asset(), assets, receiver, owner);
    }
    function withdraw(uint256 assets, address receiver, address owner, TRedemptionParams memory params) public virtual returns (uint256) {
        return withdraw(asset(), assets, receiver, owner, params);
    }
    function withdraw(address token, uint256 tokenAmount, address receiver, address owner) public virtual returns (uint256) {
        return withdraw(token, tokenAmount, receiver, owner, TRedemptionParams(IStrataCDO.TExitMode.Dynamic, 0, 0, bytes("")));
    }
    function withdraw(address token, uint256 tokenAmount, address receiver, address owner, TRedemptionExitParams memory params) public virtual returns (uint256) {
        return withdraw(token, tokenAmount, receiver, owner, TRedemptionParams({
            exitMode: params.exitMode,
            exitFee: params.exitFee,
            cooldownSeconds: params.cooldownSeconds,
            strategyOptions: bytes("")
        }));
    }
    function withdraw(address token, uint256 tokenAmount, address receiver, address owner, TRedemptionParams memory params) public virtual returns (uint256) {
        cdo.updateAccounting();
        (IStrataCDO.TExitMode exitMode, uint256 exitFee, uint32 cooldownSec) = cdo.calculateExitMode(address(this), owner);
        validateRedemptionParams(params, exitMode, exitFee, cooldownSec);

        // {Optimistic path} Reverts if token is not supported
        uint256 baseAssets = cdo.strategy().convertToAssets(token, tokenAmount, Math.Rounding.Floor);
        uint256 maxAssets = maxWithdraw(owner);
        if (baseAssets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, baseAssets, maxAssets);
        }
        uint256 shares = quoteWithdraw(baseAssets, exitFee);
        _withdraw(token, _msgSender(), receiver, owner, baseAssets, tokenAmount, shares, TRedemptionParams({
            exitMode: exitMode,
            exitFee: exitFee,
            cooldownSeconds: cooldownSec,
            strategyOptions: params.strategyOptions
        }));
        return shares;
    }

    /** @dev See {IERC4626-redeem}. */
    function redeem(uint256 shares, address receiver, address owner) public override(ERC4626Upgradeable, IERC4626)  returns (uint256) {
        return redeem(asset(), shares, receiver, owner);
    }
    function redeem(uint256 shares, address receiver, address owner, TRedemptionParams memory params) public virtual returns (uint256) {
        return redeem(asset(), shares, receiver, owner, params);
    }
    function redeem(address token, uint256 shares, address receiver, address owner) public virtual returns (uint256) {
        return redeem(token, shares, receiver, owner, TRedemptionParams(IStrataCDO.TExitMode.Dynamic, 0, 0, bytes("")));
    }
    function redeem(address token, uint256 shares, address receiver, address owner, TRedemptionExitParams memory params) public virtual returns (uint256) {
        return redeem(token, shares, receiver, owner, TRedemptionParams({
            exitMode: params.exitMode,
            exitFee: params.exitFee,
            cooldownSeconds: params.cooldownSeconds,
            strategyOptions: bytes("")
        }));
    }
    function redeem(address token, uint256 shares, address receiver, address owner, TRedemptionParams memory params) public virtual returns (uint256) {
        cdo.updateAccounting();
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        (IStrataCDO.TExitMode exitMode, uint256 exitFee, uint32 cooldownSec) = cdo.calculateExitMode(address(this), owner);
        validateRedemptionParams(params, exitMode, exitFee, cooldownSec);

        uint256 baseAssets = quoteRedeem(shares, exitFee);
        // {Optimistic path} Reverts if token is not supported
        uint256 tokenAssets = cdo.strategy().convertToTokens(token, baseAssets, Math.Rounding.Ceil);
        _withdraw(token, _msgSender(), receiver, owner, baseAssets, tokenAssets, shares, TRedemptionParams({
            exitMode: exitMode,
            exitFee: exitFee,
            cooldownSeconds: cooldownSec,
            strategyOptions: params.strategyOptions
        }));
        return tokenAssets;
    }

    /**
     * @dev Withdraw/redeem common workflow for base and meta tokens
     */
    function _withdraw(
        address token,
        address caller,
        address receiver,
        address owner,
        uint256 baseAssets,
        uint256 tokenAssets,
        uint256 sharesGross,
        TRedemptionParams memory params
    ) internal virtual {
        if (caller != owner) {
            _spendAllowance(owner, caller, sharesGross);
        }

        emit OnExit(receiver, token, tokenAssets, sharesGross, params.exitMode, params.exitFee, params.cooldownSeconds);

        if (params.exitMode == IStrataCDO.TExitMode.SharesLock) {
            _transfer(owner, address(cdo.sharesCooldown()), sharesGross);
            // Consider transfers: owner => owner, caller => owner, or caller => caller as private to hit PRIVATE_REQUEST_SLOTS_CAP.
            address initialFrom = caller == receiver || owner == receiver ? receiver : owner;
            cdo.cooldownShares(address(this), token, sharesGross, initialFrom, receiver, params.exitFee, params.cooldownSeconds, params.strategyOptions);
            return;
        }

        uint256 baseAssetsGross = _convertToAssets(
            totalAssetsRedeemable(),
            sharesGross,
            Math.Rounding.Floor
        );
        uint256 fee = Math.saturatingSub(baseAssetsGross, baseAssets);

        _burn(owner, sharesGross);
        if (fee > 0) {
            cdo.accrueFee(address(this), fee);
        }
        cdo.withdraw(address(this), token, tokenAssets, baseAssets, owner, receiver, params.strategyOptions);
        _onAfterWithdrawalChecks();
        emit Withdraw(caller, receiver, owner, baseAssets, sharesGross);
        emit OnMetaWithdraw(receiver, token, tokenAssets, sharesGross);
    }

    /**
     * ============================================
     *        Fee methods
     * ============================================
     */

    /// @notice Burns shares as fee without withdrawing assets. Permissionless but typically called by SharesCooldown
    ///         to accrue fees on the redeemable portion during cooldown process.
    /// @param shares The amount of shares to burn as fee
    /// @param owner The owner of the shares to burn
    /// @return assets The base assets accounted as fee
    function burnSharesAsFee(uint256 shares, address owner) external returns (uint256 assets) {
        cdo.updateAccounting();
        address caller = _msgSender();
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        assets = _convertToAssets(
            totalAssetsRedeemable(),
            shares,
            Math.Rounding.Floor
        );
        _burn(owner, shares);
        cdo.accrueFee(address(this), assets);
        cdo.updateBalanceFlow();
        _onAfterWithdrawalChecks();
    }

    /**
     * ============================================
     *        Configuration
     * ============================================
     * @dev During deposit, CDO requests Strategy to process the assets.
     *      Here, we allow the strategy to fetch the assets from the Vault.
     */
    function configure () external onlyCDO {
        address strategy = address(cdo.strategy());
        IERC20[] memory tokens = IStrategy(strategy).getSupportedTokens();
        uint256 len = tokens.length;
        for (uint256 i; i < len; ) {
            SafeERC20.forceApprove(tokens[i], strategy, type(uint256).max);
            unchecked { i++; }
        }
    }

    /**
     * ============================================
     *        Internals
     * ============================================
     */

    function _onAfterWithdrawalChecks () internal view {
        if (totalSupply() < MIN_SHARES) {
            revert MinSharesViolation();
        }
    }

    /// @dev Converts shares using the supplied NAV instead of reading totalAssets()
    function _convertToAssets(uint256 totalAssets_, uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(shares, totalAssets_ + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    /// @dev Converts assets using the supplied NAV instead of reading totalAssets()
    function _convertToShares(uint256 totalAssets_, uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + 10 ** _decimalsOffset(), totalAssets_ + 1, rounding);
    }

    /// @dev The calculation can be based on either the gross withdrawal amount (before fees)
    ///      or the net amount a user wishes to receive (after fees).
    /// @param amount The amount to calculate the fee on.
    /// @param isGross If true, `amount` is the gross withdrawal amount.
    ///                If false, `amount` is the net amount to be received.
    /// @return The calculated exit fee amount
    function calculateExitFee (uint256 amount, uint256 fee, bool isGross) internal pure returns (uint256) {
        return isGross
            ? Math.mulDiv(amount, fee, 1e18, Math.Rounding.Floor)
            : Math.mulDiv(amount, fee, 1e18 - fee, Math.Rounding.Floor);
    }


    function validateRedemptionParams(TRedemptionParams memory params, IStrataCDO.TExitMode exitMode, uint256 exitFee, uint32 cooldownSec) internal pure {
        if (params.exitMode == IStrataCDO.TExitMode.Dynamic) {
            return;
        }
        if (params.exitMode != exitMode || params.exitFee != exitFee || params.cooldownSeconds != cooldownSec) {
            revert RedemptionParamsMismatch(params, TRedemptionExitParams({
                exitMode: exitMode,
                exitFee: exitFee,
                cooldownSeconds: cooldownSec
            }));
        }
    }

    function _decimalsOffset() internal view override returns (uint8) {
        ERC4626Storage storage $ = _getERC4626StorageInner();
        return 18 - $._underlyingDecimals;
    }

    // Reuse the internal storage from OpenZeppelin's ERC4626Upgradeable
    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC4626")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC4626StorageLocation = 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00;
    function _getERC4626StorageInner() private pure returns (ERC4626Storage storage $) {
        assembly {
            $.slot := ERC4626StorageLocation
        }
    }
}
