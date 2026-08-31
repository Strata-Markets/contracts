// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TimelockController as TimelockBase } from "@openzeppelin/contracts/governance/TimelockController.sol";

contract StrataMasterChef is TimelockBase {

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors) TimelockBase(
        minDelay, proposers, executors, address(0)
    ) {
        // Only the initial delay is bounded; later changes use TimelockController.updateDelay
        require(minDelay >= 1 * 24 hours, "InitialDelayTooShort");
        require(minDelay <= 7 * 24 hours, "InitialDelayTooLong");
    }
}
