// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ValuationInsuranceFixture } from "./BenchmarkDepletionPolicy.t.sol";
import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { DiscreteAccounting } from "../../../contracts/tranches/DiscreteAccounting.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";

interface ITargetGainConfig {
    function setRiskParameters(UD60x18, UD60x18, UD60x18) external;
    function onAprChanged() external;
}

abstract contract DepegTargetGainCapTests is ValuationInsuranceFixture {
    function setUp() public virtual override {
        super.setUp();
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        mockAprTarget = 100_000_000_000;
        mockAprBase = 0;
        ITargetGainConfig(address(accounting)).setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        ITargetGainConfig(address(accounting)).onAprChanged();
    }

    function _benchmark() internal view virtual returns (uint256) { return 0; }

    function test_noEffectiveHeadroomStopsGainAndBenchmark() public {
        accounting.setValuationPrice(0.4e18);
        uint256 claim = accounting.insuranceAmount();
        uint256 senior = accounting.srtBaseNav();
        uint256 slashed = _totalSlashed();
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 365 days);
            accounting.updateAccounting();
            assertEq(accounting.srtBaseNav(), senior, "no unfunded projection");
            assertEq(accounting.insuranceAmount(), claim, "no APR-related insurance");
            assertEq(_benchmark(), 0, "no unfunded benchmark entitlement");
        }
        mockStrategyTvl += 1;
        accounting.updateAccounting();
        assertEq(_totalSlashed(), slashed, "reconciliation does not slash for APR");
    }

    function test_partialHeadroomRemainsFundedThroughReconciliation() public {
        mockStrategyTvl += 611e18;
        accounting.updateBalanceFlow(611e18, 0, 0, 0);
        accounting.setValuationPrice(0.4e18);
        assertEq(accounting.insuranceAmount(), 0);
        vm.warp(block.timestamp + 365 days);
        accounting.updateAccounting();
        assertLe(accounting.srtBaseNav(), 1044e18, "projection respects protected gain capacity");
        assertLe(_benchmark(), 44e18, "benchmark respects protected gain capacity");
        // Repeated updates must not rebuild an unfunded benchmark behind a capped projection.
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 365 days);
            accounting.updateAccounting();
            assertEq(accounting.insuranceAmount(), 0);
        }
        mockStrategyTvl += 1;
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 0, "reconciliation remains funded by Junior");
        assertEq(_totalSlashed(), 0);
    }

    function test_replenishmentDoesNotBackfillUnfundedInterval() public {
        accounting.setValuationPrice(0.4e18);
        vm.warp(block.timestamp + 365 days);
        accounting.updateAccounting();
        uint256 senior = accounting.srtBaseNav();
        uint256 slashed = _totalSlashed();
        mockStrategyTvl += 1000e18;
        accounting.updateBalanceFlow(1000e18, 0, 0, 0);
        accounting.updateAccounting();
        assertEq(accounting.srtBaseNav(), senior, "no retroactive gain on replenishment");
        assertEq(_benchmark(), 0);
        assertEq(_totalSlashed(), slashed);
    }
}

contract DepegTargetGainCapAccountingTest is DepegTargetGainCapTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new Accounting(18)),
            abi.encodeWithSelector(Accounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this)))
        ));
    }
}

contract DepegTargetGainCapDiscreteAccountingTest is DepegTargetGainCapTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new DiscreteAccounting(18, false)),
            abi.encodeWithSelector(DiscreteAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this)))
        ));
    }
}

contract DepegTargetGainCapDYSAccountingTest is DepegTargetGainCapTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new DYSAccounting(18, true, false, false, true, false)),
            abi.encodeWithSelector(DYSAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this)))
        ));
    }
    function _benchmark() internal view override returns (uint256) {
        return DYSAccounting(address(accounting)).srtPnLBenchmark();
    }
}

contract DepegTargetGainCapMTMAccountingTest is DepegTargetGainCapTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new MTMAccounting(18, true, false, false, true, false, false)),
            abi.encodeWithSelector(MTMAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this)))
        ));
    }
    function _benchmark() internal view override returns (uint256) {
        return MTMAccounting(address(accounting)).srtPnLBenchmark();
    }
}

contract DepegTargetGainCapMTMLiveTest is DepegTargetGainCapTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new MTMAccounting(18, true, true, false, true, false, true)),
            abi.encodeWithSelector(MTMAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this)))
        ));
    }
    function _benchmark() internal view override returns (uint256) {
        return MTMAccounting(address(accounting)).srtPnLBenchmark();
    }
}

