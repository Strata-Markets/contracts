// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { PerformanceFeeSuspensionTest } from "./PerformanceFeeSuspension.t.sol";

interface IDepegClaimAccounting {
    function setValuationPrice(uint128 price) external returns (bool);
    function setReserveBps(uint256 bps) external;
    function updateAccounting() external;
    function totalAssets() external view returns (uint256, uint256, uint256);
    function insuranceAmount() external view returns (uint256);
    function srtInsuranceFundNav() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
    function jrtBaseNav() external view returns (uint256);
    function reserveNav() external view returns (uint256);
    function srtFundNav() external view returns (uint256);
}

contract DepegClaimGainTest is PerformanceFeeSuspensionTest {
    function test_gainKeepsValuationClaimMatched_allVariants() public {
        uint256[5] memory gains = [uint256(10), 100e18, 501e18, 600e18, 800e18];
        for (uint256 variant; variant < 4; variant++) {
            IDepegClaimAccounting a = IDepegClaimAccounting(address(_deploy(variant)));
            a.setValuationPrice(0.4e18);
            a.setReserveBps(0.1e18);
            for (uint256 i; i < gains.length; i++) {
                uint256 snap = vm.snapshotState();
                mockStrategyTvl += gains[i];
                a.totalAssets();
                a.updateAccounting();
                assertEq(a.insuranceAmount(), 501e18);
                assertEq(a.srtInsuranceFundNav(), 501e18);
                assertEq(a.reserveNav(), gains[i] / 10);
                assertEq(a.srtFundNav(), 0, "earnings retain ordinary valuation protection");
                uint256 seniorBeforeRepeg = a.srtBaseNav();
                a.setValuationPrice(1e18);
                assertEq(a.insuranceAmount(), 0);
                assertEq(a.srtInsuranceFundNav(), 0);
                assertEq(a.srtBaseNav(), seniorBeforeRepeg - 501e18);
                assertEq(a.jrtBaseNav() + a.srtBaseNav() + a.reserveNav(), mockStrategyTvl);
                a.setValuationPrice(0.9e18);
                (, uint256 seniorEffective,) = a.totalAssets();
                assertEq(seniorEffective, a.srtBaseNav() * 1e18 / 0.9e18);
                vm.revertToState(snap);
            }
        }
    }

    function test_mixedClaimRepaymentStopsAtValuationCredit_allVariants() public {
        for (uint256 variant; variant < 4; variant++) {
            IDepegClaimAccounting a = IDepegClaimAccounting(address(_deploy(variant)));
            a.setValuationPrice(0.4e18);
            mockStrategyTvl = 800e18;
            a.updateAccounting();
            uint256 claim = a.insuranceAmount();
            uint256 valuationClaim = a.srtInsuranceFundNav();
            assertEq(valuationClaim, 1500e18, "lost Junior backing is covered immediately");
            assertGt(claim, valuationClaim);
            mockStrategyTvl += 100e18;
            a.updateAccounting();
            assertEq(a.insuranceAmount(), claim - 100e18);
            assertEq(a.srtInsuranceFundNav(), valuationClaim);
            mockStrategyTvl += claim - 100e18 - valuationClaim;
            a.updateAccounting();
            assertEq(a.insuranceAmount(), valuationClaim);
            assertEq(a.srtInsuranceFundNav(), valuationClaim);
        }
    }
}
