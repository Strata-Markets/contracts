// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UD60x18} from "@prb/math/src/ud60x18/ValueType.sol";
import {IRiskPremiumModel} from "./IRiskPremiumModel.sol";

/// @notice Fixed risk premium, independent of the Senior/Junior TVL ratio.
/// @dev At 100%, Senior has no share of strategy yield; its target APR is configured separately.
contract RiskPremiumStatic is IRiskPremiumModel {
    UD60x18 public immutable premium;

    constructor(UD60x18 premium_) {
        require(premium_.unwrap() <= 1e18, ">100%");
        premium = premium_;
    }

    function riskPremium(UD60x18) external view returns (UD60x18) {
        return premium;
    }
}
