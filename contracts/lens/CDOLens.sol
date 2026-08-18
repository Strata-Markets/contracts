// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import { IAprPairFeed } from "../tranches/interfaces/IAprPairFeed.sol";
import { IStrataCDO } from "../tranches/interfaces/IStrataCDO.sol";
import { IAccounting } from "../tranches/interfaces/IAccounting.sol";
import { ITranche } from "../tranches/interfaces/ITranche.sol";
import { UD60x18, pow, mul } from "@prb/math/src/ud60x18/Math.sol";
import { UD60x18Ext } from "../tranches/utils/UD60x18Ext.sol";

/**
 * @title Strata CDO Contract Helper
 * @author Strata
 */
contract CDOLens is OwnableUpgradeable {


    struct TAPRs {
        int64 base;
        int64 target;
        int64 jrt;
        int64 srt;
    }

    struct TAPRsBreakdown {
        int64 base;
        int64 target;
        int64 jrt;
        int64 srt;
        uint256 tvlRatioSrt;
        uint256 riskPremium;
    }

    /**
     * @notice Fallback pricing route for an asset that has no direct Chainlink USD feed.
     * @dev The asset is quoted in `quoteToken` through a Curve pool, then `quoteToken` is
     *      converted to USD via its own Chainlink feed (priceFeeds[quoteToken]).
     */
    struct CurveRoute {
        address pool;        // Curve pool holding both the asset and the quote token
        address quoteToken;  // intermediate token quoted by the pool, e.g. USDC
        int128 assetIndex;   // coin index of the priced asset within the pool
        int128 quoteIndex;   // coin index of `quoteToken` within the pool
    }

    IStrataCDOApi[] public cdos;

    /// @notice Chainlink-like price feed per asset, used to convert the exchange rate into USD
    mapping(address => IChainlinkPriceFeed) public priceFeeds;

    /// @notice Curve fallback route per asset, used when no direct Chainlink USD feed exists
    mapping(address => CurveRoute) public curveRoutes;

    function initialize(address owner) external initializer {
        __Ownable_init_unchained(owner);
    }

    function getAPRs (IStrataCDOApi cdo) public view returns (TAPRs memory) {
        TAPRsBreakdown memory aprs = getAPRsBreakdownInner(cdo, false);
        return TAPRs({
            base: aprs.base,
            target: aprs.target,
            jrt: aprs.jrt,
            srt: aprs.srt
        });
    }

    /// @notice Returns APRs using either the latest AprFeed round or projected APRs.
    /// @dev Set `useProjectedApr` to true for markets that support projected APRs.
    function getAPRs (IStrataCDOApi cdo, bool useProjectedApr) public view returns (TAPRs memory) {
        TAPRsBreakdown memory aprs = getAPRsBreakdownInner(cdo, useProjectedApr);
        return TAPRs({
            base: aprs.base,
            target: aprs.target,
            jrt: aprs.jrt,
            srt: aprs.srt
        });
    }

    function getAPRsBreakdown (IStrataCDOApi cdo) external view returns (TAPRsBreakdown memory) {
        return getAPRsBreakdownInner(cdo, false);
    }

    function getAPRsBreakdownInner (IStrataCDOApi cdo, bool useProjectedApr) internal view returns (TAPRsBreakdown memory) {
        IAccountingApi accounting = IAccountingApi(address(cdo.accounting()));

        IAprPairFeedApi feed = IAprPairFeedApi(address(accounting.aprPairFeed()));
        int256 aprBase;
        int256 aprTarget;

        if (useProjectedApr == false) {
            IAprPairFeed.TRound memory round = feed.latestRoundData();
            aprBase   = int256(round.aprBase);
            aprTarget = int256(round.aprTarget);
        } else {
            IStrategyAprPairProviderApi provider = feed.provider();
            (aprTarget, aprBase, ) = provider.getAprPairProjected();
        }

        uint256 nav = cdo.totalStrategyAssets();
        (uint256 jrtNav, uint256 srtNav, ) = accounting.totalAssets(nav);

        UD60x18 riskX = accounting.riskX();
        UD60x18 riskY = accounting.riskY();
        UD60x18 riskK = accounting.riskK();

        UD60x18 tvlRatioSrt = UD60x18.wrap(srtNav == 0 ? 0 : (srtNav * 1e18 / (srtNav + jrtNav)));
        UD60x18 tvlRatioJrt = UD60x18.wrap(jrtNav == 0 ? 1 : (jrtNav * 1e18 / (srtNav + jrtNav)));
        UD60x18 risk = calculateRiskPremiumInner(riskX, riskY, riskK, tvlRatioSrt);


        UD60x18 aprSrt1 = mul(UD60x18.wrap(uint256(aprBase)), UD60x18.wrap(1e18) - risk);
        int256 aprSrt = int256(UD60x18Ext.max(UD60x18.wrap(uint256(aprTarget)), aprSrt1).unwrap());

        uint256 reserveBps = accounting.reserveBps();
        if (aprBase > 0 && reserveBps > 0) {
            // Net Base APR = grossApr * (1 - performanceFee)
            uint256 factor = 1e18 - reserveBps;
            aprBase = (aprBase * int256(factor)) / int256(1e18);
        }

        int256 aprJrtSpread = (aprBase - aprSrt) * int256(tvlRatioSrt.unwrap()) / int256(tvlRatioJrt.unwrap());
        int256 aprJrt = aprBase + aprJrtSpread;

        return TAPRsBreakdown({
            base: int64(aprBase),
            target: int64(aprTarget),
            jrt: int64(aprJrt),
            srt: int64(aprSrt),
            tvlRatioSrt: tvlRatioSrt.unwrap(),
            riskPremium: risk.unwrap()
        });
    }

    function getTrancheAPR (ITranche tranche) external view returns (int64) {
        IStrataCDOApi cdo = IStrataCDOApi(tranche.getCDOAddress());
        TAPRs memory aprs = getAPRs(cdo);
        bool isJrt = cdo.isJrt(address(tranche));
        return isJrt ? aprs.jrt : aprs.srt;
    }


    /**
     * @notice Returns the USD price per share for an ERC4626 vault (tranche)
     * @dev Computes the exchange rate via IERC4626.convertToAssets, then multiplies by the
     *      USD price of the underlying asset (see getAssetUsdPrice) to produce a
     *      USD-denominated price. Result is always normalised to 18 decimal precision.
     * @param vault The ERC4626 vault (tranche) to price
     * @return price The USD price per share in 18 decimal precision
     */
    function getPrice (IERC4626 vault) external view returns (uint256 price) {
        uint8 shareDecimals = vault.decimals();
        uint256 exchangeRate = vault.convertToAssets(10 ** shareDecimals);
        address asset = vault.asset();
        uint8 assetDecimals = IERC20Metadata(asset).decimals();

        // USD price of one whole unit of the underlying asset, in 18 decimal precision
        uint256 assetUsdPrice = getAssetUsdPrice(asset);

        // exchangeRate is denominated in `assetDecimals`; divide it out to leave 18 decimals
        price = exchangeRate * assetUsdPrice / (10 ** assetDecimals);
    }

    /**
     * @notice Returns the USD price of one whole unit of `asset`, in 18 decimal precision
     * @dev Uses the asset's Chainlink feed when one is configured. When no direct feed
     *      exists, falls back to the configured Curve route: the asset is priced in the
     *      route's quote token (e.g. USDC) via the pool's `get_dy`, then the quote token
     *      is converted to USD using its own Chainlink feed.
     * @param asset The underlying asset to price
     * @return The USD price of one whole `asset` token, normalised to 18 decimals
     */
    function getAssetUsdPrice (address asset) public view returns (uint256) {
        IChainlinkPriceFeed feed = priceFeeds[asset];
        if (address(feed) != address(0)) {
            (, int256 answer,,,) = feed.latestRoundData();
            require(answer > 0, "Invalid feed price");
            return uint256(answer) * 1e18 / (10 ** feed.decimals());
        }

        // No direct USD feed: fall back to a Curve pool quoted against the route's quote token
        CurveRoute memory route = curveRoutes[asset];
        require(route.pool != address(0), "Price feed not set");

        // get_dy returns the amount of quote token received for selling 1 whole asset token (adjusted for decimals)
        uint256 assetInQuote = ICurvePool(route.pool).get_dy(
            route.assetIndex,
            route.quoteIndex,
            10 ** IERC20Metadata(asset).decimals()
        );

        // Convert the quote-token price into USD via the quote token's Chainlink feed
        IChainlinkPriceFeed quoteFeed = priceFeeds[route.quoteToken];
        require(address(quoteFeed) != address(0), "Quote feed not set");
        (, int256 quoteAnswer,,,) = quoteFeed.latestRoundData();
        require(quoteAnswer > 0, "Invalid feed price");

        uint8 quoteDecimals = IERC20Metadata(route.quoteToken).decimals();
        uint8 quoteFeedDecimals = quoteFeed.decimals();

        return assetInQuote * uint256(quoteAnswer) * 1e18
            / (10 ** (quoteDecimals + quoteFeedDecimals));
    }

    /**
     * @notice Set or remove the Chainlink-like price feed for an asset
     * @param asset The asset address to configure
     * @param feed  The Chainlink-compatible feed (set to address(0) to remove)
     */
    function setPriceFeed (address asset, IChainlinkPriceFeed feed) external onlyOwner {
        priceFeeds[asset] = feed;
    }

    /**
     * @notice Set or remove the Curve fallback route for an asset without a direct USD feed
     * @dev The asset is priced in `route.quoteToken` through the Curve pool; the quote token
     *      must itself have a Chainlink feed configured via setPriceFeed.
     * @param asset The asset address to configure
     * @param route The Curve route (set `route.pool` to address(0) to remove)
     */
    function setCurveRoute (address asset, CurveRoute calldata route) external onlyOwner {
        curveRoutes[asset] = route;
    }

    /**
     * @notice Add partner's protocols to the contract, if they are not already added
     * @param arr The array of ICDO instances
     */
    function addCDOs (IStrataCDOApi[] memory arr) external onlyOwner {
        for (uint i = 0; i < arr.length; i++) {
            address cdo = address(arr[i]);
            removeCDOInner(cdo);
            cdos.push(IStrataCDOApi(cdo));
        }
    }

    /**
     * @notice Remove partner's protocols from the contract
     * @param arr The array of ICDO instances
     */
    function removeCDOs (IStrataCDOApi[] memory arr) external onlyOwner {
        for (uint i = 0; i < arr.length; i++) {
            address cdo = address(arr[i]);
            removeCDOInner(cdo);
        }
    }

    function removeCDOInner(address cdo) internal {
        uint length = cdos.length;
        for (uint i = 0; i < length; i++) {
            if (address(cdos[i]) == cdo) {
                if (i != length - 1) {
                    cdos[i] = cdos[length - 1];
                }
                cdos.pop();
                break;
            }
        }
    }


    function calculateRiskPremiumInner (UD60x18 x, UD60x18 y, UD60x18 k, UD60x18 tvlRatioSrt) internal pure returns (UD60x18){
        // RiskPremium = x + y * TVL_ratio_sr ^ k
        UD60x18 riskPremium = x + y * pow(tvlRatioSrt, k);
        return riskPremium;
    }
}


interface IAccountingApi is IAccounting {
    function aprPairFeed() external view returns (IAprPairFeed);
    function riskX () external view returns (UD60x18);
    function riskY () external view returns (UD60x18);
    function riskK () external view returns (UD60x18);
    function reserveBps () external view returns (uint256);
}
interface IStrataCDOApi is IStrataCDO {

}

interface IStrategyAprPairProviderApi {
    function getAprPairProjected()
        external
        view
        returns (int64 aprTarget, int64 aprBase, uint64 timestamp);
}

interface IAprPairFeedApi is IAprPairFeed {
    function provider() external view returns (IStrategyAprPairProviderApi);
}

interface IChainlinkPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

interface ICurvePool {
    /// @notice Amount of coin `j` received as output for `dx` units of coin `i`
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}
