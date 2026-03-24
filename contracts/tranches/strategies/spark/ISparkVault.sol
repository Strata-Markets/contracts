// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ISparkVault is IERC4626 {
    function drip() external;
}
