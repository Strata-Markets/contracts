// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { MockInsurancePool } from "../../../test/symbiotic/mocks/MockInsurancePool.sol";

/// @notice Regression for the Cyfrin finding: a Senior exit during a Symbiotic-covered de-peg used to be split as
///         if Junior alone covered Senior's de-peg need, leaving Senior principal overstated. The next valuation
///         push then re-sized coverage from that principal, over-covering the remaining Seniors and over-booking
///         the claim. Separately, the push used to treat the existing credit as surplus, cancel it and slash it
///         again. Both are fixed: the exit takes the same fraction of every part of Senior's effective NAV, and
///         the credit kept on a push is sized from Senior's principal.
///
///         Fixture: Jrt 1000, Srt 1000, nav 2000, in-scope `Accounting`.
///         De-peg to $0.40: Senior needs 2500 tokens -> Junior gives 999, Symbiotic covers 501.
///         A Senior holding 10% of the tranche exits: 250 tokens ($100).
///         Correct decomposition of that exit (10% of each component of Senior's 2500):
///             principal 100 + Junior headroom 99.9 + Symbiotic credit 50.1 = 250.
///         Remaining Seniors are then owed $900, backed by a claim of 450.9 (90% of 501).
contract SeniorExitDuringCoveredDepegOverCoversTest is Test {
    Accounting accounting;
    MockInsurancePool pool;
    uint256 mockStrategyTvl;

    uint256 constant CAPACITY = 1_000_000e18;
    uint128 constant PRICE = 0.4e18;
    uint256 constant EXIT = 250e18; // 10% of Senior's 2500 effective tokens

    uint256 constant OWED_SENIOR_USD = 900e18;  // remaining 90% of Senior's $1000
    uint256 constant CORRECT_CLAIM = 450.9e18;  // remaining 90% of the 501 Symbiotic credit

    /// @dev Acts as the CDO: Accounting reads the strategy value from here.
    function totalStrategyAssets() external view returns (uint256) {
        return mockStrategyTvl;
    }

    function setUp() public {
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = Accounting(address(new ERC1967Proxy(
            address(new Accounting(18)),
            abi.encodeWithSelector(
                Accounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(0))
            )
        )));
        pool = new MockInsurancePool();
        pool.setCapacity(CAPACITY);
        accounting.setInsurancePool(pool);
        accounting.setReserveBps(0.1e18);
        accounting.setUnderwriterFeeBps(0.1e18);

        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);

        accounting.setValuationPrice(PRICE);
    }

    /// @dev Senior exit as the CDO performs it: the covered slice is paid from the InsuranceVault and
    ///      only the remainder leaves the strategy.
    function _seniorExit(uint256 assets) internal returns (uint256 insuranceBaseOut) {
        insuranceBaseOut = accounting.updateBalanceFlow(0, 0, 0, assets);
        mockStrategyTvl -= assets - insuranceBaseOut;
    }

    /// Next push: the remaining Seniors are topped up to exactly the $900 they are owed.
    function test_nextPush_remainingSeniorsCoveredExactly() public {
        _seniorExit(EXIT);
        accounting.setValuationPrice(PRICE - 1); // AccountablePushOracle accepts any changed price

        (, uint256 srt,) = accounting.totalAssets();
        uint256 srtUsd = srt * PRICE / 1e18;
        assertApproxEqAbs(srtUsd, OWED_SENIOR_USD, 1e12, "remaining Seniors owed $900");
    }

    /// Next push: the claim stays at 450.9, the remaining Seniors' 90% of the 501 credit.
    function test_nextPush_claimCorrect() public {
        _seniorExit(EXIT);
        accounting.setValuationPrice(PRICE - 1);

        assertApproxEqAbs(accounting.insuranceAmount(), CORRECT_CLAIM, 1e12, "claim should be 450.9");
    }

    /// Next push: the 501 slashed at the de-peg already backs the exiter's 50.1 and the remaining Seniors'
    /// 450.9, and the price barely moves, so no new slash is owed.
    function test_nextPush_doesNotReslashUnderwriters() public {
        assertEq(_slashed(), 501e18, "de-peg slash: 501");

        uint256 insuranceBaseOut = _seniorExit(EXIT);
        assertEq(_slashed(), 501e18, "the exit slashes nothing");
        assertApproxEqAbs(insuranceBaseOut, 50.1e18, 1e12, "the vault pays the exiter's 10% of the credit");

        accounting.setValuationPrice(PRICE - 1);
        assertApproxEqAbs(_slashed(), 501e18, 1e12, "the push owes ~0 new slash");
    }

    /// A repeated de-peg push with no exit at all must not cancel and re-slash the existing credit.
    function test_repeatedPush_noExit_doesNotReslash() public {
        assertEq(_slashed(), 501e18, "de-peg slash: 501");

        accounting.setValuationPrice(PRICE - 1);
        assertApproxEqAbs(_slashed(), 501e18, 1e12, "same price again: ~0 new slash");
        assertApproxEqAbs(accounting.insuranceAmount(), 501e18, 1e12, "claim unchanged");
    }

    function _slashed() internal view returns (uint256) {
        return CAPACITY - pool.capacity();
    }
}
