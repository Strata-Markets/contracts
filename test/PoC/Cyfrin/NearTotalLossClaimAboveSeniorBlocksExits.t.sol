// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { DiscreteAccounting } from "../../../contracts/tranches/DiscreteAccounting.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { InsuranceMiddleware } from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { IStrataAccounting } from "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { IInsurancePool } from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockOracleAdapter } from "../../../contracts/test/MockOracleAdapter.sol";
import { MockAppAdapter } from "../../symbiotic/NetworkMiddleware.t.sol";

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

interface IFeeAccounting {
    function underwriterFeeNav() external view returns (uint256);
    function accrueFee(bool isJrt, uint256 amount) external;
    function reduceReserve(uint256 amount, uint256 jrtAmountIn, uint256 srtAmountIn) external;
}

/// @notice Regression adapted from the auditor PoC: excess claims must not block Senior exits.
/// @dev Real accounting and middleware, covering Junior dust, fee buckets and limited insurance capacity.
abstract contract NearTotalLossClaimAboveSeniorBlocksExitsTests is ValuationInsuranceFixture {

    function _identity() internal view {
        assertEq(accounting.nav() + accounting.insuranceAmount(),
            accounting.jrtBaseNav() + accounting.srtBaseNav() + accounting.reserveNav() + _fee().underwriterFeeNav());
    }

    function _fee() internal view returns (IFeeAccounting) {
        return IFeeAccounting(address(accounting));
    }

    /// @dev One year at +10% so the reserve and the underwriter fee bucket hold something
    function _accrueGain() internal {
        vm.warp(vm.getBlockTimestamp() + 365 days);
        mockStrategyTvl = 2200e18;
        accounting.updateAccounting();
    }

    /// @dev DYS/MTM must reconcile recovery after an elapsed zero-strategy-NAV interval.
    function _zeroNavThenDonationRecovers() internal {
        _accrueGain();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        mockStrategyTvl = 0;
        accounting.updateAccounting();
        assertGt(accounting.insuranceAmount(), accounting.srtBaseNav());

        uint256 claim = accounting.insuranceAmount();
        uint256 senior = accounting.srtBaseNav();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        mockStrategyTvl = 100e18;
        accounting.updateAccounting();
        assertEq(accounting.nav(), 100e18);
        assertEq(accounting.insuranceAmount(), claim - 100e18);
        assertEq(accounting.srtBaseNav(), senior);
        _identity();
    }

    function test_nearTotalLossAllowsPartialAndFullExits() public {
        _accrueGain();
        uint256 uwFee = _fee().underwriterFeeNav();
        uint256 srt = accounting.srtBaseNav();
        assertGt(uwFee, 0);

        // The strategy loses everything but 0.5 units
        vm.warp(vm.getBlockTimestamp() + 1 days);
        mockStrategyTvl = 0.5e18;
        accounting.updateAccounting();

        uint256 claim = accounting.insuranceAmount();
        srt = accounting.srtBaseNav();
        // Fees absorb the uncovered loss before Senior; only funded residual fees remain.
        uwFee = _fee().underwriterFeeNav();
        assertEq(claim, srt + accounting.jrtBaseNav() + uwFee - 0.5e18);
        assertGe(claim, srt, "terminal dust can still leave the claim above remaining Senior NAV");

        uint256 snapshot = vm.snapshotState();
        assertEq(accounting.updateBalanceFlow(0, 0, 0, 100e18), 100e18);
        assertEq(accounting.insuranceAmount(), claim - 100e18);
        assertEq(accounting.nav(), 0.5e18);
        _identity();
        assertEq(accounting.updateBalanceFlow(0, 0, 0, srt - 100e18), srt - 100e18);
        assertEq(accounting.srtBaseNav(), 0);
        assertEq(accounting.insuranceAmount(), claim - srt, "non-Senior backing remains");
        assertEq(_fee().underwriterFeeNav(), uwFee);
        _identity();

        // Recovery still unwinds excess claims before an exit.
        vm.revertToState(snapshot);
        uint256 gap = claim - srt;
        vm.warp(vm.getBlockTimestamp() + 1);
        mockStrategyTvl = 0.5e18 + gap;
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), accounting.srtBaseNav(), "claim back to Senior NAV");
        uint256 slice = accounting.updateBalanceFlow(0, 0, 0, 100e18);
        assertEq(slice, 100e18);
    }

    function test_seniorFeeBurnDoesNotBlockExit() public {
        // Loss leaves 1% of Senior backed by the strategy: J floor 1, strategy 11, S 1000
        mockStrategyTvl = 11e18;
        accounting.updateAccounting();
        uint256 srt = accounting.srtBaseNav();
        uint256 claim = accounting.insuranceAmount();
        assertLt(claim, srt);
        uint256 slice = accounting.updateBalanceFlow(0, 0, 0, 1e18);
        assertLt(slice, 1e18);
        srt = accounting.srtBaseNav();
        claim = accounting.insuranceAmount();

        // A Senior holder burns its own shares as fee (Tranche::burnSharesAsFee -> accrueFee) worth the gap + 1
        uint256 burn = srt - claim + 1e18;
        _fee().accrueFee(false, burn);
        assertGt(accounting.insuranceAmount(), accounting.srtBaseNav());
        uint256 snapshot = vm.snapshotState();
        uint256 claimBeforeExit = accounting.insuranceAmount();
        uint256 navBeforeExit = accounting.nav();
        assertEq(accounting.updateBalanceFlow(0, 0, 0, 100e18), 100e18);
        assertEq(accounting.insuranceAmount(), claimBeforeExit - 100e18);
        assertEq(accounting.nav(), navBeforeExit);
        _identity();
        vm.revertToState(snapshot);

        // RESERVE_MANAGER_ROLE can hand the burned fee back to Senior through distributeReserve
        _fee().reduceReserve(burn, 0, burn);
        slice = accounting.updateBalanceFlow(0, 0, 0, 100e18);
        assertLe(slice, 100e18);
    }

    function test_smallPoolExcessClaimDoesNotBlockExit() public {
        _accrueGain();
        // The pool only has 10 units of slashable stake
        adapter.setSlashable(10e18);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        mockStrategyTvl = 0.5e18;
        accounting.updateAccounting();

        // Accrued fees absorb the uncovered loss first. Discrete can retain strategy-backed Senior NAV.
        uint256 claim = accounting.insuranceAmount();
        uint256 srt = accounting.srtBaseNav();
        assertEq(claim, 10e18);
        assertEq(_fee().underwriterFeeNav(), 0);
        assertEq(claim + 0.5e18, srt + accounting.jrtBaseNav());
        uint256 firstPaid = Math.min(1e18, Math.mulDiv(1e18, claim, srt));
        assertEq(accounting.updateBalanceFlow(0, 0, 0, 1e18), firstPaid);
        assertEq(accounting.insuranceAmount(), claim - firstPaid);
        mockStrategyTvl = accounting.nav();
        _identity();
        uint256 finalPaid = Math.min(srt - 1e18, claim - firstPaid);
        assertEq(accounting.updateBalanceFlow(0, 0, 0, srt - 1e18), finalPaid);
        assertEq(accounting.insuranceAmount(), claim - firstPaid - finalPaid);
        assertEq(accounting.srtBaseNav(), 0);
        _identity();
    }
}

contract NearTotalLossClaimAboveSeniorBlocksExitsAccountingTest is NearTotalLossClaimAboveSeniorBlocksExitsTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new Accounting(18)),
            abi.encodeWithSelector(
                Accounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        ));
    }
}

contract NearTotalLossClaimAboveSeniorBlocksExitsDiscreteTest is NearTotalLossClaimAboveSeniorBlocksExitsTests {
    function _deployAccounting() internal override returns (address a) {
        a = address(new ERC1967Proxy(
            address(new DiscreteAccounting(18, false)),
            abi.encodeWithSelector(
                DiscreteAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        ));
        acm.grantRole(DiscreteAccounting(a).UPDATER_STRAT_CONFIG_ROLE(), address(this));
        DiscreteAccounting(a).setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
    }
}

contract NearTotalLossClaimAboveSeniorBlocksExitsDYSTest is NearTotalLossClaimAboveSeniorBlocksExitsTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new DYSAccounting(18, false, false, false, true, false)),
            abi.encodeWithSelector(
                DYSAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        ));
    }

    function test_dysZeroNavAllowsDonationRecovery() public {
        _zeroNavThenDonationRecovers();
    }
}

contract NearTotalLossClaimAboveSeniorBlocksExitsMTMTest is NearTotalLossClaimAboveSeniorBlocksExitsTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, true, false, true, true, true)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        ));
    }

    function test_mtmZeroNavAllowsDonationRecovery() public {
        _zeroNavThenDonationRecovers();
    }
}
