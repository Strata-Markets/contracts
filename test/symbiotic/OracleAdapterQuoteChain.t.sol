// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { OracleAdapter } from "../../contracts/tranches/symbiotic/OracleAdapter.sol";
import { IRoundDataOracle } from "../../contracts/tranches/oracles/interfaces/IRoundDataOracle.sol";

contract OracleAdapterQuoteChainTest is Test {
    OracleAdapter oracle;
    address constant A = address(0xA);
    address constant B = address(0xB);
    address constant C = address(0xC);
    IRoundDataOracle constant AGG = IRoundDataOracle(address(0x100));
    IRoundDataOracle constant BGG = IRoundDataOracle(address(0x200));
    IRoundDataOracle constant CGG = IRoundDataOracle(address(0x300));

    function setUp() public {
        vm.warp(10 days);
        oracle = OracleAdapter(address(new ERC1967Proxy(address(new OracleAdapter()),
            abi.encodeCall(OracleAdapter.initialize, (address(this), address(this))))));
        _round(AGG, 2e18, block.timestamp);
        _round(BGG, 3e8, block.timestamp);
        _round(CGG, 4e6, block.timestamp);
        oracle.setFeed(OracleAdapter.Feed(C, CGG, 6, 1 hours, address(0)));
        oracle.setFeed(OracleAdapter.Feed(B, BGG, 8, 2 hours, C));
        oracle.setFeed(OracleAdapter.Feed(A, AGG, 18, 1 days, B));
    }

    function _round(IRoundDataOracle agg, int256 answer, uint256 updatedAt) internal {
        vm.mockCall(address(agg), abi.encodeCall(IRoundDataOracle.latestRoundData, ()),
            abi.encode(uint80(1), answer, updatedAt, updatedAt, uint80(1)));
    }

    function test_threeHopsAndMixedDecimals() public view {
        (uint256 price, uint256 decimals) = oracle.getPrice(A);
        assertEq(price, 24e18);
        assertEq(decimals, 18);
        (price,) = oracle.getPrice(C);
        assertEq(price, 4e18);
    }

    function test_eachHopUsesOwnHeartbeat() public {
        _round(AGG, 2e18, block.timestamp - 12 hours);
        (uint256 price,) = oracle.getPrice(A);
        assertEq(price, 24e18);
        uint256 staleTime = block.timestamp - 2 hours;
        _round(CGG, 4e6, staleTime);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, C, staleTime));
        oracle.getPrice(A);
    }

    function test_staleBaseWithFreshQuotes() public {
        uint256 staleTime = block.timestamp - 2 days;
        _round(AGG, 2e18, staleTime);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, A, staleTime));
        oracle.getPrice(A);
    }

    function test_disabledHeartbeatDoesNotDisableQuoteHeartbeat() public {
        oracle.setFeed(OracleAdapter.Feed(A, AGG, 18, 0, B));
        _round(AGG, 2e18, 1);
        (uint256 price,) = oracle.getPrice(A);
        assertEq(price, 24e18);
        uint256 staleTime = block.timestamp - 3 hours;
        _round(BGG, 3e8, staleTime);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, B, staleTime));
        oracle.getPrice(A);
    }

    function test_missingQuoteRejected() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.FeedNotSet.selector, address(0xD)));
        oracle.setFeed(OracleAdapter.Feed(A, AGG, 18, 1 days, address(0xD)));
    }

    function test_selfCycleRejected() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.CircularQuote.selector, A));
        oracle.setFeed(OracleAdapter.Feed(A, AGG, 18, 1 days, A));
    }

    function test_updateCannotCreateIndirectCycle() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.CircularQuote.selector, C));
        oracle.setFeed(OracleAdapter.Feed(C, CGG, 6, 1 hours, A));
    }

    function test_removedQuoteFailsClosedAndCanBeRestored() public {
        oracle.removeFeed(B);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.FeedNotSet.selector, B));
        oracle.getPrice(A);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.CircularQuote.selector, B));
        oracle.setFeed(OracleAdapter.Feed(B, BGG, 8, 2 hours, A));
        oracle.setFeed(OracleAdapter.Feed(B, BGG, 8, 2 hours, C));
        (uint256 price,) = oracle.getPrice(A);
        assertEq(price, 24e18);
    }

    function test_invalidQuotePrice() public {
        _round(BGG, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, B));
        oracle.getPrice(A);
    }

    function test_unregisteredAsset() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.FeedNotSet.selector, address(0)));
        oracle.getPrice(address(0));
    }
}
