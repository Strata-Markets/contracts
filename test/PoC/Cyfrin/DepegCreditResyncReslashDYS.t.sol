// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { InsuranceMiddleware } from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { IInsurancePool } from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import { IStrataAccounting } from "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockOracleAdapter } from "../../../contracts/test/MockOracleAdapter.sol";
import { MockAppAdapter } from "../../symbiotic/NetworkMiddleware.t.sol";

interface IDYSResyncAccounting {
    function setValuationPrice(uint128 price) external returns (bool);
    function setInsurancePool(IInsurancePool pool) external;
    function setFloorRate(uint256 rate) external;
    function updateBalanceFlow(uint256, uint256, uint256, uint256) external returns (uint256);
    function updateAccounting() external;
    function insuranceAmount() external view returns (uint256);
    function srtInsuranceFundNav() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
    function jrtBaseNav() external view returns (uint256);
}

/// @notice Real DYSAccounting + real InsuranceMiddleware; the test contract plays the CDO, the strategy and the APR feed
///         MockAppAdapter stands in for the Symbiotic app adapter; the vault asset is priced at $1 so vault units == USD
///         Default risk parameters; every accounting update sees a strategy NAV change, so each one reconciles
///         No slash proceeds are funded into the insurance vault during the test (the vault is unset)
contract DepegDYSRealizedPnLReslashTest is Test {
    IDYSResyncAccounting a;
    InsuranceMiddleware middleware;
    MockAppAdapter adapter;
    AccessControlManager acm;
    uint256 tvl; // strategy NAV

    uint128 constant PRICE = 0.4e18;

    // CDO / strategy / APR feed surface used by the accounting
    function totalStrategyAssets() external view returns (uint256) { return tvl; }
    function totalStrategyAssets(uint256, uint256) external view returns (uint256) { return tvl; }
    function getRate() external pure returns (uint256) { return 1e18; }
    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound({ aprTarget: 0, aprBase: 0, updatedAt: uint64(block.timestamp), answeredInRound: 1 });
    }

    function _setUpMarket(uint256 juniorIn, uint256 seniorIn) internal {
        vm.mockCall(address(this), abi.encodeWithSignature("insuranceVault()"), abi.encode(address(0)));
        vm.warp(1_750_000_000);
        acm = new AccessControlManager(address(this));
        MockERC20 base = new MockERC20("BASE", 18);
        MockERC20 coll = new MockERC20("COLL", 18);
        adapter = new MockAppAdapter(address(coll));
        adapter.setSlashable(1_000_000e18);
        MockOracleAdapter oracle = new MockOracleAdapter();
        middleware = InsuranceMiddleware(address(new ERC1967Proxy(
            address(new InsuranceMiddleware(address(adapter))),
            abi.encodeCall(InsuranceMiddleware.initialize, (address(this), address(acm), address(oracle)))
        )));
        // benchmark off, navAtReconciliation off, rates off, juniorCoversPaidSrtProjection on, conservative off
        a = IDYSResyncAccounting(address(new ERC1967Proxy(
            address(new DYSAccounting(18, false, false, false, true, false)),
            abi.encodeWithSignature("initialize(address,address,address,address)",
                address(this), address(acm), address(this), address(this))
        )));
        middleware.setMarket(address(this), IStrataAccounting(address(a)), address(base), 0, true);
        a.setInsurancePool(IInsurancePool(address(middleware)));
        tvl = juniorIn + seniorIn;
        a.updateBalanceFlow(juniorIn, 0, seniorIn, 0);
    }

    function _slashed() internal view returns (uint256 s) { (,, s,,,) = middleware.markets(address(this)); }

    function _update(uint256 newTvl) internal {
        vm.warp(block.timestamp + 1 hours);
        tvl = newTvl;
        a.updateAccounting();
    }

    /// Junior 500, Senior 1,500, floor 1%/day, push to 0.4. Senior's share of realized PnL (~45%) exceeds the price,
    /// so a realized loss Senior shares under the floor releases claim and the gain that recovers it re-books the claim
    function test_PoC_DYSRealizedLossThenGainReusesUnfundedClaim() public {
        _setUpMarket(500e18, 1_500e18);
        a.setFloorRate(0.01e18); // Senior shares realized losses (floor 1%/day)
        a.setValuationPrice(PRICE); // de-peg push: 1,500 / 0.4 - 1,500 - 499 = 1,751 base claim
        uint256 claim0 = a.insuranceAmount();
        uint256 slashed0 = _slashed();
        assertEq(claim0, 1_751e18, "push books 1,751 base");
        assertEq(slashed0, 700.4e18, "slashed 700.4 USD");

        uint256 settled = tvl;
        uint256 claim = claim0;
        uint256 released;
        for (uint256 i; i < 5; ++i) {
            _update(settled - 40e18); // realized 2% strategy loss, Senior shares it
            uint256 afterLoss = a.insuranceAmount();
            assertLt(afterLoss, claim, "Senior-shared realized loss releases valuation credit and claim");
            released += claim - afterLoss;
            uint256 slashedBefore = _slashed();

            _update(settled); // realized gain back to the same strategy NAV
            claim = a.insuranceAmount();
            assertGt(claim, afterLoss, "gain re-books the released claim");
            assertApproxEqAbs(_slashed(), claim * PRICE / 1e18 > slashedBefore ? claim * PRICE / 1e18 : slashedBefore, 2, "slash only beyond existing pending backing");
        }

        uint256 freshUsd = _slashed() - slashed0;
        uint256 claimGrowthUsd = (claim > claim0 ? claim - claim0 : 0) * PRICE / 1e18;
        console.log("claim before / after (base)  ", claim0, claim);
        console.log("released over 5 cycles (base)", released);
        console.log("slashed before / after (USD) ", slashed0, _slashed());
        console.log("fresh slash / claim growth (USD)", freshUsd, claimGrowthUsd);
        // Released backing is reused; only net claim growth requires fresh collateral.
        assertApproxEqAbs(freshUsd, claimGrowthUsd, 10, "only claim growth needs fresh collateral");
    }

    /// Junior 1,000, Senior 1,000, no floor, push to 0.4. Senior's share of realized PnL (~30%) is below the price,
    /// so a realized gain releases claim, and a realized loss (all on Junior without a floor) re-books it
    function test_PoC_DYSRealizedGainThenLossReusesUnfundedClaim() public {
        _setUpMarket(1_000e18, 1_000e18);
        a.setValuationPrice(PRICE); // 1,000 / 0.4 - 1,000 - 999 = 501 base claim
        uint256 claim0 = a.insuranceAmount();
        uint256 slashed0 = _slashed();
        assertEq(claim0, 501e18, "push books 501 base");
        assertEq(slashed0, 200.4e18, "slashed 200.4 USD");

        uint256 settled = tvl;
        uint256 claim = claim0;
        uint256 released;
        for (uint256 i; i < 5; ++i) {
            _update(settled + 40e18); // realized gain
            uint256 afterGain = a.insuranceAmount();
            assertLt(afterGain, claim, "realized gain releases valuation credit and claim");
            released += claim - afterGain;
            uint256 slashedBefore = _slashed();

            _update(settled); // realized loss back to the same strategy NAV
            claim = a.insuranceAmount();
            assertGt(claim, afterGain, "loss re-books the released claim");
            assertApproxEqAbs(_slashed(), claim * PRICE / 1e18 > slashedBefore ? claim * PRICE / 1e18 : slashedBefore, 2, "slash only beyond existing pending backing");
        }

        uint256 freshUsd = _slashed() - slashed0;
        uint256 claimGrowthUsd = (claim > claim0 ? claim - claim0 : 0) * PRICE / 1e18;
        console.log("claim before / after (base)  ", claim0, claim);
        console.log("released over 5 cycles (base)", released);
        console.log("slashed before / after (USD) ", slashed0, _slashed());
        console.log("fresh slash / claim growth (USD)", freshUsd, claimGrowthUsd);
        assertApproxEqAbs(freshUsd, claimGrowthUsd, 10, "only claim growth needs fresh collateral");
    }
}
