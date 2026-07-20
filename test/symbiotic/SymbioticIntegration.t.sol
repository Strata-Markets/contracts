// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { StrataCDO } from "../../contracts/tranches/StrataCDO.sol";
import { Accounting } from "../../contracts/tranches/Accounting.sol";
import { sUSDeStrategy } from "../../contracts/tranches/strategies/ethena/sUSDeStrategy.sol";
import { IStrategy } from "../../contracts/tranches/interfaces/IStrategy.sol";
import { NetworkMiddleware } from "../../contracts/tranches/symbiotic/NetworkMiddleware.sol";
import { INetworkMiddleware } from "../../contracts/tranches/symbiotic/interfaces/INetworkMiddleware.sol";
import { IStrataAccounting } from "../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { IOracleAdapter } from "../../contracts/tranches/symbiotic/interfaces/IOracleAdapter.sol";
import { MockOracleAdapter } from "../../contracts/test/MockOracleAdapter.sol";

/* Minimal local interfaces for the Symbiotic V2 mainnet contracts (avoids importing
   symbiotic/core, whose OZ version differs from this repo's). */

interface ISymFactory {
    function create(uint64 version, address owner, bytes calldata data) external returns (address);
}

interface ISymVaultV2 {
    function delegator() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface ISymUniversalDelegator {
    function addAdapter(address adapter) external returns (uint16 index);
    function setLimits(address adapter, uint256 assets, uint256 share) external;
    function allocate(address adapter, uint256 assets) external returns (uint256 allocated);
    function deallocate(address adapter, uint256 assets) external returns (uint256 deallocated);
}

interface ISymNetworkRegistry {
    function registerNetwork() external;
}

interface ISymNetworkMiddlewareService {
    function setMiddleware(address middleware) external;
}

interface ISymAdapterRegistry {
    function owner() external view returns (address);
    function setWhitelistedStatus(address vault, address adapter, bool status) external;
}

interface ISymAppAdapter {
    function slashable() external view returns (uint256);
    function asset() external view returns (address);
    function burner() external view returns (address);
}

interface IProxyAdminLike {
    function owner() external view returns (address);
    function upgradeAndCall(address proxy, address implementation, bytes calldata data) external payable;
}

interface IOwnableLike {
    function owner() external view returns (address);
}

contract SymbioticIntegrationTest is Test {

    // Tokens (Ethereum mainnet)
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant UNIBTC = 0x004E9C3EF86bc1ca1f0bB5C7662861Ee93350568;

    // Symbiotic V2 (Ethereum mainnet)
    ISymFactory constant VAULT_FACTORY = ISymFactory(0xAEb6bdd95c502390db8f52c8909F703E9Af6a346);
    uint64 constant VAULT_V2_VERSION = 3;
    ISymFactory constant ADAPTER_FACTORY = ISymFactory(0x161954842B7EA47CBd050cAb4875DAa4D6599476);
    uint64 constant ADAPTER_VERSION = 1;
    ISymAdapterRegistry constant ADAPTER_REGISTRY = ISymAdapterRegistry(0x788823C9579A049D986eB76718bC758C0998594a);
    ISymNetworkRegistry constant NETWORK_REGISTRY = ISymNetworkRegistry(0xC773b1011461e7314CF05f97d95aa8e92C1Fd8aA);
    ISymNetworkMiddlewareService constant MIDDLEWARE_SERVICE =
        ISymNetworkMiddlewareService(0xD7dC9B366c027743D90761F71858BCa83C6899Ad);
    uint256 constant MAX_SHARE = 1e18;

    // Live Strata USDe market (Ethereum mainnet)
    address constant CDO_PROXY = 0x908B3921aaE4fC17191D382BB61020f2Ee6C0e20;
    address constant CDO_PROXY_ADMIN = 0xcAb791D0D44eBaC17378fF2AF6356c012F15c9e6;
    address constant ACCOUNTING_PROXY = 0xa436c5Dd1Ba62c55D112C10cd10E988bb3355102;
    address constant ACCOUNTING_PROXY_ADMIN = 0x25A733feBA393a48C07A76441777324B471d212E;
    address constant STRATEGY_PROXY = 0xdbf4FB6C310C1C85D0b41B5DbCA06096F2E7099F;
    address constant STRATEGY_PROXY_ADMIN = 0x32d0d70a8Da4c0C2f354a986fD3738AFe92542F7;
    address constant ACM = 0x1d19E18ECaC4ef332a0d5d6Aa3a0f0f772605f60;
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");

    uint256 constant UNIBTC_PRICE = 60_000e18; // $60k mock price
    uint256 constant DEPOSIT = 5e8;            // 5 uniBTC underwritten

    // Actors
    address curator = makeAddr("curator");
    address underwriter = makeAddr("underwriter");
    address network = makeAddr("network");
    address operator = makeAddr("operator");
    address strataOps = makeAddr("strataOps");  // middleware owner / keeper
    address multisig = makeAddr("multisig");    // burner + true-up executor

    StrataCDO cdo = StrataCDO(CDO_PROXY);
    Accounting accounting = Accounting(ACCOUNTING_PROXY);
    IStrategy strategy;
    ISymVaultV2 vault;
    ISymUniversalDelegator delegator;
    ISymAppAdapter adapter;
    NetworkMiddleware middleware;
    MockOracleAdapter oracle;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        strategy = cdo.strategy();

        _upgradeStrataContracts();
        _deploySymbioticStack();
        _wireStrataToSymbiotic();
    }

    /// @dev Upgrades the live CDO and Accounting proxies to the implementations in this repo
    ///      (which include the premium / coverage-deficit / trueUp logic).
    function _upgradeStrataContracts() internal {
        address newAccountingImpl = address(new Accounting(18));
        address newCdoImpl = address(new StrataCDO(IERC20Metadata(USDE)));
        // The live strategy predates shareToken(), which trueUp() relies on: the production
        // rollout must upgrade the strategy implementation together with the CDO and Accounting.
        address newStrategyImpl = address(new sUSDeStrategy(IERC4626(SUSDE)));

        vm.prank(IProxyAdminLike(ACCOUNTING_PROXY_ADMIN).owner());
        IProxyAdminLike(ACCOUNTING_PROXY_ADMIN).upgradeAndCall(ACCOUNTING_PROXY, newAccountingImpl, "");

        vm.prank(IProxyAdminLike(CDO_PROXY_ADMIN).owner());
        IProxyAdminLike(CDO_PROXY_ADMIN).upgradeAndCall(CDO_PROXY, newCdoImpl, "");

        vm.prank(IProxyAdminLike(STRATEGY_PROXY_ADMIN).owner());
        IProxyAdminLike(STRATEGY_PROXY_ADMIN).upgradeAndCall(STRATEGY_PROXY, newStrategyImpl, "");

        // The live Accounting layout predates the valuation fields; valuationPrice reads 0 after
        // the upgrade and calcEffectiveNav would divide by zero. A production upgrade needs a
        // reinitializer for this; in the test we set it through the CDO.
        vm.prank(CDO_PROXY);
        accounting.setValuationPrice(1e18);
    }

    function _deploySymbioticStack() internal {
        // 3. Curator deploys the VaultV2 (uniBTC collateral) + UniversalDelegator
        bytes memory delegatorParams = abi.encode(
            curator, curator, curator, curator, curator, curator, curator, curator, curator
        );
        bytes memory vaultInit = _wrapTuple(abi.encode(
            "Strata Coverage Vault", "SCV", UNIBTC,
            false,          // depositWhitelist
            address(0),     // depositorToWhitelist
            uint256(0),     // depositLimit
            false,          // isDepositLimit
            curator, curator, curator, curator, curator, curator, curator,
            delegatorParams
        ));
        vm.prank(curator);
        vault = ISymVaultV2(VAULT_FACTORY.create(VAULT_V2_VERSION, curator, vaultInit));
        delegator = ISymUniversalDelegator(vault.delegator());

        // Underwriters deposit uniBTC
        deal(UNIBTC, underwriter, DEPOSIT);
        vm.startPrank(underwriter);
        IERC20(UNIBTC).approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, underwriter);
        vm.stopPrank();

        // 1. Register the network
        vm.prank(network);
        NETWORK_REGISTRY.registerNetwork();

        // 4. Deploy the AppAdapter for (subnetwork, operator), burner = Strata multisig
        bytes32 subnetwork = bytes32(uint256(uint160(network)) << 96); // identifier 0
        bytes memory adapterInit = _wrapTuple(abi.encode(
            multisig,        // burner
            uint48(1 days),  // duration
            operator,
            subnetwork,
            new address[](0) // converters
        ));
        vm.prank(strataOps);
        adapter = ISymAppAdapter(
            ADAPTER_FACTORY.create(ADAPTER_VERSION, strataOps, abi.encode(address(vault), adapterInit))
        );

        // 5. Symbiotic whitelists the adapter
        vm.prank(ADAPTER_REGISTRY.owner());
        ADAPTER_REGISTRY.setWhitelistedStatus(address(vault), address(adapter), true);

        // 6. Curator adds the adapter and allocates the underwritten collateral to it
        vm.startPrank(curator);
        delegator.addAdapter(address(adapter));
        delegator.setLimits(address(adapter), type(uint256).max, MAX_SHARE);
        delegator.allocate(address(adapter), DEPOSIT);
        vm.stopPrank();

        // 0/2. Deploy the middleware and register it for the network
        NetworkMiddleware impl = new NetworkMiddleware();
        middleware = NetworkMiddleware(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(NetworkMiddleware.initialize, (strataOps, address(adapter)))
        )));
        vm.prank(network);
        MIDDLEWARE_SERVICE.setMiddleware(address(middleware));
    }

    function _wireStrataToSymbiotic() internal {
        oracle = new MockOracleAdapter();
        oracle.setPrice(UNIBTC, UNIBTC_PRICE, 18); // base assets default to $1

        vm.prank(strataOps);
        middleware.setMarket(
            CDO_PROXY, IStrataAccounting(ACCOUNTING_PROXY), USDE, IOracleAdapter(address(oracle)), 0, true
        );

        address cdoOwner = IOwnableLike(CDO_PROXY).owner();
        vm.prank(cdoOwner);
        cdo.setNetworkMiddleware(INetworkMiddleware(address(middleware)));

        // Symbiotic covers Jrt declines (coverage-first mode)
        address accountingOwner = IOwnableLike(ACCOUNTING_PROXY).owner();
        vm.prank(accountingOwner);
        accounting.setCoverageFirst(true);

        // Grant RESERVE_MANAGER_ROLE to the multisig directly in ACM storage
        // (OZ AccessControl: _roles[role].hasMember[account] at slot 0)
        bytes32 roleSlot = keccak256(abi.encode(RESERVE_MANAGER_ROLE, uint256(0)));
        bytes32 memberSlot = keccak256(abi.encode(multisig, roleSlot));
        vm.store(ACM, memberSlot, bytes32(uint256(1)));
    }

    /// @dev Converts a flat abi.encode(...) argument list into a single-tuple encoding
    ///      (prepends the 0x20 head offset), as expected by abi.decode(data, (SomeStruct))
    ///      when the struct has dynamic fields.
    function _wrapTuple(bytes memory body) internal pure returns (bytes memory) {
        return abi.encodePacked(uint256(0x20), body);
    }

    /// @dev Simulates a strategy loss by reducing the USDe backing of sUSDe.
    function _induceLoss(uint256 usdeAmount) internal {
        uint256 bal = IERC20(USDE).balanceOf(SUSDE);
        deal(USDE, SUSDE, bal - usdeAmount);
        vm.prank(CDO_PROXY);
        accounting.updateAccounting();
    }

    /// @dev Simulates strategy yield by increasing the USDe backing of sUSDe.
    function _induceGain(uint256 usdeAmount) internal {
        uint256 bal = IERC20(USDE).balanceOf(SUSDE);
        deal(USDE, SUSDE, bal + usdeAmount);
        vm.prank(CDO_PROXY);
        accounting.updateAccounting();
    }

    function test_endToEnd_lossSlashTrueUp() public {
        uint256 strategyTvl = strategy.totalAssets();
        uint256 loss = strategyTvl / 100; // 1% strategy loss

        uint256 jrtNavBefore = accounting.jrtNav();
        _induceLoss(loss);

        // Deficit accrued for the Jrt decline (coverage-first mode)
        uint256 deficit = accounting.pendingCoverageDeficit();
        assertGt(deficit, 0, "deficit should accrue on loss");

        // Slash: converts the USDe deficit to uniBTC and takes it from the adapter
        uint256 multisigBefore = IERC20(UNIBTC).balanceOf(multisig);
        vm.prank(strataOps);
        middleware.slash(CDO_PROXY);

        uint256 slashedUniBtc = IERC20(UNIBTC).balanceOf(multisig) - multisigBefore;
        assertGt(slashedUniBtc, 0, "slashed collateral must reach the burner multisig");

        (,,, uint256 totalSlashed, uint256 pendingTrueUp,,) = middleware.markets(CDO_PROXY);
        assertEq(totalSlashed, slashedUniBtc);
        assertEq(pendingTrueUp, slashedUniBtc);

        // No double slash while the true-up is in flight
        vm.expectRevert(NetworkMiddleware.NoSlashableAmount.selector);
        vm.prank(strataOps);
        middleware.slash(CDO_PROXY);

        // Mock CoW swap: multisig sells uniBTC for sUSDe (simulated fill)
        uint256 shareAmount = strategy.convertToTokens(SUSDE, deficit, Math.Rounding.Ceil);
        deal(SUSDE, multisig, shareAmount);

        // True-up: inject the sUSDe back into the protocol
        vm.startPrank(multisig);
        IERC20(SUSDE).approve(CDO_PROXY, shareAmount);
        cdo.trueUp(shareAmount);
        vm.stopPrank();

        // Deficit cleared, Jrt restored (approximately: conversion rounding only)
        assertLt(accounting.pendingCoverageDeficit(), 1e18, "deficit should be (almost) cleared");
        assertApproxEqRel(accounting.jrtNav(), jrtNavBefore, 0.001e18, "Jrt should be made whole");

        // Middleware in-flight amount cleared
        (,,,, uint256 pendingAfter,,) = middleware.markets(CDO_PROXY);
        assertLt(pendingAfter, pendingTrueUp / 100, "pendingTrueUp should be (almost) cleared");
    }

    function test_premium_accruesAndFlowsToUnderwriters() public {
        // Enable the premium skim
        address accountingOwner = IOwnableLike(ACCOUNTING_PROXY).owner();
        vm.prank(accountingOwner);
        accounting.setPremiumBps(0.1e18); // 10% of gains

        // Strategy earns yield -> premium accrues
        _induceGain(strategy.totalAssets() / 50); // 2% gain
        uint256 premium = accounting.totalPremium();
        assertGt(premium, 0, "premium should accrue on gains");

        // Pay the premium in sUSDe straight to the AppAdapter
        uint256 adapterBefore = IERC20(SUSDE).balanceOf(address(adapter));
        vm.prank(multisig);
        cdo.payPremium(SUSDE);
        uint256 paid = IERC20(SUSDE).balanceOf(address(adapter)) - adapterBefore;
        assertGt(paid, 0, "premium sUSDe must reach the adapter");
        assertLt(accounting.totalPremium(), 1e18, "premium bucket should be swept");

        // Baseline before the swap proceeds arrive (vault.totalAssets counts adapter holdings)
        uint256 assetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();

        // Mock CoW swap inside the adapter: sUSDe -> uniBTC (simulated fill)
        uint256 uniBtcProceeds = strategy.convertToAssets(SUSDE, paid, Math.Rounding.Floor)
            * 1e18 / UNIBTC_PRICE / 1e10;
        deal(SUSDE, address(adapter), 0);
        uint256 adapterUniBtc = IERC20(UNIBTC).balanceOf(address(adapter));
        deal(UNIBTC, address(adapter), adapterUniBtc + uniBtcProceeds);

        // Curator deallocates: the free uniBTC is pushed into the vault, no shares minted
        vm.prank(curator);
        delegator.deallocate(address(adapter), uniBtcProceeds);

        assertGe(vault.totalAssets(), assetsBefore + uniBtcProceeds, "vault assets must grow by the premium");
        assertEq(vault.totalSupply(), supplyBefore, "no shares minted: underwriters appreciate");
    }
}
