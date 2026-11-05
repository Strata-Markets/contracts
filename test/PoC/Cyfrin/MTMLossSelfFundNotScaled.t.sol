// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { InsuranceMiddleware } from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { IInsurancePool } from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import { IStrataAccounting } from "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockOracleAdapter } from "../../../contracts/test/MockOracleAdapter.sol";
import { MockAppAdapter } from "../../symbiotic/NetworkMiddleware.t.sol";

import {RiskPremiumStatic} from "../../../contracts/tranches/accounting/premium/RiskPremiumStatic.sol";
import {IRiskPremiumModel} from "../../../contracts/tranches/accounting/premium/IRiskPremiumModel.sol";

interface ISelfFundAccounting {
    function setValuationPrice(uint128 price) external returns (bool);
    function setInsurancePool(IInsurancePool pool) external;
    function setRiskModel(IRiskPremiumModel) external;
    function updateBalanceFlow(uint256, uint256, uint256, uint256) external returns (uint256);
    function updateAccounting() external;
    function srtInsuranceFundNav() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
    function srtFundNav() external view returns (uint256);
    function srtFundedGrossNav() external view returns (uint256);
    function totalAssets() external view returns (uint256, uint256, uint256);
}

/// @dev Real accounting + real InsuranceMiddleware, the test contract plays the CDO, the strategy and the APR feed
///      MockAppAdapter stands in for the Symbiotic app adapter; vault asset priced at $1
abstract contract SelfFundFixture is Test {
    ISelfFundAccounting a;
    InsuranceMiddleware middleware;
    MockAppAdapter adapter;
    AccessControlManager acm;
    uint256 tvl; // settled strategy NAV
    uint256 mtm; // live mark (0 = same as tvl)
    int64 aprTarget;

    function totalStrategyAssets() external view returns (uint256) { return tvl; }
    function totalStrategyAssets(uint256, uint256) external view returns (uint256) { return tvl; }
    function totalStrategyAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        if (mtm == 0 || mtm == tvl) return (tvl, block.timestamp, tvl, block.timestamp);
        return (tvl, block.timestamp - 1, mtm, block.timestamp);
    }
    function getRate() external pure returns (uint256) { return 1e18; }
    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound({ aprTarget: aprTarget, aprBase: 100_000_000_000, updatedAt: uint64(block.timestamp), answeredInRound: 1 });
    }

    function _impl() internal virtual returns (address);

    function setUp() public {
        vm.mockCall(address(this), abi.encodeWithSignature("insuranceVault()"), abi.encode(address(0)));
        vm.warp(1_750_000_000);
        acm = new AccessControlManager(address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        MockERC20 base = new MockERC20("BASE", 18);
        MockERC20 coll = new MockERC20("COLL", 18);
        adapter = new MockAppAdapter(address(coll));
        adapter.setSlashable(1_000_000e18);
        MockOracleAdapter oracle = new MockOracleAdapter();
        middleware = InsuranceMiddleware(address(new ERC1967Proxy(
            address(new InsuranceMiddleware(address(adapter))),
            abi.encodeCall(InsuranceMiddleware.initialize, (address(this), address(acm), address(oracle)))
        )));
        a = ISelfFundAccounting(address(new ERC1967Proxy(_impl(), abi.encodeWithSignature(
            "initialize(address,address,address,address)", address(this), address(acm), address(this), address(this)))));
        middleware.setMarket(address(this), IStrataAccounting(address(a)), address(base), 0, true);
        a.setInsurancePool(IInsurancePool(address(middleware)));
        tvl = 2000e18;
        a.updateBalanceFlow(1000e18, 0, 1000e18, 0); // Junior 1,000 / Senior 1,000
    }
}

/// @notice MTMAccounting with MTM projection, original scenario (Senior 100, Junior at floor, push 0.5 with
///         Symbiotic credit 100, Senior entry 200 at 0.5, pool exhausted, Senior absorbs a 100 loss)
contract MTMLossSelfFundNotScaledTest is SelfFundFixture {
    function _impl() internal override returns (address) {
        // benchmark off, navAtReconciliation on (required by MTM projection), rates off,
        // juniorCoversPaidSrtProjection on, conservative off, MTM projection on
        return address(new MTMAccounting(18, false, true, false, true, false, true));
    }

    function _run(bool lossSeenInMarkFirst) internal returns (uint256 gross, uint256 fund, uint256 seniorUsdAt07) {
        a.updateBalanceFlow(0, 999e18, 0, 900e18); // Junior 1 (floor), Senior 100
        tvl = 101e18;
        a.setValuationPrice(0.5e18); // Symbiotic credit 100
        assertEq(a.srtInsuranceFundNav(), 100e18);
        tvl += 200e18;
        a.updateBalanceFlow(0, 0, 200e18, 0); // Senior entry 200 at 0.5: gross = 200, USD fund = 100
        assertEq(a.srtFundedGrossNav(), 200e18);
        assertEq(a.srtFundNav(), 100e18);
        adapter.setSlashable(0);
        // Pending slash proceeds are reusable now; exclude all coverage to isolate an uninsured loss.
        vm.mockCall(address(middleware), abi.encodeWithSelector(IInsurancePool.request.selector), abi.encode(uint256(0)));
        vm.warp(block.timestamp + 6 hours);
        if (lossSeenInMarkFirst) {
            mtm = tvl - 100e18; // the loss appears in the live mark and an ordinary update observes it
            a.updateAccounting();
            vm.warp(block.timestamp + 6 hours);
        }
        tvl -= 100e18; // the same 100 loss is realized at reconciliation
        mtm = 0;
        a.updateAccounting();
        gross = a.srtFundedGrossNav();
        fund = a.srtFundNav();
        vm.clearMockedCalls();
        vm.mockCall(address(this), abi.encodeWithSignature("insuranceVault()"), abi.encode(address(0)));
        adapter.setSlashable(1_000_000e18); // stake available again for the next push
        a.setValuationPrice(0.7e18); // partial re-peg
        (, uint256 senior,) = a.totalAssets();
        seniorUsdAt07 = senior * 0.7e18 / 1e18;
        console.log("gross / fund after reconciliation", gross, fund);
        console.log("Senior at 0.70 (tokens / USD)    ", senior, seniorUsdAt07);
    }

    /// Control: the loss is only seen at reconciliation, so the trackers scale to ~133.3 and Senior is worth ~$160
    function test_PoC_MTMRealizedOnlyLossScalesTrackersControl() public {
        (uint256 gross, uint256 fund, uint256 seniorUsd) = _run(false);
        assertApproxEqAbs(gross, 133.333e18, 0.001e18, "gross scaled to ~133.3");
        assertApproxEqAbs(fund, 66.666666666666666666e18, 1e3, "USD basis scaled");
        assertApproxEqAbs(seniorUsd, 160e18, 1e3, "Senior ~$160 at 0.70");
    }

    /// A previously observed live loss scales the entry basis when it becomes realized.
    function test_MTMLossFirstSeenInMarkScalesTrackers() public {
        (uint256 gross, uint256 fund, uint256 seniorUsd) = _run(true);
        assertApproxEqAbs(gross, 133.333333333333333333e18, 1e3, "gross scales despite prior live loss");
        assertApproxEqAbs(fund, 66.666666666666666666e18, 1e3, "USD basis scales despite prior live loss");
        assertApproxEqAbs(seniorUsd, 160e18, 1e3, "same recovery value as reconciliation-only loss");
    }
}

/// @notice Unwinding positive APR projection must not scale entry trackers without settled principal loss.
contract DYSProjectionSelfFundWriteDownTest is SelfFundFixture {
    function _impl() internal virtual override returns (address) {
        // benchmark off, navAtReconciliation off, rates off, juniorCoversPaidSrtProjection on, conservative off
        return address(new DYSAccounting(18, false, false, false, true, false));
    }

    function test_unrealizedProjectionPreservesTrackers() public {
        a.setRiskModel(new RiskPremiumStatic(UD60x18.wrap(0.5e18)));
        aprTarget = 80_000_000_000; // 8% Senior target
        tvl += 3000e18;
        a.updateBalanceFlow(3000e18, 0, 0, 0); // ample Junior: no Symbiotic credit
        a.setValuationPrice(0.5e18);
        tvl += 100e18;
        a.updateBalanceFlow(0, 0, 100e18, 0); // Senior entry 100 at 0.5: gross = 100, USD fund = 50
        assertEq(a.srtFundedGrossNav(), 100e18);
        assertEq(a.srtFundNav(), 50e18);

        uint256 settled0 = a.srtBaseNav();
        vm.warp(block.timestamp + 1 days);
        a.updateAccounting(); // APR projection only
        uint256 withProjection = a.srtBaseNav();
        tvl += 1; // reconciliation with ~zero realized PnL (strategy flat for the day)
        a.updateAccounting();

        console.log("Senior settled / with projection / after", settled0, withProjection, a.srtBaseNav());
        console.log("gross / fund after one flat day         ", a.srtFundedGrossNav(), a.srtFundNav());
        assertGt(withProjection, settled0, "projection accrued");
        // No principal loss: unwinding positive projection must preserve both entry trackers.
        assertGe(a.srtBaseNav(), settled0, "no Senior principal loss");
        assertEq(a.srtFundedGrossNav(), 100e18, "no principal loss: gross unchanged");
        assertEq(a.srtFundNav(), 50e18, "no principal loss: USD basis unchanged");
    }
}

contract MTMProjectionSelfFundWriteDownTest is DYSProjectionSelfFundWriteDownTest {
    function _impl() internal override returns (address) {
        return address(new MTMAccounting(18, false, false, false, true, false, false));
    }
}
