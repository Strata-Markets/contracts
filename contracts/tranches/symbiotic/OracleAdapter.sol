// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";

contract OracleAdapter is IOracleAdapter {
    function getPrice(address asset) external view returns (uint256 price, uint256 decimals) {
        // TODO: get price from underlying oracle
        return (1e18, 18);
    }
}
