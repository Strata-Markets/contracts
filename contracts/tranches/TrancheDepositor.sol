// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IMetaVault} from "./interfaces/IMetaVault.sol";
import {IDepositor} from "./interfaces/IDepositor.sol";
import {IStrataCDO} from "./interfaces/IStrataCDO.sol";
import {AccessControlled} from "../governance/AccessControlled.sol";

contract TrancheDepositor is AccessControlled {

    bytes32 public constant DEPOSITOR_CONFIG_ROLE = keccak256("DEPOSITOR_CONFIG_ROLE");

    event SwapInfoChanged(address indexed token);
    event CdoSwapInfoChanged(address indexed cdo, address indexed token);
    event AutoWithdrawalsChanged();
    event CdoAdded(address cdo);
    event TranchesAdded();

    error InvalidAsset(address vault, address asset);
    error MintedSharesBelowMin(uint256 shares, uint256 minShares);
    error InsufficientOutputAmount(uint256 received, uint256 minimum);
    error InvalidDeadline();
    error ZeroSlippageProtection();

    struct TAutoSwap {
        address router;
        // Fee Tier, 0 for default (100=(0.01%))
        uint24 fee;
        // Default minimum return (1000 = 100%), assuming 1:1 price
        uint24 minimumReturnPercentage;
    }

    struct TDepositParams {
        // Required for swaps: unix timestamp deadline >= block.timestamp
        uint256 swapDeadline;
        // Required for swaps: minimum acceptable tokenOut amount
        uint256 swapAmountOutMinimum;
        // Optional, default Tranche::asset()
        address swapTokenOut;
        // Optional, revert if minted shares < minShares (slippage guard)
        uint256 minShares;
    }


    mapping (address sourceToken => TAutoSwap tokenSwapInfo)              public autoSwaps;
    mapping (address sourceVault => bool enabled)                         public autoWithdrawals;
    mapping (address tranche => mapping(address token => bool enabled))   public tranches;
    mapping (address tranche => mapping(address token => TAutoSwap info)) public trancheAutoSwaps;

    function initialize(
        address owner_,
        address acm_
    ) public virtual initializer {
        AccessControlled_init(owner_, acm_);
    }

    /**
     * @notice Adds or clears the swap information for a given token
     * @dev This function allows the owner to set or update the swap parameters for a specific token
     * @param token The ERC20 token address for which to update swap info
     * @param swapInfo The new swap information to set, including router and fee
     */
    function addSwapInfo (address token, TAutoSwap calldata swapInfo) external onlyRole(DEPOSITOR_CONFIG_ROLE) {
        require(token != address(0), "ZeroAddress");
        require(swapInfo.router != address(0), "ZeroAddress");
        require(100 <= swapInfo.fee && swapInfo.fee <= 10000, "InvalidFeeTier");
        require(900 <= swapInfo.minimumReturnPercentage && swapInfo.minimumReturnPercentage <= 1000, "InvalidReturnPercentage");

        autoSwaps[token] = swapInfo;
        emit SwapInfoChanged(token);
    }

    function addAutoWithdrawals (address[] calldata tokens, bool[] calldata statuses) external onlyRole(DEPOSITOR_CONFIG_ROLE) {
        uint256 len = tokens.length;
        require(len == statuses.length, "LengthMissmatch");
        for (uint256 i; i < len; ) {
            autoWithdrawals[tokens[i]] = statuses[i];
            unchecked { i++; }
        }
        emit AutoWithdrawalsChanged();
    }
    function addCdo (IStrataCDO cdo) external onlyRole(DEPOSITOR_CONFIG_ROLE) {
        IERC20[] memory tokens = cdo.strategy().getSupportedTokens();
        address jrt = address(cdo.jrtVault());
        address srt = address(cdo.srtVault());
        uint256 len = tokens.length;
        for (uint256 i; i < len; ) {
            address t = address(tokens[i]);
            tranches[jrt][t] = true;
            tranches[srt][t] = true;
            unchecked { i++; }
        }
        emit CdoAdded(address(cdo));
    }

    /**
     * @notice Configure swap information for a given CDO and input token
     * @dev Example: for Neutrl + USDC, use Neutrl's router to swap into the base asset (NUSD)
     */
    function addCdoAutoSwap (IStrataCDO cdo, address tokenIn, TAutoSwap calldata swapInfo) external onlyRole(DEPOSITOR_CONFIG_ROLE) {
        address jrt = address(cdo.jrtVault());
        address srt = address(cdo.srtVault());
        trancheAutoSwaps[jrt][tokenIn] = swapInfo;
        trancheAutoSwaps[srt][tokenIn] = swapInfo;
        emit CdoSwapInfoChanged(address(cdo), tokenIn);
    }

   /**
     * @notice Deposits assets into the vault
     * @dev Accepts three types of assets:
     *      1. Supported by the strategy: Deposited as-is
     *      2. ERC4626 withdrawals: First withdraw the base Asset, then reenter
     *      3. Preconfigured swaps: Swapped to base Asset, then reenter
     * @param vault The tranche Vault to deposit into
     * @param asset The address of the asset to deposit
     * @param amount The amount of the asset to deposit
     * @param params Additional deposit parameters (e.g., swap configuration, minSharesOut)
     * @return shares The amount of shares minted
     */
    function deposit(IMetaVault vault, IERC20 asset, uint256 amount, address receiver, TDepositParams calldata params) external returns (uint256 shares) {
        return _deposit(vault, asset, amount, receiver, params);
    }

    /**
    * @notice Deposit `assets` of the vault's underlying from `owner` into `vault` and mint shares to `receiver`,
    *         using an EIP-2612 permit signature to authorize this helper to pull funds.
    *
    * @param vault The tranche Vault to deposit into
    * @param asset The address of the asset to deposit
    * @param amount The amount of the asset to deposit
    * @param receiver The address that will receive the minted shares
    * @param params Additional deposit parameters (e.g., swap configuration)
    * @param deadline Permit deadline (unix timestamp)
    * @param v Part of the EIP-2612 signature
    * @param r Part of the EIP-2612 signature
    * @param s Part of the EIP-2612 signature
    * @return shares Shares actually minted by the vault
    */
    function depositWithPermit(
        IMetaVault vault,
        IERC20 asset,
        uint256 amount,
        address receiver,
        TDepositParams calldata params,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external nonReentrant returns (uint256 shares) {
        address user = _msgSender();
        // Use permit if available, otherwise fallback to check allowance.
        try IERC20Permit(address(asset)).permit(user, address(this), amount, deadline, v, r, s) {}
        catch {
            require(IERC20(address(asset)).allowance(user, address(this)) >= amount,"InsufficientAllowance");
        }
        SafeERC20.safeTransferFrom(asset, user, address(this), amount);
        return _deposit(vault, asset, address(this), amount, receiver, params);
    }

    /**
     * ============================================
     *              Internal Deposit Flows
     * ============================================
     */

    // Internal helper called by public deposit methods, using the caller as the asset owner
    function _deposit(
        IMetaVault vault,
        IERC20 asset,
        uint256 amount,
        address receiver,
        TDepositParams memory params
    ) internal returns (uint256) {
        address user = _msgSender();
        return _deposit(vault, asset, user, amount, receiver, params);
    }

    // Core internal deposit method that determines and executes the appropriate deposit flow based on asset type
    function _deposit(
        IMetaVault vault,
        IERC20 asset,
        address from,
        uint256 amount,
        address receiver,
        TDepositParams memory params
    ) internal returns (uint256) {
        if (tranches[address(vault)][address(asset)] == true) {
            return _deposit_asMetaToken(vault, asset, from, amount, receiver, params.minShares);
        }
        if (autoWithdrawals[address(asset)] == true) {
            return _deposit_viaWithdraw(vault, IERC4626(address(asset)), from, amount, receiver, params);
        }
        TAutoSwap memory tracheSwapInfo = trancheAutoSwaps[address(vault)][address(asset)];
        if (tracheSwapInfo.router != address(0)) {
            return _deposit_viaSwap(vault, asset, from, amount, receiver, params, tracheSwapInfo);
        }

        TAutoSwap memory genericSwapInfo = autoSwaps[address(asset)];
        if (genericSwapInfo.router != address(0)) {
            return _deposit_viaSwap(vault, asset, from, amount, receiver, params, genericSwapInfo);
        }
        revert InvalidAsset(address(vault), address(asset));
    }

    // Internal function to deposit a directly supported (meta) token into the Vault
    function _deposit_asMetaToken (
        IMetaVault vault,
        IERC20 asset,
        address from,
        uint256 amount,
        address receiver,
        uint256 minShares
    ) internal returns (uint256) {
        require(amount > 0, "ZeroDeposit");
        require(address(receiver) != address(0), "ZeroAddress");

        if (from != address(this)) {
            // fetch tokens
            SafeERC20.safeTransferFrom(asset, from, address(this), amount);
        }

        SafeERC20.forceApprove(asset, address(vault), amount);
        uint256 shares = vault.deposit(address(asset), amount, receiver);
        if (minShares > 0 && shares < minShares) {
            revert MintedSharesBelowMin(shares, minShares);
        }
        return shares;
    }

    // Internal function to handle deposits via ERC4626 vault withdrawals before depositing into the target Vault
    function _deposit_viaWithdraw (
        IMetaVault vault,
        IERC4626 sourceVault,
        address from,
        uint256 amount,
        address receiver,
        TDepositParams memory depositParams
    ) internal returns (uint256) {
        require(amount > 0, "ZeroDeposit");

        IERC20 baseAsset = IERC20(sourceVault.asset());
        uint256 baseAssetBalanceBefore = baseAsset.balanceOf(address(this));

        sourceVault.redeem(amount, address(this), from);
        uint256 amountOut = baseAsset.balanceOf(address(this)) - baseAssetBalanceBefore;
        return _deposit(vault, baseAsset, address(this), amountOut, receiver, depositParams);
    }

    // Internal function to handle deposits via configured swaps before depositing into the target Vault
    function _deposit_viaSwap (
        IMetaVault vault,
        IERC20 tokenIn,
        address from,
        uint256 amount,
        address receiver,
        TDepositParams memory depositParams,
        TAutoSwap memory swapInfo
    ) internal returns (uint256) {

        if (from != address(this)) {
            SafeERC20.safeTransferFrom(tokenIn, from, address(this), amount);
        }

        // Approve e.g. Uniswap router to spend Token
        SafeERC20.forceApprove(tokenIn, swapInfo.router, amount);

        uint256 deadline = depositParams.swapDeadline;
        if (deadline < block.timestamp) {
            revert InvalidDeadline();
        }
        address tokenOut = depositParams.swapTokenOut;
        if (tokenOut == address(0)) {
            tokenOut = vault.asset();
        }

        uint256 amountOutMin = depositParams.swapAmountOutMinimum;
        if (amountOutMin == 0) {
            revert ZeroSlippageProtection();
        }


        bool isTokenOutSupported = tranches[address(vault)][tokenOut] == true;
        if (isTokenOutSupported == false) {
            isTokenOutSupported = autoWithdrawals[tokenOut] == true;
        }
        if (isTokenOutSupported == false) {
            revert InvalidAsset(address(vault), tokenOut);
        }

        uint256 tokenOutAmountBefore = IERC20(tokenOut).balanceOf(address(this));

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(tokenIn),
            tokenOut: tokenOut,
            fee: swapInfo.fee,
            recipient: address(this),
            deadline: deadline,
            amountIn: amount,
            amountOutMinimum: amountOutMin,
            sqrtPriceLimitX96: 0
        });

        ISwapRouter(swapInfo.router).exactInputSingle(params);
        uint256 amountReceived = IERC20(tokenOut).balanceOf(address(this)) - tokenOutAmountBefore;
        if (amountReceived < amountOutMin) {
            revert InsufficientOutputAmount(amountReceived, amountOutMin);
        }
        return _deposit(vault, IERC20(tokenOut), address(this), amountReceived, receiver, depositParams);
    }

}
