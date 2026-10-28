// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { InsuranceMiddleware } from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { MockUSDe } from "../../../contracts/test/MockUSDe.sol";
import { MockStakedUSDe } from "../../../contracts/test/MockStakedUSDe.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { sUSDeStrategy as SUSDeStrategy } from "../../../contracts/tranches/strategies/ethena/sUSDeStrategy.sol";
import { sUSDeCooldownRequestImpl as SUSDeCooldownRequestImpl } from "../../../contracts/tranches/strategies/ethena/sUSDeCooldownRequestImpl.sol";
import { IsUSDe } from "../../../contracts/tranches/strategies/ethena/IsUSDe.sol";
import { ERC20Cooldown } from "../../../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import { UnstakeCooldown } from "../../../contracts/tranches/base/cooldown/UnstakeCooldown.sol";
import { CooldownBase } from "../../../contracts/tranches/base/cooldown/CooldownBase.sol";
import { IUnstakeHandler } from "../../../contracts/tranches/interfaces/cooldown/IUnstakeHandler.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { InsuranceVault } from "../../../contracts/tranches/symbiotic/InsuranceVault.sol";
import { OracleAdapter } from "../../../contracts/tranches/symbiotic/OracleAdapter.sol";
import { IInsuranceMiddleware } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import { IInsuranceVault } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import { IStrataAccounting } from "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { IRoundDataOracle } from "../../../contracts/tranches/oracles/interfaces/IRoundDataOracle.sol";
import { MockAppAdapter } from "../../symbiotic/NetworkMiddleware.t.sol";

/// @notice Chainlink-style push feed with a settable answer and update time
contract PocRoundFeed is IRoundDataOracle {
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice Local full stack: real StrataCDO, Tranches, Accounting, sUSDeStrategy (over the repo's
///         MockStakedUSDe), real InsuranceMiddleware, InsuranceVault and OracleAdapter. Only the
///         Symbiotic AppAdapter is the existing fixture mock
/// @dev Feeds use the live mainnet answers recorded at block 26043534 (USDe/USD 0.99985382,
///      uniBTC/BTC 1.030000000002678879, BTC/USD 84587.87) with the deployment default 24h heartbeat
abstract contract SymbioticCoverageStackBase is Test {

    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");
    bytes32 constant COOLDOWN_WORKER_ROLE = keccak256("COOLDOWN_WORKER_ROLE");

    uint256 constant START_TS = 1_790_207_087; // mainnet timestamp at block 26043534
    uint256 constant DEFAULT_HEARTBEAT = 86_400; // src/deployments/SymbioticDeployments.ts DEFAULT_HEARTBEAT

    int256 constant USDE_USD_ANSWER = 99_985_382;                 // 8 dec
    int256 constant UNIBTC_BTC_ANSWER = 1_030_000_000_002_678_879; // 18 dec
    int256 constant BTC_USD_ANSWER = 8_458_787_000_000;           // 8 dec

    uint256 constant JRT_DEPOSIT = 100_000e18;
    uint256 constant SRT_DEPOSIT = 900_000e18;
    uint256 constant STAKE = 10e8; // 10 uniBTC slashable in the AppAdapter

    address owner = address(this);
    address keeper = makeAddr("keeper");     // UPDATER_FEED_ROLE, drives onAprChanged
    address multisig = makeAddr("multisig"); // RESERVE_MANAGER_ROLE, funds the claim
    address alice = makeAddr("alice");       // Junior
    address bob = makeAddr("bob");           // Senior
    address carol = makeAddr("carol");       // Senior

    MockUSDe usde;
    MockStakedUSDe susde;
    MockERC20 usdc;
    MockERC20 unibtc;

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    Accounting accounting;
    SUSDeStrategy strategy;
    ERC20Cooldown erc20Cooldown;
    UnstakeCooldown unstakeCooldown;

    MockAppAdapter adapter;
    OracleAdapter oracle;
    InsuranceMiddleware middleware;
    InsuranceVault vault;
    PocRoundFeed usdeUsd;
    PocRoundFeed unibtcBtc;
    PocRoundFeed btcUsd;

    function setUp() public virtual {
        vm.warp(START_TS);

        usde = new MockUSDe();
        susde = new MockStakedUSDe(usde, owner, owner);
        usdc = new MockERC20("USDC", 6);
        unibtc = new MockERC20("uniBTC", 8);

        acm = new AccessControlManager(owner);

        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(usde)),
            abi.encodeWithSelector(StrataCDO.initialize.selector, owner, address(acm))
        )));
        jrt = _tranche("jrtUSDe");
        srt = _tranche("srtUSDe");

        erc20Cooldown = ERC20Cooldown(address(new ERC1967Proxy(
            address(new ERC20Cooldown()),
            abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
        )));
        unstakeCooldown = UnstakeCooldown(address(new ERC1967Proxy(
            address(new UnstakeCooldown()),
            abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
        )));
        {
            address[] memory tokens = new address[](1);
            tokens[0] = address(susde);
            IUnstakeHandler[] memory handlers = new IUnstakeHandler[](1);
            handlers[0] = IUnstakeHandler(address(new SUSDeCooldownRequestImpl(IsUSDe(address(susde)))));
            unstakeCooldown.setImplementations(tokens, handlers);
        }

        strategy = SUSDeStrategy(address(new ERC1967Proxy(
            address(new SUSDeStrategy(IERC4626(address(susde)))),
            abi.encodeWithSelector(
                SUSDeStrategy.initialize.selector,
                owner, address(acm), address(cdo), address(erc20Cooldown), address(unstakeCooldown)
            )
        )));

        accounting = Accounting(address(new ERC1967Proxy(
            address(new Accounting(18)),
            abi.encodeWithSelector(
                Accounting.initialize.selector,
                owner, address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(0))
            )
        )));

        cdo.configure(
            IAccounting(address(accounting)),
            IStrategy(address(strategy)),
            ITranche(address(jrt)),
            ITranche(address(srt))
        );

        acm.grantRole(COOLDOWN_WORKER_ROLE, address(strategy));
        acm.grantRole(PAUSER_ROLE, owner);
        acm.grantRole(UPDATER_FEED_ROLE, keeper);
        acm.grantRole(RESERVE_MANAGER_ROLE, multisig);
        cdo.setActionStates(address(0), true, true);

        // Symbiotic side
        adapter = new MockAppAdapter(address(unibtc));
        adapter.setSlashable(STAKE);

        oracle = OracleAdapter(address(new ERC1967Proxy(
            address(new OracleAdapter()),
            abi.encodeCall(OracleAdapter.initialize, (owner, address(acm)))
        )));
        usdeUsd = new PocRoundFeed();
        unibtcBtc = new PocRoundFeed();
        btcUsd = new PocRoundFeed();
        usdeUsd.set(USDE_USD_ANSWER, block.timestamp);
        unibtcBtc.set(UNIBTC_BTC_ANSWER, block.timestamp);
        btcUsd.set(BTC_USD_ANSWER, block.timestamp);
        oracle.setFeed(OracleAdapter.Feed(address(usde), usdeUsd, 8, DEFAULT_HEARTBEAT, address(0)));
        oracle.setFeed(OracleAdapter.Feed(address(btcUsd), btcUsd, 8, DEFAULT_HEARTBEAT, address(0)));
        oracle.setFeed(OracleAdapter.Feed(address(unibtc), unibtcBtc, 18, DEFAULT_HEARTBEAT, address(btcUsd)));

        middleware = InsuranceMiddleware(address(new ERC1967Proxy(
            address(new InsuranceMiddleware()),
            abi.encodeCall(InsuranceMiddleware.initialize, (owner, address(acm), address(adapter), address(oracle)))
        )));
        middleware.setMarket(address(cdo), IStrataAccounting(address(accounting)), address(usde), 0, true);

        vault = InsuranceVault(address(new ERC1967Proxy(
            address(new InsuranceVault()),
            abi.encodeCall(InsuranceVault.initialize, (owner, address(acm), IStrataCDO(address(cdo)), address(usdc)))
        )));
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(middleware)), IInsuranceVault(address(vault)));

        _beforeTrancheDeposits();

        // Tranche deposits (base asset USDe, staked into sUSDe by the strategy)
        _deposit(jrt, alice, JRT_DEPOSIT);
        _deposit(srt, bob, SRT_DEPOSIT / 2);
        _deposit(srt, carol, SRT_DEPOSIT / 2);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers

    /// @dev Hook for the external sUSDe state before the market is funded
    function _beforeTrancheDeposits() internal virtual {}

    function _tranche(string memory symbol) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(false)),
            abi.encodeWithSelector(
                Tranche.initialize.selector, owner, address(acm), symbol, symbol, IERC20(address(usde)), address(cdo)
            )
        )));
    }

    function _deposit(Tranche tranche, address user, uint256 amount) internal {
        usde.mint(user, amount);
        vm.startPrank(user);
        usde.approve(address(tranche), amount);
        tranche.deposit(address(usde), amount, user);
        vm.stopPrank();
    }

    /// @dev Exogenous loss in the underlying protocol: USDe leaves the sUSDe vault
    function _underlyingLoss(uint256 usdeAmount) internal {
        vm.prank(address(susde));
        usde.transfer(address(0xdead), usdeAmount);
    }

    /// @dev Keeper-driven accounting refresh (Accounting.onAprChanged -> updateAccountingInner)
    function _keeperSync() internal {
        vm.prank(keeper);
        accounting.onAprChanged();
    }

    /// @dev Exogenous loss sized so the strategy's share of it is about `baseLoss` (other sUSDe holders
    ///      take their pro-rata part)
    function _strategyLoss(uint256 baseLoss) internal {
        _underlyingLoss(baseLoss * susde.totalAssets() / strategy.totalAssets());
    }

    /// @dev Books a Senior-bound NAV loss of about `srtBound` base assets after wiping Junior to its floor
    function _bookSeniorBoundLoss(uint256 srtBound) internal {
        _keeperSync();
        _strategyLoss(accounting.jrtBaseNav() - 1e18 + accounting.reserveNav() + srtBound);
        _keeperSync();
    }

    /// @dev Runbook step: the multisig swaps the slashed uniBTC into USDC and funds the vault
    function _fundOutstandingClaim() internal returns (uint256 usdcAmount) {
        usdcAmount = accounting.insuranceAmount() / 1e12 + 1; // $1 USDC per base unit, rounded up
        usdc.mint(multisig, usdcAmount);
        vm.startPrank(multisig);
        usdc.approve(address(cdo), usdcAmount);
        cdo.fundInsuranceClaim(address(usdc), usdcAmount);
        vm.stopPrank();
    }

    function _pending() internal view returns (uint256 pending) {
        (,,, pending,,) = middleware.markets(address(cdo));
    }

    function _totalSlashed() internal view returns (uint256 total) {
        (,, total,,,) = middleware.markets(address(cdo));
    }

    /// @dev Vault asset -> base asset at the valuation and collateral prices, same arithmetic as InsuranceMiddleware._toBaseAsset
    function _vaultToBase(uint256 vaultAmount) internal view returns (uint256) {
        uint256 basePrice = accounting.valuationPrice();
        (uint256 vaultPrice,) = oracle.getPrice(address(unibtc));
        return vaultAmount * vaultPrice * 1e10 / basePrice;
    }
}

/// @notice Regression adapted from Cyfrin: funding must not reserve or slash the same claim twice.
contract FundedClaimReservedTwiceTest is SymbioticCoverageStackBase {
    uint256 constant FIRST_SRT_BOUND_LOSS = 400_000e18;
    uint256 constant SECOND_SRT_BOUND_LOSS = 300_000e18;

    function test_fundingPreservesCapacityForFurtherLoss() public {
        _bookSeniorBoundLoss(FIRST_SRT_BOUND_LOSS);
        uint256 claim = accounting.insuranceAmount();
        uint256 capacityBefore = middleware.request(address(cdo), type(uint128).max);
        assertEq(capacityBefore, _vaultToBase(adapter.slashable()));
        assertGt(capacityBefore, SECOND_SRT_BOUND_LOSS);
        uint256 snap = vm.snapshotState();

        _fundOutstandingClaim();
        assertEq(_pending(), 0);
        assertEq(accounting.insuranceAmount(), claim);
        assertEq(middleware.slashedClaimBase(address(cdo)), claim);
        // The rounding excess of funded coverage is now reusable.
        uint256 surplus = vault.fundedCoverage() * 1e12 - claim;
        assertEq(middleware.request(address(cdo), type(uint128).max), capacityBefore + surplus);

        uint256 srtBefore = accounting.srtBaseNav();
        _strategyLoss(SECOND_SRT_BOUND_LOSS);
        _keeperSync();
        uint256 fundedCoverage = accounting.insuranceAmount() - claim;
        assertApproxEqAbs(fundedCoverage, SECOND_SRT_BOUND_LOSS, 2);
        assertEq(accounting.srtBaseNav(), srtBefore);
        assertEq(middleware.slashedClaimBase(address(cdo)), accounting.insuranceAmount());

        vm.revertToState(snap);
        _strategyLoss(SECOND_SRT_BOUND_LOSS);
        _keeperSync();
        assertEq(accounting.insuranceAmount() - claim, fundedCoverage);
        assertEq(accounting.srtBaseNav(), srtBefore);
    }

    function test_fundingPreservesSlashedBacking() public {
        _bookSeniorBoundLoss(FIRST_SRT_BOUND_LOSS);
        uint256 slashed = _totalSlashed();

        uint256 remainingStake = adapter.slashable();
        _fundOutstandingClaim();
        assertEq(adapter.slashable(), remainingStake);
        assertEq(_totalSlashed(), slashed);
        assertEq(_pending(), 0);
    }
}
