// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {MockUSDe} from "../../../contracts/test/MockUSDe.sol";
import {MockStakedUSDe} from "../../../contracts/test/MockStakedUSDe.sol";
import {MockStakedUSDS} from "../../../contracts/test/MockStakedUSDS.sol";

import {Tranche} from "../../../contracts/tranches/Tranche.sol";
import {Accounting} from "../../../contracts/tranches/Accounting.sol";
import {StrataCDO} from "../../../contracts/tranches/StrataCDO.sol";

import { sUSDeCooldownRequestImpl as SUSDeCooldownRequestImpl } from "../../../contracts/tranches/strategies/ethena/sUSDeCooldownRequestImpl.sol";
import { sUSDeAprPairProvider as SUSDeAprPairProvider, IsUSDS } from "../../../contracts/tranches/strategies/ethena/sUSDeAprPairProvider.sol";
import { sUSDeStrategy as SUSDeStrategy } from "../../../contracts/tranches/strategies/ethena/sUSDeStrategy.sol";

import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { AprPairFeed } from "../../../contracts/tranches/oracles/AprPairFeed.sol";

import { ERC20Cooldown } from "../../../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import { UnstakeCooldown } from "../../../contracts/tranches/base/cooldown/UnstakeCooldown.sol";
import { CooldownBase } from "../../../contracts/tranches/base/cooldown/CooldownBase.sol";

import { IsUSDe } from "../../../contracts/tranches/strategies/ethena/IsUSDe.sol";
import { IUnstakeHandler } from "../../../contracts/tranches/interfaces/cooldown/IUnstakeHandler.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { InsuranceMiddleware } from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { InsuranceVault } from "../../../contracts/tranches/symbiotic/InsuranceVault.sol";
import { IStrataAccounting } from "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { IAppAdapter } from "../../../contracts/tranches/symbiotic/interfaces/IAppAdapter.sol";
import { IOracleAdapter } from "../../../contracts/tranches/symbiotic/interfaces/IOracleAdapter.sol";

// Faithful stand-in for the Symbiotic guarantee adapter: the slashable stake is the
// collateral the adapter actually holds, and slash() moves that collateral to the
// middleware caller, exactly as the production adapter does
contract GuaranteeAdapterMock is IAppAdapter {
    IERC20 public immutable ASSET;
    address public middleware;

    constructor(IERC20 asset_) {
        ASSET = asset_;
    }

    function setMiddleware(address middleware_) external {
        middleware = middleware_;
    }

    function asset() external view override returns (address) {
        return address(ASSET);
    }

    function slashable() external view override returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    function stake() external view override returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    function stakeAt(uint48) external view override returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    function slash(uint256 amount) external override {
        if (msg.sender != middleware) revert NotInsuranceMiddleware();
        uint256 held = ASSET.balanceOf(address(this));
        if (amount > held) revert InsufficientSlash();
        ASSET.transfer(msg.sender, amount);
        emit Slash(amount);
    }

    function release(uint256) external override {
        // unused in this flow
    }

    function reward(address, uint256) external override {
        // unused in this flow
    }

    function burner() external pure override returns (address) {
        return address(0);
    }

    function duration() external pure override returns (uint48) {
        return 0;
    }

    function operator() external pure override returns (address) {
        return address(0);
    }

    function subnetwork() external pure override returns (bytes32) {
        return bytes32(0);
    }
}

// Prices every asset 1:1 against the quote currency, so the coverage conversions are
// identity mappings and base-asset amounts equal collateral amounts
contract PeggedOneOracleMock is IOracleAdapter {
    function getPrice(address) external pure override returns (uint256, uint256) {
        return (1e18, 18);
    }
}

/// @notice Regression adapted from the auditor's funded Ethena claim-freeze PoC.
contract CoveredClaimFreezeTest is Test {
    // External protocols
    MockUSDe public USDe;
    MockStakedUSDe public sUSDe;
    MockStakedUSDS public sUSDS;

    // Auth
    AccessControlManager public acm;

    // Strata CDO
    StrataCDO public cdo;

    // Tranches
    Tranche public jrtVault;
    Tranche public srtVault;

    // Accounting Component
    Accounting public accounting;

    // Basic Feed
    AprPairFeed public feed;

    // Strategy
    SUSDeStrategy public sUSDeStrategy;
    SUSDeAprPairProvider public sUSDeAprPairProvider;
    UnstakeCooldown public unstakeCooldown;
    ERC20Cooldown public erc20Cooldown;
    SUSDeCooldownRequestImpl public sUSDeCooldownRequestImpl;

    // Symbiotic coverage stack
    MockUSDe public collateral;
    GuaranteeAdapterMock public adapter;
    PeggedOneOracleMock public oracle;
    InsuranceMiddleware public middleware;
    InsuranceVault public insuranceVault;

    address public jnr;
    address public snr;
    address public lossSink;

    function setUp() public {
        address owner = msg.sender;

        vm.startPrank(owner);

        // Prepare Ethena and Ethreal contracts
        USDe = new MockUSDe();
        sUSDe = new MockStakedUSDe(USDe, owner, owner);
        sUSDS = new MockStakedUSDS(USDe);

        // Prepare Acm
        acm = new AccessControlManager(owner);

        // Create CDO
        cdo = StrataCDO(
            address(
                new ERC1967Proxy(
                    address(new StrataCDO(USDe)),
                    abi.encodeWithSelector(StrataCDO.initialize.selector, owner, address(acm))
                )
            )
        );

        // Prepare Tranches
        jrtVault = Tranche(
            address(
                new ERC1967Proxy(
                    address(new Tranche(false)),
                    abi.encodeWithSelector(Tranche.initialize.selector, owner, address(acm), "jrtVault", "jrtUSDe", IERC20(address(USDe)), address(cdo))
                )
            )
        );
        srtVault = Tranche(
            address(
                new ERC1967Proxy(
                    address(new Tranche(false)),
                    abi.encodeWithSelector(Tranche.initialize.selector, owner, address(acm), "srtVault", "srtUSDe", IERC20(address(USDe)), address(cdo))
                )
            )
        );

        // Prepare cooldowns
        erc20Cooldown = new ERC20Cooldown();
        unstakeCooldown = UnstakeCooldown(
            address(
                new ERC1967Proxy(
                    address(new UnstakeCooldown()),
                    abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
                )
            )
        );
        sUSDeCooldownRequestImpl = new SUSDeCooldownRequestImpl(IsUSDe(address(sUSDe)));
        address[] memory unstakeAddrs = new address[](1); unstakeAddrs[0] = address(sUSDe);
        IUnstakeHandler[] memory unstakeImpls = new IUnstakeHandler[](1); unstakeImpls[0] = IUnstakeHandler(address(sUSDeCooldownRequestImpl));

        unstakeCooldown.setImplementations(unstakeAddrs, unstakeImpls);

        // Prepare Strategy
        sUSDeStrategy = SUSDeStrategy(
            address(
                new ERC1967Proxy(
                    address(new SUSDeStrategy(IERC4626(address(sUSDe)))),
                    abi.encodeWithSelector(SUSDeStrategy.initialize.selector, owner, address(acm), address(cdo), address(erc20Cooldown), address(unstakeCooldown))
                )
            )
        );
        acm.grantRole(erc20Cooldown.COOLDOWN_WORKER_ROLE(), address(sUSDeStrategy));

        // Prepare Feed
        sUSDeAprPairProvider = new SUSDeAprPairProvider(IsUSDS(address(sUSDS)), IsUSDe(address(sUSDe)));
        feed = AprPairFeed(
            address(
                new ERC1967Proxy(
                    address(new AprPairFeed()),
                    abi.encodeWithSelector(AprPairFeed.initialize.selector, owner, address(acm), address(sUSDeAprPairProvider), 4 hours, "Ethena CDO APR Pair")
                )
            )
        );

        // Prepare accounting
        accounting = Accounting(
            address(
                new ERC1967Proxy(
                    address(new Accounting(18)),
                    abi.encodeWithSelector(Accounting.initialize.selector, owner, address(acm), address(cdo), address(feed))
                )
            )
        );

        // Configure CDO
        cdo.configure(
            IAccounting(address(accounting)),
            IStrategy(address(sUSDeStrategy)),
            ITranche(address(jrtVault)),
            ITranche(address(srtVault))
        );
        acm.grantRole(cdo.PAUSER_ROLE(), owner);
        acm.grantRole(cdo.RESERVE_MANAGER_ROLE(), owner);
        // the test contract also acts as the reserve manager that funds the claim
        acm.grantRole(cdo.RESERVE_MANAGER_ROLE(), address(this));
        cdo.setActionStates(address(0), true, true);

        // Wire the Symbiotic coverage stack with production middleware and vault
        collateral = new MockUSDe();
        adapter = new GuaranteeAdapterMock(IERC20(address(collateral)));
        oracle = new PeggedOneOracleMock();
        middleware = InsuranceMiddleware(
            address(
                new ERC1967Proxy(
                    address(new InsuranceMiddleware()),
                    abi.encodeWithSelector(InsuranceMiddleware.initialize.selector, owner, address(acm), address(adapter), address(oracle))
                )
            )
        );
        adapter.setMiddleware(address(middleware));
        insuranceVault = InsuranceVault(
            address(
                new ERC1967Proxy(
                    address(new InsuranceVault()),
                    abi.encodeWithSelector(InsuranceVault.initialize.selector, owner, address(acm), IStrataCDO(address(cdo)), address(USDe))
                )
            )
        );
        cdo.setInsuranceConfig(middleware, insuranceVault);
        middleware.setMarket(address(cdo), IStrataAccounting(address(accounting)), address(USDe), 0, true);

        // Fund the underwriter stake that backs the coverage
        collateral.mint(address(adapter), 3000e18);

        jnr = makeAddr("junior");
        snr = makeAddr("senior");
        lossSink = makeAddr("lossSink");

        vm.stopPrank();
    }

    function test_fundedClaimPaysPermittedAndRepeatedExits() public {
        _seedMarket(1000e18, 1000e18);
        assertEq(accounting.jrtBaseNav(), 1000e18);
        assertEq(accounting.srtBaseNav(), 1000e18);
        assertEq(accounting.nav(), 2000e18);

        // Covered loss one: the strategy loses 1050e18, Junior absorbs down to its 1e18
        // dust floor and the remaining 51e18 Senior-bound loss is fully covered
        vm.prank(address(sUSDeStrategy));
        sUSDe.transfer(lossSink, 1050e18);
        vm.prank(address(srtVault));
        cdo.updateAccounting();

        assertEq(cdo.totalStrategyAssets(), 950e18);
        assertEq(accounting.nav(), 950e18);
        assertEq(accounting.jrtBaseNav(), 1e18);
        assertEq(accounting.srtBaseNav(), 1000e18);
        assertEq(accounting.insuranceAmount(), 51e18);

        // Covered loss two: the strategy loses the remaining 950e18. Junior is already at
        // its dust floor and the underwriter-fee bucket is empty, so the full loss is covered
        vm.prank(address(sUSDeStrategy));
        sUSDe.transfer(lossSink, 950e18);
        vm.prank(address(srtVault));
        cdo.updateAccounting();

        // insuranceAmount now exceeds the Senior base NAV: 0 + 1001e18 == 1e18 + 1000e18
        assertEq(cdo.totalStrategyAssets(), 0);
        assertEq(accounting.nav(), 0);
        assertEq(accounting.jrtBaseNav(), 1e18);
        assertEq(accounting.srtBaseNav(), 1000e18);
        assertEq(accounting.insuranceAmount(), 1001e18);

        // Fund the whole outstanding claim into the insurance vault, so the later
        // redemptions have liquid coverage available
        USDe.mint(address(this), 1001e18);
        USDe.approve(address(cdo), 1001e18);
        cdo.fundInsuranceClaim(address(USDe), 1001e18);
        assertEq(insuranceVault.fundedCoverage(), 1001e18);

        // maxWithdraw still reports the full Senior NAV, inviting the exit
        assertEq(accounting.maxWithdraw(false), 1000e18);
        assertEq(srtVault.maxWithdraw(snr), 1000e18);

        // The accounting underflow is fixed; the tranche still requires 0.1 shares to remain.
        vm.prank(snr);
        vm.expectRevert(bytes4(keccak256("MinSharesViolation()")));
        srtVault.withdraw(address(USDe), 1000e18, snr, snr);

        uint256 snapshot = vm.snapshotState();
        vm.prank(snr);
        srtVault.withdraw(address(USDe), 999.9e18, snr, snr);
        _assertPaid(999.9e18);

        vm.revertToState(snapshot);
        vm.prank(snr);
        srtVault.withdraw(address(USDe), 500e18, snr, snr);
        _assertPaid(500e18);
        vm.prank(snr);
        srtVault.withdraw(address(USDe), 499.9e18, snr, snr);
        _assertPaid(999.9e18);
    }

    function _assertPaid(uint256 paid) internal view {
        assertEq(accounting.insuranceAmount(), 1001e18 - paid);
        assertEq(insuranceVault.fundedCoverage(), 1001e18 - paid);
        assertEq(srtVault.balanceOf(snr), 1000e18 - paid);
        assertEq(USDe.balanceOf(snr), paid);
        assertEq(accounting.nav(), 0);
        assertEq(accounting.jrtBaseNav(), 1e18);
        assertEq(accounting.srtBaseNav(), 1000e18 - paid);
    }

    function _seedMarket(uint256 jrtAmount, uint256 srtAmount) internal {
        USDe.mint(jnr, jrtAmount);
        vm.startPrank(jnr);
        USDe.approve(address(jrtVault), type(uint256).max);
        jrtVault.deposit(address(USDe), jrtAmount, jnr);
        vm.stopPrank();

        USDe.mint(snr, srtAmount);
        vm.startPrank(snr);
        USDe.approve(address(srtVault), type(uint256).max);
        srtVault.deposit(address(USDe), srtAmount, snr);
        vm.stopPrank();
    }
}
