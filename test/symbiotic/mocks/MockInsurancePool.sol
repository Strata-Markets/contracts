// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IInsurancePool } from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";

/// @notice Insurance pool mock that covers losses up to a settable capacity, in base assets.
contract MockInsurancePool is IInsurancePool {
    uint256 public capacity;

    function setCapacity(uint256 capacity_) external {
        capacity = capacity_;
    }

    function request(address, uint256 lossAmount) external view returns (uint256) {
        return lossAmount < capacity ? lossAmount : capacity;
    }
}
