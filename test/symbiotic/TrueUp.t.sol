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
///           keeping the identity navT1 + insuranceAmount == jrt + srt + reserve + premium;
///         - `trueUp()` settles the outstanding claim: it raises nav, clears the claim, credits no
///           tranche, and is never skimmed by reserve/premium nor re-detected as a fresh gain;
///         - a later gain first unwinds the claim (self-healing recovery) before being distributed.
/// @dev This test contract plays the role of the CDO for the Accounting instance under test: it
///      implements the one function Accounting calls on `cdo` (totalStrategyAssets()), and being
///      `cdo`, every call it makes to Accounting passes the onlyCDO check.
contract TrueUp is Test {

    uint256 constant ONE_ASSET = 1e18;

    Accounting accounting;
    MockInsurancePool pool;
    uint256 mockStrategyTvl;

    event TrueUpApplied(uint256 amount, uint256 insuranceAmount);

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
        accounting.setNetworkMiddleware(address(pool));

        // Non-zero reserve and premium skims: if coverage or settlement ever ran through the gain
        // waterfall, these would silently eat part of the covered/injected amount.
        accounting.setReserveBps(0.1e18);
        // Premium policy is owned by the middleware, so the pool sets it.
        vm.prank(address(pool));
        accounting.setPremiumBps(0.1e18);

        // Seed an initial deposit: 1000 Jrt + 1000 Srt, mirroring what CDO.deposit() would book.
        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
    }

    /// Mezzanine: Jrt absorbs first, coverage holds the Srt shortfall whole.
    function test_mezzanine_coverageHoldsSrtWhole_thenTrueUpSettles() public {
        // Loss 1050: Jrt wiped to its floor (999 absorbed); the remaining 51 that would reach Srt
        // is instead absorbed by coverage, so Srt stays whole.
        mockStrategyTvl = 950e18;
        accounting.updateAccounting(950e18);

        assertEq(accounting.jrtBaseNav(), ONE_ASSET, "Jrt wiped to its floor");
        assertEq(accounting.srtBaseNav(), 1000e18, "Srt held whole by coverage");
        assertEq(accounting.insuranceAmount(), 51e18, "claim equals the Srt-bound loss");
        assertEq(accounting.nav(), 950e18);

        uint256 reserveBefore = accounting.reserveNav();
        uint256 premiumBefore = accounting.premiumNav();
        uint256 srtBefore = accounting.srtBaseNav();
        uint256 jrtBefore = accounting.jrtBaseNav();

        // Coverage funds arrive: settle the full claim.
        vm.expectEmit(false, false, false, true);
        emit TrueUpApplied(51e18, 0);
        accounting.trueUp(51e18);

        assertEq(accounting.insuranceAmount(), 0, "claim fully settled");
        assertEq(accounting.srtBaseNav(), srtBefore, "Srt untouched by settlement (already whole)");
        assertEq(accounting.jrtBaseNav(), jrtBefore, "Jrt untouched by settlement");
        assertEq(accounting.reserveNav(), reserveBefore, "settlement not skimmed by reserve");
        assertEq(accounting.premiumNav(), premiumBefore, "settlement not skimmed by premium");
        assertEq(accounting.nav(), 950e18 + 51e18, "nav rises by exactly the settled amount");

        // Funds actually land in the strategy; re-accounting must not re-detect them as a gain.
        mockStrategyTvl = accounting.nav();
        accounting.updateAccounting(mockStrategyTvl);

        assertEq(accounting.insuranceAmount(), 0, "no new claim");
        assertEq(accounting.reserveNav(), reserveBefore, "no phantom gain to reserve");
        assertEq(accounting.premiumNav(), premiumBefore, "no phantom gain to premium");
        assertEq(accounting.srtBaseNav(), srtBefore, "Srt stays whole");
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

    /// A recovery gain first unwinds the outstanding claim before any reserve/premium skim.
    function test_recoveryGain_unwindsClaim_beforeSkim() public {
        // Covered loss: 51 booked to the claim (mezzanine).
        mockStrategyTvl = 950e18;
        accounting.updateAccounting(950e18);
        assertEq(accounting.insuranceAmount(), 51e18);

        uint256 premiumBefore = accounting.premiumNav();

        // A 30 recovery gain: fully consumed unwinding the claim, so it skims nothing.
        mockStrategyTvl = 980e18;
        accounting.updateAccounting(980e18);

        assertEq(accounting.insuranceAmount(), 21e18, "gain unwinds the claim first");
        assertEq(accounting.premiumNav(), premiumBefore, "recovery gain is not skimmed by premium");
    }

    /// Without a configured pool, losses hit the tranches as usual and no claim is created.
    function test_noPool_lossHitsTranches_noClaim() public {
        accounting.setNetworkMiddleware(address(0));

        mockStrategyTvl = 950e18;
        accounting.updateAccounting(950e18);

        assertEq(accounting.insuranceAmount(), 0, "no claim without a pool");
        assertEq(accounting.jrtBaseNav(), ONE_ASSET, "Jrt wiped to its floor");
        assertEq(accounting.srtBaseNav(), 949e18, "Srt absorbs the residual loss");
    }
}
