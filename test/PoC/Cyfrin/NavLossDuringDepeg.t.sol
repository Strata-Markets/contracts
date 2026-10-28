// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UD60x18} from "@prb/math/src/ud60x18/ValueType.sol";
import {Accounting} from "../../../contracts/tranches/Accounting.sol";
import {DiscreteAccounting} from "../../../contracts/tranches/DiscreteAccounting.sol";
import {DYSAccounting} from "../../../contracts/tranches/DYSAccounting.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IAprPairFeed} from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import {Test} from "forge-std/Test.sol";
import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";
import {InsuranceMiddleware} from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import {IStrataAccounting} from
    "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import {IInsurancePool} from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import {MockERC20} from "../../../contracts/test/MockERC20.sol";
import {MockOracleAdapter} from "../../../contracts/test/MockOracleAdapter.sol";
import {MockAppAdapter} from "../../symbiotic/NetworkMiddleware.t.sol";

/// @dev The subset of the accounting ABI shared by Accounting, DiscreteAccounting, DYSAccounting and MTMAccounting
interface IDepegNavLossAccounting {
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
///      strategy/rate read the four accounting variants make. Both assets have 18 decimals; collateral is
///      priced at $1, base assets use valuationPrice, and bufferBps is 0
abstract contract DepegNavLossFixture is Test {
    uint256 constant ONE_ASSET = 1e18;
    uint256 constant SLASHABLE = 1_000_000e18;

    IDepegNavLossAccounting accounting;
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
        virtual
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
        oracle = new MockOracleAdapter(); // collateral defaults to $1

        middleware = InsuranceMiddleware(
            address(
                new ERC1967Proxy(
                    address(new InsuranceMiddleware(address(adapter))),
                    abi.encodeCall(
                        InsuranceMiddleware.initialize,
                        (address(this), address(acm), address(oracle))
                    )
                )
            )
        );

        accounting = IDepegNavLossAccounting(_deployAccounting());

        // This contract is the market CDO, the accounting is the only caller allowed into coverAndSlash
        middleware.setMarket(
            address(this), IStrataAccounting(address(accounting)), address(baseAsset), 0, true
        );
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
        return Math.saturatingSub(
            Math.saturatingSub(Math.mulDiv(1000e18, 1e18, price), 1000e18), 999e18
        );
    }
}

/// @notice Regressions adapted from the auditor PoCs: realized losses during a de-peg must
///         replenish Senior valuation coverage in the accounting update, before redemption.
/// @dev Runs all four engines against real middleware with mocked collateral and strategy NAV.
abstract contract NavLossDuringDepegTests is DepegNavLossFixture {
    function _assertWhole(uint128 price) internal view {
        (, uint256 senior,) = accounting.totalAssets();
        assertEq(senior, uint256(1000e18) * 1e18 / price);
        assertEq(middleware.slashedClaimBase(address(this)), accounting.insuranceAmount());
    }

    function test_lossCoveredWithoutPricePush() public {
        accounting.setValuationPrice(0.6e18);
        mockStrategyTvl = 1500e18;
        accounting.updateAccounting();
        _assertWhole(0.6e18);
        assertEq(_totalSlashed(), (uint256(1000e18) * 1e18 / 0.6e18 - 1499e18) * 0.6e18 / 1e18);
        uint256 slashed = _totalSlashed();
        accounting.updateAccounting();
        accounting.setValuationPrice(0.6e18);
        assertEq(_totalSlashed(), slashed, "no repeated slash");
    }

    function test_existingClaimAndRedemption() public {
        accounting.setValuationPrice(0.4e18);
        mockStrategyTvl = 1750e18;
        accounting.updateAccounting();
        _assertWhole(0.4e18);
        assertEq(accounting.insuranceAmount(), 751e18);
        uint256 paid = accounting.updateBalanceFlow(0, 0, 0, 250e18);
        assertEq(paid, 75.1e18);
        mockStrategyTvl -= 250e18 - paid;
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 675.9e18);
        assertEq(middleware.slashedClaimBase(address(this)), 675.9e18);
        assertEq(_totalSlashed(), 751e18 * 0.4e18 / 1e18);
        accounting.setValuationPrice(1e18);
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(accounting.srtBaseNav(), 900e18);
    }

    function test_recoveryAndRepeg() public {
        accounting.setValuationPrice(0.4e18);
        mockStrategyTvl = 1750e18;
        accounting.updateAccounting();
        assertEq(accounting.srtInsuranceFundNav(), 751e18);
        mockStrategyTvl = 2000e18;
        accounting.updateAccounting();
        assertEq(_totalSlashed(), 751e18 * 0.4e18 / 1e18);
        uint256 principal = accounting.srtBaseNav() - accounting.srtInsuranceFundNav();
        accounting.setValuationPrice(1e18);
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(accounting.srtInsuranceFundNav(), 0);
        assertEq(accounting.srtBaseNav(), principal);
        assertEq(middleware.slashedClaimBase(address(this)), 0);
    }

    function test_partialCapacity() public {
        accounting.setValuationPrice(0.4e18);
        adapter.setSlashable(40e18); // $40 covers only 100 base tokens at $0.40
        mockStrategyTvl = 1750e18;
        accounting.updateAccounting();
        (, uint256 senior,) = accounting.totalAssets();
        assertEq(senior, 2350e18);
        assertEq(accounting.insuranceAmount(), 601e18);
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 601e18);
    }

    function test_noPool() public {
        accounting.setValuationPrice(0.6e18);
        accounting.setInsurancePool(IInsurancePool(address(0)));
        mockStrategyTvl = 1500e18;
        accounting.updateAccounting();
        (, uint256 senior,) = accounting.totalAssets();
        assertEq(senior, 1499e18);
        assertEq(accounting.insuranceAmount(), 0);
    }

    function test_previewRemainsBelowSettlement() public {
        accounting.setValuationPrice(0.6e18);
        mockStrategyTvl = 1500e18;
        (, uint256 preview,) = accounting.totalAssets();
        assertEq(preview, 1499e18);
        accounting.updateAccounting();
        (, uint256 settled,) = accounting.totalAssets();
        assertGt(settled, preview, "valuation coverage is booked during the accounting update");
        _assertWhole(0.6e18);
    }

    function test_mixedClaimsKeepOnlyNavClaimAtRepeg() public {
        accounting.setValuationPrice(0.4e18);
        mockStrategyTvl = 750e18;
        accounting.updateAccounting();
        _assertWhole(0.4e18);
        uint256 navClaim = accounting.insuranceAmount() - accounting.srtInsuranceFundNav();
        assertGt(navClaim, 0);
        uint256 slashed = _totalSlashed();
        accounting.updateAccounting();
        assertEq(_totalSlashed(), slashed);
        accounting.setValuationPrice(1e18);
        assertEq(accounting.insuranceAmount(), navClaim);
        assertEq(accounting.srtInsuranceFundNav(), 0);
    }
}

contract NavLossDuringDepegAccountingTest is NavLossDuringDepegTests {
    function _deployAccounting() internal override returns (address) {
        return address(
            new ERC1967Proxy(
                address(new Accounting(18)),
                abi.encodeWithSelector(
                    Accounting.initialize.selector,
                    address(this),
                    address(acm),
                    IStrataCDO(address(this)),
                    IAprPairFeed(address(0))
                )
            )
        );
    }
}

contract NavLossDuringDepegDiscreteTest is NavLossDuringDepegTests {
    function _deployAccounting() internal override returns (address a) {
        a = address(
            new ERC1967Proxy(
                address(new DiscreteAccounting(18, false)),
                abi.encodeWithSelector(
                    DiscreteAccounting.initialize.selector,
                    address(this),
                    address(acm),
                    IStrataCDO(address(this)),
                    IAprPairFeed(address(this))
                )
            )
        );
        acm.grantRole(DiscreteAccounting(a).UPDATER_STRAT_CONFIG_ROLE(), address(this));
        DiscreteAccounting(a).setRiskParameters(
            UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18)
        );
    }
}

contract NavLossDuringDepegDYSTest is NavLossDuringDepegTests {
    function _deployAccounting() internal override returns (address) {
        return address(
            new ERC1967Proxy(
                address(new DYSAccounting(18, false, false, false, true, false)),
                abi.encodeWithSelector(
                    DYSAccounting.initialize.selector,
                    address(this),
                    address(acm),
                    IStrataCDO(address(this)),
                    IAprPairFeed(address(this))
                )
            )
        );
    }
}

contract NavLossDuringDepegMTMTest is NavLossDuringDepegTests {
    bool twoSnapshots;

    function totalStrategyAssetsSnapshot(uint256, uint256)
        external
        view
        override
        returns (uint256, uint256, uint256, uint256)
    {
        if (twoSnapshots) {
            return (mockStrategyTvl, block.timestamp - 1, mockStrategyTvl - 100e18, block.timestamp);
        }
        return (mockStrategyTvl, block.timestamp, mockStrategyTvl, block.timestamp);
    }
    /// Only reconciled losses trigger coverage; live MTM loss is covered once reconciled.

    function test_reconciliationThenLiveMtm() public {
        accounting.setValuationPrice(0.4e18);
        vm.warp(block.timestamp + 1 days);
        mockStrategyTvl = 1750e18;
        twoSnapshots = true;
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 751e18);
        (, uint256 seniorLive,) = accounting.totalAssets();
        assertEq(seniorLive, 2400e18);
        uint256 slashed = _totalSlashed();
        accounting.updateAccounting();
        assertEq(_totalSlashed(), slashed, "same MTM must not reslash");

        vm.warp(block.timestamp + 1);
        mockStrategyTvl = 1650e18;
        twoSnapshots = false;
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), 851e18);
        _assertWhole(0.4e18);
    }

    function _deployAccounting() internal override returns (address) {
        return address(
            new ERC1967Proxy(
                address(new MTMAccounting(18, false, true, false, true, true, true)),
                abi.encodeWithSelector(
                    MTMAccounting.initialize.selector,
                    address(this),
                    address(acm),
                    IStrataCDO(address(this)),
                    IAprPairFeed(address(this))
                )
            )
        );
    }
}
