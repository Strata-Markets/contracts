// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { UD60x18 } from "@prb/math/src/UD60x18.sol";

library UD60x18Ext {

    /// @notice max(x, y)
    function max(UD60x18 x, UD60x18 y) internal pure returns (UD60x18) {
        return UD60x18.unwrap(x) >= UD60x18.unwrap(y) ? x : y;
    }

    /// @notice x * y / 1e18, rounded down
    function mul(UD60x18 x, UD60x18 y) internal pure returns (UD60x18) {
        return UD60x18.wrap(Math.mulDiv(UD60x18.unwrap(x), UD60x18.unwrap(y), 1e18));
    }
}
