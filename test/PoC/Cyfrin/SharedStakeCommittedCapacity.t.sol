// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { DiscreteAccounting } from "../../../contracts/tranches/DiscreteAccounting.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { InsuranceMiddleware } from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { IStrataAccounting } from "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { IInsurancePool } from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockOracleAdapter } from "../../../contracts/test/MockOracleAdapter.sol";

/// Minimal AppAdapter: one slashable stake shared by every market of the middleware.
contract SharedStakeAdapter {
    address public asset;
    uint256 public slashable;
    constructor(address asset_) { asset = asset_; }
    function setSlashable(uint256 amount) external { slashable = amount; }
    function slash(uint256 amount) external {
        uint256 executed = amount > slashable ? slashable : amount;
        require(executed > 0, "InsufficientSlash");
        slashable -= executed;
    }
    function release(uint256 amount) external { slashable -= amount > slashable ? slashable : amount; }
}

/// Second market's CDO: reports its strategy TVL and forwards onlyCDO calls to its Accounting.
contract PocCdo {
    uint256 public tvl;
    function setTvl(uint256 tvl_) external { tvl = tvl_; }
    function totalStrategyAssets() external view returns (uint256) { return tvl; }
    function totalStrategyAssets(uint256, uint256) external view returns (uint256) { return tvl; }
    function totalStrategyAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        return (tvl, block.timestamp, tvl, block.timestamp);
    }
    function exec(address target, bytes calldata data) external returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) {
            assembly { revert(add(result, 32), mload(result)) }
        }
    }
}

/// @notice Regression adapted from Cyfrin: funded claims must not reserve shared stake again.
contract SharedStakeCommittedCapacityTest is Test {
    uint256 constant UNIBTC_PRICE = 60_000e18; // $60k, 18-dec price
    uint256 constant BUFFER_BPS = 5_000;       // 50%, MAX_BUFFER_BPS

    address owner = makeAddr("owner");
    InsuranceMiddleware middleware;
    SharedStakeAdapter adapter;
    MockERC20 usde;
    MockERC20 unibtc;

    Accounting accountingA;
    uint256 tvlA;

    PocCdo cdoB;
    Accounting accountingB;

    function totalStrategyAssets() external view returns (uint256) {
        return tvlA;
    }

    function totalStrategyAssets(uint256, uint256) external view returns (uint256) { return tvlA; }
    function totalStrategyAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        return (tvlA, block.timestamp, tvlA, block.timestamp);
    }
    function _navLossClaim() internal pure virtual returns (uint256) { return 501e18; }
    function _implementation() internal virtual returns (address) { return address(new Accounting(18)); }

    function setUp() public {
        usde = new MockERC20("USDe", 18);
        unibtc = new MockERC20("uniBTC", 8);
        adapter = new SharedStakeAdapter(address(unibtc));

        MockOracleAdapter oracle = new MockOracleAdapter();
        oracle.setPrice(address(unibtc), UNIBTC_PRICE, 18); // USDe defaults to $1

        AccessControlManager acm = new AccessControlManager(address(this));
        middleware = InsuranceMiddleware(address(new ERC1967Proxy(
            address(new InsuranceMiddleware()),
            abi.encodeCall(InsuranceMiddleware.initialize, (owner, address(acm), address(adapter), address(oracle)))
        )));

        // Market A: this contract is the CDO.
        accountingA = _deployAccounting(acm, address(this));
        vm.prank(owner);
        middleware.setMarket(address(this), IStrataAccounting(address(accountingA)), address(usde), BUFFER_BPS, true);
        accountingA.setInsurancePool(IInsurancePool(address(middleware)));
        tvlA = 2000e18;
        accountingA.updateBalanceFlow(1000e18, 0, 1000e18, 0);

        // Market B: PocCdo is the CDO, sharing the same middleware and stake.
        cdoB = new PocCdo();
        accountingB = _deployAccounting(acm, address(cdoB));
        vm.prank(owner);
        middleware.setMarket(address(cdoB), IStrataAccounting(address(accountingB)), address(usde), BUFFER_BPS, true);
        cdoB.exec(address(accountingB), abi.encodeCall(Accounting.setInsurancePool, (IInsurancePool(address(middleware)))));
        cdoB.setTvl(2000e18);
        cdoB.exec(address(accountingB), abi.encodeCall(Accounting.updateBalanceFlow, (1000e18, 0, 1000e18, 0)));
    }

    function _deployAccounting(AccessControlManager acm, address cdo) internal returns (Accounting) {
        return Accounting(address(new ERC1967Proxy(
            _implementation(),
            abi.encodeWithSelector(
                Accounting.initialize.selector,
                address(this), address(acm), IStrataCDO(cdo), IAprPairFeed(address(new MockAprPairFeed()))
            )
        )));
    }

    /// uniBTC (8 dec) -> base (USDe, $1, 18 dec) at $60k, no buffer; mirrors the middleware's _toBaseAsset.
    function _toBase(uint256 vault) internal pure returns (uint256) {
        return vault * UNIBTC_PRICE / 1e8;
    }

    /// Strips the 50% buffer: the base coverage a vault amount can back.
    function _debuffered(uint256 base) internal pure returns (uint256) {
        return base * 10_000 / (10_000 + BUFFER_BPS);
    }

    function _pending(address cdo) internal view returns (uint256 pending) {
        (,,, pending,,) = middleware.markets(cdo);
    }

    /// Base coverage the live stake can actually back for a 50%-buffer market, ignoring any reservation.
    function _liveCapacityBase() internal view returns (uint256) {
        return _debuffered(_toBase(adapter.slashable()));
    }

    /// B's strategy drops 2000 -> 700: Junior absorbs 999 (down to its 1-asset floor), no reserve,
    /// so 301 is Senior-bound and requested from the shared pool.
    function _lossOnB() internal {
        cdoB.setTvl(700e18);
        cdoB.exec(address(accountingB), abi.encodeWithSignature("updateAccounting()"));
    }

    /// Funding A must preserve the capacity available to B.
    function test_fundedClaimDoesNotReserveOtherMarketsCapacity() public {
        adapter.setSlashable(2_000_000); // 0.02 uniBTC shared stake (~$1,200)

        // A de-pegs to 0.40: 501 claim, buffered 0.012525 uniBTC slashed synchronously.
        accountingA.setValuationPrice(0.4e18);
        assertEq(accountingA.insuranceAmount(), 501e18);
        assertEq(adapter.slashable(), 2_000_000 - 1_252_500);

        // Burner swaps the 0.012525 uniBTC to ~751.5 USDC and funds it. StrataCDO.fundInsuranceClaim converts it
        // to base at valuationPrice (751.5 / 0.40 = 1878.75) and confirms that to the middleware; pending -> 0.
        middleware.confirmInsuranceClaimFunding(address(this), 751.5e18 * 1e18 / 0.4e18);
        assertEq(_pending(address(this)), 0, "A's slash fully funded");
        // The claim stays open until A's Seniors redeem and are paid from the insurance vault.
        assertEq(accountingA.insuranceAmount(), 501e18);

        // Nothing is left to slash for A, and 0.007475 uniBTC (~$298.99 of coverage) is live and unowed.
        uint256 liveCapacity = _liveCapacityBase();
        assertApproxEqAbs(liveCapacity, 299e18, 1e6);

        // A's funded claim is already backed, so B can use the remaining live stake.
        uint256 offeredB = middleware.request(address(cdoB), type(uint128).max);
        emit log_named_decimal_uint("live stake can back (USDe)", liveCapacity, 18);
        emit log_named_decimal_uint("B offered (USDe)", offeredB, 18);
        assertEq(offeredB, liveCapacity, "funding does not reserve live stake again");

        // B receives 299 of coverage and Senior absorbs only the remaining 2.
        _lossOnB();
        assertApproxEqAbs(accountingB.insuranceAmount(), 299e18, 1e6);
        assertApproxEqAbs(accountingB.srtBaseNav(), 1499e18 - _navLossClaim(), 1e6);
        assertLe(adapter.slashable(), 1, "at most one vault unit remains after conversion");
    }
    function _assertBacked() internal view {
        assertEq(middleware.slashedClaimBase(address(this)), accountingA.insuranceAmount());
    }

    function test_repegThenDeeperLossDoesNotReuseSettledBacking() public {
        adapter.setSlashable(100_000_000);
        accountingA.setValuationPrice(0.4e18);
        _assertBacked();
        middleware.confirmInsuranceClaimFunding(address(this), 1000e18);
        accountingA.setValuationPrice(0.5e18);
        assertEq(accountingA.insuranceAmount(), 1e18);
        _assertBacked();
        accountingA.setValuationPrice(0.4e18);
        assertEq(accountingA.insuranceAmount(), 501e18);
        _assertBacked();
        vm.expectRevert(InsuranceMiddleware.NoSlashableAmount.selector);
        vm.prank(owner);
        middleware.slash(address(this));
        accountingA.setValuationPrice(1e18);
        _assertBacked();
        assertEq(middleware.slashedClaimBase(address(this)), 0);
    }

    function test_recoveryThenNewNavLossTracksOnlyOpenBacking() public {
        adapter.setSlashable(100_000_000);
        tvlA = 500e18;
        accountingA.updateAccounting();
        assertEq(accountingA.insuranceAmount(), _navLossClaim());
        _assertBacked();
        middleware.confirmInsuranceClaimFunding(address(this), 1000e18);
        tvlA = 600e18;
        accountingA.updateAccounting();
        assertEq(accountingA.insuranceAmount(), _navLossClaim() - 100e18);
        _assertBacked();
        tvlA = 500e18;
        accountingA.updateAccounting();
        assertEq(accountingA.insuranceAmount(), _navLossClaim());
        _assertBacked();
    }

    function test_redemptionThenNewLossTracksOnlyOpenBacking() public {
        adapter.setSlashable(100_000_000);
        tvlA = 500e18;
        accountingA.updateAccounting();
        uint256 paid = accountingA.updateBalanceFlow(0, 0, 0, 100e18);
        assertEq(paid, _navLossClaim() / 10);
        tvlA -= 100e18 - paid;
        assertEq(accountingA.insuranceAmount(), _navLossClaim() - paid);
        _assertBacked();
        tvlA -= 100e18;
        accountingA.updateAccounting();
        assertEq(accountingA.insuranceAmount(), _navLossClaim() - paid + 100e18);
        _assertBacked();
    }

}
contract SharedStakeDiscreteTest is SharedStakeCommittedCapacityTest {
    function _navLossClaim() internal pure override returns (uint256) { return 500e18; }
    function _implementation() internal override returns (address) { return address(new DiscreteAccounting(18, false)); }
}
contract SharedStakeDYSTest is SharedStakeCommittedCapacityTest {
    function _implementation() internal override returns (address) { return address(new DYSAccounting(18, false, false, false, true, false)); }
}
contract SharedStakeMTMTest is SharedStakeCommittedCapacityTest {
    function _implementation() internal override returns (address) { return address(new MTMAccounting(18, false, true, false, true, true, true)); }
}
