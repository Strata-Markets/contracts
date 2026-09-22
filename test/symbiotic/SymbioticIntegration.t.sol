// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { StrataCDO } from "../../contracts/tranches/StrataCDO.sol";
import { Accounting } from "../../contracts/tranches/Accounting.sol";
import { sUSDeStrategy } from "../../contracts/tranches/strategies/ethena/sUSDeStrategy.sol";
import { IStrategy } from "../../contracts/tranches/interfaces/IStrategy.sol";
import { IStrataCDO } from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import { InsuranceMiddleware } from "../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { IInsuranceMiddleware } from "../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import { IStrataAccounting } from "../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { OracleAdapter } from "../../contracts/tranches/symbiotic/OracleAdapter.sol";
import { InsuranceVault } from "../../contracts/tranches/symbiotic/InsuranceVault.sol";
import { IInsuranceVault } from "../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import { IRoundDataOracle } from "../../contracts/tranches/oracles/interfaces/IRoundDataOracle.sol";

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

interface ISymInsuranceMiddlewareService {
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

    // Chainlink push feeds (Ethereum mainnet): USDe/USD (single hop), uniBTC via uniBTC/BTC x BTC/USD
    IRoundDataOracle constant USDE_USD = IRoundDataOracle(0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961);   // 8 dec
    IRoundDataOracle constant UNIBTC_BTC = IRoundDataOracle(0x861d15F8a4059cb918bD6F3670adAEB1220B298f); // 18 dec
    IRoundDataOracle constant BTC_USD = IRoundDataOracle(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c);    // 8 dec
    uint256 constant FEED_HEARTBEAT = 7 days;

    // Symbiotic V2 (Ethereum mainnet)
    ISymFactory constant VAULT_FACTORY = ISymFactory(0xAEb6bdd95c502390db8f52c8909F703E9Af6a346);
    uint64 constant VAULT_V2_VERSION = 3;
    ISymFactory constant ADAPTER_FACTORY = ISymFactory(0x161954842B7EA47CBd050cAb4875DAa4D6599476);
    uint64 constant ADAPTER_VERSION = 1;
    ISymAdapterRegistry constant ADAPTER_REGISTRY = ISymAdapterRegistry(0x788823C9579A049D986eB76718bC758C0998594a);
    ISymNetworkRegistry constant NETWORK_REGISTRY = ISymNetworkRegistry(0xC773b1011461e7314CF05f97d95aa8e92C1Fd8aA);
    ISymInsuranceMiddlewareService constant MIDDLEWARE_SERVICE =
        ISymInsuranceMiddlewareService(0xD7dC9B366c027743D90761F71858BCa83C6899Ad);
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
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");

    uint256 constant UNIBTC_PRICE = 60_000e18; // $60k mock price
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant DEPOSIT = 5e8;            // 5 uniBTC underwritten

    // Actors
    address curator = makeAddr("curator");
    address underwriter = makeAddr("underwriter");
    address network = makeAddr("network");
    address operator = makeAddr("operator");
    address strataOps = makeAddr("strataOps");  // middleware owner / keeper
    address multisig = makeAddr("multisig");    // burner + insurance claim funding executor

    StrataCDO cdo = StrataCDO(CDO_PROXY);
    Accounting accounting = Accounting(ACCOUNTING_PROXY);
    IStrategy strategy;
    ISymVaultV2 vault;
    ISymUniversalDelegator delegator;
    ISymAppAdapter adapter;
    InsuranceMiddleware middleware;
    InsuranceVault insuranceVault;
    OracleAdapter oracle;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        strategy = cdo.strategy();

        _upgradeStrataContracts();
        _deploySymbioticStack();
        _wireStrataToSymbiotic();
    }

    /// @dev Upgrades the live CDO and Accounting proxies to the implementations in this repo
    ///      (which include the underwriter fee / coverage-deficit / insurance claim funding logic).
    function _upgradeStrataContracts() internal {
        address newAccountingImpl = address(new Accounting(18));
        address newCdoImpl = address(new StrataCDO(IERC20Metadata(USDE)));
        // The live strategy predates shareToken(), which fundInsuranceClaim() relies on: the production
        // rollout must upgrade the strategy implementation together with the CDO and Accounting.
        address newStrategyImpl = address(new sUSDeStrategy(IERC4626(SUSDE)));

        // Run the V2 migration atomically with the upgrade (sets feeWatermarkNav = nav), matching
        // the production rollout. Without it the reserve/underwriter fee skim underflows on the next update.
        vm.prank(IProxyAdminLike(ACCOUNTING_PROXY_ADMIN).owner());
        IProxyAdminLike(ACCOUNTING_PROXY_ADMIN).upgradeAndCall(
            ACCOUNTING_PROXY, newAccountingImpl, abi.encodeCall(Accounting.initializeV2, ())
        );

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

        // 0/2. Deploy the shared oracle (real mainnet Chainlink feeds) + middleware, and register
        //      it for the network. USDe prices single-hop; uniBTC two-hop via uniBTC/BTC x BTC/USD.
        oracle = OracleAdapter(address(new ERC1967Proxy(
            address(new OracleAdapter()),
            abi.encodeCall(OracleAdapter.initialize, (strataOps, strataOps))
        )));
        vm.startPrank(strataOps);
        oracle.setFeed(USDE, USDE_USD, 8, IRoundDataOracle(address(0)), 0, FEED_HEARTBEAT);
        oracle.setFeed(UNIBTC, UNIBTC_BTC, 18, BTC_USD, 8, FEED_HEARTBEAT);
        vm.stopPrank();

        InsuranceMiddleware impl = new InsuranceMiddleware();
        middleware = InsuranceMiddleware(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(InsuranceMiddleware.initialize, (strataOps, strataOps, address(adapter), address(oracle)))
        )));
        vm.prank(network);
        MIDDLEWARE_SERVICE.setMiddleware(address(middleware));
    }

    function _wireStrataToSymbiotic() internal {
        vm.prank(strataOps);
        middleware.setMarket(
            CDO_PROXY, IStrataAccounting(ACCOUNTING_PROXY), USDE, 0, true
        );

        // The per-CDO vault that holds the swapped coverage proceeds and pays redeeming Seniors.
        InsuranceVault vaultImpl = new InsuranceVault();
        insuranceVault = InsuranceVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(InsuranceVault.initialize, (multisig, multisig, IStrataCDO(CDO_PROXY), USDC))
        )));

        address cdoOwner = IOwnableLike(CDO_PROXY).owner();
        vm.prank(cdoOwner);
        cdo.setInsuranceConfig(
            IInsuranceMiddleware(address(middleware)),
            IInsuranceVault(address(insuranceVault))
        );

        // Grant roles directly in ACM storage (OZ AccessControl: _roles[role].hasMember[account] at slot 0).
        bytes32 reserveRoleSlot = keccak256(abi.encode(RESERVE_MANAGER_ROLE, uint256(0)));
        bytes32 reserveMemberSlot = keccak256(abi.encode(multisig, reserveRoleSlot));
        vm.store(ACM, reserveMemberSlot, bytes32(uint256(1)));

        bytes32 configRoleSlot = keccak256(abi.encode(UPDATER_STRAT_CONFIG_ROLE, uint256(0)));
        bytes32 configMemberSlot = keccak256(abi.encode(strataOps, configRoleSlot));
        vm.store(ACM, configMemberSlot, bytes32(uint256(1)));

        vm.prank(strataOps);
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
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

    function test_endToEnd_lossSlashInsuranceClaimFunding() public {
        uint256 strategyTvl = strategy.totalAssets();

        // Coverage only absorbs the Senior-bound loss, so the strategy NAV must drop past Jrt AND
        // the reserve, then a small amount (within the coverage capacity) into Srt.
        uint256 srtNavBefore = accounting.srtNav();
        uint256 targetStrategyLoss = accounting.jrtNav() + accounting.reserveNav() + strategyTvl / 500;
        // The strategy holds only a fraction of the sUSDe supply, so removing X USDe of backing
        // reduces the strategy NAV by X * strategyNav / totalUsdeBacking. Invert to hit the target.
        uint256 totalUsdeBacking = IERC20(USDE).balanceOf(SUSDE);
        uint256 usdeToRemove = targetStrategyLoss * totalUsdeBacking / strategyTvl;

        // Synchronous coverage: booking the claim in updateAccounting also slashes the adapter in the
        // same tx, so the slashed uniBTC reaches the burner multisig during _induceLoss itself.
        uint256 multisigBefore = IERC20(UNIBTC).balanceOf(multisig);
        _induceLoss(usdeToRemove);

        // Jrt absorbs down to its floor; the Srt-bound remainder is covered and booked as a claim.
        uint256 deficit = accounting.insuranceAmount();
        assertGt(deficit, 0, "an insurance claim should accrue for the Srt-bound loss");
        assertApproxEqRel(accounting.srtNav(), srtNavBefore, 0.001e18, "Srt held whole by coverage");

        uint256 slashedUniBtc = IERC20(UNIBTC).balanceOf(multisig) - multisigBefore;
        assertGt(slashedUniBtc, 0, "slashed collateral must reach the burner multisig");

        (,, uint256 totalSlashed, uint256 pendingInsuranceClaimFunding,,) = middleware.markets(CDO_PROXY);
        assertEq(totalSlashed, slashedUniBtc);
        assertEq(pendingInsuranceClaimFunding, slashedUniBtc);

        // The claim was already slashed synchronously, so a manual slash finds nothing to take.
        vm.expectRevert(InsuranceMiddleware.NoSlashableAmount.selector);
        vm.prank(strataOps);
        middleware.slash(CDO_PROXY);

        // Mock CoW swap: the multisig sells the slashed uniBTC for USDC (simulated fill). USDe is at
        // par here, so the claim's dollar value is 1:1; USDC is 6 decimals against USDe's 18.
        uint256 usdcAmount = deficit / 1e12;
        deal(USDC, multisig, usdcAmount);

        // Finalization: fund the insurance vault. The proceeds deliberately never enter the strategy.
        vm.startPrank(multisig);
        IERC20(USDC).approve(CDO_PROXY, usdcAmount);
        cdo.fundInsuranceClaim(USDC, usdcAmount);
        vm.stopPrank();

        assertEq(insuranceVault.fundedCoverage(), usdcAmount, "vault holds the swapped coverage");
        assertEq(IERC20(USDC).balanceOf(address(insuranceVault)), usdcAmount);

        // The claim stays open: it settles by paying redeeming Seniors, not by injecting into the
        // strategy. Srt keeps reading whole in the meantime.
        assertApproxEqRel(accounting.insuranceAmount(), deficit, 0.001e18, "claim still outstanding");
        assertApproxEqRel(accounting.srtNav(), srtNavBefore, 0.001e18, "Srt should remain whole");

        // Middleware in-flight amount cleared, so the same shortfall is not slashed twice
        (,,, uint256 pendingAfter,,) = middleware.markets(CDO_PROXY);
        assertLt(pendingAfter, pendingInsuranceClaimFunding / 100, "pendingInsuranceClaimFunding should be (almost) cleared");
    }

    /// A Senior redemption is paid from two sources: the covered slice in the coverage token out of
    /// the InsuranceVault, and the remainder out of the strategy. Nothing is bought back into the
    /// impaired underlying, and the claim shrinks by exactly the slice paid.
    function test_seniorRedemption_splitsBetweenVaultAndStrategy() public {
        _induceCoveredLoss();

        uint256 claimBefore = accounting.insuranceAmount();
        uint256 usdcAmount = claimBefore / 1e12;
        deal(USDC, multisig, usdcAmount);
        vm.startPrank(multisig);
        IERC20(USDC).approve(CDO_PROXY, usdcAmount);
        cdo.fundInsuranceClaim(USDC, usdcAmount);
        vm.stopPrank();

        address srtVault = address(cdo.srtVault());
        address user = makeAddr("srtRedeemer");

        // Redeem a slice well inside the accounting cap.
        uint256 baseAssets = accounting.maxWithdraw(false) / 4;
        assertGt(baseAssets, 0, "Senior must have redeemable NAV");
        uint256 expectedCoverageOut = Math.mulDiv(baseAssets, claimBefore, accounting.srtBaseNav());

        uint256 vaultFundedCoverageBefore = insuranceVault.fundedCoverage();
        uint256 navBefore = accounting.nav();

        uint256 shareAmount = strategy.convertToTokens(SUSDE, baseAssets, Math.Rounding.Ceil);
        vm.prank(srtVault);
        cdo.withdraw(srtVault, SUSDE, shareAmount, baseAssets, srtVault, user, "");

        // The covered slice left the vault in USDC and reached the user.
        uint256 coveragePaid = vaultFundedCoverageBefore - insuranceVault.fundedCoverage();
        assertGt(coveragePaid, 0, "the covered slice must be paid from the vault");
        assertEq(IERC20(USDC).balanceOf(user), coveragePaid, "user receives it in the coverage token");

        // The claim shrank by that slice, in base terms.
        assertApproxEqRel(
            claimBefore - accounting.insuranceAmount(),
            expectedCoverageOut,
            0.001e18,
            "claim shrinks by the covered slice"
        );

        // nav only dropped by what actually left the strategy, not the full redemption.
        uint256 navDrop = navBefore - accounting.nav();
        assertApproxEqRel(
            navDrop,
            baseAssets - expectedCoverageOut,
            0.001e18,
            "nav drops by the strategy slice only"
        );
        assertLt(navDrop, baseAssets, "the vault-paid slice must not come out of nav");

        uint256 insuranceBaseOut = claimBefore - accounting.insuranceAmount();
        assertEq(navDrop + insuranceBaseOut, baseAssets, "user receives exactly the redeemed value");
        assertLe(insuranceBaseOut, claimBefore, "cannot consume more claim than outstanding");
        assertLe(coveragePaid, vaultFundedCoverageBefore, "cannot draw more than the vault holds");
        assertLe(coveragePaid * 1e12, insuranceBaseOut, "payout never exceeds the claim slice");
        assertGe(coveragePaid * 1e12 + 1e12, insuranceBaseOut, "and is within one 6-dec unit of it");
    }

    /// Until the keeper funds the vault the covered slice has no backing, so a Senior redemption
    /// reverts rather than short-paying the user.
    function test_seniorRedemption_revertsWhileClaimUnfunded() public {
        _induceCoveredLoss();

        address srtVault = address(cdo.srtVault());
        uint256 baseAssets = accounting.maxWithdraw(false) / 4;
        uint256 shareAmount = strategy.convertToTokens(SUSDE, baseAssets, Math.Rounding.Ceil);

        assertEq(insuranceVault.fundedCoverage(), 0, "vault is unfunded");

        vm.expectPartialRevert(InsuranceVault.InsufficientCoverage.selector);
        vm.prank(srtVault);
        cdo.withdraw(srtVault, SUSDE, shareAmount, baseAssets, srtVault, makeAddr("u"), "");
    }

    /// A de-peg deep enough to exhaust Junior engages coverage, and the redeeming Senior is paid its
    /// covered slice at the de-pegged price. This is the case where `_baseToCoverage` actually
    /// applies valuationPrice: a base token is worth less than a dollar, so the coverage token owed
    /// is proportionally less than the base amount.
    function test_seniorRedemption_depegPaysCoverageAtValuationPrice() public {
        uint128 price = 0.1e18; // deep enough that Junior cannot absorb it
        vm.prank(CDO_PROXY);
        accounting.setValuationPrice(price);

        uint256 claim = accounting.insuranceAmount();
        assertGt(claim, 0, "a de-peg beyond Junior must engage coverage");

        // Fund the vault with the claim's dollar value at the de-pegged price, in 6-dec USDC.
        uint256 usdcNeeded = claim * price / 1e18 / 1e12;
        assertGt(usdcNeeded, 0);
        deal(USDC, multisig, usdcNeeded);
        vm.startPrank(multisig);
        IERC20(USDC).approve(CDO_PROXY, usdcNeeded);
        cdo.fundInsuranceClaim(USDC, usdcNeeded);
        vm.stopPrank();

        address srtVault = address(cdo.srtVault());
        address user = makeAddr("depegRedeemer");
        uint256 baseAssets = accounting.maxWithdraw(false) / 10;
        assertGt(baseAssets, 0, "Senior must have redeemable NAV");

        uint256 shareAmount = strategy.convertToTokens(SUSDE, baseAssets, Math.Rounding.Ceil);
        vm.prank(srtVault);
        cdo.withdraw(srtVault, SUSDE, shareAmount, baseAssets, srtVault, user, "");

        // The claim delta is the covered slice in base terms. Note updateBalanceFlow converts the
        // Senior outflow from effective to base terms first, so it is well below `baseAssets`.
        uint256 insuranceBaseOut = claim - accounting.insuranceAmount();
        assertGt(insuranceBaseOut, 0, "the redemption must consume part of the claim");

        uint256 paid = IERC20(USDC).balanceOf(user);
        uint256 expectedUsdc = insuranceBaseOut * price / 1e18 / 1e12;
        assertApproxEqRel(paid, expectedUsdc, 0.001e18, "coverage paid at the de-pegged price");

        // The whole point: at $0.10 the coverage token owed is far below the base amount it settles.
        assertLt(paid * 1e12, insuranceBaseOut, "a de-pegged claim costs less than par");

        // Not over-paid: the vault only ever gives out the de-pegged value of the claim slice, and
        // never more than it was funded with or more than the claim outstanding.
        assertLe(paid, usdcNeeded, "cannot draw more than the vault was funded with");
        assertLe(insuranceBaseOut, claim, "cannot consume more claim than outstanding");
        assertLe(paid * 1e12 * 1e18 / price, insuranceBaseOut + 1e12, "payout never exceeds the slice");
    }

    /// The full happy path in one go: loss -> synchronous slash -> swap -> fund the vault -> Senior
    /// redeems everything it can. Checks the end state the partial redemptions never reach, and in
    /// particular how close the claim gets to zero once the 18 -> 6 decimal truncation is in play.
    function test_endToEnd_happyPath_drainsTheClaim() public {
        _induceCoveredLoss();

        uint256 claimBefore = accounting.insuranceAmount();
        // Fund generously so the vault is never the binding constraint.
        uint256 usdcAmount = claimBefore / 1e12 + 1e6;
        deal(USDC, multisig, usdcAmount);
        vm.startPrank(multisig);
        IERC20(USDC).approve(CDO_PROXY, usdcAmount);
        cdo.fundInsuranceClaim(USDC, usdcAmount);
        vm.stopPrank();

        address srtVault = address(cdo.srtVault());
        address user = makeAddr("fullRedeemer");

        // Redeem everything the accounting allows.
        uint256 baseAssets = accounting.maxWithdraw(false);
        uint256 shareAmount = strategy.convertToTokens(SUSDE, baseAssets, Math.Rounding.Ceil);
        vm.prank(srtVault);
        cdo.withdraw(srtVault, SUSDE, shareAmount, baseAssets, srtVault, user, "");

        uint256 claimAfter = accounting.insuranceAmount();
        uint256 paid = IERC20(USDC).balanceOf(user);
        assertGt(paid, 0, "the covered slice was paid in the coverage token");

        // The claim is drained down to at most the truncation dust of a single 6-decimal unit: the
        // payout floors when scaling into USDC, so a wei-level remainder can be left behind.
        assertLt(claimAfter, 1e12, "claim drained to at most one 6-dec unit of dust");
        assertLe(claimAfter, claimBefore, "claim never grows on a redemption");

        // Senior is fully redeemed and the identity still holds.
        assertLe(accounting.srtBaseNav(), 1e18, "Srt redeemed down to its dust floor");
    }

    /// The de-peg equivalent of the unfunded case. The slice is sized differently here (the Senior
    /// outflow is converted to base terms and then priced at valuationPrice), so it needs its own
    /// coverage: a redemption still reverts until the swapped proceeds reach the vault.
    function test_seniorRedemption_depegRevertsWhileClaimUnfunded() public {
        uint128 price = 0.1e18;
        vm.prank(CDO_PROXY);
        accounting.setValuationPrice(price);

        assertGt(accounting.insuranceAmount(), 0, "a de-peg beyond Junior must engage coverage");
        assertEq(insuranceVault.fundedCoverage(), 0, "vault unfunded");

        address srtVault = address(cdo.srtVault());
        uint256 baseAssets = accounting.maxWithdraw(false) / 10;
        uint256 shareAmount = strategy.convertToTokens(SUSDE, baseAssets, Math.Rounding.Ceil);

        vm.expectPartialRevert(InsuranceVault.InsufficientCoverage.selector);
        vm.prank(srtVault);
        cdo.withdraw(srtVault, SUSDE, shareAmount, baseAssets, srtVault, makeAddr("u"), "");
    }

    /// Partial funding is not enough either: the vault reverts rather than short-paying the user.
    function test_seniorRedemption_revertsWhenVaultOnlyPartiallyFunded() public {
        _induceCoveredLoss();

        // Fund a tenth of what the claim is worth, so any sizeable redemption outruns it.
        uint256 claim = accounting.insuranceAmount();
        uint256 usdcAmount = claim / 1e12 / 10;
        deal(USDC, multisig, usdcAmount);
        vm.startPrank(multisig);
        IERC20(USDC).approve(CDO_PROXY, usdcAmount);
        cdo.fundInsuranceClaim(USDC, usdcAmount);
        vm.stopPrank();
        assertEq(insuranceVault.fundedCoverage(), usdcAmount, "vault only partially funded");

        address srtVault = address(cdo.srtVault());
        uint256 baseAssets = accounting.maxWithdraw(false);
        uint256 shareAmount = strategy.convertToTokens(SUSDE, baseAssets, Math.Rounding.Ceil);

        vm.expectPartialRevert(InsuranceVault.InsufficientCoverage.selector);
        vm.prank(srtVault);
        cdo.withdraw(srtVault, SUSDE, shareAmount, baseAssets, srtVault, makeAddr("u"), "");
    }

    function test_seniorRedemption_firstTouchAfterLoss_revertsUntilVaultFunded() public {
        // Drop the backing WITHOUT the keeper's updateAccounting, so no claim exists yet.
        uint256 strategyTvl = strategy.totalAssets();
        uint256 targetStrategyLoss = accounting.jrtNav() + accounting.reserveNav() + strategyTvl / 500;
        uint256 totalUsdeBacking = IERC20(USDE).balanceOf(SUSDE);
        deal(USDE, SUSDE, totalUsdeBacking - targetStrategyLoss * totalUsdeBacking / strategyTvl);

        assertEq(accounting.insuranceAmount(), 0, "no claim booked yet");
        assertEq(insuranceVault.fundedCoverage(), 0, "vault unfunded");
        uint256 uniBtcBefore = IERC20(UNIBTC).balanceOf(multisig);

        address srtVault = address(cdo.srtVault());
        uint256 baseAssets = accounting.maxWithdraw(false) / 10;
        uint256 shareAmount = strategy.convertToTokens(SUSDE, baseAssets, Math.Rounding.Ceil);

        // The redemption's own accounting update books the claim and slashes.
        vm.prank(CDO_PROXY);
        accounting.updateAccounting();
        assertGt(accounting.insuranceAmount(), 0, "claim booked");
        assertGt(IERC20(UNIBTC).balanceOf(multisig), uniBtcBefore, "collateral slashed");

        // It then cannot pay the covered slice, because the swap has not funded the vault yet.
        vm.expectPartialRevert(InsuranceVault.InsufficientCoverage.selector);
        vm.prank(srtVault);
        cdo.withdraw(srtVault, SUSDE, shareAmount, baseAssets, srtVault, makeAddr("firstToucher"), "");

        assertEq(insuranceVault.fundedCoverage(), 0, "vault still unfunded");
    }

    /// Drives the strategy NAV down past Jrt and the reserve into Srt, so coverage engages and is
    /// slashed synchronously. Shared by the end-to-end and redemption tests.
    function _induceCoveredLoss() internal {
        uint256 strategyTvl = strategy.totalAssets();
        uint256 targetStrategyLoss = accounting.jrtNav() + accounting.reserveNav() + strategyTvl / 500;
        uint256 totalUsdeBacking = IERC20(USDE).balanceOf(SUSDE);
        _induceLoss(targetStrategyLoss * totalUsdeBacking / strategyTvl);
        require(accounting.insuranceAmount() > 0, "expected a coverage claim");
    }

    function test_underwriterFee_accruesAndFlowsToUnderwriters() public {
        // Enable the underwriter fee skim (the middleware owns the underwriter fee policy)
        vm.prank(strataOps);
        middleware.setMarketUnderwriterFeeBps(CDO_PROXY, 0.1e18); // 10% of raw Senior risk premium

        // Strategy earns yield after Senior has accrued a positive target gain -> underwriter fee accrues
        vm.warp(block.timestamp + 365 days);
        _induceGain(strategy.totalAssets() / 50); // 2% gain
        uint256 underwriterFee = accounting.totalUnderwriterFeeNav();
        assertGt(underwriterFee, 0, "underwriter fee should accrue on gains");

        // Pay the underwriter fee in sUSDe straight to the AppAdapter
        uint256 adapterBefore = IERC20(SUSDE).balanceOf(address(adapter));
        vm.prank(multisig);
        cdo.payUnderwriterFee(SUSDE);
        uint256 paid = IERC20(SUSDE).balanceOf(address(adapter)) - adapterBefore;
        assertGt(paid, 0, "underwriter fee sUSDe must reach the adapter");
        assertLt(accounting.totalUnderwriterFeeNav(), 1e18, "underwriter fee bucket should be swept");

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

        assertGe(vault.totalAssets(), assetsBefore + uniBtcProceeds, "vault assets must grow by the underwriter fee");
        assertEq(vault.totalSupply(), supplyBefore, "no shares minted: underwriters appreciate");
    }

    function test_underwriterFee_manualMode_routesToSafe() public {
        // Switch to manual distribution: underwriter fee goes to a dedicated safe, not the AppAdapter.
        address rewardSafe = makeAddr("rewardSafe");
        address cdoOwner = IOwnableLike(CDO_PROXY).owner();
        vm.startPrank(cdoOwner);
        cdo.setUnderwriterFeeRewardSafe(rewardSafe);
        cdo.setManualUnderwriterFeeDistribution(true);
        vm.stopPrank();

        vm.prank(strataOps);
        middleware.setMarketUnderwriterFeeBps(CDO_PROXY, 0.1e18);

        vm.warp(block.timestamp + 365 days);
        _induceGain(strategy.totalAssets() / 50); // 2% gain
        assertGt(accounting.totalUnderwriterFeeNav(), 0, "underwriter fee should accrue on gains");

        uint256 safeBefore = IERC20(SUSDE).balanceOf(rewardSafe);
        uint256 adapterBefore = IERC20(SUSDE).balanceOf(address(adapter));

        vm.prank(multisig);
        cdo.payUnderwriterFee(SUSDE);

        assertGt(IERC20(SUSDE).balanceOf(rewardSafe) - safeBefore, 0, "underwriter fee sUSDe must reach the safe");
        assertEq(IERC20(SUSDE).balanceOf(address(adapter)), adapterBefore, "AppAdapter must not receive underwriter fee in manual mode");
        assertLt(accounting.totalUnderwriterFeeNav(), 1e18, "underwriter fee bucket should be swept");
    }
}
