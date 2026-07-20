// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { DiscreteAccounting } from "../../contracts/tranches/DiscreteAccounting.sol";
import { IStrataCDO } from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../contracts/governance/AccessControlManager.sol";

/// @notice Verifies the Symbiotic coverage additions on DiscreteAccounting: premium accrues on
///         realized gains, trueUp() restores the covered tranche directly (never skimmed by
///         reserve/premium and never re-detected as a fresh gain), for both coverageFirst modes.
/// @dev The test contract plays the CDO: it implements the two-arg totalStrategyAssets(nav, anchor)
///      that DiscreteAccounting calls, and being `cdo`, its calls pass the onlyCDO checks.
contract DiscreteTrueUpTest is Test {

    uint256 constant ONE_ASSET = 1e18;

    DiscreteAccounting accounting;
    uint256 mockStrategyTvl;

    event TrueUpApplied(uint256 amount, bool jrtCredited, uint256 pendingCoverageDeficit);

    /// @dev DiscreteAccounting reads the strategy through this two-arg overload.
    function totalStrategyAssets(uint256, uint256) external view returns (uint256) {
        return mockStrategyTvl;
    }

    function setUp() public {
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = DiscreteAccounting(
            address(
                new ERC1967Proxy(
                    address(new DiscreteAccounting(18, false)),
                    abi.encodeWithSelector(
                        DiscreteAccounting.initialize.selector,
                        address(this),
                        address(acm),
                        IStrataCDO(address(this)),
                        IAprPairFeed(address(0))
                    )
                )
            )
        );

        accounting.setReserveBps(0.1e18);
        accounting.setPremiumBps(0.1e18);

        // Seed 1000 Jrt + 1000 Srt.
        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
    }

    function test_premiumAccruesOnGain_notAsJuniorYield() public {
        // Realize a 100 gain: reserve 10, premium 10, Junior receives the remaining 80.
        mockStrategyTvl = 2100e18;
        accounting.updateAccounting();

        assertEq(accounting.reserveNav(), 10e18, "reserve should skim 10% of the gain");
        assertEq(accounting.totalPremium(), 10e18, "premium should skim 10% of the gain");
        assertEq(accounting.jrtBaseNav(), 1080e18, "Junior gets the gain net of both skims");
        assertEq(accounting.srtBaseNav(), 1000e18, "Senior unaffected (apr feed = 0)");
    }

    function test_coverageFirstFalse_trueUpRestoresSrt_bypassingSkim() public {
        // Realize a gain first so reserve + premium hold non-zero balances.
        mockStrategyTvl = 2100e18;
        accounting.updateAccounting();
        uint256 premiumBefore = accounting.totalPremium();
        assertEq(premiumBefore, 10e18);

        // Loss large enough (1100) to wipe Junior (1080) + reserve (10) and reach Senior.
        mockStrategyTvl = 1000e18;
        accounting.updateAccounting();

        uint256 deficit = accounting.pendingCoverageDeficit();
        assertGt(deficit, 0, "Senior shortfall should accrue a coverage deficit");
        assertEq(accounting.premiumNav(), premiumBefore, "premium must never absorb losses");
        uint256 srtAfterLoss = accounting.srtBaseNav();

        vm.expectEmit(false, false, false, true);
        emit TrueUpApplied(deficit, false, 0);
        bool jrtCredited = accounting.trueUp(deficit);

        assertFalse(jrtCredited, "Srt is the credited tranche in coverageFirst=false");
        assertEq(accounting.srtBaseNav(), srtAfterLoss + deficit, "Srt restored by exactly the deficit");
        assertEq(accounting.premiumNav(), premiumBefore, "true-up must not touch the premium bucket");
        assertEq(accounting.pendingCoverageDeficit(), 0, "deficit cleared");

        // Non-regression: with the injected funds now in the strategy, a re-accounting must not
        // re-detect them as a gain (which would skim reserve/premium or inflate Junior).
        mockStrategyTvl = accounting.nav();
        uint256 premiumSnapshot = accounting.premiumNav();
        uint256 reserveSnapshot = accounting.reserveNav();
        uint256 srtSnapshot = accounting.srtBaseNav();
        accounting.updateAccounting();
        assertEq(accounting.premiumNav(), premiumSnapshot, "no phantom gain to premium");
        assertEq(accounting.reserveNav(), reserveSnapshot, "no phantom gain to reserve");
        assertEq(accounting.srtBaseNav(), srtSnapshot, "Srt stays restored");
        assertEq(accounting.pendingCoverageDeficit(), 0, "no new deficit");
    }

    function test_coverageFirstTrue_trueUpRestoresJrt() public {
        accounting.setCoverageFirst(true);

        // Pure Junior-side loss (100), Senior untouched, Junior far from floor.
        mockStrategyTvl = 1900e18;
        accounting.updateAccounting();

        uint256 deficit = accounting.pendingCoverageDeficit();
        assertEq(deficit, 100e18, "deficit equals the Junior decline");
        assertEq(accounting.srtBaseNav(), 1000e18, "Senior untouched");
        uint256 jrtAfterLoss = accounting.jrtBaseNav();

        vm.expectEmit(false, false, false, true);
        emit TrueUpApplied(deficit, true, 0);
        bool jrtCredited = accounting.trueUp(deficit);

        assertTrue(jrtCredited, "Jrt is the credited tranche in coverageFirst=true");
        assertEq(accounting.jrtBaseNav(), jrtAfterLoss + deficit, "Jrt restored by exactly the deficit");
        assertEq(accounting.jrtNavProjected(), accounting.jrtBaseNav(), "projected tracks real after true-up");
        assertEq(accounting.pendingCoverageDeficit(), 0, "deficit cleared");
    }

    function test_reducePremium_withdrawsFromBucketAndNav() public {
        mockStrategyTvl = 2100e18;
        accounting.updateAccounting();
        assertEq(accounting.totalPremium(), 10e18);

        uint256 navBefore = accounting.nav();

        // CDO pays out 6 of the premium (and withdraws the tokens, so strategy TVL drops too).
        accounting.reducePremium(6e18);
        mockStrategyTvl -= 6e18;

        assertEq(accounting.premiumNav(), 4e18, "premium bucket reduced");
        assertEq(accounting.nav(), navBefore - 6e18, "nav reduced by the withdrawn premium");

        // Re-accounting sees no phantom loss (TVL and nav dropped together).
        uint256 jrtSnapshot = accounting.jrtBaseNav();
        accounting.updateAccounting();
        assertEq(accounting.jrtBaseNav(), jrtSnapshot, "no phantom loss to Junior");
        assertEq(accounting.pendingCoverageDeficit(), 0, "no deficit from the premium payout");
    }
}
