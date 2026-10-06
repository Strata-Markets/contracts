// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Accounting } from "../../contracts/tranches/Accounting.sol";
import { DiscreteAccounting } from "../../contracts/tranches/DiscreteAccounting.sol";
import { DYSAccounting } from "../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../contracts/tranches/MTMAccounting.sol";
import { AccessControlManager } from "../../contracts/governance/AccessControlManager.sol";
import { IInsurancePool } from "../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import { MockInsurancePool } from "./mocks/MockInsurancePool.sol";

interface IFeeSuspensionAccounting {
    function setReserveBps(uint256 bps) external;
    function setInsurancePool(IInsurancePool pool) external;
    function setValuationPrice(uint128 price) external returns (bool);
    function updateAccounting() external;
    function updateBalanceFlow(uint256 jrtIn, uint256 jrtOut, uint256 srtIn, uint256 srtOut) external returns (uint256);
    function reserveBps() external view returns (uint256);
    function reserveNav() external view returns (uint256);
    function feeWatermarkNav() external view returns (uint256);
    function jrtBaseNav() external view returns (uint256);
    function insuranceAmount() external view returns (uint256);
}

contract PerformanceFeeSuspensionTest is Test {
    uint256 mockStrategyTvl;
    event ReservePercentageChanged(uint256 reserveBps);

    function totalStrategyAssets() external view returns (uint256) {
        return mockStrategyTvl;
    }

    function totalStrategyAssets(uint256, uint256) external view returns (uint256) {
        return mockStrategyTvl;
    }

    function totalStrategyAssetsSnapshot(uint256, uint256)
        external view returns (uint256, uint256, uint256, uint256)
    {
        return (mockStrategyTvl, block.timestamp, mockStrategyTvl, block.timestamp);
    }

    function getRate() external pure returns (uint256) {
        return 1e18;
    }

    function _deploy(uint256 variant) internal returns (IFeeSuspensionAccounting accounting) {
        mockStrategyTvl = 0;
        address implementation;
        if (variant == 0) {
            implementation = address(new Accounting(18));
        } else if (variant == 1) {
            implementation = address(new DiscreteAccounting(18, false));
        } else if (variant == 2) {
            implementation = address(new DYSAccounting(18, false, false, false, false, false));
        } else {
            implementation = address(new MTMAccounting(18, false, false, false, false, false, false));
        }
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = IFeeSuspensionAccounting(address(new ERC1967Proxy(
            implementation,
            abi.encodeWithSignature(
                "initialize(address,address,address,address)",
                address(this), address(acm), address(this), address(0)
            )
        )));
        accounting.setReserveBps(0.1e18);
        MockInsurancePool pool = new MockInsurancePool();
        pool.setCapacity(1_000_000e18);
        accounting.setInsurancePool(pool);
        accounting.updateAccounting();
        assertEq(accounting.reserveBps(), 0.1e18, "empty market does not suspend fees");
        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
    }

    function test_valuationLoss_preservesReserveAndRequiresManualReenable() public {
        for (uint256 variant; variant < 4; variant++) {
            IFeeSuspensionAccounting accounting = _deploy(variant);
            mockStrategyTvl += 100e18;
            accounting.updateAccounting();
            assertEq(accounting.reserveNav(), 10e18);
            vm.expectEmit(false, false, false, true, address(accounting));
            emit ReservePercentageChanged(0);
            accounting.setValuationPrice(0.9e18);
            assertEq(accounting.reserveBps(), 0);
            assertEq(accounting.reserveNav(), 10e18, "existing reserve is unchanged");
            accounting.setValuationPrice(1e18);
            mockStrategyTvl += 100e18;
            accounting.updateAccounting();
            assertEq(accounting.reserveBps(), 0, "repeg does not re-enable fees");
            assertEq(accounting.reserveNav(), 10e18);
            assertEq(accounting.feeWatermarkNav(), mockStrategyTvl, "waived gains advance watermark");
            accounting.setReserveBps(0.1e18);
            mockStrategyTvl += 100e18;
            accounting.updateAccounting();
            assertEq(accounting.reserveNav(), 20e18, "only new gains are charged");
        }
    }

    function test_coveredDepeg_yieldNoLongerUnderflowsReserveFee() public {
        for (uint256 variant; variant < 4; variant++) {
            IFeeSuspensionAccounting accounting = _deploy(variant);
            accounting.setValuationPrice(0.4e18);
            assertEq(accounting.insuranceAmount(), 501e18);
            assertEq(accounting.reserveBps(), 0);
            mockStrategyTvl += 100e18;
            accounting.updateAccounting();
            assertEq(accounting.insuranceAmount(), 401e18, "yield still repays insurance first");
            assertEq(accounting.reserveNav(), 0);
        }
    }

    function test_juniorDepletion_disablesFeesThroughRecovery() public {
        for (uint256 variant; variant < 4; variant++) {
            IFeeSuspensionAccounting accounting = _deploy(variant);
            mockStrategyTvl = 1001e18;
            vm.expectEmit(false, false, false, true, address(accounting));
            emit ReservePercentageChanged(0);
            accounting.updateAccounting();
            assertEq(accounting.jrtBaseNav(), 1e18);
            assertEq(accounting.reserveBps(), 0, "depletion alone is sufficient");
            mockStrategyTvl = 2100e18;
            accounting.updateAccounting();
            assertEq(accounting.reserveBps(), 0);
            assertEq(accounting.reserveNav(), 0);
            assertEq(accounting.feeWatermarkNav(), mockStrategyTvl);
            accounting.setReserveBps(0.1e18);
            mockStrategyTvl += 100e18;
            accounting.updateAccounting();
            assertEq(accounting.reserveNav(), 10e18);
        }
    }

    function test_smallNavLoss_keepsFeesEnabled() public {
        for (uint256 variant; variant < 4; variant++) {
            IFeeSuspensionAccounting accounting = _deploy(variant);
            mockStrategyTvl = 1900e18;
            accounting.updateAccounting();
            assertGt(accounting.jrtBaseNav(), 1e18);
            assertEq(accounting.reserveBps(), 0.1e18);
        }
    }
}