// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { AaveAprPairProvider, IAavePool } from "../../../contracts/tranches/strategies/ethena/AaveAprPairProvider.sol";
import { AaveOracleAprPairProvider } from "../../../contracts/tranches/strategies/midas/AaveOracleAprPairProvider.sol";
import { IsUSDe } from "../../../contracts/tranches/strategies/ethena/IsUSDe.sol";

contract MockAToken {
    uint256 public totalSupply;
    constructor(uint256 _supply) {
        totalSupply = _supply;
    }
    function setTotalSupply(uint256 _supply) external {
        totalSupply = _supply;
    }
}

contract MockAavePoolForTest is IAavePool {
    uint128 public currentLiquidityRate;
    address public aToken;

    constructor(uint128 _rate, address _aToken) {
        currentLiquidityRate = _rate;
        aToken = _aToken;
    }

    function setRate(uint128 _rate) external {
        currentLiquidityRate = _rate;
    }

    function getReserveData(address) external view returns (
        uint256, uint128, uint128, uint128, uint128, uint128, uint40, uint16,
        address, address, address, address, uint128, uint128, uint128
    ) {
        return (
            0, 0, currentLiquidityRate, 0, 0, 0, 0, 0,
            aToken, address(0), address(0), address(0), 0, 0, 0
        );
    }
}

contract AaveAprProviderClampingTest is Test {
    uint256 constant BOUND_MAX = 0.4e12; // 40%

    function testZeroWeightReturnsZeroWithoutPanic() public {
        MockAToken aToken = new MockAToken(0);
        MockAavePoolForTest pool = new MockAavePoolForTest(0, address(aToken));
        address[] memory tokens = new address[](0);

        AaveAprPairProvider provider = new AaveAprPairProvider(
            pool,
            tokens,
            IsUSDe(address(0))
        );

        int64 apr = provider.getAPRtarget();
        assertEq(apr, 0);
    }

    function testRateAboveBoundMaxClampsWithoutRevert() public {
        MockAToken aToken = new MockAToken(1_000_000e6);
        // 55% APR in Ray: 0.55 * 1e27 = 55e25
        uint128 rate55Percent = uint128(55e25);
        MockAavePoolForTest pool = new MockAavePoolForTest(rate55Percent, address(aToken));
        address[] memory tokens = new address[](1);
        tokens[0] = makeAddr("USDC");

        AaveAprPairProvider provider = new AaveAprPairProvider(
            pool,
            tokens,
            IsUSDe(address(0))
        );

        int64 apr = provider.getAPRtarget();
        // Clamped to BOUND_MAX (40% / 0.4e12)
        assertEq(uint64(apr), uint64(BOUND_MAX));
    }

    function testNormalRateUnclamped() public {
        MockAToken aToken = new MockAToken(1_000_000e6);
        // 10% APR in Ray: 0.10 * 1e27 = 10e25
        uint128 rate10Percent = uint128(10e25);
        MockAavePoolForTest pool = new MockAavePoolForTest(rate10Percent, address(aToken));
        address[] memory tokens = new address[](1);
        tokens[0] = makeAddr("USDC");

        AaveAprPairProvider provider = new AaveAprPairProvider(
            pool,
            tokens,
            IsUSDe(address(0))
        );

        int64 apr = provider.getAPRtarget();
        // Exact 10% in 1e12: 0.10 * 1e12 = 100_000_000_000
        assertEq(uint64(apr), uint64(0.10e12));
    }
}
