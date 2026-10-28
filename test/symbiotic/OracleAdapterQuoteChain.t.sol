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
        _decimals(AGG, 18);
        _decimals(BGG, 8);
        _decimals(CGG, 6);
        _round(AGG, 2e18, block.timestamp);
        _round(BGG, 3e8, block.timestamp);
        _round(CGG, 4e6, block.timestamp);
        oracle.setFeed(OracleAdapter.Feed(C, CGG, 6, 1 hours, address(0)));
        oracle.setFeed(OracleAdapter.Feed(B, BGG, 8, 2 hours, C));
        oracle.setFeed(OracleAdapter.Feed(A, AGG, 18, 1 days, B));
    }

    function _decimals(IRoundDataOracle agg, uint8 decimals_) internal {
        vm.mockCall(address(agg), abi.encodeCall(IRoundDataOracle.decimals, ()), abi.encode(decimals_));
    }

    function test_mismatchedDecimalsRejectedOnRegistration() public {
        vm.expectRevert(bytes("DecimalsMismatch"));
        oracle.setFeed(OracleAdapter.Feed(address(0xD), BGG, 18, 1 hours, address(0)));
    }

    function test_mismatchedDecimalsRejectedOnReplacement() public {
        vm.expectRevert(bytes("DecimalsMismatch"));
        oracle.setFeed(OracleAdapter.Feed(A, BGG, 18, 1 hours, address(0)));
        (uint256 price,) = oracle.getPrice(A);
        assertEq(price, 24e18);
    }

    function test_decimalNormalization() public {
        uint8[3] memory scales = [uint8(1), uint8(27), uint8(36)];
        for (uint256 i; i < scales.length; ++i) {
            _decimals(AGG, scales[i]);
            _round(AGG, int256(2 * 10 ** uint256(scales[i])), block.timestamp);
            oracle.setFeed(OracleAdapter.Feed(A, AGG, scales[i], 1 hours, address(0)));
            (uint256 price,) = oracle.getPrice(A);
            assertEq(price, 2e18);
        }
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

    // f-100 regression: malformed timestamps must fail explicitly, regardless of heartbeat.
    function test_zeroTimestampRejectedWithAndWithoutHeartbeat() public {
        _round(AGG, 2e18, 0);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, A));
        oracle.getPrice(A);
        oracle.setFeed(OracleAdapter.Feed(A, AGG, 18, 0, B));
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, A));
        oracle.getPrice(A);
    }

    function test_futureTimestampRejectedWithAndWithoutHeartbeat() public {
        _round(AGG, 2e18, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, A));
        oracle.getPrice(A);
        oracle.setFeed(OracleAdapter.Feed(A, AGG, 18, 0, B));
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, A));
        oracle.getPrice(A);
    }

    function test_invalidQuoteTimestampRejectsEntireChain() public {
        oracle.setFeed(OracleAdapter.Feed(C, CGG, 6, 0, address(0)));
        _round(CGG, 4e6, 0);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, C));
        oracle.getPrice(A);
        _round(CGG, 4e6, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, C));
        oracle.getPrice(A);
    }

    function test_timestampAndHeartbeatBoundaries() public {
        _round(CGG, 4e6, block.timestamp);
        (uint256 price,) = oracle.getPrice(A);
        assertEq(price, 24e18);
        _round(CGG, 4e6, block.timestamp - 1 hours);
        (price,) = oracle.getPrice(A);
        assertEq(price, 24e18);
        uint256 staleTime = block.timestamp - 1 hours - 1;
        _round(CGG, 4e6, staleTime);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, C, staleTime));
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
