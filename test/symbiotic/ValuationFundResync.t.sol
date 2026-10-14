// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {IStrataCDO} from '../../contracts/tranches/interfaces/IStrataCDO.sol';
import {Accounting} from '../../contracts/tranches/Accounting.sol';
import {DiscreteAccounting} from '../../contracts/tranches/DiscreteAccounting.sol';
import {DYSAccounting} from '../../contracts/tranches/DYSAccounting.sol';
import {MTMAccounting} from '../../contracts/tranches/MTMAccounting.sol';
import {MockInsurancePool} from './mocks/MockInsurancePool.sol';

import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {AccessControlManager} from '../../contracts/governance/AccessControlManager.sol';
import {IAprPairFeed} from '../../contracts/tranches/interfaces/IAprPairFeed.sol';

interface IValuationFundHarness {
    function seed(MockInsurancePool pool, bool selfFunded) external;
    function setValuationPrice(uint128 price) external returns (bool);
    function insuranceAmount() external view returns (uint256);
    function srtInsuranceFundNav() external view returns (uint256);
    function srtFundNav() external view returns (uint256);
    function srtFundedGrossNav() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
}

// Seed valuation balances after initialization; price updates also run the production PnL checkpoint.
contract ValuationFundAccounting is Accounting {
    constructor() Accounting(18) {}
    function seed(MockInsurancePool pool, bool selfFunded) external {
        cdo = IStrataCDO(msg.sender);
        insurancePool = pool;
        jrtBaseNav = 1000e18;
        srtBaseNav = 1000e18;
        nav = 2000e18;
        valuationPrice = selfFunded ? uint128(0.4e18) : uint128(1e18);
        if (selfFunded) {
            // 100 of Senior deposits at 0.4 carry 150 of self-funded protection.
            srtFundedGrossNav = 100e18;
            srtFundNav = 150e18;
        }
    }
}
contract ValuationFundDiscreteAccounting is DiscreteAccounting {
    constructor() DiscreteAccounting(18, false) {}
    function seed(MockInsurancePool pool, bool selfFunded) external {
        cdo = IStrataCDO(msg.sender);
        insurancePool = pool;
        jrtBaseNav = 1000e18;
        jrtNavProjected = 1000e18;
        srtBaseNav = 1000e18;
        nav = 2000e18;
        valuationPrice = selfFunded ? uint128(0.4e18) : uint128(1e18);
        if (selfFunded) {
            // 100 of Senior deposits at 0.4 carry 150 of self-funded protection.
            srtFundedGrossNav = 100e18;
            srtFundNav = 150e18;
        }
    }
}
contract ValuationFundDYSAccounting is DYSAccounting {
    constructor() DYSAccounting(18, false, false, false, false, false) {}
    function seed(MockInsurancePool pool, bool selfFunded) external {
        cdo = IStrataCDO(msg.sender);
        insurancePool = pool;
        jrtBaseNav = 1000e18;
        jrtNavProjected = 1000e18;
        srtBaseNav = 1000e18;
        nav = 2000e18;
        valuationPrice = selfFunded ? uint128(0.4e18) : uint128(1e18);
        if (selfFunded) {
            // 100 of Senior deposits at 0.4 carry 150 of self-funded protection.
            srtFundedGrossNav = 100e18;
            srtFundNav = 150e18;
        }
    }
}
contract ValuationFundMTMAccounting is MTMAccounting {
    constructor() MTMAccounting(18, false, false, false, false, false, false) {}
    function seed(MockInsurancePool pool, bool selfFunded) external {
        cdo = IStrataCDO(msg.sender);
        insurancePool = pool;
        jrtBaseNav = 1000e18;
        jrtNavProjected = 1000e18;
        srtBaseNav = 1000e18;
        nav = 2000e18;
        valuationPrice = selfFunded ? uint128(0.4e18) : uint128(1e18);
        if (selfFunded) {
            // 100 of Senior deposits at 0.4 carry 150 of self-funded protection.
            srtFundedGrossNav = 100e18;
            srtFundNav = 150e18;
        }
    }
}
contract ValuationFundResyncTest is Test {
    uint256 constant CAPACITY = 1_000_000e18;

    function totalStrategyAssets() external pure returns (uint256) {
        return 2000e18;
    }
    function totalStrategyAssets(uint256, uint256) external pure returns (uint256) {
        return 2000e18;
    }
    function totalStrategyAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        return (2000e18, block.timestamp, 2000e18, block.timestamp);
    }
    function getRate() external pure returns (uint256) {
        return 1e18;
    }
    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound(0, 100_000_000_000, uint64(block.timestamp), 1);
    }

    function _deploy(
        uint256 variant,
        bool selfFunded
    ) internal returns (IValuationFundHarness accounting, MockInsurancePool pool) {
        if (variant == 0) {
            accounting = IValuationFundHarness(address(new ValuationFundAccounting()));
        } else if (variant == 1) {
            accounting = IValuationFundHarness(address(new ValuationFundDiscreteAccounting()));
        } else if (variant == 2) {
            accounting = IValuationFundHarness(address(new ValuationFundDYSAccounting()));
        } else {
            accounting = IValuationFundHarness(address(new ValuationFundMTMAccounting()));
        }
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = IValuationFundHarness(
            address(
                new ERC1967Proxy(
                    address(accounting),
                    abi.encodeWithSelector(
                        Accounting.initialize.selector,
                        address(this),
                        address(acm),
                        IStrataCDO(address(this)),
                        IAprPairFeed(address(this))
                    )
                )
            )
        );
        pool = new MockInsurancePool();
        pool.setCapacity(CAPACITY);
        accounting.seed(pool, selfFunded);
        accounting.setValuationPrice(0.4e18);
        assertEq(accounting.insuranceAmount(), selfFunded ? 351e18 : 501e18);
    }

    function test_partialRecovery_updatesSelfFundBeforeInsurance() public {
        for (uint256 variant; variant < 4; variant++) {
            (IValuationFundHarness accounting, MockInsurancePool pool) = _deploy(variant, true);
            uint256 capacity = pool.capacity();
            accounting.setValuationPrice(0.41e18);

            uint256 selfFund = (uint256(100e18) * 0.59e18) / 0.41e18;
            uint256 claim = (uint256(1000e18) * 1e18) / 0.41e18 - 1000e18 - selfFund - 999e18;
            assertEq(accounting.srtFundNav(), selfFund);
            assertEq(accounting.insuranceAmount(), claim);
            assertEq(accounting.srtInsuranceFundNav(), claim);
            assertEq(accounting.srtBaseNav(), 1000e18 + claim);
            assertEq(pool.capacity(), capacity, 'recovery must not slash replacement coverage');

            accounting.setValuationPrice(0.41e18);
            assertEq(pool.capacity(), capacity, 'unchanged price must not slash');
        }
    }

    function test_fullRepeg_clearsBothFunds() public {
        for (uint256 variant; variant < 4; variant++) {
            (IValuationFundHarness accounting, MockInsurancePool pool) = _deploy(variant, true);
            uint256 capacity = pool.capacity();
            accounting.setValuationPrice(1e18);
            assertEq(accounting.srtFundedGrossNav(), 0);
            assertEq(accounting.srtFundNav(), 0);
            assertEq(accounting.srtInsuranceFundNav(), 0);
            assertEq(accounting.insuranceAmount(), 0);
            assertEq(accounting.srtBaseNav(), 1000e18);
            assertEq(pool.capacity(), capacity);
        }
    }

    function test_withoutSelfFund_stillResyncsInsurance() public {
        for (uint256 variant; variant < 4; variant++) {
            (IValuationFundHarness accounting, MockInsurancePool pool) = _deploy(variant, false);
            uint256 capacity = pool.capacity();
            accounting.setValuationPrice(0.41e18);
            uint256 claim = (uint256(1000e18) * 1e18) / 0.41e18 - 1000e18 - 999e18;
            assertEq(accounting.insuranceAmount(), claim);
            assertEq(accounting.srtInsuranceFundNav(), claim);
            assertEq(pool.capacity(), capacity);
            accounting.setValuationPrice(1e18);
            assertEq(accounting.insuranceAmount(), 0);
            assertEq(accounting.srtInsuranceFundNav(), 0);
        }
    }

    function test_deeperDepeg_preservesSelfFundAndSlashesOnlyDelta() public {
        for (uint256 variant; variant < 4; variant++) {
            (IValuationFundHarness accounting, MockInsurancePool pool) = _deploy(variant, true);
            accounting.setValuationPrice(0.39e18);
            uint256 claim = (uint256(1000e18) * 1e18) / 0.39e18 - 1000e18 - 150e18 - 999e18;
            assertEq(accounting.srtFundNav(), 150e18);
            assertEq(accounting.insuranceAmount(), claim);
            assertEq(accounting.srtInsuranceFundNav(), claim);
            assertEq(CAPACITY - pool.capacity(), claim);
        }
    }
}
