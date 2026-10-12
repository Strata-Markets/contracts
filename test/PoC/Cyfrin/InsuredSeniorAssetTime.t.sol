// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { Test } from "forge-std/Test.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { InsuranceMiddleware } from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { IStrataAccounting } from "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { IInsurancePool } from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockOracleAdapter } from "../../../contracts/test/MockOracleAdapter.sol";
import { MockAppAdapter } from "../../symbiotic/NetworkMiddleware.t.sol";

/// @dev Accounting ABI shared by the DYS and MTM fixtures.
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
///      strategy/rate read the accounting variants make. Both assets are priced at $1 with 18 decimals
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
    uint256 mockProjectedTvl;
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
        return (mockStrategyTvl, mockProjectedTvl > 0 ? block.timestamp - 1 : block.timestamp, mockProjectedTvl > 0 ? mockProjectedTvl : mockStrategyTvl, block.timestamp);
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

}

/// @notice Regressions adapted from the Cyfrin PoC: insurance-backed Senior NAV must not
///         earn or absorb strategy PnL. Both variants run the same allocation and checkpoint tests.
abstract contract InsuredSeniorAssetTimeRegressionTests is ValuationInsuranceFixture {

    function setUp() public virtual override {
        super.setUp();
        // Constant 40% risk premium: riskX = 0.4, riskY = 0
        _setRiskPremium(UD60x18.wrap(0.4e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
    }

    function _setRiskPremium(UD60x18 x, UD60x18 y, UD60x18 k) internal virtual;

    function _underwriterFeeNav() internal view virtual returns (uint256);

    /// @dev Junior exits 900 so the market is 100 Junior / 1000 Senior
    function _tenPercentJunior() internal {
        mockStrategyTvl = 1100e18;
        accounting.updateBalanceFlow(0, 900e18, 0, 0);
        assertEq(accounting.jrtBaseNav(), 100e18);
        assertEq(accounting.srtBaseNav(), 1000e18);
    }

    function _loss(uint256 assets) internal {
        mockStrategyTvl = assets;
        accounting.updateAccounting();
    }

    function _recover(bool advanceTime) internal {
        _loss(100e18);
        if (advanceTime) { vm.warp(block.timestamp + 1 days); }
        _loss(2000e18);
        uint256 gross = uint256(999e18) * 6 / 10 * 99 / 100;
        assertApproxEqAbs(accounting.srtBaseNav(), 1000e18 + gross * 96 / 100, 1e6);
        assertApproxEqAbs(accounting.jrtBaseNav(), 1000e18 - gross, 1e6);
        assertApproxEqAbs(_underwriterFeeNav(), gross * 4 / 100, 1e6);
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(_totalSlashed(), 901e18, "recovery must not slash again");
    }

    function test_recoveryExcludesClaimBackedSeniorCapital() public {
        _tenPercentJunior();
        _loss(880e18);
        assertEq(accounting.insuranceAmount(), 121e18);
        vm.warp(block.timestamp + 1 days);
        _loss(1100e18);
        assertApproxEqAbs(accounting.srtBaseNav(), 1056.9592e18, 1e6);
        assertApproxEqAbs(accounting.jrtBaseNav(), 40.6675e18, 1e6);
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(_totalSlashed(), 121e18);
    }

    function test_deepRecoveryDoesNotReslash() public { _recover(true); }
    function test_sameBlockRecoveryUsesNetSeniorSnapshot() public { _recover(false); }

    function test_furtherLossDoesNotCreditJuniorOrBlockExit() public {
        _loss(2e18);
        DYSAccounting(address(accounting)).setFloorRate(0.01e18);
        vm.warp(block.timestamp + 1 days);
        _loss(1e18);
        assertEq(accounting.srtBaseNav(), 999.7e18);
        assertEq(accounting.jrtBaseNav(), 1e18);
        assertEq(accounting.insuranceAmount(), 999.7e18);
        assertEq(accounting.updateBalanceFlow(0, 0, 0, 1e18), 1e18);
    }

    function test_redemptionCheckpointsOldClaimWeight() public {
        _tenPercentJunior();
        _loss(880e18);
        vm.warp(block.timestamp + 1 days);
        uint256 covered = accounting.updateBalanceFlow(0, 0, 0, 100e18);
        assertEq(covered, 12.1e18);
        mockStrategyTvl -= 100e18 - covered;
        assertEq(_weight(), 879e18 * 1 days);
        vm.warp(block.timestamp + 1 days);
        accounting.updateBalanceFlow(0, 0, 0, 0);
        assertEq(_weight(), (879e18 + 791.1e18) * 1 days);
    }

    function _weight() internal view returns (uint256) {
        return DYSAccounting(address(accounting)).srtNavTime();
    }

    function test_valuationPushesCheckpointBeforeClaimChanges() public {
        vm.warp(block.timestamp + 1 days);
        accounting.setValuationPrice(0.4e18);
        assertEq(accounting.insuranceAmount(), 501e18);
        assertEq(_weight(), 1000e18 * 1 days);
        vm.warp(block.timestamp + 1 days);
        accounting.setValuationPrice(0.5e18);
        assertEq(accounting.insuranceAmount(), 1e18);
        assertEq(_weight(), 2000e18 * 1 days);
        vm.warp(block.timestamp + 1 days);
        accounting.setValuationPrice(1e18);
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(_weight(), 3000e18 * 1 days);
        vm.warp(block.timestamp + 1 days);
        accounting.updateBalanceFlow(0, 0, 0, 0);
        assertEq(_weight(), 4000e18 * 1 days);
    }

    function test_partialCoverageTracksActualClaim() public {
        adapter.setSlashable(100e18);
        accounting.setValuationPrice(0.4e18);
        assertEq(accounting.insuranceAmount(), 100e18);
        vm.warp(block.timestamp + 1 days);
        accounting.updateBalanceFlow(0, 0, 0, 0);
        assertEq(_weight(), 1000e18 * 1 days);
    }

    function _prepareProjection() internal virtual {}

    function test_liveProjectionAndInsuranceAreBothExcluded() public {
        vm.warp(block.timestamp + 30 days);
        _prepareProjection();
        accounting.updateAccounting();
        DYSAccounting a = DYSAccounting(address(accounting));
        uint256 projection = a.srtPnLProjected();
        assertGt(projection, 0);
        uint256 principal = accounting.srtBaseNav() - projection;
        accounting.setValuationPrice(0.4e18);
        assertGt(accounting.insuranceAmount(), 0);
        uint256 weightBefore = _weight();
        uint256 projectedTimeBefore = a.srtProjectedPnLTime();
        vm.warp(block.timestamp + 1 days);
        accounting.setValuationPrice(1e18);
        uint256 netDelta = (_weight() - weightBefore) - (a.srtProjectedPnLTime() - projectedTimeBefore);
        assertEq(netDelta, principal * 1 days, "deduct claim and live projection independently");
        mockProjectedTvl = 0;
        mockStrategyTvl += 20e18;
        (uint256 junior, uint256 senior,) = accounting.totalAssets();
        accounting.updateAccounting();
        assertEq(accounting.srtBaseNav(), senior);
        assertEq(accounting.jrtBaseNav(), junior);
        assertEq(_weight(), 0, "reconciliation resets old weights");
    }
}

contract InsuredSeniorAssetTimeRegressionDYSTest is InsuredSeniorAssetTimeRegressionTests {
    function _deployAccounting() internal override returns (address a) {
        // decimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection, conservativePrice
        a = address(new ERC1967Proxy(
            address(new DYSAccounting(18, false, false, false, true, false)),
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
}

contract InsuredSeniorAssetTimeRegressionMTMTest is InsuredSeniorAssetTimeRegressionTests {
    function test_reconciliationThenMtmUsesNewClaimAndResetsWeights() public {
        vm.warp(block.timestamp + 1 days);
        mockStrategyTvl = 100e18;
        // Reconcile the loss one second before the current MTM snapshot.
        mockProjectedTvl = 100e18;
        (uint256 junior, uint256 senior,) = accounting.totalAssets();
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 901e18);
        assertEq(accounting.jrtBaseNav(), junior);
        assertEq(accounting.srtBaseNav(), senior);
        assertEq(_weight(), 99e18, "new epoch weights only 99 strategy-backed Senior for one second");
    }

    function _prepareProjection() internal override { mockProjectedTvl = mockStrategyTvl + 20e18; }
    function _deployAccounting() internal override returns (address a) {
        // decimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection,
        // conservativePrice, mtmProjection
        a = address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, true, false, true, true, true)),
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
}