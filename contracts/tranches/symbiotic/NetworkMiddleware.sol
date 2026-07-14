// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { INetworkMiddleware } from "./interfaces/INetworkMiddleware.sol";
import { IAppAdapter } from "./interfaces/IAppAdapter.sol";
import { IStrataAccounting } from "./interfaces/IStrataAccounting.sol";
import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";

contract NetworkMiddleware is Initializable, Ownable2StepUpgradeable, PausableUpgradeable, INetworkMiddleware {

    // Per-market coverage configuration and state, keyed by the market's CDO address
    struct TMarket {
        // The market's accounting contract; source of pendingCoverageDeficit
        IStrataAccounting accounting;
        // The market's base asset, in which the coverage deficit is denominated
        address baseAsset;
        // baseAsset oracle
        IOracleAdapter oracle;
        // Cumulative amount slashed for this market, in vault asset
        uint256 totalSlashed;
        // Slashed but not yet injected back into the CDO (true-up in flight), in vault asset
        uint256 pendingTrueUp;
        // per-market pause flag
        bool enabled;

        // TODO: do we need a haircut param - buffer add when slashing in order to counteract price movements ?
    }

    IAppAdapter public override appAdapter;

    /// @notice Coverage registry of the Strata markets sharing this middleware's AppAdapter
    mapping(address cdo => TMarket) public markets;

    // ===============================================
    // Events and Errors

    error NoSlashableAmount();
    error MarketNotEnabled(address cdo);
    error NotAuthorized(address sender);

    event MarketSet(address indexed cdo, address accounting, address baseAsset, address oracle, bool enabled);
    event CoverageSlashed(address indexed cdo, uint256 requested, uint256 slashed);
    event TrueUpConfirmed(address indexed cdo, uint256 amount);

    uint256[48] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address appAdapter_) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
        appAdapter = IAppAdapter(appAdapter_);
    }

    // ===============================================
    // Only Owner functions

    function slash(address cdo) external onlyOwner whenNotPaused {
        TMarket storage market = markets[cdo];
        if (!market.enabled) {
            revert MarketNotEnabled(cdo);
        }

        // needed amount in vault asset
        uint256 neededAmount = _getNeededAmount(cdo);
        if (neededAmount == 0) {
            revert NoSlashableAmount();
        }

        // The adapter caps the slash to the currently slashable stake and does not return the
        // executed amount; derive it from the slashable() delta.
        uint256 slashableBefore = appAdapter.slashable();
        appAdapter.slash(neededAmount);
        uint256 slashed = slashableBefore - appAdapter.slashable();

        market.totalSlashed += slashed;
        market.pendingTrueUp += slashed;
        emit CoverageSlashed(cdo, neededAmount, slashed);
    }

    /// @notice Marks a completed true-up: slashed funds were injected back into the market's CDO.
    /// @dev Reduces the in-flight amount so future slashes are sized against the remaining deficit.
    ///      Called by the market's CDO itself during trueUp(), or by the owner as a manual fallback.
    /// @param cdo The CDO address identifying the market in the coverage registry.
    /// @param amount The trued-up amount, denominated in the market's base asset.
    function confirmTrueUp(address cdo, uint256 amount) external {
        if (msg.sender != cdo && msg.sender != owner()) {
            revert NotAuthorized(msg.sender);
        }

        TMarket storage market = markets[cdo];
        // Saturating: the injected value can exceed the booked in-flight amount when the asset
        // price moves between the slash and the true-up.
        market.pendingTrueUp = Math.saturatingSub(market.pendingTrueUp, _toVaultAsset(market, amount));

        emit TrueUpConfirmed(cdo, amount);
    }

    /// @notice Registers or updates a market in the coverage registry.
    function setMarket(
        address cdo,
        IStrataAccounting accounting,
        address baseAsset,
        IOracleAdapter oracle,
        bool enabled
    ) external onlyOwner {
        TMarket storage market = markets[cdo];
        market.accounting = accounting;
        market.baseAsset = baseAsset;
        market.oracle = oracle;
        market.enabled = enabled;
        emit MarketSet(cdo, address(accounting), baseAsset, address(oracle), enabled);
    }

    // Releases slashable coverage back to the vault without penalizing underwriters.
    function release(uint256 amount) external onlyOwner whenNotPaused {
        appAdapter.release(amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ===============================================
    // Internal functions

    /// @notice Returns the amount to slash for a market, in vault asset terms.
    /// @dev Deficit still pending true-up is excluded so the same shortfall is not slashed twice.
    ///      The adapter additionally caps the executed amount to the currently slashable stake.
    function _getNeededAmount(address cdo) internal view returns (uint256) {
        TMarket storage market = markets[cdo];
        uint256 deficit = _toVaultAsset(market, market.accounting.pendingCoverageDeficit());
        return Math.saturatingSub(deficit, market.pendingTrueUp);
    }

    /// @notice Converts an amount of the market's base asset into the Symbiotic vault asset.
    /// @dev Prices both assets in the oracle's common quote currency and adjusts for the
    ///      token decimals on both sides. Rounds down (in favor of the underwriters).
    function _toVaultAsset(TMarket storage market, uint256 baseAssets) internal view returns (uint256) {
        address vaultAsset = appAdapter.asset();
        (uint256 basePrice, uint256 basePriceDecimals) = market.oracle.getPrice(market.baseAsset);
        (uint256 vaultPrice, uint256 vaultPriceDecimals) = market.oracle.getPrice(vaultAsset);
        return Math.mulDiv(
            baseAssets,
            basePrice * 10 ** (IERC20Metadata(vaultAsset).decimals() + vaultPriceDecimals),
            vaultPrice * 10 ** (IERC20Metadata(market.baseAsset).decimals() + basePriceDecimals)
        );
    }
}
