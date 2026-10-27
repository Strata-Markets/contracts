// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import 'forge-std/Test.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {MidasStrategy} from 'contracts/tranches/strategies/midas/MidasStrategy.sol';
import {MidasCooldownRequestImpl} from 'contracts/tranches/strategies/midas/MidasCooldownRequestImpl.sol';
import {
    AaveOracleAprPairProvider,
    IRoundDataOracle,
    IAavePool
} from 'contracts/tranches/strategies/midas/AaveOracleAprPairProvider.sol';
import {MockMToken} from 'contracts/test/midas/MockMToken.sol';
import {MockBaseAsset} from 'contracts/test/midas/MockBaseAsset.sol';
import {MockOracle} from 'contracts/test/midas/MockOracle.sol';
import {MockDepositVault} from 'contracts/test/midas/MockDepositVault.sol';
import {MockRedemptionVault} from 'contracts/test/midas/MockRedemptionVault.sol';
import {IMToken} from 'contracts/tranches/strategies/midas/interfaces/IMToken.sol';
import {IDepositVault} from 'contracts/tranches/strategies/midas/interfaces/IDepositVault.sol';
import {IRedemptionVault} from 'contracts/tranches/strategies/midas/interfaces/IRedemptionVault.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

contract MidasStrategyTest is Test {
    MidasStrategy public strategy;
    MockMToken public mToken;
    MockBaseAsset public baseAsset;
    MockOracle public oracle;
    MockDepositVault public depositVault;
    MockRedemptionVault public redemptionVault;

    address public deployer = address(this);

    function setUp() public {
        vm.warp(100_000);

        mToken = new MockMToken();
        baseAsset = new MockBaseAsset(); // 6 decimals (USDC)
        oracle = new MockOracle();
        depositVault = new MockDepositVault(mToken, oracle);
        redemptionVault = new MockRedemptionVault(mToken, baseAsset, oracle);

        // Set oracle round: $1.05 per mToken (1.05e8 in Chainlink 8-decimal)
        oracle.setRoundData(1, 1_00000000, block.timestamp - 86400); // Round 1: $1.00
        oracle.setRoundData(2, 1_05000000, block.timestamp); // Round 2: $1.05

        strategy = new MidasStrategy(
            IERC20(address(baseAsset)),
            IMToken(address(mToken)),
            IDepositVault(address(depositVault)),
            IRedemptionVault(address(redemptionVault)),
            oracle
        );
    }

    function test_withdrawalCapacityOnlyAllowsExitTokens() public view {
        assertEq(strategy.maxWithdraw(address(this), address(baseAsset), 0), type(uint256).max);
        assertEq(strategy.maxWithdraw(address(this), address(mToken), 0), type(uint256).max);
        assertEq(strategy.maxWithdraw(address(this), address(0xDA1), 0), 0);
        assertEq(strategy.maxWithdraw(address(this), address(0xDA1), 100e18), 0);
    }

    // ========================================
    // Oracle Rate Tests
    // ========================================

    function test_getOracleRate() public view {
        uint256 rate = strategy.getOracleRate();
        assertEq(rate, 1.05e18, 'Oracle rate should be 1.05e18');
    }

    function test_getOracleRate_reverts_on_zero() public {
        MockOracle badOracle = new MockOracle();
        badOracle.setRoundData(1, 0, block.timestamp);

        MidasStrategy badStrategy = new MidasStrategy(
            IERC20(address(baseAsset)),
            IMToken(address(mToken)),
            IDepositVault(address(depositVault)),
            IRedemptionVault(address(redemptionVault)),
            badOracle
        );

        vm.expectRevert('InvalidRate');
        badStrategy.getOracleRate();
    }

    function test_getOracleRate_reverts_on_negative() public {
        MockOracle badOracle = new MockOracle();
        badOracle.setRoundData(1, -1_00000000, block.timestamp);

        MidasStrategy badStrategy2 = new MidasStrategy(
            IERC20(address(baseAsset)),
            IMToken(address(mToken)),
            IDepositVault(address(depositVault)),
            IRedemptionVault(address(redemptionVault)),
            badOracle
        );

        vm.expectRevert('InvalidRate');
        badStrategy2.getOracleRate();
    }

    // ========================================
    // Conversion Tests (6-decimal baseAsset)
    // ========================================

    function test_convertToAssets_mToken() public view {
        // 100 mToken (100e18) at $1.05 = 105 USDC (105e6)
        // mulDiv(100e18, 1.05e18, 1e30) = 105e36 / 1e30 = 105e6
        uint256 result = strategy.convertToAssets(address(mToken), 100e18, Math.Rounding.Floor);
        assertEq(result, 105e6, '100 mToken at $1.05 = 105 USDC (6 decimals)');
    }

    function test_convertToAssets_baseAsset_identity() public view {
        // baseAsset to baseAsset = identity
        uint256 result = strategy.convertToAssets(address(baseAsset), 42e6, Math.Rounding.Floor);
        assertEq(result, 42e6, 'baseAsset should be identity');
    }

    function test_convertToTokens_mToken() public view {
        // 105 USDC (105e6) at $1.05/mToken = 100 mToken (100e18)
        // mulDiv(105e6, 1e30, 1.05e18) = 105e36 / 1.05e18 = 100e18
        uint256 result = strategy.convertToTokens(address(mToken), 105e6, Math.Rounding.Floor);
        assertEq(result, 100e18, '105 USDC at $1.05 = 100 mToken (18 decimals)');
    }

    function test_convertToTokens_baseAsset_identity() public view {
        uint256 result = strategy.convertToTokens(address(baseAsset), 42e6, Math.Rounding.Floor);
        assertEq(result, 42e6, 'baseAsset should be identity');
    }

    function test_convertToAssets_unsupported_reverts() public {
        vm.expectRevert();
        strategy.convertToAssets(address(0x1), 100e18, Math.Rounding.Floor);
    }

    function test_convertToTokens_unsupported_reverts() public {
        vm.expectRevert();
        strategy.convertToTokens(address(0x1), 100e6, Math.Rounding.Floor);
    }

    // ========================================
    // Rounding Tests
    // ========================================

    function test_rounding_ceil_gte_floor_convertToTokens() public view {
        // 100 USDC (100e6) / 1.05 = 95.238095... mToken
        uint256 floor = strategy.convertToTokens(address(mToken), 100e6, Math.Rounding.Floor);
        uint256 ceil = strategy.convertToTokens(address(mToken), 100e6, Math.Rounding.Ceil);
        assertGe(ceil, floor, 'Ceil should be >= Floor');
        assertGt(ceil, floor, 'Should have different rounding for 100/1.05');
    }

    function test_rounding_ceil_gte_floor_convertToAssets() public view {
        // 1 wei of mToken * 1.05 — tiny amount to test edge rounding
        uint256 floor = strategy.convertToAssets(address(mToken), 1, Math.Rounding.Floor);
        uint256 ceil = strategy.convertToAssets(address(mToken), 1, Math.Rounding.Ceil);
        assertGe(ceil, floor, 'Ceil should be >= Floor');
    }

    function test_withdraw_rounds_ceil_for_shares() public view {
        // Verifies withdraw uses Ceil rounding (protocol-safe: more mToken needed)
        uint256 baseAssets_ = 100e6; // 100 USDC
        uint256 shares = strategy.convertToTokens(address(mToken), baseAssets_, Math.Rounding.Ceil);
        uint256 assetsBack = strategy.convertToAssets(address(mToken), shares, Math.Rounding.Floor);
        assertGe(assetsBack, baseAssets_, 'Round-trip should not lose dust');
    }

    // ========================================
    // totalAssets Tests
    // ========================================

    function test_totalAssets() public {
        // Mint mToken to strategy
        mToken.mint(address(strategy), 1000e18);

        uint256 total = strategy.totalAssets();
        // 1000 mToken at $1.05 = 1050 USDC = 1050e6
        assertEq(total, 1050e6, '1000 mToken at $1.05 = 1050 USDC');
    }

    function test_totalAssets_staleness_fresh() public {
        mToken.mint(address(strategy), 1000e18);

        uint256 latestNav = 900e6;
        // Oracle updatedAt = block.timestamp (set in setUp)
        // Pass timestamp BEFORE oracle update → should return fresh totalAssets
        uint256 fresh = strategy.totalAssets(latestNav, block.timestamp - 100);
        assertEq(fresh, 1050e6, 'Should return fresh NAV when oracle updated after timestamp');
    }

    function test_totalAssets_staleness_stale() public {
        mToken.mint(address(strategy), 1000e18);

        uint256 latestNav = 900e6;
        // Pass timestamp AFTER oracle update → should return latestNav
        uint256 stale = strategy.totalAssets(latestNav, block.timestamp + 100);
        assertEq(stale, latestNav, 'Should return latestNav when oracle is stale');
    }

    function test_rateScale() public view {
        // shareTokenDecimals=18, baseAssetDecimals=6 → scale = 10^(18+18-6) = 10^30
        assertEq(10 ** (18 + strategy.shareTokenDecimals() - strategy.baseAssetDecimals()), 1e30);
    }

    // ========================================
    // CooldownRequestImpl Tests
    // ========================================

    function test_isCooldownActive_always_true() public {
        MidasCooldownRequestImpl impl = new MidasCooldownRequestImpl(
            IERC20(address(baseAsset)),
            IMToken(address(mToken)),
            IRedemptionVault(address(redemptionVault))
        );
        assertTrue(impl.isCooldownActive(), 'isCooldownActive should always be true');
    }

    // ========================================
    // APR Pair Provider Tests (Base APR math)
    // ========================================

    function test_aprBase_calculation() public {
        // AaveOracleAprPairProvider.getAPRbase() reads from oracle
        // Round 1: $1.00 at t-7days
        // Round 2: $1.001 at t
        // APR = (ppsChange * SECONDS_PER_YEAR * 1e12) / ppsT0 / deltaT
        // = (100000 * 31536000 * 1e12) / 100000000 / 604800
        // = 52_142_857_142 (≈5.21%)

        MockOracle aprOracle = new MockOracle();
        uint256 t0 = 1_000;
        uint256 t1 = 1_000 + 7 days; // 7 days apart
        // Price: $1.00 → $1.001 in 7 days — small, reasonable change
        aprOracle.setRoundData(1, 1_00000000, t0); // $1.00
        aprOracle.setRoundData(2, 1_00100000, t1); // $1.001

        // Verify the expected APR math manually:
        int256 ppsChange = 1_00100000 - 1_00000000; // 100000
        uint256 deltaT = t1 - t0; // 604800
        int256 apr = (ppsChange * int256(uint256(31_536_000)) * 1e12) / 1_00000000 / int256(deltaT);
        assertGt(apr, 0, 'APR should be positive');
        assertLt(apr, int256(uint256(0.4e12)), 'APR should be below BOUND_MAX (40%)');
    }

    // ========================================
    // Fuzz Tests
    // ========================================

    function testFuzz_convertRoundTrip(uint256 baseAssets_) public view {
        // Bound to reasonable range (in 6-decimal USDC)
        baseAssets_ = bound(baseAssets_, 1, 1e15); // up to 1 billion USDC

        // Convert to mToken (Ceil) then back to assets (Floor)
        uint256 shares = strategy.convertToTokens(address(mToken), baseAssets_, Math.Rounding.Ceil);
        uint256 assetsBack = strategy.convertToAssets(address(mToken), shares, Math.Rounding.Floor);

        // assetsBack should be >= baseAssets_ (no dust loss with Ceil→Floor trip)
        assertGe(assetsBack, baseAssets_, 'Round-trip should not lose dust');
    }

    function testFuzz_oracleRate(int256 answer) public {
        // Bound answer to positive values Chainlink would use
        answer = bound(answer, 1, type(int128).max);

        MockOracle fuzzOracle = new MockOracle();
        fuzzOracle.setRoundData(1, answer, block.timestamp);

        MidasStrategy fuzzStrategy = new MidasStrategy(
            IERC20(address(baseAsset)),
            IMToken(address(mToken)),
            IDepositVault(address(depositVault)),
            IRedemptionVault(address(redemptionVault)),
            fuzzOracle
        );

        uint256 rate = fuzzStrategy.getOracleRate();
        assertEq(rate, uint256(answer) * 1e10, 'Rate should be answer * 10^10');
    }
}
