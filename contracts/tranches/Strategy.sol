// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IStrategy } from "./interfaces/IStrategy.sol";
import { CDOComponent }  from "./base/CDOComponent.sol";

/// @title Strategy
/// @notice Abstract base contract for CDO investment strategies
/// @dev Provides a foundation for concrete strategy implementations
/// @dev Concrete strategies must implement specific investment logic by extending this contract
abstract contract Strategy is IStrategy, CDOComponent {

    address public immutable baseAsset;
    uint8 public immutable baseAssetDecimals;
    // Backing storage for shareToken(); private so subclasses can override the getter.
    address private immutable _shareToken;
    uint8 public immutable shareTokenDecimals;

    constructor(address baseAsset_, address shareToken_) {
        baseAsset = baseAsset_;
        // address(0) is allowed for composite strategies (e.g. IsolatedStrategy) that override
        // shareToken() and getRate() and therefore never read these immutables at runtime.
        baseAssetDecimals = baseAsset_ != address(0) ? IERC20Metadata(baseAsset_).decimals() : 0;
        _shareToken = shareToken_;
        shareTokenDecimals = shareToken_ != address(0) ? IERC20Metadata(shareToken_).decimals() : 0;
    }

    function shareToken() public view virtual returns (address) {
        return _shareToken;
    }

    // Exchange rate of 1 share in base asset terms, scaled to 1e18.
    // Converts 1 share (10**shareTokenDecimals) via convertToAssets, then normalises to 1e18.
    function getRate() external view virtual override returns (uint256) {
        uint256 price = convertToAssets(_shareToken, 10 ** shareTokenDecimals, Math.Rounding.Floor);
        return price * 10 ** (18 - baseAssetDecimals);
    }

    /// @notice Deposits with strategy-specific options.
    /// @dev Defaults to the plain deposit flow; overrides must enforce onlyCDO.
    function deposit (
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address owner,
        bytes memory /*options*/
    ) external virtual returns (uint256) {
        return deposit(tranche, token, tokenAmount, baseAssets, owner);
    }

    /// @notice Withdraws with strategy-specific options.
    /// @dev Defaults to the plain withdraw flow; overrides must enforce onlyCDO.
    function withdraw (
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver,
        bool shouldSkipCooldown,
        bytes memory /*options*/
    ) external virtual returns (uint256) {
        return withdraw(tranche, token, tokenAmount, baseAssets, sender, receiver, shouldSkipCooldown);
    }

    /**
     * @notice Returns the deposit fee percentage for the underlying protocol
     * @return feeBps The deposit fee in basis points (e.g., 10 = 0.1%)
     */
    function depositFeeBps (address /*tranche*/, address /*tokenIn*/, uint256 /*tokenAmount*/) external virtual view returns (uint256 feeBps) {
        return 0;
    }

    /**
     * @notice Returns the maximum deposit amount allowed by the strategy
     * @dev Override this method to implement deposit limits per tranche/token
     * @dev e.g. checking the underlying protocol's deposit state
     */
    function maxDeposit(address /*tranche*/, address /*tokenIn*/, uint256 /*tokenAmout*/) external virtual view returns (uint256 assets) {
        return type(uint256).max;
    }

    /**
     * @notice Returns the maximum withdrawal amount allowed by the strategy
     * @dev Override this method to implement withdrawal limits per tranche/token
     * @dev e.g. checking the underlying protocol's withdrawal state
     */
    function maxWithdraw(address /*tranche*/, address /*tokenOut*/, uint256 /*tokenAmout*/) external virtual view returns (uint256 assets) {
        return type(uint256).max;
    }

    function convertToAssets (address token, uint256 tokenAmount, Math.Rounding rounding) public view virtual returns (uint256 baseAssets);
    function convertToTokens (address token, uint256 baseAssets, Math.Rounding rounding) public view virtual returns (uint256 tokenAmount);

    function deposit (
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address owner
    ) public virtual returns (uint256);
    function withdraw (
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver
    ) public virtual returns (uint256);
    function withdraw (
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver,
        bool shouldSkipCooldown
    ) public virtual returns (uint256);

    function configure () external virtual onlyCDO {
        // No default configuration
    }

    function totalAssets () public view virtual returns (uint256);
    function totalAssets (uint256 latestNav, uint256 timestamp) public virtual view returns (uint256);

    function totalAssetsSnapshot(
        uint256 latestNav,
        uint256 timestamp
    ) external virtual view returns (
        uint256 navT1,
        uint256 navT1Time,
        uint256 navMTM,
        uint256 navMTMTime
    ) {
        navMTM = totalAssets();
        navMTMTime = block.timestamp;
        navT1 = totalAssets(latestNav, timestamp);
        navT1Time = navMTM != navT1 ? timestamp : navMTMTime;
    }
}
