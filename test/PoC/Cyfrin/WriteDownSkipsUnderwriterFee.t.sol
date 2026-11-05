// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {MockUSDe} from "../../../contracts/test/MockUSDe.sol";
import {MockStakedUSDe} from "../../../contracts/test/MockStakedUSDe.sol";
import {MockStakedUSDS} from "../../../contracts/test/MockStakedUSDS.sol";

import {Tranche} from "../../../contracts/tranches/Tranche.sol";
import {Accounting} from "../../../contracts/tranches/Accounting.sol";
import {StrataCDO} from "../../../contracts/tranches/StrataCDO.sol";
import {ISharesCooldown} from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";

import {sUSDeCooldownRequestImpl as SUSDeCooldownRequestImpl} from "../../../contracts/tranches/strategies/ethena/sUSDeCooldownRequestImpl.sol";
import {sUSDeAprPairProvider as SUSDeAprPairProvider, IsUSDS} from "../../../contracts/tranches/strategies/ethena/sUSDeAprPairProvider.sol";
import {sUSDeStrategy as SUSDeStrategy} from "../../../contracts/tranches/strategies/ethena/sUSDeStrategy.sol";

import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";
import {AprPairFeed} from "../../../contracts/tranches/oracles/AprPairFeed.sol";

import {ERC20Cooldown} from "../../../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import {UnstakeCooldown} from "../../../contracts/tranches/base/cooldown/UnstakeCooldown.sol";
import {CooldownBase} from "../../../contracts/tranches/base/cooldown/CooldownBase.sol";

import {IsUSDe} from "../../../contracts/tranches/strategies/ethena/IsUSDe.sol";
import {IUnstakeHandler} from "../../../contracts/tranches/interfaces/cooldown/IUnstakeHandler.sol";
import {ITranche} from "../../../contracts/tranches/interfaces/ITranche.sol";
import {IStrategy} from "../../../contracts/tranches/interfaces/IStrategy.sol";
import {IAccounting} from "../../../contracts/tranches/interfaces/IAccounting.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {InsuranceMiddleware} from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import {InsuranceVault} from "../../../contracts/tranches/symbiotic/InsuranceVault.sol";
import {IStrataAccounting} from "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import {IInsurancePool} from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";

import {GuaranteeAdapterMock, PeggedOneOracleMock} from "./CoveredClaimFreeze.t.sol";
import {MockInsurancePool} from "../../symbiotic/mocks/MockInsurancePool.sol";
import {ITerminalLossAccounting, TerminalAccounting, TerminalDiscrete, TerminalDYS, TerminalMTM} from "./ProtectedFeesTerminalLoss.t.sol";

/// @notice Insurance funding write-downs consume accrued underwriter fees before Senior principal.
/// @dev Full stack: real StrataCDO, Tranche x2, Accounting, sUSDeStrategy, AprPairFeed, InsuranceMiddleware and
///      InsuranceVault, wired like the client's CoveredClaimFreeze regression. Underwriter fees accrue organically:
///      10% target APR from the sUSDS savings rate, 20% underwriter fee share of the risk premium, one year
contract WriteDownFeeOrderFullStackTest is Test {
    MockUSDe public USDe;
    MockStakedUSDe public sUSDe;
    MockStakedUSDS public sUSDS;
    AccessControlManager public acm;
    StrataCDO public cdo;
    Tranche public jrtVault;
    Tranche public srtVault;
    Accounting public accounting;
    AprPairFeed public feed;
    SUSDeStrategy public sUSDeStrategy;
    SUSDeAprPairProvider public sUSDeAprPairProvider;
    UnstakeCooldown public unstakeCooldown;
    ERC20Cooldown public erc20Cooldown;
    SUSDeCooldownRequestImpl public sUSDeCooldownRequestImpl;
    MockUSDe public collateral;
    GuaranteeAdapterMock public adapter;
    PeggedOneOracleMock public oracle;
    InsuranceMiddleware public middleware;
    InsuranceVault public insuranceVault;

    address public owner;
    address public jnr = makeAddr("junior");
    address public snr = makeAddr("senior");
    address public lossSink = makeAddr("lossSink");

    // 10% APR expressed as Sky's per-second growth factor (ray)
    uint256 constant SSR_10PCT = 1e27 + uint256(0.1e27) / 365 days;
    uint256 constant UNDERWRITER_FEE_BPS = 0.2e18; // UNDERWRITER_FEE_BPS_MAX
    uint256 constant CLAIM = 200e18;               // loss beyond Junior that insurance covers
    uint256 constant FUNDED = 100e18;              // what the swapped slash proceeds actually fund

    function setUp() public {
        // Realistic timestamp: AprPairFeed treats its empty stored round as fresh when block.timestamp < 4h
        vm.warp(1_750_000_000);
        owner = msg.sender;
        vm.startPrank(owner);
        USDe = new MockUSDe();
        sUSDe = new MockStakedUSDe(USDe, owner, owner);
        sUSDS = new MockStakedUSDS(USDe);
        acm = new AccessControlManager(owner);
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(USDe, ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, owner, address(acm)))));
        jrtVault = Tranche(address(new ERC1967Proxy(address(new Tranche(false)),
            abi.encodeWithSelector(Tranche.initialize.selector, owner, address(acm), "jrtVault", "jrtUSDe", IERC20(address(USDe)), address(cdo)))));
        srtVault = Tranche(address(new ERC1967Proxy(address(new Tranche(false)),
            abi.encodeWithSelector(Tranche.initialize.selector, owner, address(acm), "srtVault", "srtUSDe", IERC20(address(USDe)), address(cdo)))));
        erc20Cooldown = ERC20Cooldown(address(new ERC1967Proxy(address(new ERC20Cooldown()),
            abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm)))));
        unstakeCooldown = UnstakeCooldown(address(new ERC1967Proxy(address(new UnstakeCooldown()),
            abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm)))));
        sUSDeCooldownRequestImpl = new SUSDeCooldownRequestImpl(IsUSDe(address(sUSDe)));
        address[] memory unstakeAddrs = new address[](1); unstakeAddrs[0] = address(sUSDe);
        IUnstakeHandler[] memory unstakeImpls = new IUnstakeHandler[](1); unstakeImpls[0] = IUnstakeHandler(address(sUSDeCooldownRequestImpl));
        unstakeCooldown.setImplementations(unstakeAddrs, unstakeImpls);
        sUSDeStrategy = SUSDeStrategy(address(new ERC1967Proxy(address(new SUSDeStrategy(IERC4626(address(sUSDe)))),
            abi.encodeWithSelector(SUSDeStrategy.initialize.selector, owner, address(acm), address(cdo), address(erc20Cooldown), address(unstakeCooldown)))));
        acm.grantRole(erc20Cooldown.COOLDOWN_WORKER_ROLE(), address(sUSDeStrategy));
        sUSDeAprPairProvider = new SUSDeAprPairProvider(IsUSDS(address(sUSDS)), IsUSDe(address(sUSDe)));
        feed = AprPairFeed(address(new ERC1967Proxy(address(new AprPairFeed()),
            abi.encodeWithSelector(AprPairFeed.initialize.selector, owner, address(acm), address(sUSDeAprPairProvider), 4 hours, "Ethena CDO APR Pair"))));
        accounting = Accounting(address(new ERC1967Proxy(address(new Accounting(18)),
            abi.encodeWithSelector(Accounting.initialize.selector, owner, address(acm), address(cdo), address(feed)))));
        cdo.configure(IAccounting(address(accounting)), IStrategy(address(sUSDeStrategy)), ITranche(address(jrtVault)), ITranche(address(srtVault)));
        acm.grantRole(cdo.PAUSER_ROLE(), owner);
        acm.grantRole(cdo.RESERVE_MANAGER_ROLE(), owner);
        acm.grantRole(cdo.RESERVE_MANAGER_ROLE(), address(this));
        // the test contract also acts as the APR feed keeper
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), address(this));
        cdo.setActionStates(address(0), true, true);

        collateral = new MockUSDe();
        adapter = new GuaranteeAdapterMock(IERC20(address(collateral)));
        oracle = new PeggedOneOracleMock();
        middleware = InsuranceMiddleware(address(new ERC1967Proxy(address(new InsuranceMiddleware(address(adapter))),
            abi.encodeWithSelector(InsuranceMiddleware.initialize.selector, owner, address(acm), address(oracle)))));
        adapter.setMiddleware(address(middleware));
        insuranceVault = InsuranceVault(address(new ERC1967Proxy(address(new InsuranceVault()),
            abi.encodeWithSelector(InsuranceVault.initialize.selector, owner, address(acm), IStrataCDO(address(cdo)), address(USDe)))));
        cdo.setInsuranceConfig(middleware, insuranceVault);
        middleware.setMarket(address(cdo), IStrataAccounting(address(accounting)), address(USDe), 0, true);
        collateral.mint(address(adapter), 3000e18);
        vm.stopPrank();

        // A positive Senior target APR so Senior earns, and the underwriter fee accrues, over time
        sUSDS.setSsr(SSR_10PCT);
    }

    // ---------------------------------------------------------------- helpers

    function _seed(uint256 j, uint256 s) internal {
        USDe.mint(jnr, j);
        vm.startPrank(jnr);
        USDe.approve(address(jrtVault), type(uint256).max);
        jrtVault.deposit(address(USDe), j, jnr);
        vm.stopPrank();
        USDe.mint(snr, s);
        vm.startPrank(snr);
        USDe.approve(address(srtVault), type(uint256).max);
        srtVault.deposit(address(USDe), s, snr);
        vm.stopPrank();
        // Keeper pushes the APR pair so Senior starts accruing its target
        accounting.onAprChanged();
    }

    function _checkpoint() internal {
        vm.prank(address(srtVault));
        cdo.updateAccounting();
    }

    function _identity() internal view {
        assertEq(
            accounting.nav() + accounting.insuranceAmount(),
            accounting.jrtBaseNav() + accounting.srtBaseNav() + accounting.reserveNav() + accounting.underwriterFeeNav(),
            "NAV identity"
        );
    }

    /// @dev Normal operation for one year with the given underwriter fee, then a strategy loss that wipes Junior to
    ///      its 1e18 floor and leaves `CLAIM` for Symbiotic. `stake` caps the slashable collateral at loss time
    function _accrueThenLoss(uint256 feeBps, uint256 stake) internal returns (uint256 seniorBefore, uint256 fee) {
        if (feeBps > 0) {
            vm.prank(owner);
            middleware.setMarketUnderwriterFeeBps(address(cdo), feeBps);
        }
        _seed(1000e18, 1000e18);
        vm.warp(block.timestamp + 365 days);
        _checkpoint();
        seniorBefore = accounting.srtBaseNav();
        fee = accounting.underwriterFeeNav();
        console.log("after 1y: Senior / Junior / fee", seniorBefore, accounting.jrtBaseNav(), fee);
        assertEq(accounting.reserveNav(), 0, "flat strategy: no reserve");

        // Reduce the underwriter stake to `stake` (e.g. vault withdrawals / other markets' commitments)
        uint256 held = collateral.balanceOf(address(adapter));
        if (stake < held) {
            vm.prank(address(adapter));
            collateral.transfer(lossSink, held - stake);
        }

        uint256 juniorAbsorbs = accounting.jrtBaseNav() - 1e18;
        vm.prank(address(sUSDeStrategy));
        sUSDe.transfer(lossSink, juniorAbsorbs + CLAIM);
        _checkpoint();
        assertEq(accounting.jrtBaseNav(), 1e18, "Junior at its floor");
        _identity();
    }

    /// @dev Swap of the slashed collateral returns only `FUNDED` coverage tokens; reserve manager records them
    function _fund(uint256 amount) internal {
        USDe.mint(address(this), amount);
        USDe.approve(address(cdo), amount);
        cdo.fundInsuranceClaim(address(USDe), amount);
    }

    // ---------------------------------------------------------------- tests

    /// Accrued fees absorb the gap first and cannot be paid again afterwards.
    function test_WriteDownConsumesAccruedFeeBeforeSenior() public {
        (uint256 seniorBefore, uint256 fee) = _accrueThenLoss(UNDERWRITER_FEE_BPS, 3000e18);
        assertGt(fee, 0, "fee accrued");
        assertEq(accounting.insuranceAmount(), CLAIM, "claim fully covered at loss time");
        assertEq(accounting.srtBaseNav(), seniorBefore, "Senior whole after covered loss");
        assertEq(accounting.underwriterFeeNav(), fee, "fee bucket survives covered loss");

        _fund(FUNDED);
        uint256 loss = cdo.writeDownInsuranceClaim(CLAIM - FUNDED - fee);

        console.log("fee accrued (unpaid)      ", fee);
        console.log("write-down principal loss ", loss);
        console.log("Senior before / after     ", seniorBefore, accounting.srtBaseNav());
        assertEq(loss, CLAIM - FUNDED - fee, "only residual Senior principal loss returned");
        assertEq(accounting.srtBaseNav(), seniorBefore - (CLAIM - FUNDED - fee), "fees absorb the shortfall first");
        assertEq(accounting.underwriterFeeNav(), 0, "fee bucket consumed");
        assertEq(accounting.reserveNav(), 0);
        assertEq(accounting.jrtBaseNav(), 1e18);
        assertEq(accounting.insuranceAmount(), FUNDED);
        _identity();

        // Written-down fees can no longer be paid out.
        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        cdo.payUnderwriterFee(address(sUSDe));
        _identity();
    }

    /// With no accrued fees, Senior absorbs the entire funding shortfall.
    function test_PoC_WriteDownWithoutFeeChargesSeniorSameAmount() public {
        (uint256 seniorBefore, uint256 fee) = _accrueThenLoss(0, 3000e18);
        assertEq(fee, 0);
        _fund(FUNDED);
        uint256 loss = cdo.writeDownInsuranceClaim(CLAIM - FUNDED);
        assertEq(loss, CLAIM - FUNDED);
        assertEq(accounting.srtBaseNav(), seniorBefore - (CLAIM - FUNDED), "Senior bears the full 100");
        _identity();
    }

    /// Counterfactual through the loss waterfall: underwriters can only deliver the same 100 of coverage, but the gap
    /// is known at loss time (stake caps coverage at 100). The loss waterfall then charges the accrued fee before
    /// Senior, so Senior loses `100 - fee` instead of `100`
    function test_PoC_SameDeliveredCoverageAtLossTimeFeeAbsorbsFirst() public {
        (uint256 seniorBefore, uint256 fee) = _accrueThenLoss(UNDERWRITER_FEE_BPS, FUNDED);
        assertGt(fee, 0);
        assertEq(accounting.insuranceAmount(), FUNDED, "coverage capped at 100");
        assertEq(accounting.underwriterFeeNav(), 0, "waterfall consumed the fee");
        assertEq(accounting.srtBaseNav(), seniorBefore - (CLAIM - FUNDED - fee), "Senior loses only 100 - fee");
        console.log("Senior loss via waterfall ", seniorBefore - accounting.srtBaseNav());
        console.log("Senior loss via write-down", CLAIM - FUNDED - fee);
        _identity();
    }

    /// The fee is paid while the realized claim is open, as `payUnderwriterFee` caps only at `accounting.nav()`,
    /// then the claim proves under-funded and is written down: Senior bears the shortfall and the fee is already gone
    function test_PoC_FeePaidWhileClaimOpenThenWriteDownHitsSenior() public {
        (uint256 seniorBefore, uint256 fee) = _accrueThenLoss(UNDERWRITER_FEE_BPS, 3000e18);
        assertGt(accounting.nav(), fee, "nav covers the fee");
        cdo.payUnderwriterFee(address(sUSDe));
        assertLe(accounting.underwriterFeeNav(), 1, "fee paid while claim open");
        assertEq(accounting.insuranceAmount(), CLAIM, "claim still open");

        _fund(FUNDED);
        uint256 loss = cdo.writeDownInsuranceClaim(CLAIM - FUNDED);
        assertEq(loss, CLAIM - FUNDED);
        assertEq(accounting.srtBaseNav(), seniorBefore - (CLAIM - FUNDED));
        _identity();
    }
}

/// @notice All four accounting variants use the same fee-before-Senior write-down order.
interface IWriteDownFeeAccounting {
    function writeDownInsuranceClaim(uint256 fundedBase, uint256 maxPrincipalLoss) external returns (uint256);
}

contract WriteDownFeeOrderAllVariantsTest is Test {
    ITerminalLossAccounting a;
    MockInsurancePool pool;
    uint256 strategyNav;

    function totalStrategyAssets() external view returns (uint256) { return strategyNav; }
    function totalStrategyAssets(uint256, uint256) external view returns (uint256) { return strategyNav; }
    function totalStrategyAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        return (strategyNav, block.timestamp, strategyNav, block.timestamp);
    }

    function _deploy(uint256 variant) internal {
        strategyNav = 0;
        vm.warp(1_750_000_000);
        address impl;
        if (variant == 0) impl = address(new TerminalAccounting());
        else if (variant == 1) impl = address(new TerminalDiscrete());
        else if (variant == 2) impl = address(new TerminalDYS());
        else impl = address(new TerminalMTM());
        AccessControlManager acm = new AccessControlManager(address(this));
        a = ITerminalLossAccounting(address(new ERC1967Proxy(impl,
            abi.encodeWithSignature("initialize(address,address,address,address)", address(this), address(acm), address(this), address(0)))));
        pool = new MockInsurancePool();
        a.setInsurancePool(IInsurancePool(address(pool)));
        // Junior 100, Senior 1000, no claim, fee bucket 50
        a.seed(100e18, 1000e18, 0, 0, 0, 0, 0, 1e18);
        a.seedFee(50e18);
        strategyNav = 1150e18;
    }

    function _identity() internal view {
        assertEq(a.nav() + a.insuranceAmount(), a.jrtBaseNav() + a.srtBaseNav() + a.reserveNav() + a.underwriterFeeNav());
    }

    /// Loss 300: Junior -> floor, 201 covered by insurance, fee 50 untouched initially. Vault funds 100; fees absorb 50 and Senior loses 51
    function _writeDownChargesFeeFirst(uint256 i) internal {
        _deploy(i);
        pool.setCapacity(10_000e18);
        uint256 senior = a.srtBaseNav();
        strategyNav -= 300e18;
        a.updateAccounting();
        uint256 claim = a.insuranceAmount();
        assertEq(a.underwriterFeeNav(), 50e18, "fee survives covered loss");
        assertEq(a.srtBaseNav(), senior, "Senior whole after covered loss");
        (bool ok, bytes memory ret) = address(a).call(
            abi.encodeWithSignature("writeDownInsuranceClaim(uint256,uint256)", 100e18, claim - 100e18 - 50e18));
        assertTrue(ok, "write-down");
        assertEq(abi.decode(ret, (uint256)), claim - 100e18 - 50e18);
        assertEq(a.srtBaseNav(), senior - (claim - 100e18 - 50e18), "Senior bears only the residual shortfall");
        assertEq(a.underwriterFeeNav(), 0, "fee consumed first");
        _identity();
    }

    /// Counterfactual: the same 100 is delivered, but capacity is 100 at loss time -> fee absorbs 50 first
    function _waterfallChargesFeeFirst(uint256 i) internal {
        _deploy(i);
        pool.setCapacity(100e18);
        uint256 senior = a.srtBaseNav();
        uint256 jr = a.jrtBaseNav();
        strategyNav -= 300e18;
        a.updateAccounting();
        assertEq(a.insuranceAmount(), 100e18);
        assertEq(a.underwriterFeeNav(), 0, "fee absorbed first");
        uint256 jrLoss = jr - a.jrtBaseNav();
        assertEq(a.srtBaseNav(), senior - (300e18 - jrLoss - 100e18 - 50e18), "Senior bears only shortfall - fee");
        _identity();
    }

    function test_allVariantsFeeOnlyWriteDownAllowsZeroPrincipalLimit() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            a.seed(1e18, 1000e18, 200e18, 0, 0, 0, 0, 1e18);
            a.seedFee(150e18);
            uint256 navBefore = a.nav();
            uint256 amount = IWriteDownFeeAccounting(address(a)).writeDownInsuranceClaim(100e18, 0);
            assertEq(amount, 0);
            assertEq(a.srtBaseNav(), 1000e18);
            assertEq(a.underwriterFeeNav(), 50e18);
            assertEq(a.insuranceAmount(), 100e18);
            assertEq(a.nav(), navBefore);
            _identity();
            assertEq(IWriteDownFeeAccounting(address(a)).writeDownInsuranceClaim(100e18, 0), 0);
            assertEq(a.underwriterFeeNav(), 50e18, "funded claim does not consume fees");
        }
    }

    function test_allVariantsDepegSizesResidualPrincipalAfterFees() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            a.seed(1e18, 1250e18, 450e18, 250e18, 0, 0, 0, 0.8e18);
            a.seedFee(50e18);
            uint256 navBefore = a.nav();
            IWriteDownFeeAccounting w = IWriteDownFeeAccounting(address(a));
            vm.expectRevert("ExceedsMaxPrincipalLoss");
            w.writeDownInsuranceClaim(275e18, 100e18 - 1);
            assertEq(a.underwriterFeeNav(), 50e18, "failed call rolls back fee absorption");
            assertEq(a.insuranceAmount(), 450e18);
            assertEq(w.writeDownInsuranceClaim(275e18, 100e18), 100e18);
            assertEq(a.underwriterFeeNav(), 0);
            assertEq(a.srtBaseNav(), 1125e18, "100 principal plus 25 credit unwound");
            assertEq(a.srtInsuranceFundNav(), 225e18);
            assertEq(a.insuranceAmount(), 275e18);
            assertEq(a.nav(), navBefore);
            _identity();
        }
    }

    function test_allVariantsDepegScalesSelfFundingOnlyForSeniorLoss() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            a.seed(1e18, 1650e18, 451e18, 250e18, 400e18, 100e18, 0, 0.8e18);
            a.seedFee(50e18);
            uint256 navBefore = a.nav();
            assertEq(IWriteDownFeeAccounting(address(a)).writeDownInsuranceClaim(236e18, 140e18), 140e18);
            assertEq(a.underwriterFeeNav(), 0);
            assertEq(a.srtFundedGrossNav(), 360e18, "entry basis scales by Senior principal loss only");
            assertEq(a.srtFundNav(), 72e18);
            assertEq(a.srtInsuranceFundNav(), 225e18);
            assertEq(a.insuranceAmount(), 236e18);
            assertEq(a.srtBaseNav(), 1485e18);
            assertEq(a.nav(), navBefore);
            _identity();
        }
    }

    function test_allVariantsValuationOnlyClaimPreservesFees() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            a.seed(1e18, 1250e18, 250e18, 250e18, 0, 0, 0, 0.8e18);
            a.seedFee(200e18);
            vm.expectRevert("InsuranceShortfallUnresolved");
            IWriteDownFeeAccounting(address(a)).writeDownInsuranceClaim(100e18, 1000e18);
            assertEq(a.underwriterFeeNav(), 200e18);
            assertEq(a.insuranceAmount(), 250e18);
            _identity();
        }
    }

    function test_allVariantsReleaseCreditBeforeChargingFees() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            a.seed(101e18, 1250e18, 351e18, 250e18, 0, 0, 0, 0.8e18);
            a.seedFee(50e18);
            assertEq(IWriteDownFeeAccounting(address(a)).writeDownInsuranceClaim(251e18, 0), 0);
            assertEq(a.underwriterFeeNav(), 50e18, "free credit unwind resolves gap before fees");
            assertEq(a.insuranceAmount(), 251e18);
            assertEq(a.srtBaseNav(), 1150e18);
            _identity();
        }
    }

    function test_PoC_AccountingWriteDownChargesFeeFirst() public { _writeDownChargesFeeFirst(0); }
    function test_PoC_DiscreteWriteDownChargesFeeFirst() public { _writeDownChargesFeeFirst(1); }
    function test_PoC_DYSWriteDownChargesFeeFirst() public { _writeDownChargesFeeFirst(2); }
    function test_PoC_MTMWriteDownChargesFeeFirst() public { _writeDownChargesFeeFirst(3); }
    function test_PoC_AccountingWaterfallChargesFeeFirst() public { _waterfallChargesFeeFirst(0); }
    function test_PoC_DiscreteWaterfallChargesFeeFirst() public { _waterfallChargesFeeFirst(1); }
    function test_PoC_DYSWaterfallChargesFeeFirst() public { _waterfallChargesFeeFirst(2); }
    function test_PoC_MTMWaterfallChargesFeeFirst() public { _waterfallChargesFeeFirst(3); }
}
