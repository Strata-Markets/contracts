// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";

import { MTMAccounting } from "../../contracts/tranches/MTMAccounting.sol";
import { IStrataCDO } from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../contracts/governance/AccessControlManager.sol";
import { MockInsurancePool } from "./mocks/MockInsurancePool.sol";

/// @notice Verifies the Symbiotic integration on MTMAccounting: underwriter fee accrues on realized gains,
///         a Senior-bound loss is covered and slashed synchronously, a redemption settles the claim, and
///         a de-peg that outruns Junior is covered and unwinds on re-peg.
/// @dev The test contract plays the CDO: MTMAccounting reads the strategy through
///      totalStrategyAssetsSnapshot, and being `cdo` its calls pass the onlyCDO checks.
contract MTMInsuranceClaimFundingTest is Test {

    MTMAccounting accounting;
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

    /// @dev MTMAccounting reads the strategy through this snapshot overload.
    function totalStrategyAssetsSnapshot(uint256, uint256)
        external
        view
        returns (uint256, uint256, uint256, uint256)
    {
        return (mockStrategyTvl, block.timestamp, mockStrategyTvl, block.timestamp);
    }

    function getRate() external pure returns (uint256) {
        return 1e18;
    }

    function _deploy() internal {
        _deploy(false, 0);
    }

    function _deploy(bool useBenchmarkProjection_, int64 aprTarget_) internal {
        mockAprTarget = aprTarget_;
        mockAprBase = 100_000_000_000; // 10% APR, SD7x12
        mockStrategyTvl = 0;

        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = MTMAccounting(
            address(
                new ERC1967Proxy(
                    // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
                    // juniorCoversPaidSrtProjection, conservativePrice, mtmProjection
                    address(new MTMAccounting(18, useBenchmarkProjection_, false, false, false, false, false)),
                    abi.encodeWithSelector(
                        MTMAccounting.initialize.selector,
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

        accounting.setReserveBps(0.1e18);
        acm.grantRole(accounting.UPDATER_STRAT_CONFIG_ROLE(), address(this));
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        // Underwriter fee policy reaches accounting through the CDO, which this contract stands in for.
        accounting.setUnderwriterFeeBps(0.1e18);

        // Seed 1000 Jrt + 1000 Srt.
        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
    }

    function setUp() public {
        _deploy();
    }

    /// A realized gain accrues underwriter fee from final Senior gain, not total PnL.
    function test_underwriterFeeAccruesFromSeniorGain() public {
        vm.warp(block.timestamp + 365 days);
        mockStrategyTvl = 2100e18;
        accounting.updateAccounting();

        assertEq(accounting.totalUnderwriterFeeNav(), 1.25e18, "underwriter fee should be 5% of Senior gain");
        assertEq(accounting.srtBaseNav(), 1023.75e18, "Senior pays underwriter fee from its gain");
        assertEq(accounting.insuranceAmount(), 0, "no coverage claim on a gain");
    }

    function test_underwriterFeeAccruesWhenBenchmarkWins() public {
        _deploy(true, 80_000_000_000); // 8% benchmark beats 5% risk-adjusted base APR.

        vm.warp(block.timestamp + 365 days);
        accounting.updateAccounting(); // projection accrues benchmark Senior PnL.

        mockStrategyTvl = 2100e18;
        accounting.updateAccounting();

        assertEq(accounting.totalUnderwriterFeeNav(), 4e18, "underwriter fee should charge benchmark Senior gain");
        assertEq(accounting.srtBaseNav(), 1076e18, "Senior pays underwriter fee from benchmark gain");
        assertEq(accounting.jrtBaseNav(), 1010e18, "Junior result is unchanged by Senior-paid fee");
    }

    /// A loss that overflows Junior into Senior is covered, slashed in the same tx, then funded.
    function test_coverageEngages_thenRedemptionSettles() public {
        mockStrategyTvl = 500e18;
        accounting.updateAccounting();

        uint256 claim = accounting.insuranceAmount();
        assertGt(claim, 0, "coverage should engage on a Junior-overflow loss");

        uint256 insuranceOut = accounting.updateBalanceFlow(0, 0, 0, accounting.srtBaseNav());

        assertEq(insuranceOut, claim, "the whole claim leaves with the exiting Senior");
        assertEq(accounting.insuranceAmount(), 0, "claim settled by the payout");
    }

    /// Without a pool the same loss simply lands on the tranches.
    function test_noPool_noClaim() public {
        accounting.setInsurancePool(MockInsurancePool(address(0)));

        uint256 srtBefore = accounting.srtBaseNav();
        mockStrategyTvl = 500e18;
        accounting.updateAccounting();

        assertEq(accounting.insuranceAmount(), 0, "no claim without a pool");
        assertLt(accounting.srtBaseNav(), srtBefore, "Senior absorbs the overflow without coverage");
    }

    /// Coverage leaves Senior better off than no coverage for the same loss.
    function test_coverage_protectsSeniorVsNoPool() public {
        mockStrategyTvl = 500e18;
        accounting.updateAccounting();
        uint256 srtWithPool = accounting.srtBaseNav();

        _deploy();
        accounting.setInsurancePool(MockInsurancePool(address(0)));
        mockStrategyTvl = 500e18;
        accounting.updateAccounting();
        uint256 srtNoPool = accounting.srtBaseNav();

        assertGt(srtWithPool, srtNoPool, "coverage should leave Senior with more NAV");
    }

    /// A mild de-peg is absorbed entirely by Junior, so Symbiotic is never asked to cover.
    function test_valuation_juniorAbsorbs_noClaim() public {
        accounting.setValuationPrice(0.9e18);

        assertEq(accounting.srtInsuranceFundNav(), 0, "Junior covers it; no coverage needed");
        assertEq(accounting.insuranceAmount(), 0, "no claim booked");
    }

    /// A de-peg deep enough to exhaust Junior is covered, and the credit unwinds on re-peg.
    function test_valuation_coversWhatJuniorCannot_thenRepegUnwinds() public {
        // 0.4: Srt needs 1000/0.4 - 1000 = 1500 extra. Junior can give 999 (down to its dust
        // floor), so the 501 residual is the Senior-bound valuation loss Symbiotic covers.
        accounting.setValuationPrice(0.4e18);

        assertEq(accounting.srtInsuranceFundNav(), 501e18, "coverage takes the Junior-exhausted residual");
        assertEq(accounting.insuranceAmount(), 501e18, "and books a matching claim");

        accounting.setValuationPrice(1e18);
        assertEq(accounting.srtInsuranceFundNav(), 0, "fund unwinds on re-peg");
        assertEq(accounting.insuranceAmount(), 0, "claim unwinds with it");
    }
}
