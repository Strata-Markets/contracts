// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {CDOLens, IChainlinkPriceFeed} from "../contracts/lens/CDOLens.sol";
import {LensPriceFeed} from "../contracts/lens/LensPriceFeed.sol";

/**
 * @title CDOLens getPrice Fork Test
 * @notice Deploys CDOLens on a mainnet fork and exercises getPrice for the srUSDe, jrUSDe, and USDat tranches
 *         tranches through both the direct Chainlink path and the Curve pool fallback.
 */
contract CDOLensGetPriceTest is Test {
    CDOLens public lens;

    address constant USDe = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant USDat = 0x23238f20b894f29041f48D88eE91131C395Aaa71;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant SR_USDe = 0x3d7d6fdf07EE548B939A80edbc9B2256d0cdc003;
    address constant JR_USDe = 0xC58D044404d8B14e953C115E67823784dEA53d8F;
    address constant SR_USDat = 0xFaa9a0e1Db9E22AE3A20B2B58a68DC24D053d066;
    address constant NUSD = 0xE556ABa6fe6036275Ec1f87eda296BE72C811BCE;
    address constant JR_NUSD = 0xFC807058A352b61aEef6A38e2D0fC3990225E772;

    address alice = makeAddr("updater");

    // Chainlink feeds on Ethereum mainnet
    address constant USDE_USD_FEED = 0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961;
    address constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    // Curve USDat/USDC StableSwap pool (coin 0 = USDC, coin 1 = USDat)
    address constant CURVE_USDAT_USDC_POOL = 0xF4d0CF32908b2C7f1021339c43Df0F77f06896d7;
    LensPriceFeed nusdFeed;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        lens = _deployLens();

        // Configure the direct Chainlink feed for USDe
        lens.setPriceFeed(USDe, IChainlinkPriceFeed(USDE_USD_FEED));
        lens.setPriceFeed(USDC, IChainlinkPriceFeed(USDC_USD_FEED));
    }

    function _deployLens() internal returns (CDOLens) {
        CDOLens impl = new CDOLens();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(CDOLens.initialize.selector, address(this)));
        lens = CDOLens(address(proxy));

        // Configure the Chainlink feed for USDe
        lens.setPriceFeed(USDe, IChainlinkPriceFeed(USDE_USD_FEED));
        nusdFeed = new LensPriceFeed(alice);
        lens.setPriceFeed(NUSD, IChainlinkPriceFeed(nusdFeed));
    }

    function _setCurveRoute() internal {
        lens.setCurveRoute(
            USDat,
            CDOLens.CurveRoute({
                pool: CURVE_USDAT_USDC_POOL,
                quoteToken: USDC,
                assetIndex: 1, // USDat is coin 1 in the pool
                quoteIndex: 0 // USDC is coin 0 in the pool
            })
        );
    }

    // --- Direct Chainlink path -------------------------------------------------

    function test_getPrice_srUSDe() public view {
        uint256 price = lens.getPrice(IERC4626(SR_USDe));
        console2.log("srUSDe USD price (18 dec):", price);
        assertGt(price, 0, "srUSDe price should be > 0");
    }

    function test_getPrice_jrUSDe() public view {
        uint256 price = lens.getPrice(IERC4626(JR_USDe));
        console2.log("jrUSDe USD price (18 dec):", price);
        assertGt(price, 0, "jrUSDe price should be > 0");
    }

    function test_getPrice_reverts_without_feed() public {
        // A fresh lens with neither a Chainlink feed nor a Curve route configured for USDe
        CDOLens freshLens = _deployLens();
        vm.expectRevert("Price feed not set");
        freshLens.getPrice(IERC4626(SR_USDe));
    }

    // --- Curve pool fallback ---------------------------------------------------

    // This test calculates the expected USDat price in USD using the Curve pool and Chainlink USDC price
    function test_getPrice_curveFallback() public {

        uint8 usdatDecimals = IERC20Metadata(USDat).decimals();
        uint256 priceOfUSDatInUSDC =
            ICurvePool(CURVE_USDAT_USDC_POOL).get_dy(1, 0, 10 ** usdatDecimals);

        console2.log("USDat decimals:", usdatDecimals);
        console2.log("USDat price in USDC:", priceOfUSDatInUSDC);

        (, int256 quote,,,) = IChainlinkPriceFeed(USDC_USD_FEED).latestRoundData();
        console2.log("USDC price in USD from Chainlink:", quote);

        uint finalAnswer = priceOfUSDatInUSDC * uint256(quote) * 1e18 / (1e14);
        console2.log("Final USDat price in USD:", finalAnswer);

        _setCurveRoute();

        uint256 x = lens.getAssetUsdPrice(USDat);
        console2.log("USDat USD price via direct feed:", x);

        assertEq(x, finalAnswer, "Calculated price should match lens price");
    }

    function test_getPrice_srUSDat() public {
        _setCurveRoute();

        uint256 price = lens.getPrice(IERC4626(SR_USDat));
        console2.log("srUSDat USD price (18 dec):", price);
        assertGt(price, 0, "srUSDat price should be > 0");
    }

    function test_NusdFeed() public view {
        uint8 decimals = IChainlinkPriceFeed(nusdFeed).decimals();
        assertEq(decimals, 8);

        (, int256 answer,,,) = IChainlinkPriceFeed(nusdFeed).latestRoundData();
        assertEq(answer, 1e8);
    }

    function test_getPrice_jrNUSD() public view {
        uint256 price = lens.getPrice(IERC4626(JR_NUSD));
        console2.log("jrNUSD USD price (18 dec):", price);
        assertGt(price, 0, "jrNUSD price should be > 0");
    }
}


interface ICurvePool {
    /// @notice Amount of coin `j` received as output for `dx` units of coin `i`
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}
