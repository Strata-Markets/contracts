// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { DiscreteAccounting } from "../../contracts/tranches/DiscreteAccounting.sol";
import { IStrataCDO } from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../contracts/governance/AccessControlManager.sol";
import { MockInsurancePool } from "./mocks/MockInsurancePool.sol";

/// @notice Verifies the insuranceAmount coverage model on DiscreteAccounting: a covered loss holds
///         Senior whole and books insuranceAmount, trueUp() settles it (no tranche credit, never
///         skimmed), a later gain unwinds it, and premium still accrues/pays out.
/// @dev The test contract plays the CDO: it implements the two-arg totalStrategyAssets(nav, anchor)
///      that DiscreteAccounting calls, and being `cdo`, its calls pass the onlyCDO checks.
contract DiscreteTrueUpTest is Test {

    uint256 constant ONE_ASSET = 1e18;

    DiscreteAccounting accounting;
    MockInsurancePool pool;
    uint256 mockStrategyTvl;

    event TrueUpApplied(uint256 amount, uint256 insuranceAmount);

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

        pool = new MockInsurancePool();
        pool.setCapacity(1_000_000e18);
        accounting.setNetworkMiddleware(address(pool));

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
        assertEq(accounting.insuranceAmount(), 0, "no coverage claim on a gain");
    }

    function test_coverageHoldsSrtWhole_thenTrueUpSettles() public {
        // Loss 1050: Jrt fully absorbs (1000), the Srt-bound 50 is covered, so Srt stays whole.
        mockStrategyTvl = 950e18;
        accounting.updateAccounting();

        assertEq(accounting.jrtBaseNav(), 0, "Jrt absorbs first");
        assertEq(accounting.srtBaseNav(), 1000e18, "Srt held whole by coverage");
        assertEq(accounting.insuranceAmount(), 50e18, "claim equals the Srt-bound loss");
        assertEq(accounting.premiumNav(), 0, "premium never absorbs losses");

        uint256 reserveBefore = accounting.reserveNav();

        vm.expectEmit(false, false, false, true);
        emit TrueUpApplied(50e18, 0);
        accounting.trueUp(50e18);

        assertEq(accounting.insuranceAmount(), 0, "claim fully settled");
        assertEq(accounting.srtBaseNav(), 1000e18, "Srt untouched by settlement (already whole)");
        assertEq(accounting.reserveNav(), reserveBefore, "settlement not skimmed by reserve");
        assertEq(accounting.nav(), 950e18 + 50e18, "nav rises by exactly the settled amount");

        // Funds land in the strategy; re-accounting must not re-detect them as a gain.
        mockStrategyTvl = accounting.nav();
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 0, "no new claim");
        assertEq(accounting.srtBaseNav(), 1000e18, "Srt stays whole");
    }

    function test_smallLossHitsJrt_noClaim() public {
        // Loss 100, within Jrt's capacity: Jrt eats it, nothing reaches Srt, no coverage.
        mockStrategyTvl = 1900e18;
        accounting.updateAccounting();

        assertEq(accounting.jrtBaseNav(), 900e18, "Jrt absorbs the loss it can cover");
        assertEq(accounting.srtBaseNav(), 1000e18, "Srt untouched");
        assertEq(accounting.insuranceAmount(), 0, "no claim: nothing reached Srt");
    }

    function test_recoveryGain_unwindsClaim_beforeSkim() public {
        // Covered loss: 50 booked to the claim.
        mockStrategyTvl = 950e18;
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 50e18);

        uint256 premiumBefore = accounting.premiumNav();

        // A 30 recovery gain: fully consumed unwinding the claim, so it skims nothing.
        mockStrategyTvl = 980e18;
        accounting.updateAccounting();

        assertEq(accounting.insuranceAmount(), 20e18, "gain unwinds the claim first");
        assertEq(accounting.premiumNav(), premiumBefore, "recovery gain not skimmed by premium");
    }

    function test_noPool_lossHitsTranches_noClaim() public {
        accounting.setNetworkMiddleware(address(0));

        mockStrategyTvl = 950e18;
        accounting.updateAccounting();

        assertEq(accounting.insuranceAmount(), 0, "no claim without a pool");
        assertEq(accounting.jrtBaseNav(), 0, "Jrt fully absorbs");
        assertEq(accounting.srtBaseNav(), 950e18, "Srt absorbs the residual loss");
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
        assertEq(accounting.insuranceAmount(), 0, "no claim from the premium payout");
    }
}
