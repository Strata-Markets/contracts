// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { InsuranceMiddleware } from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { IStrataAccounting } from "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { IInsurancePool } from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockOracleAdapter } from "../../../contracts/test/MockOracleAdapter.sol";
import { MockAppAdapter } from "../../symbiotic/NetworkMiddleware.t.sol";

// Regression adapted from the auditor PoC: same fixture, assertions changed to require the fix.
contract AuditorClaimUnwindRegressionTest is Test {
    uint256 constant SLASHABLE = 1_000_000e18;
    uint256 constant NAV0 = 2000e18;
    uint256 constant CLAIM = 501e18;

    Accounting accounting;
    InsuranceMiddleware middleware;
    MockAppAdapter adapter;
    MockOracleAdapter oracle;
    MockERC20 baseAsset;
    MockERC20 collateral;
    AccessControlManager acm;

    uint256 mockStrategyTvl;

    // ---------------------------------------------------------------- CDO callbacks

    function totalStrategyAssets() external view returns (uint256) {
        return mockStrategyTvl;
    }

    // ---------------------------------------------------------------- setup

    function setUp() public {
        acm = new AccessControlManager(address(this));

        baseAsset = new MockERC20("BASE", 18);
        collateral = new MockERC20("COLL", 18);
        adapter = new MockAppAdapter(address(collateral));
        adapter.setSlashable(SLASHABLE);
        oracle = new MockOracleAdapter(); // both assets default to $1

        middleware = InsuranceMiddleware(address(new ERC1967Proxy(
            address(new InsuranceMiddleware()),
            abi.encodeCall(InsuranceMiddleware.initialize, (address(this), address(acm), address(adapter), address(oracle)))
        )));

        accounting = Accounting(address(new ERC1967Proxy(
            address(new Accounting(18)),
            abi.encodeWithSelector(
                Accounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(0))
            )
        )));

        // This contract is the market CDO, the accounting is the only caller allowed into coverAndSlash
        middleware.setMarket(address(this), IStrataAccounting(address(accounting)), address(baseAsset), 0, true);
        accounting.setInsurancePool(IInsurancePool(address(middleware)));

        // Same fee configuration as the repo fixtures
        accounting.setReserveBps(0.1e18);
        accounting.setUnderwriterFeeBps(0.1e18);

        // Seed 1000 Jrt + 1000 Srt, as CDO.deposit() would book it
        mockStrategyTvl = NAV0;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
    }

    function _bookDepegClaim() internal {
        accounting.setValuationPrice(0.4e18);
        assertEq(accounting.insuranceAmount(), CLAIM, "de-peg claim booked");
        assertEq(accounting.nav(), NAV0, "valuation claim does not move nav");
        assertEq(accounting.feeWatermarkNav(), NAV0, "watermark sits at nav");
    }

    // ---------------------------------------------------------------- PoC

    function test_regression_gainAndViewsWorkWithReserve() public {
        _bookDepegClaim();
        // Valuation loss now disables fees; explicitly re-enable them to exercise the auditor's case.
        accounting.setReserveBps(0.1e18);
        uint256[7] memory gains = [uint256(9), 10, 100e18, CLAIM, 556666666666666666665, 600e18, 700e18];
        for (uint256 i; i < gains.length; i++) {
            uint256 snap = vm.snapshotState();
            mockStrategyTvl = NAV0 + gains[i];
            accounting.totalAssets();
            accounting.updateAccounting();
            assertEq(accounting.insuranceAmount(), CLAIM);
            assertEq(accounting.srtInsuranceFundNav(), CLAIM);
            assertEq(accounting.reserveNav(), gains[i] / 10);
            accounting.setReserveBps(0);
            accounting.setValuationPrice(1e18);
            assertEq(accounting.insuranceAmount(), 0);
            assertEq(accounting.srtInsuranceFundNav(), 0);
            assertEq(accounting.srtBaseNav(), 1000e18);
            assertEq(accounting.jrtBaseNav(), 1000e18 + gains[i] - gains[i] / 10);
            vm.revertToState(snap);
        }
    }
}
