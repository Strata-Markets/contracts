// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { AccessControlled } from "../../governance/AccessControlled.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IInsuranceMiddleware } from "./interfaces/IInsuranceMiddleware.sol";
import { IAccounting } from "../interfaces/IAccounting.sol";
import { IInsuranceVault } from "./interfaces/IInsuranceVault.sol";
import { IAppAdapter } from "./interfaces/IAppAdapter.sol";
import { IStrataAccounting } from "./interfaces/IStrataAccounting.sol";
import { IStrataCDO } from "../interfaces/IStrataCDO.sol";
import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";

contract InsuranceMiddleware is IInsuranceMiddleware, AccessControlled {

    // Per-market coverage configuration and state, keyed by the market's CDO address
    struct TMarket {
        // The market's accounting contract; source of the insuranceAmount claim
        IStrataAccounting accounting;
        // The market's base asset, in which the coverage deficit is denominated
        address baseAsset;
        // Cumulative amount slashed for this market, in vault asset
        uint256 totalSlashed;
        // Slashed but not yet funded into the insurance vault (insurance claim funding in flight), in vault asset
        uint256 pendingInsuranceClaimFunding;
        // per-market pause flag
        bool enabled;
        // Extra buffer (in bps) added to the slashed amount to pre-fund the vault-asset -> base-asset
        // swap discount during the insurance claim funding (e.g. a uniBTC market depeg). 0 = no buffer.
        uint256 bufferBps;
    }

    uint256 constant BPS = 10_000;
    uint256 constant MAX_BUFFER_BPS = 5_000; // 50%

    IAppAdapter public override appAdapter;

    /// @notice Shared, project-wide price source for the deficit -> vault-asset conversion.
    ///         Keyed by asset internally, so a single instance prices every market's base asset
    ///         and the vault asset.
    IOracleAdapter public oracle;

    /// @notice Coverage registry of the Strata markets sharing this middleware's AppAdapter
    mapping(address cdo => TMarket) public markets;

    /// @notice Enumerable list of registered market CDOs, used to net shared coverage capacity
    address[] public marketCdos;

    /// @notice Outstanding claim backed by slashes or reused funding, in base assets.
    mapping(address cdo => uint256) public slashedClaimBase;

    // ===============================================
    // Events and Errors

    error InvalidReturnedAmount();
    error NotAuthorized(address sender);

    event MarketSet(address indexed cdo, address accounting, address baseAsset, uint256 bufferBps, bool enabled);
    event OracleSet(address indexed oracle);
    event CoverageReused(address indexed cdo, uint256 coveredBase);
    event CoverageSlashed(address indexed cdo, uint256 requested, uint256 slashed);
    event InsuranceClaimFundingConfirmed(address indexed cdo, uint256 amount);
    event SlashedCollateralReturned(address indexed cdo, uint256 amount);



    function initialize(address owner_, address acm_, address appAdapter_, address oracle_) external initializer {
        AccessControlled_init(owner_, acm_);
        appAdapter = IAppAdapter(appAdapter_);
        oracle = IOracleAdapter(oracle_);
    }

    // ===============================================
    // Coverage and owner functions

    /// @notice Uses funded surplus first, then slashes the remaining new claim.
    /// @dev Accounting calls before adding lossBase to insuranceAmount, so the vault reserves
    ///      only existing claims when calculating surplusCoverage().
    function coverAndSlash(address cdo, uint256 lossBase) external returns (uint256 coveredBase) {
        TMarket storage market = markets[cdo];
        if (msg.sender != address(market.accounting)) {
            revert NotAuthorized(msg.sender);
        }
        if (!market.enabled || lossBase == 0) {
            return 0;
        }

        uint256 reused = Math.min(lossBase, _fundedBase(cdo, market, true));
        if (reused > 0) {
            slashedClaimBase[cdo] += reused;
            emit CoverageReused(cdo, reused);
        }
        lossBase -= reused;
        if (lossBase == 0) return reused;

        // A remainder after reuse can be smaller than one collateral atom.
        uint256 neededVault = Math.max(1, _bufferedVault(market, lossBase));
        uint256 slashableBefore = appAdapter.slashable();
        uint256 slashVault = Math.min(neededVault, slashableBefore);
        if (slashVault == 0) {
            return reused;
        }

        appAdapter.slash(slashVault);
        uint256 slashed = slashableBefore - appAdapter.slashable();

        market.totalSlashed += slashed;
        market.pendingInsuranceClaimFunding += slashed;
        emit CoverageSlashed(cdo, lossBase, slashed);

        // Full coverage (the normal path, since request() sized lossBase within slashable) delivers
        // exactly lossBase; the buffer is a swap cushion, not extra coverage. Only if slashable was
        // exhausted concurrently do we fall short, returning the de-buffered slashed base.
        uint256 deliverableBase = Math.mulDiv(_toBaseAsset(market, slashed), BPS, BPS + market.bufferBps);
        coveredBase = slashed >= neededVault
            ? lossBase
            : Math.min(deliverableBase, lossBase);
        // Accounting synchronizes reductions separately; this call always covers a new claim increment.
        slashedClaimBase[cdo] += coveredBase;
        return reused + coveredBase;
    }

    /// @notice Drops backing for claims that have settled through redemption or recovery.
    /// @dev Accounting must call immediately after every claim decrease, before any subsequent increase.
    ///      A reduction first removes any unslashed obligation; retained backing cannot exceed the live claim.
    function syncInsuranceClaim(address cdo) external {
        TMarket storage market = markets[cdo];
        if (msg.sender != address(market.accounting)) {
            revert NotAuthorized(msg.sender);
        }
        slashedClaimBase[cdo] = Math.min(slashedClaimBase[cdo], market.accounting.insuranceAmount());
    }

    /// @notice Marks a completed insurance claim funding: slashed funds were funded into the market's insurance vault.
    /// @dev Updates funding status only; already-slashed backing remains until the claim settles.
    ///      Called by the market's CDO itself during fundInsuranceClaim(), or by the owner as a manual fallback.
    /// @param cdo The CDO address identifying the market in the coverage registry.
    /// @param amount The funded claim amount, denominated in the market's base asset.
    function confirmInsuranceClaimFunding(address cdo, uint256 amount) external {
        if (msg.sender != cdo && msg.sender != owner()) {
            revert NotAuthorized(msg.sender);
        }

        TMarket storage market = markets[cdo];
        // Saturating: the injected value can exceed the booked in-flight amount when the asset
        // price moves between the slash and the insurance claim funding.
        market.pendingInsuranceClaimFunding = Math.saturatingSub(market.pendingInsuranceClaimFunding, _toVaultAsset(market, amount));

        emit InsuranceClaimFundingConfirmed(cdo, amount);
    }

    /// @notice Confirms a manual return of unfunded slash proceeds exceeding the remaining claim.
    /// @dev Records the owner's confirmation only; does not transfer or verify returned tokens.
    ///      Cumulative slashes and the adapter's slashable capacity remain unchanged.
    /// @param amount Returned collateral in Symbiotic vault asset units.
    function confirmSlashedCollateralReturned(address cdo, uint256 amount) external onlyOwner {
        TMarket storage market = markets[cdo];
        uint256 claim = market.accounting.insuranceAmount();
        uint256 required;
        if (claim > 0) {
            uint256 unfunded = Math.saturatingSub(claim, _fundedBase(cdo, market, false));
            // Retain enough collateral at current prices, including the swap buffer; round up.
            required = Math.mulDiv(
                _toVaultAsset(market, unfunded, Math.Rounding.Ceil), BPS + market.bufferBps, BPS, Math.Rounding.Ceil
            );
        }
        uint256 surplus = Math.saturatingSub(market.pendingInsuranceClaimFunding, required);
        if (amount == 0 || amount > surplus) revert InvalidReturnedAmount();

        market.pendingInsuranceClaimFunding -= amount;
        emit SlashedCollateralReturned(cdo, amount);
    }

    /// @notice Registers or updates a market in the coverage registry.
    function setMarket(
        address cdo,
        IStrataAccounting accounting,
        address baseAsset,
        uint256 bufferBps,
        bool enabled
    ) external onlyOwner {
        require(bufferBps <= MAX_BUFFER_BPS, "InvalidBuffer");
        TMarket storage market = markets[cdo];
        if (address(market.accounting) == address(0)) {
            marketCdos.push(cdo);
        }
        market.accounting = accounting;
        market.baseAsset = baseAsset;
        market.bufferBps = bufferBps;
        market.enabled = enabled;
        emit MarketSet(cdo, address(accounting), baseAsset, bufferBps, enabled);
    }

    /// @notice Sets the underwriter fee skim rate for a market, through its CDO.
    /// @dev The CDO restricts setUnderwriterFeeBps to this middleware and forwards it to accounting,
    ///      which in turn only accepts the call from the CDO. So the underwriter fee policy is owned
    ///      here rather than by the market's own owner, without the middleware reaching into accounting.
    /// @param cdo The CDO address identifying the market in the coverage registry.
    /// @param bps The new underwriter fee percentage in basis points (1e18 = 100%).
    function setMarketUnderwriterFeeBps(address cdo, uint256 bps) external onlyOwner {
        IStrataCDO(cdo).setUnderwriterFeeBps(bps);
    }

    /// @notice Sets the shared price source used for all deficit -> vault-asset conversions.
    function setOracle(IOracleAdapter oracle_) external onlyOwner {
        oracle = oracle_;
        emit OracleSet(address(oracle_));
    }

    // Releases slashable coverage back to the vault without penalizing underwriters.
    function release(uint256 amount) external onlyOwner {
        appAdapter.release(amount);
    }

    // ===============================================
    // IInsurancePool

    /// @dev View: returns how much of `lossAmount` (in the market's base asset) the shared pool can
    ///      currently cover. Funded surplus is used first. Additional capacity is slashable stake minus
    ///      the coverage already
    ///      committed to every market (their outstanding claims not yet slashed), so simultaneous
    ///      multi-market stress cannot over-commit the shared stake. The available stake is
    ///      de-buffered by the market's bufferBps: covering B base consumes bufferedVault(B) of the
    ///      stake at slash time, so the reported capacity must divide back out that same buffer.
    /// @dev Sized off the current-block slashable(); coverage is slashed synchronously in the same tx
    ///      it is booked (accounting calls coverAndSlash), so there is no window for slashable to drift.
    function request(address cdo, uint256 lossAmount) external view returns (uint256 covered) {
        TMarket storage market = markets[cdo];
        if (!market.enabled || lossAmount == 0) {
            return 0;
        }
        covered = Math.min(lossAmount, _fundedBase(cdo, market, true));
        if (covered == lossAmount) return covered;
        uint256 availableVault = Math.saturatingSub(appAdapter.slashable(), _committedVault());
        uint256 availableBase = Math.mulDiv(
            _toBaseAsset(market, availableVault),
            BPS,
            BPS + market.bufferBps
        );
        covered += Math.min(lossAmount - covered, availableBase);
    }

    /// @notice Total coverage already committed across all markets, in vault asset.
    /// @dev Only claims without allocated or funded backing consume live stake. Funding does not
    ///      create a new reservation. Reserve the buffered vault equivalent of the remaining deficit.
    function _committedVault() internal view returns (uint256 total) {
        uint256 len = marketCdos.length;
        for (uint256 i; i < len; ++i) {
            TMarket storage market = markets[marketCdos[i]];
            if (!market.enabled) {
                continue;
            }
            address cdo = marketCdos[i];
            uint256 backed = Math.max(slashedClaimBase[cdo], _fundedBase(cdo, market, false));
            total += _bufferedVault(market, Math.saturatingSub(market.accounting.insuranceAmount(), backed));
        }
    }

    // ===============================================
    // Internal functions

    /// @dev Same valuation-price basis as CDO payouts; rounds down when converting funding to base.
    ///      Pending slashing proceeds are not available funded surplus.
    function _fundedBase(address cdo, TMarket storage market, bool surplusOnly) internal view returns (uint256) {
        IInsuranceVault vault = IStrataCDO(cdo).insuranceVault();
        if (address(vault) == address(0)) return 0;
        uint256 amount = surplusOnly ? vault.surplusCoverage() : vault.fundedCoverage();
        if (amount == 0) return 0;
        uint256 valuedBase = Math.mulDiv(amount, 10 ** IERC20Metadata(market.baseAsset).decimals(), 10 ** vault.coverageTokenDecimals());
        return Math.mulDiv(valuedBase, 1e18, IAccounting(address(market.accounting)).valuationPrice());
    }

    /// @notice Vault asset required to cover a base-asset claim, including the market's swap buffer.
    /// @dev bufferBps pre-funds the vault -> base conversion discount at insurance claim funding (e.g. a uniBTC
    ///      depeg), so both the slash sizing and the committed-capacity reservation size the claim
    ///      as bufferedVault(base) = toVaultAsset(base) * (BPS + bufferBps) / BPS.
    function _bufferedVault(TMarket storage market, uint256 baseAssets) internal view returns (uint256) {
        return Math.mulDiv(_toVaultAsset(market, baseAssets), BPS + market.bufferBps, BPS);
    }

    /// @notice Converts an amount of the market's base asset into the Symbiotic vault asset.
    /// @dev Uses accounting's valuation price for base assets and the USD oracle for vault assets, adjusting for the
    ///      token decimals on both sides. Rounds down (in favor of the underwriters).
    function _toVaultAsset(TMarket storage market, uint256 baseAssets) internal view returns (uint256) {
        return _toVaultAsset(market, baseAssets, Math.Rounding.Floor);
    }

    function _toVaultAsset(TMarket storage market, uint256 baseAssets, Math.Rounding rounding) internal view returns (uint256) {
        if (baseAssets == 0) return 0;

        address vaultAsset = appAdapter.asset();
        uint256 basePrice = IAccounting(address(market.accounting)).valuationPrice();
        (uint256 vaultPrice, uint256 vaultPriceDecimals) = oracle.getPrice(vaultAsset);
        return Math.mulDiv(
            baseAssets,
            basePrice * 10 ** (IERC20Metadata(vaultAsset).decimals() + vaultPriceDecimals),
            vaultPrice * 10 ** (IERC20Metadata(market.baseAsset).decimals() + 18 /* valuationPrice decimals */),
            rounding
        );
    }

    /// @notice Converts an amount of the Symbiotic vault asset into the market's base asset.
    /// @dev Inverse of {_toVaultAsset}. Rounds down (in favor of the underwriters).
    function _toBaseAsset(TMarket storage market, uint256 vaultAssets) internal view returns (uint256) {
        if (vaultAssets == 0) return 0;

        address vaultAsset = appAdapter.asset();
        uint256 basePrice = IAccounting(address(market.accounting)).valuationPrice();
        (uint256 vaultPrice, uint256 vaultPriceDecimals) = oracle.getPrice(vaultAsset);
        return Math.mulDiv(
            vaultAssets,
            vaultPrice * 10 ** (IERC20Metadata(market.baseAsset).decimals() + 18 /* valuationPrice decimals */),
            basePrice * 10 ** (IERC20Metadata(vaultAsset).decimals() + vaultPriceDecimals)
        );
    }
}
