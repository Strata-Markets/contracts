// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { console, Test } from "forge-std/Test.sol";
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

/// @notice Regression for the Cyfrin finding: during a de-peg deeper than Junior's buffer,
///         AccountingLib::splitValuatedNavOut used to charge Junior the full out x (1 - p) of every Senior exit that
///         fit Junior's headroom, although Junior only pledges part of Senior's top-up. The same 50% Senior exit then
///         left different Junior and Senior base NAVs depending on whether it was one redemption or ten.
///         A Senior exit now takes the same fraction of every part of Senior's effective NAV, so the result is
///         independent of chunking.
/// @dev Real accounting variant + real InsuranceMiddleware from the imported fixture, the test contract is the CDO;
///      Market: Junior 1000, Senior 4000, de-peg to 0.5, 50% of Senior exits, then re-peg to 1
abstract contract ChunkedSeniorDepegExitsTests is ValuationInsuranceFixture {

    struct Outcome {
        uint256 srtEffBeforeRepeg;
        uint256 jrtAfterRepeg;
        uint256 srtAfterRepeg;
    }

    function _exitSenior(uint256 out) internal {
        uint256 slice = accounting.updateBalanceFlow(0, 0, 0, out);
        // The CDO pays the coverage slice from the insurance vault and the rest from the strategy
        mockStrategyTvl -= out - slice;
    }

    function _run(uint256 exits) internal returns (Outcome memory o) {
        uint256 snap = vm.snapshotState();

        // Fixture seeds Junior 1000 and Senior 1000, add 3000 Senior
        mockStrategyTvl = 5000e18;
        accounting.updateBalanceFlow(0, 0, 3000e18, 0);

        accounting.setValuationPrice(0.5e18);
        (, uint256 srtEff,) = accounting.totalAssets();

        // Half of Senior leaves, in `exits` equal redemptions
        uint256 out = srtEff / 2 / exits;
        for (uint256 i; i < exits; ++i) {
            _exitSenior(out);
        }
        (, o.srtEffBeforeRepeg,) = accounting.totalAssets();

        accounting.setValuationPrice(1e18);
        o.jrtAfterRepeg = accounting.jrtBaseNav();
        o.srtAfterRepeg = accounting.srtBaseNav();

        vm.revertToState(snap);
    }

    function _log(string memory label, Outcome memory o) internal pure {
        console.log(label);
        console.log("  remaining senior effective before re-peg", o.srtEffBeforeRepeg);
        console.log("  junior base after re-peg                ", o.jrtAfterRepeg);
        console.log("  remaining senior base after re-peg      ", o.srtAfterRepeg);
    }

    function test_ChunkedSeniorDepegExits_matchSingleExit_NoInsurancePool() public {
        accounting.setInsurancePool(IInsurancePool(address(0)));

        // Top-up needed 4000, Junior pledges 999: Senior effective 4999
        Outcome memory single = _run(1);
        Outcome memory chunked = _run(10);
        _log("one exit of 2499.5", single);
        _log("ten exits of 249.95", chunked);

        // Identical while the de-peg lasts
        assertApproxEqAbs(single.srtEffBeforeRepeg, 2499.5e18, 1e6);
        assertApproxEqAbs(chunked.srtEffBeforeRepeg, 2499.5e18, 1e6);

        // Every Senior component leaves pro rata: after re-peg the remaining Seniors hold their 2000 of
        // principal and Junior keeps 500.5, however the redemption was chunked
        assertApproxEqAbs(single.srtAfterRepeg, 2000e18, 1e6);
        assertApproxEqAbs(single.jrtAfterRepeg, 500.5e18, 1e6);
        assertApproxEqAbs(chunked.srtAfterRepeg, single.srtAfterRepeg, 1e6, "chunking moved Senior");
        assertApproxEqAbs(chunked.jrtAfterRepeg, single.jrtAfterRepeg, 1e6, "chunking moved Junior");
    }

    function test_ChunkedSeniorDepegExits_matchSingleExit_WithDepegCredit() public {
        // Top-up needed 4000, Junior pledges 999, Symbiotic credit 3001: Senior effective 8000
        Outcome memory single = _run(1);
        Outcome memory chunked = _run(10);
        _log("one exit of 4000", single);
        _log("ten exits of 400", chunked);

        assertApproxEqAbs(single.srtEffBeforeRepeg, 4000e18, 1e6);
        assertApproxEqAbs(chunked.srtEffBeforeRepeg, 4000e18, 1e6);

        assertApproxEqAbs(single.srtAfterRepeg, 2000e18, 1e6);
        assertApproxEqAbs(single.jrtAfterRepeg, 500.5e18, 1e6);
        assertApproxEqAbs(chunked.srtAfterRepeg, single.srtAfterRepeg, 1e6, "chunking moved Senior");
        assertApproxEqAbs(chunked.jrtAfterRepeg, single.jrtAfterRepeg, 1e6, "chunking moved Junior");
    }
}

contract ChunkedSeniorDepegExitsAccountingTest is ChunkedSeniorDepegExitsTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new Accounting(18)),
            abi.encodeWithSelector(
                Accounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(0))
            )
        ));
    }
}

contract ChunkedSeniorDepegExitsDiscreteTest is ChunkedSeniorDepegExitsTests {
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

contract ChunkedSeniorDepegExitsDYSTest is ChunkedSeniorDepegExitsTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new DYSAccounting(18, false, false, false, true, false)),
            abi.encodeWithSelector(
                DYSAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        ));
    }
}

contract ChunkedSeniorDepegExitsMTMTest is ChunkedSeniorDepegExitsTests {
    function _deployAccounting() internal override returns (address) {
        return address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, true, false, true, true, true)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        ));
    }
}
