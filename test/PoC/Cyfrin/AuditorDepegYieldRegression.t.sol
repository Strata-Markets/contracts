// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { MockInsurancePool } from "../../symbiotic/mocks/MockInsurancePool.sol";

// Regression adapted from the auditor PoC: same fixture, assertions changed to require the fix.
contract AuditorDepegYieldRegressionTest is Test {
    uint128 constant PRICE = 0.4e18;
    uint256 constant CLAIM = 501e18;

    Accounting accounting;
    MockInsurancePool pool;
    uint256 mockStrategyTvl;
    int64 mockAprTarget; // SD7x12, 0 unless a test sets it

    // ---------------------------------------------------------------- CDO / strategy / feed callbacks

    function totalStrategyAssets() external view returns (uint256) {
        return mockStrategyTvl;
    }

    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound({
            aprTarget: mockAprTarget,
            aprBase: 0,
            updatedAt: uint64(block.timestamp),
            answeredInRound: 1
        });
    }

    // ---------------------------------------------------------------- setup

    function setUp() public {
        _deploy(0);
    }

    function _deploy(int64 aprTarget) internal {
        mockAprTarget = aprTarget;
        mockStrategyTvl = 0; // fresh market: nothing in the strategy before the first deposit
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = Accounting(address(new ERC1967Proxy(
            address(new Accounting(18)),
            abi.encodeWithSelector(
                Accounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        )));
        pool = new MockInsurancePool();
        pool.setCapacity(1_000_000e18);
        accounting.setInsurancePool(pool);

        // Seed 1000 Jrt + 1000 Srt, as CDO.deposit() would book it
        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);

        // De-peg: Junior gives 999, Symbiotic covers 501 (claim 501, credit 501); nav stays at 2000
        accounting.setValuationPrice(PRICE);
        assertEq(accounting.insuranceAmount(), CLAIM);
        assertEq(accounting.srtInsuranceFundNav(), CLAIM);
    }

    function _atPar() internal view returns (uint256 jrt, uint256 srt) {
        (jrt, srt,) = accounting.totalAssets();
    }

    /// @dev Books `gain` either during the de-peg or after the re-peg push, returns both tranches at par
    function _repegWithGain(uint256 gain, bool gainDuringDepeg) internal returns (uint256 jrt, uint256 srt) {
        uint256 snap = vm.snapshotState();
        if (gainDuringDepeg) {
            mockStrategyTvl += gain;
            accounting.updateAccounting(); // any deposit / withdrawal / keeper update books it
            accounting.setValuationPrice(1e18);
        } else {
            accounting.setValuationPrice(1e18);
            mockStrategyTvl += gain;
            accounting.updateAccounting();
        }
        (jrt, srt) = _atPar();
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(accounting.srtInsuranceFundNav(), 0, "no stale valuation credit after repeg");
        assertEq(jrt + srt, mockStrategyTvl);
        vm.revertToState(snap);
    }

    // ---------------------------------------------------------------- Regressions

    function test_regression_yieldTimingDoesNotTransferValue() public {
        (uint256 juniorAfter, uint256 seniorAfter) = _repegWithGain(100e18, false);
        (uint256 juniorDuring, uint256 seniorDuring) = _repegWithGain(100e18, true);
        assertEq(juniorAfter, 1100e18);
        assertEq(seniorAfter, 1000e18);
        assertEq(juniorDuring, juniorAfter);
        assertEq(seniorDuring, seniorAfter);
    }

    function test_regression_claimAndCreditStayMatched() public {
        mockStrategyTvl += 100e18;
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), CLAIM);
        assertEq(accounting.srtInsuranceFundNav(), CLAIM);
        assertEq(accounting.jrtBaseNav(), 1100e18);
        accounting.setValuationPrice(1e18);
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(accounting.srtInsuranceFundNav(), 0);
    }

    function test_regression_allGainSizesPreserveAllocation() public {
        uint256[4] memory gains = [uint256(50e18), 250e18, 501e18, 800e18];
        for (uint256 i; i < gains.length; i++) {
            (uint256 juniorAfter, uint256 seniorAfter) = _repegWithGain(gains[i], false);
            (uint256 juniorDuring, uint256 seniorDuring) = _repegWithGain(gains[i], true);
            assertEq(juniorDuring, juniorAfter);
            assertEq(seniorDuring, seniorAfter);
        }
    }

    function test_regression_nextDepegProtectsFullPrincipal() public {
        mockStrategyTvl += 100e18;
        accounting.updateAccounting();
        accounting.setValuationPrice(1e18);
        assertEq(accounting.srtBaseNav(), 1000e18);
        assertEq(accounting.srtInsuranceFundNav(), 0);
        accounting.setValuationPrice(0.9e18);
        (uint256 junior, uint256 senior) = _atPar();
        assertEq(senior, uint256(1000e18) * 1e18 / 0.9e18);
        assertEq(junior + senior, 2100e18);
    }

    function test_regression_nonZeroAprLeavesNoStaleCredit() public {
        _aprYear(false);
        _aprYear(true);
    }

    /// @dev One year at a 10% Senior target APR: 300 of yield at 6m (or at 12m, after the re-peg), re-peg at 12m
    function _aprYear(bool gainDuringDepeg) internal returns (uint256 jrt, uint256 srt) {
        uint256 snap = vm.snapshotState();
        _deploy(100_000_000_000); // 10% target APR
        assertEq(accounting.aprSrt().unwrap(), 0.1e18);

        vm.warp(block.timestamp + 182.5 days);
        if (gainDuringDepeg) mockStrategyTvl += 300e18;
        accounting.updateAccounting();

        vm.warp(block.timestamp + 182.5 days);
        accounting.setValuationPrice(1e18);
        if (!gainDuringDepeg) mockStrategyTvl += 300e18;
        accounting.updateAccounting();

        (jrt, srt) = _atPar();
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(accounting.srtInsuranceFundNav(), 0, "no stale valuation credit after repeg");
        assertEq(jrt + srt, mockStrategyTvl);
        vm.revertToState(snap);
    }

    function test_regression_largeGainWithReserveLeavesNoStaleCredit() public {
        accounting.setReserveBps(0.1e18);
        mockStrategyTvl += 600e18;
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), CLAIM);
        assertEq(accounting.srtInsuranceFundNav(), CLAIM);
        assertEq(accounting.reserveNav(), 60e18);
        accounting.setValuationPrice(1e18);
        (uint256 junior, uint256 senior) = _atPar();
        assertEq(senior, 1000e18);
        assertEq(junior, 1540e18);
        assertEq(accounting.srtInsuranceFundNav(), 0);
        accounting.setValuationPrice(0.9e18);
        (, senior) = _atPar();
        assertEq(senior, uint256(1000e18) * 1e18 / 0.9e18);
    }

    function test_regression_reserveCanBeDisabledAfterGain() public {
        accounting.setReserveBps(0.1e18);
        mockStrategyTvl += 100e18;
        accounting.setReserveBps(0);
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), CLAIM);
        assertEq(accounting.reserveNav(), 10e18);
    }
}
