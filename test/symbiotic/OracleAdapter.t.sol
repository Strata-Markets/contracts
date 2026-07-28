// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { OracleAdapter } from "../../contracts/tranches/symbiotic/OracleAdapter.sol";
import { IRoundDataOracle } from "../../contracts/tranches/oracles/interfaces/IRoundDataOracle.sol";

/// @notice Fork tests for the shared OracleAdapter against the live mainnet Chainlink feeds that
///         price the Strata markets' base assets and the Symbiotic vault asset.
/// @dev Single-hop feeds (USDe/USD, USDC/USD) quote USD directly; uniBTC has no USD feed and is
///      priced two-hop as uniBTC/BTC x BTC/USD. Every getPrice() result is normalized to 18-dec USD.
contract OracleAdapterForkTest is Test {

    // Base assets / vault asset (Ethereum mainnet)
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNIBTC = 0x004E9C3EF86bc1ca1f0bB5C7662861Ee93350568;

    // Chainlink push feeds (Ethereum mainnet)
    IRoundDataOracle constant USDE_USD = IRoundDataOracle(0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961);   // 8 dec
    IRoundDataOracle constant USDC_USD = IRoundDataOracle(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);   // 8 dec
    IRoundDataOracle constant UNIBTC_BTC = IRoundDataOracle(0x861d15F8a4059cb918bD6F3670adAEB1220B298f); // 18 dec
    IRoundDataOracle constant BTC_USD = IRoundDataOracle(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c);    // 8 dec

    uint256 constant HEARTBEAT = 7 days; // generous: these feeds update far more often

    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");

    OracleAdapter oracle;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        OracleAdapter impl = new OracleAdapter();
        oracle = OracleAdapter(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(OracleAdapter.initialize, (owner))
        )));

        vm.startPrank(owner);
        oracle.setFeed(USDE, USDE_USD, 8, IRoundDataOracle(address(0)), 0, HEARTBEAT);
        oracle.setFeed(USDC, USDC_USD, 8, IRoundDataOracle(address(0)), 0, HEARTBEAT);
        oracle.setFeed(UNIBTC, UNIBTC_BTC, 18, BTC_USD, 8, HEARTBEAT);
        vm.stopPrank();
    }

    /// @dev Reads a feed's latest answer normalized to 18 decimals, the same as the adapter.
    function _normalized(IRoundDataOracle feed, uint256 feedDecimals) internal view returns (uint256) {
        (, int256 answer,,,) = feed.latestRoundData();
        return uint256(answer) * 1e18 / (10 ** feedDecimals);
    }

    function test_singleHop_USDe_matchesFeed() public view {
        (uint256 price, uint256 decimals) = oracle.getPrice(USDE);
        assertEq(decimals, 18, "normalized to 18 decimals");
        assertEq(price, _normalized(USDE_USD, 8), "USDe price equals the normalized feed answer");
        // Sanity: within a sane peg band around $1.
        assertApproxEqRel(price, 1e18, 0.02e18, "USDe within 2% of $1");
    }

    function test_singleHop_USDC_matchesFeed() public view {
        (uint256 price, uint256 decimals) = oracle.getPrice(USDC);
        assertEq(decimals, 18);
        assertEq(price, _normalized(USDC_USD, 8), "USDC price equals the normalized feed answer");
        assertApproxEqRel(price, 1e18, 0.02e18, "USDC within 2% of $1");
    }

    function test_twoHop_uniBTC_multipliesFeeds() public view {
        (uint256 price, uint256 decimals) = oracle.getPrice(UNIBTC);
        assertEq(decimals, 18);

        uint256 uniBtcInBtc = _normalized(UNIBTC_BTC, 18); // ~1.0x BTC
        uint256 btcInUsd = _normalized(BTC_USD, 8);        // ~$60k+
        uint256 expected = uniBtcInBtc * btcInUsd / 1e18;

        assertEq(price, expected, "uniBTC USD price equals uniBTC/BTC x BTC/USD");
        // Sanity: uniBTC trades near BTC, so its USD price should be in a BTC-sized band.
        assertGt(price, 10_000e18, "uniBTC price is BTC-sized (lower bound)");
        assertLt(price, 1_000_000e18, "uniBTC price is BTC-sized (upper bound)");
        // uniBTC is worth at least ~1 BTC (exchange rate >= 1), so its USD price >= BTC/USD.
        assertGe(price, btcInUsd, "uniBTC priced at least at par with BTC");
    }

    function test_getPrice_revertsForUnregisteredAsset() public {
        address unregistered = makeAddr("unregistered");
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.FeedNotSet.selector, unregistered));
        oracle.getPrice(unregistered);
    }

    function test_getPrice_revertsWhenStale() public {
        // Register with a 1-hour heartbeat, then jump well past it.
        vm.prank(owner);
        oracle.setFeed(USDE, USDE_USD, 8, IRoundDataOracle(address(0)), 0, 1 hours);

        (,,, uint256 updatedAt,) = USDE_USD.latestRoundData();
        vm.warp(updatedAt + 2 hours);

        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, USDE, updatedAt));
        oracle.getPrice(USDE);
    }

    function test_getPrice_staleQuoteHopReverts() public {
        // The staleness guard applies to both hops: stale BTC/USD must revert uniBTC pricing.
        (,,, uint256 quoteUpdatedAt,) = BTC_USD.latestRoundData();
        vm.prank(owner);
        oracle.setFeed(UNIBTC, UNIBTC_BTC, 18, BTC_USD, 8, 1 hours);

        vm.warp(quoteUpdatedAt + 2 hours);
        // Reverts on one of the two hops (whichever the guard trips first is a StalePrice for UNIBTC).
        vm.expectRevert();
        oracle.getPrice(UNIBTC);
    }

    function test_getPrice_revertsWhenPaused() public {
        vm.prank(owner);
        oracle.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        oracle.getPrice(USDE);

        vm.prank(owner);
        oracle.unpause();
        oracle.getPrice(USDE); // no revert once unpaused
    }

    function test_setFeed_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        oracle.setFeed(USDE, USDE_USD, 8, IRoundDataOracle(address(0)), 0, HEARTBEAT);
    }

    function test_setFeed_zeroBaseReverts() public {
        vm.expectRevert(bytes("ZeroAggregator"));
        vm.prank(owner);
        oracle.setFeed(USDE, IRoundDataOracle(address(0)), 8, IRoundDataOracle(address(0)), 0, HEARTBEAT);
    }

    function test_removeFeed() public {
        vm.prank(owner);
        oracle.removeFeed(USDC);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.FeedNotSet.selector, USDC));
        oracle.getPrice(USDC);
    }
}
