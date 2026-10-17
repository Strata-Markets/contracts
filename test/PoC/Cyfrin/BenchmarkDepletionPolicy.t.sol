// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { console } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { DiscreteAccounting } from "../../../contracts/tranches/DiscreteAccounting.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { InsuranceMiddleware } from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { IStrataAccounting } from "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { IInsurancePool } from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockOracleAdapter } from "../../../contracts/test/MockOracleAdapter.sol";
import { MockAppAdapter } from "../../symbiotic/NetworkMiddleware.t.sol";

/// @dev The subset of the accounting ABI shared by Accounting, DiscreteAccounting, DYSAccounting and MTMAccounting
interface IValuationAccounting {
    function setValuationPrice(uint128 price) external returns (bool);
    function setInsurancePool(IInsurancePool pool) external;
    function setReserveBps(uint256 bps) external;
    function setUnderwriterFeeBps(uint256 bps) external;
    function updateBalanceFlow(uint256, uint256, uint256, uint256) external returns (uint256);
    function updateAccounting() external;
    function srtInsuranceFundNav() external view returns (uint256);
    function insuranceAmount() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
    function jrtBaseNav() external view returns (uint256);
    function reserveNav() external view returns (uint256);
    function nav() external view returns (uint256);
    function feeWatermarkNav() external view returns (uint256);
    function valuationPrice() external view returns (uint128);
    function totalAssets() external view returns (uint256, uint256, uint256);
}

/// @notice Real accounting variant + real InsuranceMiddleware, with only the Symbiotic AppAdapter and the
///         price oracle mocked (both are exogenous: the adapter just tracks slashable stake)
/// @dev The test contract plays the CDO (as the repo fixtures in test/symbiotic do), so it answers every
///      strategy/rate read the four accounting variants make. Both assets are priced at $1 with 18 decimals
///      and bufferBps is 0, so one unit of slashed collateral equals one unit of base asset
abstract contract ValuationInsuranceFixture is Test {
    uint256 constant ONE_ASSET = 1e18;
    uint256 constant SLASHABLE = 1_000_000e18;

    IValuationAccounting accounting;
    InsuranceMiddleware middleware;
    MockAppAdapter adapter;
    MockOracleAdapter oracle;
    MockERC20 baseAsset;
    MockERC20 collateral;
    AccessControlManager acm;

    uint256 mockStrategyTvl;
    int64 mockAprTarget;
    int64 mockAprBase;

    // ---------------------------------------------------------------- CDO callbacks

    function totalStrategyAssets() external view returns (uint256) {
        return mockStrategyTvl;
    }

    function totalStrategyAssets(uint256, uint256) external view returns (uint256) {
        return mockStrategyTvl;
    }

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

    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound({
            aprTarget: mockAprTarget,
            aprBase: mockAprBase,
            updatedAt: uint64(block.timestamp),
            answeredInRound: 1
        });
    }

    // ---------------------------------------------------------------- setup

    function _deployAccounting() internal virtual returns (address);

    function setUp() public virtual {
        vm.mockCall(address(this), abi.encodeWithSignature("insuranceVault()"), abi.encode(address(0)));
        vm.warp(1_750_000_000);
        acm = new AccessControlManager(address(this));
        mockAprBase = 100_000_000_000; // 10% APR, SD7x12

        baseAsset = new MockERC20("BASE", 18);
        collateral = new MockERC20("COLL", 18);
        adapter = new MockAppAdapter(address(collateral));
        adapter.setSlashable(SLASHABLE);
        oracle = new MockOracleAdapter(); // both assets default to $1

        middleware = InsuranceMiddleware(address(new ERC1967Proxy(
            address(new InsuranceMiddleware()),
            abi.encodeCall(InsuranceMiddleware.initialize, (address(this), address(acm), address(adapter), address(oracle)))
        )));

        accounting = IValuationAccounting(_deployAccounting());

        // This contract is the market CDO, the accounting is the only caller allowed into coverAndSlash
        middleware.setMarket(address(this), IStrataAccounting(address(accounting)), address(baseAsset), 0, true);
        accounting.setInsurancePool(IInsurancePool(address(middleware)));

        // Same fee configuration as the repo fixtures
        accounting.setReserveBps(0.1e18);
        accounting.setUnderwriterFeeBps(0.1e18);

        // Seed 1000 Jrt + 1000 Srt, as CDO.deposit() would book it
        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
    }

    function _totalSlashed() internal view returns (uint256 totalSlashed) {
        (,, totalSlashed,,,) = middleware.markets(address(this));
    }

    function _pendingFunding() internal view returns (uint256 pending) {
        (,,, pending,,) = middleware.markets(address(this));
    }

    /// @dev Senior-bound need at `price` for 1000 principal and 999 of Junior headroom, same arithmetic as the code
    function _need(uint128 price) internal pure returns (uint256) {
        return Math.saturatingSub(Math.saturatingSub(Math.mulDiv(1000e18, 1e18, price), 1000e18), 999e18);
    }
}

/// @notice Benchmark accrual stops at the Junior floor; previously accrued yield remains insured.
abstract contract BenchmarkDepletionPolicyTests is ValuationInsuranceFixture {

    function setUp() public virtual override {
        mockAprTarget = 80_000_000_000; // 8% benchmark, SD7x12
        super.setUp();
        _setRiskPremium(UD60x18.wrap(0.4e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
    }

    function _setRiskPremium(UD60x18 x, UD60x18 y, UD60x18 k) internal virtual;

    function _underwriterFeeNav() internal view virtual returns (uint256);

    function _srtPnLBenchmark() internal view virtual returns (uint256);

    /// @dev Junior is wiped out by a 1500 loss and Symbiotic covers 501, leaving Junior at its floor
    function _wipeOutJunior() internal {
        mockStrategyTvl = 500e18;
        accounting.updateAccounting();
        assertEq(accounting.jrtBaseNav(), 1e18, "Junior at its floor");
        assertEq(accounting.srtBaseNav(), 1000e18, "Senior held whole");
        assertEq(accounting.insuranceAmount(), 501e18);
        assertEq(_totalSlashed(), 501e18);
    }

    function test_depletedYearAccruesNoBenchmarkOrAdditionalSlash() public {
        _wipeOutJunior();
        vm.warp(block.timestamp + 365 days);
        accounting.updateAccounting();
        assertEq(_srtPnLBenchmark(), 0);
        mockStrategyTvl += 1;
        accounting.updateAccounting();
        assertEq(accounting.srtBaseNav(), 1000e18);
        assertEq(_underwriterFeeNav(), 0);
        assertEq(_totalSlashed(), 501e18);
        assertEq(accounting.insuranceAmount(), 501e18 - 1);
    }

    function test_dailyUpdatesDoNotDrainUnderwriters() public {
        _wipeOutJunior();
        for (uint256 i; i < 30; ++i) {
            vm.warp(block.timestamp + 1 days);
            accounting.updateAccounting();
            assertEq(_srtPnLBenchmark(), 0);
            mockStrategyTvl += 1;
            accounting.updateAccounting();
        }
        assertEq(accounting.srtBaseNav(), 1000e18);
        assertEq(accounting.jrtBaseNav(), ONE_ASSET);
        assertEq(_totalSlashed(), 501e18);
        assertEq(_underwriterFeeNav(), 0);
    }

    function test_preDepletionBenchmarkCanStillBeInsured() public {
        vm.warp(block.timestamp + 365 days);
        accounting.updateAccounting();
        assertEq(_srtPnLBenchmark(), 80e18);
        mockStrategyTvl = 500e18;
        accounting.updateAccounting();
        assertEq(accounting.srtBaseNav(), 1076.8e18);
        assertEq(_totalSlashed(), 581e18, "old benchmark remains insured");
        assertEq(_underwriterFeeNav(), 3.2e18);
        vm.warp(block.timestamp + 365 days);
        accounting.updateAccounting();
        assertEq(_srtPnLBenchmark(), 0);
        mockStrategyTvl += 1;
        accounting.updateAccounting();
        assertEq(_totalSlashed(), 581e18, "no fresh entitlement while depleted");
    }

    function test_intervalEndingInDepletionAccruesNoBenchmark() public {
        accounting.setUnderwriterFeeBps(0);
        accounting.updateBalanceFlow(0, 998e18, 0, 0);
        mockStrategyTvl = 1002e18;
        vm.warp(block.timestamp + 365 days);
        accounting.updateAccounting();
        assertEq(accounting.jrtBaseNav(), ONE_ASSET);
        assertEq(_srtPnLBenchmark(), 0, "exclude the interval that depletes Junior");
        vm.warp(block.timestamp + 365 days);
        accounting.updateAccounting();
        assertEq(_srtPnLBenchmark(), 0, "no accrual while Junior stays depleted");
        mockStrategyTvl += 1;
        accounting.updateAccounting();
        assertEq(_totalSlashed(), 0);
        assertEq(accounting.srtBaseNav(), 1000e18);
    }
}

contract BenchmarkDepletionPolicyDYSTest is BenchmarkDepletionPolicyTests {
    function _deployAccounting() internal override returns (address a) {
        // decimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection, conservativePrice
        a = address(new ERC1967Proxy(
            address(new DYSAccounting(18, true, false, false, true, false)),
            abi.encodeWithSelector(
                DYSAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        ));
        acm.grantRole(DYSAccounting(a).UPDATER_STRAT_CONFIG_ROLE(), address(this));
    }

    function _setRiskPremium(UD60x18 x, UD60x18 y, UD60x18 k) internal override {
        DYSAccounting(address(accounting)).setRiskParameters(x, y, k);
    }

    function _underwriterFeeNav() internal view override returns (uint256) {
        return DYSAccounting(address(accounting)).underwriterFeeNav();
    }

    function _srtPnLBenchmark() internal view override returns (uint256) {
        return DYSAccounting(address(accounting)).srtPnLBenchmark();
    }
}

contract BenchmarkDepletionPolicyMTMTest is BenchmarkDepletionPolicyTests {
    function _deployAccounting() internal override returns (address a) {
        // decimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection,
        // conservativePrice, mtmProjection
        a = address(new ERC1967Proxy(
            address(new MTMAccounting(18, true, false, false, true, false, false)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        ));
        acm.grantRole(MTMAccounting(a).UPDATER_STRAT_CONFIG_ROLE(), address(this));
    }

    function _setRiskPremium(UD60x18 x, UD60x18 y, UD60x18 k) internal override {
        MTMAccounting(address(accounting)).setRiskParameters(x, y, k);
    }

    function _underwriterFeeNav() internal view override returns (uint256) {
        return MTMAccounting(address(accounting)).underwriterFeeNav();
    }

    function _srtPnLBenchmark() internal view override returns (uint256) {
        return MTMAccounting(address(accounting)).srtPnLBenchmark();
    }
}