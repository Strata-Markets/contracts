// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { DYSAccounting } from "../../contracts/tranches/DYSAccounting.sol";
import { IStrataCDO } from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../contracts/governance/AccessControlManager.sol";
import { MockInsurancePool } from "./mocks/MockInsurancePool.sol";

/// @notice Verifies the insuranceAmount coverage model on DYSAccounting: coverage engages on a loss
///         that overflows Junior + reserve into Senior, trueUp() settles the claim, a later gain
///         unwinds it, and without a pool the loss hits the tranches. DYS shares loss by risk weight
///         (Senior takes its share directly), so the assertions are structural; the on-chain NAV
///         invariant (`navT1 + insuranceAmount == sum`) is the correctness net — any threading bug
///         reverts with InvalidNavSplit.
/// @dev The test contract plays the CDO: it implements the two-arg totalStrategyAssets and getRate,
///      and being `cdo`, its calls pass the onlyCDO checks.
contract DYSTrueUpTest is Test {

    DYSAccounting accounting;
    MockInsurancePool pool;
    uint256 mockStrategyTvl;

    event TrueUpApplied(uint256 amount, uint256 insuranceAmount);

    function totalStrategyAssets(uint256, uint256) external view returns (uint256) {
        return mockStrategyTvl;
    }

    function getRate() external pure returns (uint256) {
        return 1e18;
    }

    function _deploy() internal {
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = DYSAccounting(
            address(
                new ERC1967Proxy(
                    // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
                    // juniorCoversPaidSrtProjection, conservativeRedemptionPrice
                    address(new DYSAccounting(18, false, false, false, false, false)),
                    abi.encodeWithSelector(
                        DYSAccounting.initialize.selector,
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

        accounting.setReserveBps(0.1e18);
        accounting.setPremiumBps(0.1e18);

        // Seed 1000 Jrt + 1000 Srt.
        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
    }

    function setUp() public {
        _deploy();
        accounting.setNetworkMiddleware(address(pool));
    }

    /// A loss large enough to overflow Junior + reserve into Senior engages coverage; trueUp settles.
    function test_coverageEngages_thenTrueUpSettles() public {
        // Large loss (1500 of 2000): overflows Junior into the coverage layer.
        mockStrategyTvl = 500e18;
        accounting.updateAccounting();

        uint256 claim = accounting.insuranceAmount();
        assertGt(claim, 0, "coverage should engage on a Junior-overflow loss");

        // Settle the full claim.
        vm.expectEmit(false, false, false, true);
        emit TrueUpApplied(claim, 0);
        accounting.trueUp(claim);

        assertEq(accounting.insuranceAmount(), 0, "claim fully settled");
    }

    /// Without a pool, the same loss hits the tranches and no claim is created.
    function test_noPool_noClaim() public {
        vm.prank(address(this));
        accounting.setNetworkMiddleware(address(0));

        uint256 srtBefore = accounting.srtBaseNav();

        mockStrategyTvl = 500e18;
        accounting.updateAccounting();

        assertEq(accounting.insuranceAmount(), 0, "no claim without a pool");
        assertLt(accounting.srtBaseNav(), srtBefore, "Senior absorbs the overflow without coverage");
    }

    /// Coverage keeps more Senior NAV than no coverage for the same loss.
    function test_coverage_protectsSeniorVsNoPool() public {
        // With pool (setUp wired it): induce the loss and record Senior.
        mockStrategyTvl = 500e18;
        accounting.updateAccounting();
        uint256 srtWithPool = accounting.srtBaseNav();

        // Fresh instance without a pool, same loss.
        _deploy();
        mockStrategyTvl = 500e18;
        accounting.updateAccounting();
        uint256 srtNoPool = accounting.srtBaseNav();

        assertGt(srtWithPool, srtNoPool, "coverage should leave Senior with more NAV");
    }

    /// A recovery gain unwinds the outstanding claim.
    function test_recoveryGain_unwindsClaim() public {
        mockStrategyTvl = 500e18;
        accounting.updateAccounting();
        uint256 claim = accounting.insuranceAmount();
        assertGt(claim, 0);

        // Partial recovery: strategy TVL rises; the gain unwinds part of the claim.
        mockStrategyTvl = 800e18;
        accounting.updateAccounting();

        assertLt(accounting.insuranceAmount(), claim, "recovery gain unwinds the claim");
    }
}
