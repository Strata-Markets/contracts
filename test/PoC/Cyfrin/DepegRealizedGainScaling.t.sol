// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { InsuranceMiddleware } from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { IInsurancePool } from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import { IStrataAccounting } from "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockOracleAdapter } from "../../../contracts/test/MockOracleAdapter.sol";
import { MockAppAdapter } from "../../symbiotic/NetworkMiddleware.t.sol";

import { IRiskPremiumModel } from "../../../contracts/tranches/accounting/premium/IRiskPremiumModel.sol";
import { RiskPremiumStatic } from "../../../contracts/tranches/accounting/premium/RiskPremiumStatic.sol";

interface IRealizedGainAccounting {
    function setValuationPrice(uint128 price) external returns (bool);
    function setInsurancePool(IInsurancePool pool) external;
    function setRiskModel(IRiskPremiumModel) external;
    function updateBalanceFlow(uint256, uint256, uint256, uint256) external returns (uint256);
    function updateAccounting() external;
    function setUnderwriterFeeBps(uint256 bps) external;
    function underwriterFeeNav() external view returns (uint256);
    function jrtBaseNav() external view returns (uint256);
    function reserveNav() external view returns (uint256);
    function insuranceAmount() external view returns (uint256);
    function srtInsuranceFundNav() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
}

/// @dev Real accounting + real InsuranceMiddleware, the test contract plays the CDO, the strategy and the APR feed
///      MockAppAdapter stands in for the Symbiotic app adapter; vault asset priced at $1 so vault units == USD
abstract contract RealizedGainFixture is Test {
    IRealizedGainAccounting a;
    InsuranceMiddleware middleware;
    MockAppAdapter adapter;
    AccessControlManager acm;
    uint256 tvl; // settled strategy NAV
    uint256 rate = 1e18;

    function totalStrategyAssets() external view returns (uint256) { return tvl; }
    function totalStrategyAssets(uint256, uint256) external view returns (uint256) { return tvl; }
    function totalStrategyAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        return (tvl, block.timestamp, tvl, block.timestamp);
    }
    function getRate() external view returns (uint256) { return rate; }
    function strategy() external view returns (address) { return address(this); }
    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound({ aprTarget: 0, aprBase: 100_000_000_000, updatedAt: uint64(block.timestamp), answeredInRound: 1 });
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
        a = IRealizedGainAccounting(address(new ERC1967Proxy(_impl(), abi.encodeWithSignature(
            "initialize(address,address,address,address)", address(this), address(acm), address(this), address(this)))));
        middleware.setMarket(address(this), IStrataAccounting(address(a)), address(base), 0, true);
        a.setInsurancePool(IInsurancePool(address(middleware)));
        tvl = 2000e18;
        a.updateBalanceFlow(1000e18, 0, 1000e18, 0); // Junior 1,000 / Senior 1,000
    }

    function _slashed() internal view returns (uint256 s) { (,, s,,,) = middleware.markets(address(this)); }

    /// @dev Senior 1,000, Junior 1,000, rp 10%, covered de-peg push to 0.4 (claim 501 base, 200.4 USD slashed),
    ///      then a 100 realized strategy gain observed at the next reconciliation
    function _realizedGainDuringCoveredDepeg()
        internal
        returns (uint256 seniorGain, uint256 claim0, uint256 claim1, uint256 slashed0, uint256 slashed1)
    {
        a.setRiskModel(new RiskPremiumStatic(UD60x18.wrap(0.1e18)));
        a.setValuationPrice(0.4e18); // Junior exhausted, Symbiotic covers the rest
        claim0 = a.insuranceAmount();
        slashed0 = _slashed();
        assertEq(claim0, 501e18);
        assertEq(slashed0, 200.4e18);
        uint256 principal0 = a.srtBaseNav() - a.srtInsuranceFundNav();
        vm.warp(block.timestamp + 1 days);
        tvl += 100e18; // realized strategy gain
        rate = 1.1e18;
        a.updateAccounting();
        seniorGain = a.srtBaseNav() - a.srtInsuranceFundNav() - principal0;
        claim1 = a.insuranceAmount();
        slashed1 = _slashed();
        console.log("Senior realized gain (base)  ", seniorGain);
        console.log("claim before / after (base)  ", claim0, claim1);
        console.log("slashed before / after (USD) ", slashed0, slashed1);
    }

    function _normalGain() internal pure virtual returns (uint256) { return 45e18; }

    /// @dev The normal 45-asset allocation is scaled to 18 at $0.40 before valuation protection.
    function _assertRealizedGainScaled() internal {
        (uint256 seniorGain, uint256 claim0, uint256 claim1, uint256 slashed0, uint256 slashed1) = _realizedGainDuringCoveredDepeg();
        assertEq(seniorGain, _normalGain() * 4 / 10, "Senior gain scaled by valuation price");
        assertLe(claim1, claim0, "gain must not increase the insurance claim");
        assertEq(slashed1, slashed0, "no additional collateral slashed");
    }
}

abstract contract RealizedSplitFixture is RealizedGainFixture {
    function test_RealizedGainAtParIsUnchanged() public {
        a.setRiskModel(new RiskPremiumStatic(UD60x18.wrap(0.1e18)));
        uint256 seniorBefore = a.srtBaseNav();
        vm.warp(block.timestamp + 1 days);
        tvl += 100e18;
        rate = 1.1e18;
        a.updateAccounting();
        assertEq(a.srtBaseNav() - seniorBefore, _normalGain());
        assertEq(a.insuranceAmount(), 0);
        assertEq(_slashed(), 0);
    }

    function test_UnderwriterFeeUsesScaledGain() public {
        a.setUnderwriterFeeBps(0.1e18);
        (uint256 gain, uint256 claim0, uint256 claim1, uint256 slash0, uint256 slash1) = _realizedGainDuringCoveredDepeg();
        uint256 gross = _normalGain() * 4 / 10;
        uint256 fee = gross / 100; // 10% premium * 10% underwriter fee.
        assertEq(a.underwriterFeeNav(), fee);
        assertEq(gain, gross - fee);
        assertLe(claim1, claim0);
        assertEq(slash1, slash0);
        assertEq(a.jrtBaseNav() + a.srtBaseNav() + a.reserveNav() + fee, tvl + claim1);
    }
}

contract RealizedGainDYSTest is RealizedSplitFixture {
    function _impl() internal override returns (address) {
        // deployment defaults: benchmark off, navAtReconciliation off, rates off, juniorCoversPaidSrtProjection on,
        // conservative off
        return address(new DYSAccounting(18, false, false, false, true, false));
    }

    function test_DYSRealizedGainScaledDuringDepeg() public {
        _assertRealizedGainScaled();
    }
}

contract RealizedGainMTMTest is RealizedSplitFixture {
    function _impl() internal override returns (address) {
        // benchmark off, navAtReconciliation on (required by MTM projection), rates off,
        // juniorCoversPaidSrtProjection on, conservative off, MTM projection on
        return address(new MTMAccounting(18, false, true, false, true, false, true));
    }

    function test_MTMRealizedGainScaledDuringDepeg() public {
        _assertRealizedGainScaled();
    }
}

/// @notice Control: continuous Accounting caps Senior's gain during the de-peg, so nothing new is slashed
contract RealizedGainAccountingControlTest is RealizedGainFixture {
    function _impl() internal override returns (address) {
        return address(new Accounting(18));
    }

    function test_PoC_AccountingRealizedGainDuringDepegControl() public {
        (, uint256 claim0, uint256 claim1, uint256 slashed0, uint256 slashed1) = _realizedGainDuringCoveredDepeg();
        assertEq(claim1, claim0, "claim unchanged at 501");
        assertEq(slashed1, slashed0, "nothing new slashed");
    }
}

contract RealizedGainDYSRatesTest is RealizedSplitFixture {
    function _impl() internal override returns (address) {
        return address(new DYSAccounting(18, false, false, true, true, false));
    }
    function _normalGain() internal pure override returns (uint256) { return 90e18; }
    function test_RateGainScaledDuringDepeg() public { _assertRealizedGainScaled(); }
}

contract RealizedGainMTMRatesTest is RealizedSplitFixture {
    function _impl() internal override returns (address) {
        return address(new MTMAccounting(18, false, true, true, true, false, true));
    }
    function _normalGain() internal pure override returns (uint256) { return 90e18; }
    function test_RateGainScaledDuringDepeg() public { _assertRealizedGainScaled(); }
}
