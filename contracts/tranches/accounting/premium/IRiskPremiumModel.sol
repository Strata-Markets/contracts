// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UD60x18} from "@prb/math/src/ud60x18/Math.sol";

interface IRiskPremiumModel {
    function riskPremium(UD60x18 tvlRatio) external view returns (UD60x18);
}
