// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UD60x18, pow} from "@prb/math/src/ud60x18/Math.sol";
import {IRiskPremiumModel} from "./IRiskPremiumModel.sol";

/// @title RiskPremiumPower
/// @notice Initial Strata risk premium model: `x + y * tvlRatio^k`.
contract RiskPremiumPower is IRiskPremiumModel {
    UD60x18 public immutable x;
    UD60x18 public immutable y;
    UD60x18 public immutable k;

    constructor (UD60x18 x_, UD60x18 y_, UD60x18 k_) {
        // The premium peaks at tvlRatio = 1, where it equals x + y.
        require((x_ + y_).unwrap() < 1e18, ">=100%");
        x = x_;
        y = y_;
        k = k_;
    }

    function riskPremium(UD60x18 tvlRatio) external view returns (UD60x18) {
        return x + y * pow(tvlRatio, k);
    }
}
