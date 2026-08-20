// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrataCDO} from "../../interfaces/IStrataCDO.sol";

/// @notice Pushes Accountable proof-of-reserve values to Strata CDOs.
/// @dev For each target CDO, this contract must be granted `PAUSER_ROLE` in that CDO's AccessControlManager and
///      set as that CDO's valuation keeper.
contract AccountablePushOracle is Ownable {
    uint128 public constant MAX_PRICE = 1e18;

    address public observer;
    uint256 public nonce;

    event ObserverSet(address observer);
    event ProofOfReservePushed(address indexed cdo, uint128 price);

    error InvalidPrice();
    error InvalidSignature();
    error ValuationPriceUnchanged();
    error ZeroAddress();

    constructor(address owner, address observer_) Ownable(owner) {
        _setObserver(observer_);
    }

    function setObserver(address observer_) external onlyOwner {
        _setObserver(observer_);
    }

    /// @notice Pushes Accountable proof-of-reserve values and updates the CDO valuation price.
    /// @dev The observer signs `abi.encode(nonce, address(cdo), totalSupply, totalReserveUsd)`.
    ///      The price is capped at 1e18; unchanged prices revert before signature validation.
    /// @param cdo The CDO that receives the updated valuation price.
    /// @param totalSupply Accountable total supply, scaled to 18 decimals.
    /// @param totalReserveUsd Accountable total reserve value in USD, scaled to 18 decimals.
    /// @param signature Observer signature over the ABI-encoded nonce, CDO address, total supply, and reserve value.
    function pushProofOfReserve(
        IStrataCDO cdo,
        uint256 totalSupply,
        uint256 totalReserveUsd,
        bytes memory signature
    ) external onlyOwner {
        if (address(cdo) == address(0)) {
            revert ZeroAddress();
        }
        if (totalSupply == 0 || totalReserveUsd == 0) {
            revert InvalidPrice();
        }

        uint256 price = Math.mulDiv(totalReserveUsd, MAX_PRICE, totalSupply);
        if (price > MAX_PRICE) {
            price = MAX_PRICE;
        }

        uint128 cappedPrice = uint128(price);
        uint128 currentPrice = cdo.accounting().valuationPrice();
        if (cappedPrice == currentPrice) {
            revert ValuationPriceUnchanged();
        }

        bytes memory payload = abi.encode(nonce++, address(cdo), totalSupply, totalReserveUsd);
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(payload);
        if (ECDSA.recover(digest, signature) != observer) {
            revert InvalidSignature();
        }

        cdo.setValuationPrice(cappedPrice);
        if (cappedPrice < currentPrice) {
            // Price drops pause actions; price recoveries keep the current action states
            cdo.setActionStates(address(cdo.jrtVault()), false, false);
            cdo.setActionStates(address(cdo.srtVault()), false, false);
        }

        emit ProofOfReservePushed(address(cdo), cappedPrice);
    }

    function _setObserver(address observer_) internal {
        if (observer_ == address(0)) {
            revert ZeroAddress();
        }
        observer = observer_;
        emit ObserverSet(observer_);
    }
}
