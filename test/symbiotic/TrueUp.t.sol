// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Accounting } from "../../contracts/tranches/Accounting.sol";
import { IStrataCDO } from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../contracts/governance/AccessControlManager.sol";

/// @notice Proves that `Accounting.trueUp()` restores a covered tranche's NAV directly and is
///         never routed through the gain waterfall: reserveBps/premiumBps never skim it, it is
///         never credited to the "wrong" tranche, and the very next accounting update (with the
///         strategy TVL now reflecting the injected funds) does not re-detect it as a fresh gain.
/// @dev This test contract plays the role of the CDO for the Accounting instance under test: it
///      implements the one function Accounting actually calls on `cdo` (totalStrategyAssets()),
///      and being `cdo`, every call it makes to Accounting passes the onlyCDO check.
contract TrueUp is Test {

    uint256 constant ONE_ASSET = 1e18;

    Accounting accounting;
    uint256 mockStrategyTvl;

    event TrueUpApplied(uint256 amount, bool jrtCredited, uint256 pendingCoverageDeficit);

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

        // Non-zero reserve and premium skims: if trueUp ever ran through the gain waterfall,
        // these would silently eat part of the injected coverage.
        accounting.setReserveBps(0.1e18);
        accounting.setPremiumBps(0.1e18);

        // Seed an initial deposit: 1000 Jrt + 1000 Srt, mirroring what CDO.deposit() would book.
        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
    }

    function test_coverageFirstFalse_trueUp_restoresSrt_bypassingSkim() public {
        // coverageFirst defaults to false: Jrt absorbs first, Symbiotic covers the Srt shortfall.
        assertFalse(accounting.coverageFirst());

        // Induce a 1050 loss: wipes Jrt down to its floor (999 absorbed) and 51 reaches Srt.
        mockStrategyTvl = 950e18;
        accounting.updateAccounting(950e18);

        assertEq(accounting.jrtBaseNav(), ONE_ASSET, "Jrt should be wiped to its floor");
        assertEq(accounting.srtBaseNav(), 949e18, "Srt should absorb the residual loss");
        uint256 deficit = accounting.pendingCoverageDeficit();
        assertEq(deficit, 51e18, "deficit should equal exactly the Srt shortfall");

        uint256 reserveBefore = accounting.reserveNav();
        uint256 premiumBefore = accounting.premiumNav();
        uint256 jrtBefore = accounting.jrtBaseNav();

        // Coverage arrives: true-up for the full deficit.
        vm.expectEmit(false, false, false, true);
        emit TrueUpApplied(deficit, false, 0);
        bool jrtCredited = accounting.trueUp(deficit);

        assertFalse(jrtCredited, "Srt should be the credited tranche");
        assertEq(accounting.srtBaseNav(), 1000e18, "Srt should be made exactly whole");
        assertEq(accounting.jrtBaseNav(), jrtBefore, "Jrt must be untouched by the true-up");
        assertEq(accounting.reserveNav(), reserveBefore, "reserve must not skim the true-up");
        assertEq(accounting.premiumNav(), premiumBefore, "premium must not skim the true-up");
        assertEq(accounting.pendingCoverageDeficit(), 0, "deficit should be fully cleared");

        // The true-up is reflected in nav immediately (no waiting for the next strategy read).
        assertEq(accounting.nav(), 950e18 + deficit);

        // Now simulate the coverage funds actually landing in the strategy (their real
        // destination) and re-run accounting. If the true-up were merely a bookkeeping trick
        // rather than a real NAV credit, this step would either double count it as a fresh gain
        // (and skim reserve/premium/give it to Jrt) or fail the invariant check.
        mockStrategyTvl = accounting.nav();
        uint256 reserveAfterTrueUp = accounting.reserveNav();
        uint256 premiumAfterTrueUp = accounting.premiumNav();
        uint256 jrtAfterTrueUp = accounting.jrtBaseNav();
        uint256 srtAfterTrueUp = accounting.srtBaseNav();

        accounting.updateAccounting(mockStrategyTvl);

        assertEq(accounting.reserveNav(), reserveAfterTrueUp, "no phantom gain should hit reserve");
        assertEq(accounting.premiumNav(), premiumAfterTrueUp, "no phantom gain should hit premium");
        assertEq(accounting.jrtBaseNav(), jrtAfterTrueUp, "no phantom gain should inflate Jrt");
        assertEq(accounting.srtBaseNav(), srtAfterTrueUp, "Srt should stay exactly restored");
        assertEq(accounting.pendingCoverageDeficit(), 0, "no new deficit should appear");
    }

    function test_coverageFirstTrue_trueUp_restoresJrt_bypassingSkim() public {
        vm.prank(address(this));
        accounting.setCoverageFirst(true);

        // Induce a pure Jrt-side loss (100), far from Jrt's floor, Srt untouched.
        mockStrategyTvl = 1900e18;
        accounting.updateAccounting(1900e18);

        assertEq(accounting.jrtBaseNav(), 900e18, "Jrt should absorb the loss in coverageFirst mode");
        assertEq(accounting.srtBaseNav(), 1000e18, "Srt should be untouched");
        uint256 deficit = accounting.pendingCoverageDeficit();
        assertEq(deficit, 100e18, "deficit should equal exactly the Jrt decline");

        uint256 reserveBefore = accounting.reserveNav();
        uint256 premiumBefore = accounting.premiumNav();
        uint256 srtBefore = accounting.srtBaseNav();

        vm.expectEmit(false, false, false, true);
        emit TrueUpApplied(deficit, true, 0);
        bool jrtCredited = accounting.trueUp(deficit);

        assertTrue(jrtCredited, "Jrt should be the credited tranche");
        assertEq(accounting.jrtBaseNav(), 1000e18, "Jrt should be made exactly whole");
        assertEq(accounting.srtBaseNav(), srtBefore, "Srt must be untouched by the true-up");
        assertEq(accounting.reserveNav(), reserveBefore, "reserve must not skim the true-up");
        assertEq(accounting.premiumNav(), premiumBefore, "premium must not skim the true-up");
        assertEq(accounting.pendingCoverageDeficit(), 0, "deficit should be fully cleared");

        // Same non-regression check: once the funds are actually in the strategy, re-accounting
        // must not re-detect them as a gain.
        mockStrategyTvl = accounting.nav();
        uint256 jrtAfterTrueUp = accounting.jrtBaseNav();
        uint256 srtAfterTrueUp = accounting.srtBaseNav();
        uint256 reserveAfterTrueUp = accounting.reserveNav();
        uint256 premiumAfterTrueUp = accounting.premiumNav();

        accounting.updateAccounting(mockStrategyTvl);

        assertEq(accounting.jrtBaseNav(), jrtAfterTrueUp, "Jrt should stay exactly restored");
        assertEq(accounting.srtBaseNav(), srtAfterTrueUp, "Srt should remain untouched");
        assertEq(accounting.reserveNav(), reserveAfterTrueUp, "no phantom gain should hit reserve");
        assertEq(accounting.premiumNav(), premiumAfterTrueUp, "no phantom gain should hit premium");
        assertEq(accounting.pendingCoverageDeficit(), 0, "no new deficit should appear");
    }

    /// @notice Contrasts a genuine strategy gain (correctly skimmed and given to Jrt) against a
    ///         true-up injection of the same size (which must skip that path entirely).
    function test_contrast_genuineGainIsSkimmed_trueUpIsNot() public {
        // A real 100 gain: reserve and premium each take their 10% cut, Jrt gets the remaining 80.
        mockStrategyTvl = 2100e18;
        accounting.updateAccounting(2100e18);

        assertEq(accounting.reserveNav(), 10e18, "genuine gain must be skimmed by the reserve");
        assertEq(accounting.premiumNav(), 10e18, "genuine gain must be skimmed by the premium");
        assertEq(accounting.jrtBaseNav(), 1080e18, "Jrt should receive the gain net of skims");
        assertEq(accounting.srtBaseNav(), 1000e18, "Srt should be unaffected by the gain (apr=0)");

        // Now induce a loss (1100) large enough to exceed Jrt's post-gain headroom (1079) and
        // reach Srt, and true-up to cover it.
        mockStrategyTvl = 1000e18;
        accounting.updateAccounting(1000e18);
        uint256 deficit = accounting.pendingCoverageDeficit();
        assertGt(deficit, 0, "a loss should have accrued a coverage deficit");

        uint256 reserveBefore = accounting.reserveNav();
        uint256 premiumBefore = accounting.premiumNav();

        accounting.trueUp(deficit);

        // Unlike the genuine gain above, the true-up leaves the skim buckets untouched.
        assertEq(accounting.reserveNav(), reserveBefore, "true-up must never be skimmed by the reserve");
        assertEq(accounting.premiumNav(), premiumBefore, "true-up must never be skimmed by the premium");
    }
}
