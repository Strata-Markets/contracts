// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { AccountablePushOracle } from "../../../contracts/tranches/oracles/valuation/AccountablePushOracle.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";

contract ValuationPauseCDOMock {
    uint128 public valuationPrice = 1e18;
    uint256 public valuationCalls;
    address public constant jrtVault = address(0x11);
    address public constant srtVault = address(0x22);
    mapping(address => bool) public depositEnabled;
    mapping(address => bool) public withdrawEnabled;

    constructor() { reopen(); }

    function accounting() external view returns (address) { return address(this); }

    function setValuationPrice(uint128 price) external {
        require(price >= 0.0001e18 && price <= 1e18, "InvalidValuationPrice");
        valuationPrice = price;
        ++valuationCalls;
    }

    function setActionStates(address tranche, bool deposit, bool withdraw) external {
        depositEnabled[tranche] = deposit;
        withdrawEnabled[tranche] = withdraw;
    }

    function reopen() public {
        depositEnabled[jrtVault] = true;
        depositEnabled[srtVault] = true;
        withdrawEnabled[jrtVault] = true;
        withdrawEnabled[srtVault] = true;
    }
}

contract SubMinimumValuationPauseTest is Test {
    uint256 constant OBSERVER_KEY = 123;
    uint256 constant SUPPLY = 1_000_000e18;
    AccountablePushOracle oracle;
    ValuationPauseCDOMock market;

    function setUp() public {
        oracle = new AccountablePushOracle(address(this), vm.addr(OBSERVER_KEY));
        market = new ValuationPauseCDOMock();
    }

    function _signature(uint256 supply, uint256 reserves, uint256 key) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            abi.encode(oracle.nonce(), address(market), supply, reserves)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _push(uint256 reserves) internal {
        oracle.pushProofOfReserve(IStrataCDO(address(market)), SUPPLY, reserves,
            _signature(SUPPLY, reserves, OBSERVER_KEY));
    }

    function _assertPaused() internal view {
        assertFalse(market.depositEnabled(market.jrtVault()));
        assertFalse(market.withdrawEnabled(market.jrtVault()));
        assertFalse(market.depositEnabled(market.srtVault()));
        assertFalse(market.withdrawEnabled(market.srtVault()));
    }

    function test_subMinimumPausesWithoutValuationUpdate() public {
        _push(50e18); // 0.00005 USD per unit
        _assertPaused();
        assertEq(market.valuationPrice(), 1e18);
        assertEq(market.valuationCalls(), 0);
        assertEq(oracle.nonce(), 1);
    }

    function test_zeroReservesPausesWithoutValuationUpdate() public {
        _push(0);
        _assertPaused();
        assertEq(market.valuationPrice(), 1e18);
        assertEq(market.valuationCalls(), 0);
        assertEq(oracle.nonce(), 1);
    }

    function test_repeatedSubMinimumProofRepausesAtStoredMinimum() public {
        market.setValuationPrice(oracle.MIN_PRICE());
        _push(50e18);
        market.reopen();
        _push(50e18);
        _assertPaused();
        assertEq(market.valuationPrice(), oracle.MIN_PRICE());
        assertEq(market.valuationCalls(), 1);
        assertEq(oracle.nonce(), 2);
    }

    function test_exactMinimumUpdatesValuationAndPauses() public {
        _push(100e18);
        _assertPaused();
        assertEq(market.valuationPrice(), oracle.MIN_PRICE());
        assertEq(market.valuationCalls(), 1);
    }

    function test_invalidSignatureCannotPause() public {
        bytes memory signature = _signature(SUPPLY, 0, 456);
        vm.expectRevert(AccountablePushOracle.InvalidSignature.selector);
        oracle.pushProofOfReserve(IStrataCDO(address(market)), SUPPLY, 0, signature);
        assertTrue(market.depositEnabled(market.jrtVault()));
        assertTrue(market.withdrawEnabled(market.srtVault()));
        assertEq(oracle.nonce(), 0);
    }

    function test_zeroSupplyStillRejected() public {
        vm.expectRevert(AccountablePushOracle.InvalidPrice.selector);
        oracle.pushProofOfReserve(IStrataCDO(address(market)), 0, 0, hex"");
    }

    function test_supportedRecoveryDoesNotUnpause() public {
        _push(500_000e18);
        _assertPaused();
        _push(900_000e18);
        _assertPaused();
        assertEq(market.valuationPrice(), 0.9e18);
        assertEq(market.valuationCalls(), 2);
    }

    function test_unchangedSupportedPriceStillRejected() public {
        vm.expectRevert(AccountablePushOracle.ValuationPriceUnchanged.selector);
        oracle.pushProofOfReserve(IStrataCDO(address(market)), SUPPLY, SUPPLY, hex"");
    }
}
