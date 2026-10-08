// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {INestAccountant, INestVaultPredicateProxy} from "../../contracts/tranches/strategies/nest/interfaces/INestContracts.sol";

/**
 * @title NestOpalForkTest
 * @notice Fork tests against real mainnet nOPAL contracts.
 * @dev Forks MAINNET_RPC_URL in setUp. Run with:
 *      MAINNET_RPC_URL=<archive rpc> forge test --match-path test/nest/NestOpalForkTest.t.sol -v
 *
 *      Validates that:
 *      1. nOPAL token has 6 decimals (critical for 1e6 divisor)
 *      2. Accountant returns a valid rate via getRateInQuoteSafe
 *      3. Hook does not block transfers (shareLockPeriod = 0 or no lock)
 *      4. V2 NestVaultPredicateProxy at 0xB65B65Cf... has deployed code and exposes the bytes deposit
 *      5. Teller at 0xA5F8e584... has deployed code
 *      6. NAV formula produces correct results with live rate
 */
contract NestOpalForkTest is Test {

    // ═══════ Mainnet addresses (keep in sync with Eth.nestopal in src/platforms/Eth.ts) ═══════

    address constant NOPAL = 0x119Dd7dAFf816f29D7eE47596ae5E4bdC4299165;
    address constant ACCOUNTANT = 0x2Ed2f77a961fc92F73D1087786099c39C894Ed1D;
    address constant PREDICATE_PROXY = 0xB65B65CfF0CA1f3cc12fe58a13110E43DfA999F1;
    address constant TELLER = 0xA5F8e5843dd597a179453bF782844e8Bf808A90b;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    // ═══════ Tests ═══════

    /// @notice Verify nOPAL has exactly 6 decimals - critical for the 1e6 divisor
    function test_Fork_nOPAL_Decimals() public view {
        (bool success, bytes memory data) = NOPAL.staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(success, "decimals() call should succeed");
        uint8 decimals = abi.decode(data, (uint8));
        assertEq(decimals, 6, "nOPAL must have 6 decimals - 1e6 divisor depends on this");
    }

    /// @notice Verify nOPAL token name matches expected
    function test_Fork_nOPAL_Name() public view {
        (bool success, bytes memory data) = NOPAL.staticcall(abi.encodeWithSignature("name()"));
        assertTrue(success, "name() call should succeed");
        string memory name = abi.decode(data, (string));
        assertEq(name, "Nest BlackOpal LiquidStone II Vault", "nOPAL name mismatch");
    }

    /// @notice Verify Accountant returns a valid, non-zero rate for USDC quote
    function test_Fork_Accountant_Rate() public view {
        uint256 rate = INestAccountant(ACCOUNTANT).getRateInQuoteSafe(USDC);
        assertGt(rate, 0, "Rate should be non-zero");
        // Rate should be reasonable: between 0.5 and 5.0 USDC/nOPAL (500000 to 5000000)
        assertGt(rate, 500000, "Rate too low - possible decimals issue");
        assertLt(rate, 5000000, "Rate too high - possible decimals issue");
        console2.log("Live nOPAL/USDC rate:", rate);
    }

    /// @notice Verify the NAV formula produces correct results with the live rate
    function test_Fork_NAV_Formula() public view {
        uint256 rate = INestAccountant(ACCOUNTANT).getRateInQuoteSafe(USDC);

        // Simulate: 100 nOPAL shares
        uint256 shares = 100 * 1e6;
        uint256 nav = Math.mulDiv(shares, rate, 1e6);

        // NAV should be ~100 * rate/1e6 USDC (between 50 and 500 USDC)
        assertGt(nav, 50 * 1e6, "NAV for 100 nOPAL too low");
        assertLt(nav, 500 * 1e6, "NAV for 100 nOPAL too high");

        console2.log("100 nOPAL NAV (USDC-wei):", nav);
        console2.log("100 nOPAL NAV (USDC):", nav / 1e6);
    }

    /// @notice Verify PredicateProxy has deployed code
    function test_Fork_PredicateProxy_HasCode() public view {
        uint256 codeSize;
        assembly { codeSize := extcodesize(PREDICATE_PROXY) }
        assertGt(codeSize, 0, "PredicateProxy should have deployed code");
        console2.log("PredicateProxy code size:", codeSize);
    }

    /// @notice Verify Teller has deployed code
    function test_Fork_Teller_HasCode() public view {
        uint256 codeSize;
        assembly { codeSize := extcodesize(TELLER) }
        assertGt(codeSize, 0, "Teller should have deployed code");
        console2.log("Teller code size:", codeSize);
    }

    /// @notice Verify nOPAL hook does not have a share lock that would block adapter
    function test_Fork_Hook_NoShareLock() public view {
        // Get the hook address from the BoringVault
        (bool success, bytes memory data) = NOPAL.staticcall(abi.encodeWithSignature("hook()"));
        assertTrue(success, "hook() call should succeed");
        address hook = abi.decode(data, (address));
        console2.log("Hook address:", hook);

        // Try calling shareLockPeriod() on the hook - if it exists and returns 0, we're safe
        // If it doesn't exist (reverts), there's no lock mechanism - also safe
        (bool lockSuccess, bytes memory lockData) = hook.staticcall(abi.encodeWithSignature("shareLockPeriod()"));
        if (lockSuccess && lockData.length >= 32) {
            uint256 lockPeriod = abi.decode(lockData, (uint256));
            assertEq(lockPeriod, 0, "shareLockPeriod must be 0 for adapter to work");
            console2.log("shareLockPeriod:", lockPeriod);
        } else {
            // No shareLockPeriod function - no lock mechanism. Safe.
            console2.log("Hook does not have shareLockPeriod() - no lock mechanism (safe)");
        }
    }

    /// @notice Verify the conversion round-trip with live rate
    function test_Fork_ConversionRoundTrip() public view {
        uint256 rate = INestAccountant(ACCOUNTANT).getRateInQuoteSafe(USDC);

        uint256 originalTokens = 12345 * 1e6; // 12345 nOPAL

        // tokens → assets (Floor)
        uint256 assets = Math.mulDiv(originalTokens, rate, 1e6, Math.Rounding.Floor);
        // assets → tokens (Ceil)
        uint256 tokensBack = Math.mulDiv(assets, 1e6, rate, Math.Rounding.Ceil);

        // Protocol should never lose: tokensBack >= originalTokens
        assertGe(tokensBack, originalTokens, "Round-trip should not lose tokens (favors protocol)");
        // But should be very close (at most 2 wei difference)
        assertApproxEqAbs(tokensBack, originalTokens, 2, "Round-trip difference should be at most 2 wei");
    }

    /// @notice Verify the V2 bytes deposit selector matches our interface and is present in the live implementation
    function test_Fork_PredicateProxy_Selector() public view {
        // On-chain signature: deposit(address,uint256,address,address,bytes) returns (uint256 shares)
        bytes4 expectedSelector = bytes4(keccak256("deposit(address,uint256,address,address,bytes)"));
        assertEq(expectedSelector, bytes4(0x16c730be), "Selector mismatch for V2 bytes deposit");
        assertEq(INestVaultPredicateProxy.deposit.selector, expectedSelector, "INestVaultPredicateProxy selector drifted");

        // The proxy is ERC1967, so look for the selector in the implementation's dispatcher
        address impl = address(uint160(uint256(vm.load(PREDICATE_PROXY, ERC1967_IMPL_SLOT))));
        assertGt(impl.code.length, 0, "Implementation should have deployed code");
        assertTrue(_codeHasSelector(impl.code, expectedSelector), "Implementation does not expose the V2 bytes deposit");
    }

    /// @dev Looks for PUSH4 <selector> (0x63 ++ selector) in the runtime bytecode
    function _codeHasSelector(bytes memory code, bytes4 selector) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 < code.length; i++) {
            if (
                code[i] == 0x63 &&
                code[i + 1] == selector[0] &&
                code[i + 2] == selector[1] &&
                code[i + 3] == selector[2] &&
                code[i + 4] == selector[3]
            ) return true;
        }
        return false;
    }

    /// @notice Verify Accountant rate is consistent across multiple calls
    function test_Fork_Accountant_RateStable() public view {
        uint256 rate1 = INestAccountant(ACCOUNTANT).getRateInQuoteSafe(USDC);
        uint256 rate2 = INestAccountant(ACCOUNTANT).getRateInQuoteSafe(USDC);
        assertEq(rate1, rate2, "Rate should be deterministic within same block");
    }
}
