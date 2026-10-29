// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;


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
    // MTM only: when set, the settled snapshot stays at (settledTvl, settledTime) and only the live mark moves
    bool liveMarkOnly;
    uint256 settledTvl;
    uint256 settledTime;
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
        if (liveMarkOnly) return (settledTvl, settledTime, mockStrategyTvl, block.timestamp);
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
        acm = new AccessControlManager(address(this));
        mockAprBase = 100_000_000_000; // 10% APR, SD7x12

        baseAsset = new MockERC20("BASE", 18);
        collateral = new MockERC20("COLL", 18);
        adapter = new MockAppAdapter(address(collateral));
        adapter.setSlashable(SLASHABLE);
        oracle = new MockOracleAdapter(); // both assets default to $1

        middleware = InsuranceMiddleware(address(new ERC1967Proxy(
            address(new InsuranceMiddleware(address(adapter))),
            abi.encodeCall(InsuranceMiddleware.initialize, (address(this), address(acm), address(oracle)))
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

interface IFloorAccounting {
    function setFloorRate(uint256 rate) external;
    function setRiskParameters(UD60x18 riskX_, UD60x18 riskY_, UD60x18 riskK_) external;
    function windowStartSrtNav() external view returns (uint256);
    function windowNetFlows() external view returns (int256);
    function windowEnd() external view returns (uint256);
    function underwriterFeeNav() external view returns (uint256);
    function UPDATER_STRAT_CONFIG_ROLE() external view returns (bytes32);
}

/// @notice Regressions adapted from the auditor's stale valuation-credit floor PoCs.
abstract contract ValuationFloorBaselineTests is ValuationInsuranceFixture {
    function setUp() public virtual override {
        super.setUp();
        _floor().setRiskParameters(UD60x18.wrap(0.4e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        _floor().setFloorRate(0.01e18);
    }

    function _floor() internal view returns (IFloorAccounting) {
        return IFloorAccounting(address(accounting));
    }

    function _baseline() internal view returns (uint256) {
        return uint256(int256(_floor().windowStartSrtNav()) + _floor().windowNetFlows());
    }

    function _rollDuringDepeg(uint128 price) internal {
        accounting.setValuationPrice(price);
        vm.warp(block.timestamp + 1 days);
        mockStrategyTvl -= 1;
        accounting.updateAccounting();
        assertApproxEqAbs(_baseline(), accounting.srtBaseNav(), 2);
    }

    function _recoverAndLose(uint256 loss) internal {
        accounting.setValuationPrice(1e18);
        assertApproxEqAbs(_baseline(), 1000e18, 2, "credit removed from baseline");
        uint256 juniorBefore = accounting.jrtBaseNav();
        uint256 slashedBefore = _totalSlashed();
        vm.warp(block.timestamp + 1 hours);
        mockStrategyTvl -= loss;
        accounting.updateAccounting();
        assertLe(accounting.srtBaseNav(), 1000e18, "loss cannot create Senior profit");
        assertLe(juniorBefore - accounting.jrtBaseNav(), loss + 2, "no fictitious Junior loss");
        assertEq(_totalSlashed(), slashedBefore, "no extra slash after recovery");
        assertEq(_floor().underwriterFeeNav(), 0, "no fee on fictitious gain");
    }

    function test_FloorResetPreservesValuationCredit() public {
        accounting.setValuationPrice(0.4e18);
        assertGt(accounting.srtInsuranceFundNav(), 0);
        uint256 seniorBefore = accounting.srtBaseNav();
        _floor().setFloorRate(0.009e18);
        assertEq(_floor().windowStartSrtNav(), seniorBefore);
        assertEq(_floor().windowNetFlows(), 0);
    }

    function test_RepegThenSmallLoss() public {
        _rollDuringDepeg(0.4e18);
        _recoverAndLose(10e18);
        assertApproxEqAbs(accounting.srtBaseNav(), 997e18, 2);
    }

    function test_RepegThenDustLoss() public {
        _rollDuringDepeg(0.4e18);
        _recoverAndLose(5);
        assertApproxEqAbs(accounting.srtBaseNav(), 1000e18, 5);
    }

    function test_ThinJuniorDoesNotCauseAnotherSlash() public {
        mockStrategyTvl = 1100e18;
        accounting.updateBalanceFlow(0, 900e18, 0, 0);
        _rollDuringDepeg(0.8e18);
        _recoverAndLose(10e18);
    }

    function test_CreditAndRecoveryWithoutRollover() public {
        uint256 end = _floor().windowEnd();
        accounting.setValuationPrice(0.4e18);
        assertEq(_baseline(), 1501e18);
        assertEq(_floor().windowNetFlows(), 501e18);
        _recoverAndLose(10e18);
        assertEq(_floor().windowEnd(), end, "valuation does not restart the daily budget");
        assertEq(_floor().windowNetFlows(), 0);
    }

    /// @notice Valuation credit receives floor protection immediately, before any rollover.
    function test_CreditProtectedBeforeRollover() public {
        accounting.setValuationPrice(0.4e18);
        _checkCreditProtectedDuringDepeg();
    }

    /// @notice Rolling the window preserves the same protection for principal plus credit.
    function test_CreditProtectedAfterRollover() public {
        _rollDuringDepeg(0.4e18);
        _checkCreditProtectedDuringDepeg();
    }

    function _checkCreditProtectedDuringDepeg() internal {
        uint256 seniorBefore = accounting.srtBaseNav();
        uint256 creditBefore = accounting.srtInsuranceFundNav();
        uint256 juniorBefore = accounting.jrtBaseNav();
        uint256 baseline = _baseline();
        uint256 end = _floor().windowEnd();
        assertApproxEqAbs(creditBefore, 501e18, 2);
        assertApproxEqAbs(baseline, 1501e18, 2, "baseline includes valuation credit");
        assertEq(baseline, seniorBefore);

        // Capture the floor before the loss and any resulting valuation-coverage top-up.
        uint256 expectedFloor = baseline * 99 / 100;
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        mockStrategyTvl -= 300e18;
        accounting.updateAccounting();

        uint256 additionalCredit = accounting.srtInsuranceFundNav() - creditBefore;
        uint256 seniorBeforeTopUp = accounting.srtBaseNav() - additionalCredit;
        assertApproxEqAbs(seniorBeforeTopUp, expectedFloor, 2, "loss allocation respects the credit-inclusive floor");
        assertApproxEqAbs(
            juniorBefore - accounting.jrtBaseNav(),
            300e18 - (seniorBefore - expectedFloor),
            2,
            "Junior absorbs the loss beyond Senior's allowance"
        );
        assertEq(_floor().underwriterFeeNav(), 0, "no gain fee on floor protection");
        assertEq(_baseline(), baseline + additionalCredit, "new valuation credit also adjusts the baseline");
        assertEq(_floor().windowEnd(), end, "loss and top-up do not reset the window");
    }

    function test_PartialRecoveryAndFurtherDepeg() public {
        _rollDuringDepeg(0.4e18);
        uint256 end = _floor().windowEnd();
        uint256 creditBefore = accounting.srtInsuranceFundNav();
        accounting.setValuationPrice(0.45e18);
        assertLt(accounting.srtInsuranceFundNav(), creditBefore);
        assertGt(accounting.srtInsuranceFundNav(), 0);
        assertApproxEqAbs(_baseline(), accounting.srtBaseNav(), 2, "partial unwind follows NAV");
        accounting.setValuationPrice(0.35e18);
        assertGt(accounting.srtInsuranceFundNav(), creditBefore);
        assertApproxEqAbs(_baseline(), accounting.srtBaseNav(), 2, "additional credit follows NAV");
        accounting.setValuationPrice(1e18);
        assertApproxEqAbs(_baseline(), 1000e18, 2);
        assertEq(_floor().windowEnd(), end);
    }

    function test_LossAtNextRolloverUsesCorrectBaseline() public {
        _rollDuringDepeg(0.4e18);
        accounting.setValuationPrice(1e18);
        vm.warp(block.timestamp + 1 days);
        mockStrategyTvl -= 10e18;
        accounting.updateAccounting();
        assertApproxEqAbs(accounting.srtBaseNav(), 997e18, 2);
        assertEq(_floor().windowStartSrtNav(), accounting.srtBaseNav());
        assertEq(_floor().windowNetFlows(), 0);
    }

    function test_RealLossStillReceivesFloorProtection() public {
        _rollDuringDepeg(0.4e18);
        accounting.setValuationPrice(1e18);
        vm.warp(block.timestamp + 1 hours);
        mockStrategyTvl -= 200e18;
        accounting.updateAccounting();
        assertApproxEqAbs(accounting.srtBaseNav(), 990e18, 2, "Senior retains the 1% loss floor");
    }
}

contract ValuationFloorBaselineDYSTest is ValuationFloorBaselineTests {
    function _deployAccounting() internal override returns (address a) {
        // decimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection, conservativePrice
        a = address(new ERC1967Proxy(
            address(new DYSAccounting(18, false, false, false, true, false)),
            abi.encodeWithSelector(
                DYSAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        ));
        acm.grantRole(IFloorAccounting(a).UPDATER_STRAT_CONFIG_ROLE(), address(this));
    }
}

contract ValuationFloorBaselineMTMTest is ValuationFloorBaselineTests {
    function _deployAccounting() internal override returns (address a) {
        // decimals, benchmark, navAtReconciliation, ratesForReconciliation, juniorCoversPaidSrtProjection,
        // conservativePrice, mtmProjection
        a = address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, true, false, true, true, true)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        ));
        acm.grantRole(IFloorAccounting(a).UPDATER_STRAT_CONFIG_ROLE(), address(this));
    }

    function test_LiveDipAfterRecoveryDoesNotLiftSenior() public {
        _rollDuringDepeg(0.4e18);
        accounting.setValuationPrice(1e18);
        uint256 seniorBefore = accounting.srtBaseNav();
        uint256 juniorBefore = accounting.jrtBaseNav();
        uint256 navBefore = accounting.nav();
        liveMarkOnly = true;
        settledTvl = navBefore;
        settledTime = block.timestamp;
        vm.warp(block.timestamp + 1 hours);
        mockStrategyTvl = navBefore - 10e18;
        accounting.updateAccounting();
        assertEq(accounting.nav(), navBefore, "settled NAV unchanged");
        assertLe(accounting.srtBaseNav(), seniorBefore, "live dip cannot create Senior profit");
        assertLe(int256(juniorBefore) - int256(accounting.jrtBaseNav()), int256(10e18), "no fictitious Junior loss");
        assertApproxEqAbs(accounting.srtBaseNav(), 997e18, 2);
    }
}
