// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Accounting } from "../../contracts/tranches/Accounting.sol";
import { IStrataCDO } from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../contracts/governance/AccessControlManager.sol";
import { MockInsurancePool } from "./mocks/MockInsurancePool.sol";

/// @notice Proves the insuranceAmount coverage model in `Accounting`:
///         - a covered loss holds the covered tranche whole and books the loss to insuranceAmount,
///           keeping the identity navT1 + insuranceAmount == jrt + srt + reserve + underwriter fee;
///         - Senior redemption settles the outstanding claim: it clears the claim, credits no
///           tranche, and is never skimmed by reserve/underwriter fee nor re-detected as a fresh gain;
///         - a later gain first unwinds the claim (self-healing recovery) before being distributed.
/// @dev This test contract plays the role of the CDO for the Accounting instance under test: it
///      implements the one function Accounting calls on `cdo` (totalStrategyAssets()), and being
///      `cdo`, every call it makes to Accounting passes the onlyCDO check.
contract InsuranceClaimFundingTest is Test {

    uint256 constant ONE_ASSET = 1e18;

    Accounting accounting;
    MockInsurancePool pool;
    uint256 mockStrategyTvl;

    /// @dev Stands in for IStrataCDO.totalStrategyAssets(), the only cdo call these paths make.
    function totalStrategyAssets() external view returns (uint256) {
        return mockStrategyTvl;
    }

    function setUp() public {
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = Accounting(
            address(
                new ERC1967Proxy(
                    address(new Accounting(18)),
                    abi.encodeWithSelector(
                        Accounting.initialize.selector,
                        address(this),
                        address(acm),
                        IStrataCDO(address(this)),
                        IAprPairFeed(address(0))
                    )
                )
            )
        );

        pool = new MockInsurancePool();
        pool.setCapacity(1_000_000e18);
        accounting.setInsurancePool(pool);

        // Non-zero reserve and underwriter fee skims: if coverage or settlement ever ran through the gain
        // waterfall, these would silently eat part of the covered/injected amount.
        accounting.setReserveBps(0.1e18);
        // Underwriter fee policy reaches accounting through the CDO, which this contract stands in for.
        accounting.setUnderwriterFeeBps(0.1e18);

        // Seed an initial deposit: 1000 Jrt + 1000 Srt, mirroring what CDO.deposit() would book.
        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
    }

    /// A mild de-peg is fully absorbed by Junior, so Symbiotic is never asked to cover.
    function test_valuation_juniorAbsorbs_noClaim() public {
        // 0.9: Srt needs 1000/0.9 - 1000 = 111.1 extra, well within Junior's 999 of headroom.
        accounting.setValuationPrice(0.9e18);

        assertEq(accounting.srtInsuranceFundNav(), 0, "Junior covers it; no coverage needed");
        assertEq(accounting.insuranceAmount(), 0, "no claim booked");
    }

    /// A de-peg deep enough to exhaust Junior: Symbiotic covers the residual and Senior reads whole.
    function test_valuation_coversWhatJuniorCannot_thenRepegUnwinds() public {
        // 0.4: Srt needs 1000/0.4 - 1000 = 1500 extra. Junior can give 999 (down to its 1 dust
        // floor), so the 501 residual is the Senior-bound valuation loss Symbiotic covers.
        accounting.setValuationPrice(0.4e18);

        assertEq(accounting.srtInsuranceFundNav(), 501e18, "coverage takes the Junior-exhausted residual");
        assertEq(accounting.insuranceAmount(), 501e18, "and books a matching claim");

        // Senior reads whole: 1000 base + 999 from Junior + 501 covered = 2500 tokens at $0.40 = $1000.
        (uint256 jrtNav, uint256 srtNav,) = accounting.totalAssets(mockStrategyTvl);
        assertEq(srtNav, 2500e18, "Srt held whole in token terms against the de-peg");
        assertEq(jrtNav, 1e18, "Junior drained to its dust floor first");

        // Re-peg: Senior no longer needs the support, so the fund and the claim unwind.
        accounting.setValuationPrice(1e18);
        assertEq(accounting.srtInsuranceFundNav(), 0, "fund unwinds on re-peg");
        assertEq(accounting.insuranceAmount(), 0, "claim unwinds with it");
    }

    /// Without a pool the de-peg residual simply stays with Senior.
    function test_valuation_noPool_noClaim() public {
        accounting.setInsurancePool(MockInsurancePool(address(0)));
        accounting.setValuationPrice(0.4e18);

        assertEq(accounting.srtInsuranceFundNav(), 0, "no coverage without a pool");
        assertEq(accounting.insuranceAmount(), 0, "no claim without a pool");
    }

    /// Mezzanine: Jrt absorbs first, coverage holds the Srt shortfall whole.
    function test_mezzanine_coverageHoldsSrtWhole_thenRedemptionSettles() public {
        // Loss 1050: Jrt wiped to its floor (999 absorbed); the remaining 51 that would reach Srt
        // is instead absorbed by coverage, so Srt stays whole.
        mockStrategyTvl = 950e18;
        accounting.updateAccounting(950e18);

        assertEq(accounting.jrtBaseNav(), ONE_ASSET, "Jrt wiped to its floor");
        assertEq(accounting.srtBaseNav(), 1000e18, "Srt held whole by coverage");
        assertEq(accounting.insuranceAmount(), 51e18, "claim equals the Srt-bound loss");
        assertEq(accounting.nav(), 950e18);

        uint256 reserveBefore = accounting.reserveNav();
        uint256 underwriterFeeBefore = accounting.underwriterFeeNav();
        uint256 jrtBefore = accounting.jrtBaseNav();

        // Senior exits in full. The claim leaves with it: the covered slice is reported back so the
        // CDO can pay it from the insurance vault, and only the rest comes out of the strategy.
        uint256 insuranceOut = accounting.updateBalanceFlow(0, 0, 0, 1000e18);

        assertEq(insuranceOut, 51e18, "the whole claim leaves with the exiting Senior");
        assertEq(accounting.insuranceAmount(), 0, "claim settled by the payout");
        assertEq(accounting.srtBaseNav(), 0, "Srt fully redeemed");
        assertEq(accounting.jrtBaseNav(), jrtBefore, "Jrt untouched by the Senior exit");
        assertEq(accounting.reserveNav(), reserveBefore, "settlement not skimmed by reserve");
        assertEq(accounting.underwriterFeeNav(), underwriterFeeBefore, "settlement not skimmed by underwriter fee");
        // Only 949 of base assets left the strategy; the 51 covered slice was paid from the vault.
        assertEq(accounting.nav(), 950e18 - (1000e18 - 51e18), "nav drops by the strategy slice only");

        // The strategy really is down by that slice; re-accounting sees no phantom gain or loss.
        mockStrategyTvl = accounting.nav();
        accounting.updateAccounting(mockStrategyTvl);

        assertEq(accounting.insuranceAmount(), 0, "no new claim");
        assertEq(accounting.reserveNav(), reserveBefore, "no phantom gain to reserve");
        assertEq(accounting.underwriterFeeNav(), underwriterFeeBefore, "no phantom gain to underwriter fee");
    }

    /// Coverage only covers the Senior-bound loss, so a loss that stays within Jrt's capacity is
    /// absorbed by Jrt with no claim created.
    function test_smallLossHitsJrt_noClaim() public {
        // Loss 100, fully within Jrt's capacity: Jrt eats it, nothing reaches Srt, no coverage.
        mockStrategyTvl = 1900e18;
        accounting.updateAccounting(1900e18);

        assertEq(accounting.jrtBaseNav(), 900e18, "Jrt absorbs the loss it can cover");
        assertEq(accounting.srtBaseNav(), 1000e18, "Srt untouched");
        assertEq(accounting.insuranceAmount(), 0, "no claim: nothing reached Srt");
    }

    /// A recovery gain first unwinds the outstanding claim before any reserve/underwriter fee skim.
    function test_recoveryGain_unwindsClaim_beforeSkim() public {
        // Covered loss: 51 booked to the claim (mezzanine).
        mockStrategyTvl = 950e18;
        accounting.updateAccounting(950e18);
        assertEq(accounting.insuranceAmount(), 51e18);

        uint256 underwriterFeeBefore = accounting.underwriterFeeNav();

        // A 30 recovery gain: fully consumed unwinding the claim, so it skims nothing.
        mockStrategyTvl = 980e18;
        accounting.updateAccounting(980e18);

        assertEq(accounting.insuranceAmount(), 21e18, "gain unwinds the claim first");
        assertEq(accounting.underwriterFeeNav(), underwriterFeeBefore, "recovery gain is not skimmed by underwriter fee");
    }

    /// Without a configured pool, losses hit the tranches as usual and no claim is created.
    function test_noPool_lossHitsTranches_noClaim() public {
        accounting.setInsurancePool(MockInsurancePool(address(0)));

        mockStrategyTvl = 950e18;
        accounting.updateAccounting(950e18);

        assertEq(accounting.insuranceAmount(), 0, "no claim without a pool");
        assertEq(accounting.jrtBaseNav(), ONE_ASSET, "Jrt wiped to its floor");
        assertEq(accounting.srtBaseNav(), 949e18, "Srt absorbs the residual loss");
    }
}
