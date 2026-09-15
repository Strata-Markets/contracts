// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";

import { DiscreteAccounting } from "../../contracts/tranches/DiscreteAccounting.sol";
import { IStrataCDO } from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../contracts/governance/AccessControlManager.sol";
import { MockInsurancePool } from "./mocks/MockInsurancePool.sol";
import { IInsurancePool } from "../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";

/// @notice Verifies the insuranceAmount coverage model on DiscreteAccounting: a covered loss holds
///         Senior whole and books insuranceAmount, a Senior redemption settles it (never
///         skimmed), a later gain unwinds it, and underwriter fee still accrues/pays out.
/// @dev The test contract plays the CDO: it implements the two-arg totalStrategyAssets(nav, anchor)
///      that DiscreteAccounting calls, and being `cdo`, its calls pass the onlyCDO checks.
contract DiscreteInsuranceClaimFundingTest is Test {

    uint256 constant ONE_ASSET = 1e18;

    DiscreteAccounting accounting;
    MockInsurancePool pool;
    uint256 mockStrategyTvl;
    int64 mockAprTarget;
    int64 mockAprBase;

    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound({
            aprTarget: mockAprTarget,
            aprBase: mockAprBase,
            updatedAt: uint64(block.timestamp),
            answeredInRound: 1
        });
    }

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
                        IAprPairFeed(address(this))
                    )
                )
            )
        );

        pool = new MockInsurancePool();
        pool.setCapacity(1_000_000e18);
        accounting.setInsurancePool(pool);

        mockAprBase = 100_000_000_000; // 10% APR, SD7x12
        accounting.setReserveBps(0.1e18);
        acm.grantRole(accounting.UPDATER_STRAT_CONFIG_ROLE(), address(this));
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        // Underwriter fee policy reaches accounting through the CDO, which this contract stands in for.
        accounting.setUnderwriterFeeBps(0.1e18);

        // Seed 1000 Jrt + 1000 Srt.
        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
    }

    function test_underwriterFeeAccruesFromSeniorGain_notAsJuniorCost() public {
        // Raw risk premium is 50%, underwriterFeeBps is 10%, so Senior pays 5%
        // of its 50 gain to underwriters. Junior still keeps the raw risk premium.
        vm.warp(block.timestamp + 365 days);
        mockStrategyTvl = 2100e18;
        accounting.updateAccounting();

        assertEq(accounting.reserveNav(), 10e18, "reserve should skim 10% of the gain");
        assertEq(accounting.totalUnderwriterFeeNav(), 2.5e18, "underwriter fee should be 5% of Senior gain");
        assertEq(accounting.jrtBaseNav(), 1040e18, "Junior keeps the raw risk premium");
        assertEq(accounting.srtBaseNav(), 1047.5e18, "Senior pays underwriter fee from its gain");
        assertEq(accounting.insuranceAmount(), 0, "no coverage claim on a gain");
    }

    function test_coverageHoldsSrtWhole_thenRedemptionSettles() public {
        // Loss 1050: Jrt fully absorbs (1000), the Srt-bound 50 is covered, so Srt stays whole.
        mockStrategyTvl = 950e18;
        accounting.updateAccounting();

        assertEq(accounting.jrtBaseNav(), 0, "Jrt absorbs first");
        assertEq(accounting.srtBaseNav(), 1000e18, "Srt held whole by coverage");
        assertEq(accounting.insuranceAmount(), 50e18, "claim equals the Srt-bound loss");
        assertEq(accounting.underwriterFeeNav(), 0, "underwriter fee never absorbs losses");

        uint256 reserveBefore = accounting.reserveNav();

        // Senior exits in full: the claim leaves with it, reported back for the vault payout.
        uint256 insuranceOut = accounting.updateBalanceFlow(0, 0, 0, 1000e18);

        assertEq(insuranceOut, 50e18, "the whole claim leaves with the exiting Senior");
        assertEq(accounting.insuranceAmount(), 0, "claim settled by the payout");
        assertEq(accounting.srtBaseNav(), 0, "Srt fully redeemed");
        assertEq(accounting.reserveNav(), reserveBefore, "settlement not skimmed by reserve");
        // Only 950 of base assets left the strategy; the 50 covered slice came from the vault.
        assertEq(accounting.nav(), 0, "nav drops by the strategy slice only");

        // Re-accounting sees no phantom gain or loss.
        mockStrategyTvl = accounting.nav();
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 0, "no new claim");
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

        uint256 underwriterFeeBefore = accounting.underwriterFeeNav();

        // A 30 recovery gain: fully consumed unwinding the claim, so it skims nothing.
        mockStrategyTvl = 980e18;
        accounting.updateAccounting();

        assertEq(accounting.insuranceAmount(), 20e18, "gain unwinds the claim first");
        assertEq(accounting.underwriterFeeNav(), underwriterFeeBefore, "recovery gain not skimmed by underwriter fee");
    }

    function test_noPool_lossHitsTranches_noClaim() public {
        accounting.setInsurancePool(MockInsurancePool(address(0)));

        mockStrategyTvl = 950e18;
        accounting.updateAccounting();

        assertEq(accounting.insuranceAmount(), 0, "no claim without a pool");
        assertEq(accounting.jrtBaseNav(), 0, "Jrt fully absorbs");
        assertEq(accounting.srtBaseNav(), 950e18, "Srt absorbs the residual loss");
    }

    function test_setUnderwriterFeeBps_onlyCDO() public {
        // The fee policy reaches accounting only through the CDO, so the pool cannot set it directly.
        vm.expectRevert();
        vm.prank(address(pool));
        accounting.setUnderwriterFeeBps(0.2e18);

        // This contract stands in for the CDO, so it can.
        accounting.setUnderwriterFeeBps(0.2e18);
        assertEq(accounting.underwriterFeeBps(), 0.2e18);
    }

    function test_reduceUnderwriterFee_withdrawsFromBucketAndNav() public {
        vm.warp(block.timestamp + 365 days);
        mockStrategyTvl = 2100e18;
        accounting.updateAccounting();
        assertEq(accounting.totalUnderwriterFeeNav(), 2.5e18);

        uint256 navBefore = accounting.nav();

        // CDO pays out 1 of the underwriter fee (and withdraws the tokens, so strategy TVL drops too).
        accounting.reduceUnderwriterFee(1e18);
        mockStrategyTvl -= 1e18;

        assertEq(accounting.underwriterFeeNav(), 1.5e18, "underwriter fee bucket reduced");
        assertEq(accounting.nav(), navBefore - 1e18, "nav reduced by the withdrawn underwriter fee");

        // Re-accounting sees no phantom loss (TVL and nav dropped together).
        uint256 jrtSnapshot = accounting.jrtBaseNav();
        accounting.updateAccounting();
        assertEq(accounting.jrtBaseNav(), jrtSnapshot, "no phantom loss to Junior");
        assertEq(accounting.insuranceAmount(), 0, "no claim from the underwriter fee payout");
    }
}
