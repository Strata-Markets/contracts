// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControlManager} from "../../contracts/governance/AccessControlManager.sol";
import {StrataCDO} from "../../contracts/tranches/StrataCDO.sol";
import {Tranche} from "../../contracts/tranches/Tranche.sol";
import {DiscreteAccounting as Accounting} from "../../contracts/tranches/DiscreteAccounting.sol";
import {IsolatedStrategy} from "../../contracts/tranches/strategies/IsolatedStrategy.sol";
import {MidasStrategy} from "../../contracts/tranches/strategies/midas/MidasStrategy.sol";
import {SparkUSDCStrategy} from "../../contracts/tranches/strategies/spark/SparkUSDCStrategy.sol";
import {ISparkVault} from "../../contracts/tranches/strategies/spark/ISparkVault.sol";
import {IMToken} from "../../contracts/tranches/strategies/midas/interfaces/IMToken.sol";
import {IDepositVault} from "../../contracts/tranches/strategies/midas/interfaces/IDepositVault.sol";
import {IRedemptionVault} from "../../contracts/tranches/strategies/midas/interfaces/IRedemptionVault.sol";
import {IRoundDataOracle} from "../../contracts/tranches/strategies/midas/AaveOracleAprPairProvider.sol";
import {IAccounting} from "../../contracts/tranches/interfaces/IAccounting.sol";
import {IStrategy} from "../../contracts/tranches/interfaces/IStrategy.sol";
import {ITranche} from "../../contracts/tranches/interfaces/ITranche.sol";
import {IStrataCDO} from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import {MockBaseAsset} from "../../contracts/test/midas/MockBaseAsset.sol";
import {MockMToken} from "../../contracts/test/midas/MockMToken.sol";
import {MockOracle} from "../../contracts/test/midas/MockOracle.sol";
import {MockDepositVault} from "../../contracts/test/midas/MockDepositVault.sol";
import {MockRedemptionVault} from "../../contracts/test/midas/MockRedemptionVault.sol";
import {MockERC4626} from "../../contracts/test/MockERC4626.sol";
import {MockAprPairFeed} from "../../contracts/test/MockAprPairFeed.sol";
import {UnstakeCooldown} from "../../contracts/tranches/base/cooldown/UnstakeCooldown.sol";
import {ERC20Cooldown} from "../../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import {CooldownBase} from "../../contracts/tranches/base/cooldown/CooldownBase.sol";
import {IERC20Cooldown} from "../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import {MidasCooldownRequestImpl} from "../../contracts/tranches/strategies/midas/MidasCooldownRequestImpl.sol";
import {IUnstakeHandler} from "../../contracts/tranches/interfaces/cooldown/IUnstakeHandler.sol";
import {ICooldown} from "../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import {Rebalancer} from "../../contracts/tranches/strategies/base/Rebalancer.sol";

import {console2} from "forge-std/console2.sol";

// Base deploy contract for integration tests using real Spark (junior) and Midas (senior) strats.
contract IsolatedIntegrationDeploy is Test {
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 internal constant COOLDOWN_WORKER_ROLE = keccak256("COOLDOWN_WORKER_ROLE");

    address internal owner;

    // CDO infrastructure
    MockBaseAsset internal baseAsset;         // 6-decimal USDC
    AccessControlManager internal acm;
    StrataCDO internal cdo;
    Tranche internal jrtVault;
    Tranche internal srtVault;
    MockAprPairFeed internal aprFeed;
    IsolatedStrategy internal strategy;
    Accounting internal accounting;

    // Junior strat — Spark (ERC4626 wrapping baseAsset)
    MockERC4626 internal spVault;
    SparkUSDCStrategy internal juniorStrat;

    Rebalancer internal rebalancer;

    // Senior strat — Midas mHYPER
    MockMToken internal mHYPER;
    MockOracle internal oracle;
    MockDepositVault internal depositVault;
    MockRedemptionVault internal redemptionVault;
    ERC20Cooldown internal erc20Cooldown;
    UnstakeCooldown internal unstakeCooldown;
    MidasCooldownRequestImpl internal midasCooldownImpl;
    MidasStrategy internal seniorStrat;

    function setUp() public virtual {
        owner = makeAddr("integrationOwner");
        vm.label(owner, "IntegrationOwner");
        vm.deal(owner, 100 ether);
    }

    function _deployIntegrationStack() internal {
        vm.startPrank(owner);

        // 1. Base asset (6 dec — matches USDC)
        baseAsset = new MockBaseAsset();
        vm.label(address(baseAsset), "BaseAsset");

        // 2. Access control
        acm = new AccessControlManager(owner);
        vm.label(address(acm), "ACM");

        // 3. CDO
        StrataCDO cdoImpl = new StrataCDO(IERC20Metadata(address(baseAsset)));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(cdoImpl),
            abi.encodeWithSelector(StrataCDO.initialize.selector, owner, address(acm))
        )));
        vm.label(address(cdo), "StrataCDO");

        // 4. Tranches
        jrtVault = _deployTranche("JRT", "Junior Tranche");
        srtVault = _deployTranche("SRT", "Senior Tranche");

        // 5. APR feed
        aprFeed = new MockAprPairFeed();
        vm.label(address(aprFeed), "AprFeed");

        // 6. Midas mHYPER infrastructure — oracle starts at $1.00 (1e8 in 8-dec Chainlink)
        mHYPER = new MockMToken();
        vm.label(address(mHYPER), "mHYPER");
        oracle = new MockOracle(); // constructor sets roundId=1, answer=1e8
        vm.label(address(oracle), "Oracle");
        depositVault = new MockDepositVault(mHYPER, oracle);
        vm.label(address(depositVault), "DepositVault");
        redemptionVault = new MockRedemptionVault(mHYPER, baseAsset, oracle);
        redemptionVault.setInstantEnabled(true);
        redemptionVault.setOracle(oracle);
        vm.label(address(redemptionVault), "RedemptionVault");

        // 7. Midas ERC20Cooldown + UnstakeCooldown + MidasCooldownRequestImpl for mHYPER
        ERC20Cooldown erc20CooldownImpl = new ERC20Cooldown();
        erc20Cooldown = ERC20Cooldown(address(new ERC1967Proxy(
            address(erc20CooldownImpl),
            abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
        )));
        vm.label(address(erc20Cooldown), "MidasERC20Cooldown");

        UnstakeCooldown unstakeCooldownImpl = new UnstakeCooldown();
        unstakeCooldown = UnstakeCooldown(address(new ERC1967Proxy(
            address(unstakeCooldownImpl),
            abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
        )));
        vm.label(address(unstakeCooldown), "MidasUnstakeCooldown");

        midasCooldownImpl = new MidasCooldownRequestImpl(
            IERC20(address(baseAsset)),
            IMToken(address(mHYPER)),
            IRedemptionVault(address(redemptionVault))
        );
        vm.label(address(midasCooldownImpl), "MidasCooldownImpl");

        address[] memory cooldownTokens = new address[](1);
        cooldownTokens[0] = address(mHYPER);
        IUnstakeHandler[] memory cooldownImpls = new IUnstakeHandler[](1);
        cooldownImpls[0] = IUnstakeHandler(address(midasCooldownImpl));
        unstakeCooldown.setImplementations(cooldownTokens, cooldownImpls);

        // 8. Spark vault (ERC4626 wrapping baseAsset — simulates Spark USDC vault)
        spVault = new MockERC4626(IERC20(address(baseAsset)));
        vm.label(address(spVault), "SpVault");

        // 8. Deploy strategy proxy without initializing — strats need its address first
        IsolatedStrategy strategyImpl = new IsolatedStrategy();
        strategy = IsolatedStrategy(address(new ERC1967Proxy(address(strategyImpl), "")));
        vm.label(address(strategy), "IsolatedStrategy");

        // 9. Deploy strat implementations (immutables) and proxies (initialize with strategy address)
        SparkUSDCStrategy sparkImpl = new SparkUSDCStrategy(ISparkVault(address(spVault)));
        juniorStrat = SparkUSDCStrategy(address(new ERC1967Proxy(
            address(sparkImpl),
            abi.encodeWithSelector(SparkUSDCStrategy.initialize.selector, owner, address(acm), IStrataCDO(address(strategy)), erc20Cooldown)
        )));
        vm.label(address(juniorStrat), "JuniorStrat(Spark)");

        MidasStrategy midasImpl = new MidasStrategy(
            IERC20(address(baseAsset)),
            IMToken(address(mHYPER)),
            IDepositVault(address(depositVault)),
            IRedemptionVault(address(redemptionVault)),
            IRoundDataOracle(address(oracle))
        );
        address[] memory depositTokens_ = new address[](0);
        seniorStrat = MidasStrategy(address(new ERC1967Proxy(
            address(midasImpl),
            abi.encodeWithSelector(
                MidasStrategy.initialize.selector,
                owner, address(acm), address(strategy),
                address(erc20Cooldown), address(unstakeCooldown),
                depositTokens_
            )
        )));
        vm.label(address(seniorStrat), "SeniorStrat(Midas)");
        acm.grantRole(COOLDOWN_WORKER_ROLE, address(juniorStrat));
        acm.grantRole(COOLDOWN_WORKER_ROLE, address(seniorStrat));

        // 10. Initialize strategy now that both strat proxies exist
        IsolatedStrategy(address(strategy)).initialize(
            owner,
            address(acm),
            IStrataCDO(address(cdo)),
            3e17 // juniorAllocationFloor: 30%
        );
        IsolatedStrategy(address(strategy)).configureStrategies(
            IStrategy(address(juniorStrat)),
            IStrategy(address(seniorStrat))
        );


        // 11. Rebalancer
        Rebalancer rebalancerImpl = new Rebalancer(4, 100e6);
        rebalancer = Rebalancer(address(new ERC1967Proxy(
            address(rebalancerImpl),
            abi.encodeWithSelector(Rebalancer.initialize.selector, owner, address(acm), address(strategy), address(unstakeCooldown))
        )));
        strategy.setRebalancer(rebalancer);
        vm.label(address(rebalancer), "Rebalancer");

        // 13. Accounting (6-dec NAV, matching baseAsset)
        Accounting accountingImpl = new Accounting(6, true);
        accounting = Accounting(address(new ERC1967Proxy(
            address(accountingImpl),
            abi.encodeWithSelector(Accounting.initialize.selector, owner, address(acm), IStrataCDO(address(cdo)), aprFeed)
        )));
        vm.label(address(accounting), "Accounting");

        acm.grantRole(PAUSER_ROLE, owner);

        cdo.configure(
            IAccounting(address(accounting)),
            IStrategy(address(strategy)),
            ITranche(address(jrtVault)),
            ITranche(address(srtVault))
        );
        cdo.setActionStates(address(0), true, true);

        vm.stopPrank();
    }

    function _deployTranche(string memory symbol, string memory name) internal returns (Tranche) {
        Tranche trancheImpl = new Tranche(false);
        address proxy = address(new ERC1967Proxy(
            address(trancheImpl),
            abi.encodeWithSelector(
                Tranche.initialize.selector,
                owner,
                address(acm),
                name,
                symbol,
                IERC20(address(baseAsset)),
                IStrataCDO(address(cdo))
            )
        ));
        vm.label(proxy, symbol);
        return Tranche(proxy);
    }

    // Debt toward a strat == that strat's deficit in imbalances() (debts() was removed).
    function _debtToJunior() internal view returns (uint256) {
        (uint256 deficitStratIdx, uint256 deficitAmount,,) = strategy.imbalances();
        return deficitStratIdx == 0 ? deficitAmount : 0;
    }

    function _debtToSenior() internal view returns (uint256) {
        (uint256 deficitStratIdx, uint256 deficitAmount,,) = strategy.imbalances();
        return deficitStratIdx == 1 ? deficitAmount : 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Integration tests: real Spark (junior) + real Midas mHYPER (senior) strats
// ─────────────────────────────────────────────────────────────────────────────
contract IsolatedVaultIntegration is IsolatedIntegrationDeploy {
    address internal alice;
    address internal bob;

    // 6-decimal USDC amounts
    uint256 internal constant INITIAL_BALANCE = 10_000e6;
    uint256 internal constant DEPOSIT_AMOUNT  = 1_000e6;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob   = makeAddr("bob");
        vm.label(alice, "Alice");
        vm.label(bob,   "Bob");

        _deployIntegrationStack();

        baseAsset.mint(alice, INITIAL_BALANCE);
        baseAsset.mint(bob,   INITIAL_BALANCE);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deposit routing
    // ─────────────────────────────────────────────────────────────────────────

    function test_Integration_JrtDeposit_RoutesToSparkStrat() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        // Junior strat should hold Spark vault shares; senior strat should be empty
        uint256 spShares = spVault.balanceOf(address(juniorStrat));
        assertGt(spShares, 0, "Junior strat should hold Spark vault shares");
        assertEq(juniorStrat.totalAssets(), DEPOSIT_AMOUNT, "Junior strat totalAssets should match deposit");

        assertEq(mHYPER.balanceOf(address(seniorStrat)), 0, "Senior strat should remain empty");
        assertEq(seniorStrat.totalAssets(), 0, "Senior strat totalAssets should be zero");
    }

    function test_Integration_SrtDeposit_RoutesToMidasStrat() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT); // JRT must exist before SRT
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // Senior strat should hold mHYPER; junior strat unchanged
        uint256 mHyperBalance = mHYPER.balanceOf(address(seniorStrat));
        assertEq(mHyperBalance, DEPOSIT_AMOUNT * 1e12, "Senior strat should hold mHYPER (18 dec)");
        assertEq(seniorStrat.totalAssets(), DEPOSIT_AMOUNT, "Senior strat totalAssets should match deposit");

        // Junior strat unchanged
        assertGt(spVault.balanceOf(address(juniorStrat)), 0, "Junior strat Spark shares unchanged");
        assertEq(juniorStrat.totalAssets(), DEPOSIT_AMOUNT, "Junior strat totalAssets unchanged");
    }

    function test_Integration_TotalStrategyAssets_SumOfBothStrats() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        (uint256 jrtAssets, uint256 srtAssets) = strategy.totalAssetsByTranche();
        assertEq(jrtAssets, DEPOSIT_AMOUNT, "JRT strategy assets should equal junior strat");
        assertEq(srtAssets, DEPOSIT_AMOUNT, "SRT strategy assets should equal senior strat");
        assertEq(cdo.totalStrategyAssets(), 2 * DEPOSIT_AMOUNT, "Total should be sum of both strats");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Cross-strat withdrawal
    // ─────────────────────────────────────────────────────────────────────────

    function test_Integration_SrtWithdraw_BorrowsFromSparkFirst() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2; // 500 USDC

        uint256 aliceBalBefore = baseAsset.balanceOf(alice);
        uint256 juniorSharesBefore = spVault.balanceOf(address(juniorStrat));

        vm.startPrank(alice);
        srtVault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        // Spark is liquid — alice receives funds immediately, no cooldown
        assertEq(baseAsset.balanceOf(alice) - aliceBalBefore, withdrawAmount, "Alice should receive the withdrawn assets");

        // Junior strat (Spark) was consumed
        uint256 juniorSharesAfter = spVault.balanceOf(address(juniorStrat));
        assertLt(juniorSharesAfter, juniorSharesBefore, "Junior strat Spark shares reduced");
        assertApproxEqAbs(
            juniorStrat.totalAssets(),
            DEPOSIT_AMOUNT - withdrawAmount,
            1,
            "Junior strat totalAssets reduced by withdrawal"
        );

        // Senior strat (Midas) untouched
        assertEq(mHYPER.balanceOf(address(seniorStrat)), DEPOSIT_AMOUNT * 1e12, "Senior strat mHYPER unchanged");

        // Debt recorded
        assertApproxEqAbs(_debtToJunior(), withdrawAmount, 2, "seniorDebtToJunior tracks borrowed amount");
    }

    function test_Integration_SrtWithdraw_FallsBackToMidas_WhenSparkInsufficient() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);       // 1000 in Spark
        _depositToSrt(alice, DEPOSIT_AMOUNT * 2);   // 2000 in Midas (needs extra JRT buffer)

        // Withdraw more than Spark has: 1500 > 1000
        uint256 withdrawAmount = DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2;

        uint256 aliceBalBefore = baseAsset.balanceOf(alice);

        vm.startPrank(alice);
        srtVault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        // Midas (senior/own strat) covers the remainder — async cooldown for alice
        ICooldown.TBalanceState memory state = unstakeCooldown.balanceOf(IERC20(address(mHYPER)), address(alice));

        // Spark portion (1000) is instant; Midas portion (500) is pending
        assertEq(baseAsset.balanceOf(alice) - aliceBalBefore, withdrawAmount - state.pending, "Alice receives Spark portion immediately");

        // Junior strat (Spark) fully drained
        assertApproxEqAbs(juniorStrat.totalAssets(), 0, 1, "Junior strat (Spark) fully drained");
        // Junior's accounting entitlement is above the 30% liquid allocation floor, so imbalances()
        // reports the full entitlement deficit instead of capping it at the floor target.
        assertApproxEqAbs(_debtToJunior(), DEPOSIT_AMOUNT, 2, "Junior deficit follows entitlement above floor");

        // Senior strat (Midas) provided the remainder
        uint256 remainder = withdrawAmount - DEPOSIT_AMOUNT;
        assertApproxEqAbs(
            DEPOSIT_AMOUNT * 2 - seniorStrat.totalAssets(),
            remainder,
            1,
            "Senior strat (Midas) covered the remainder"
        );
    }

    function test_Integration_JrtWithdraw_BorrowsFromMidasFirst() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2; // 500 USDC

        uint256 aliceBalBefore = baseAsset.balanceOf(alice);
        uint256 seniorMhyperBefore = mHYPER.balanceOf(address(seniorStrat));

        vm.startPrank(alice);
        jrtVault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        // Midas is async — complete the cooldown for alice
        ICooldown.TBalanceState memory state = unstakeCooldown.balanceOf(IERC20(address(mHYPER)), address(alice));

        vm.warp(block.timestamp + 3 days);
        redemptionVault.fulfillRequest(0); // simulate Midas admin approval
        unstakeCooldown.finalize(IERC20(address(mHYPER)), address(alice));

        // Alice received the withdrawn assets
        assertEq(baseAsset.balanceOf(alice) - aliceBalBefore, withdrawAmount, "Alice should receive withdrawn assets");

        // Senior strat (Midas) was consumed
        uint256 seniorMhyperAfter = mHYPER.balanceOf(address(seniorStrat));
        assertEq(seniorMhyperBefore - seniorMhyperAfter, withdrawAmount * 1e12, "Senior strat mHYPER consumed");
        assertApproxEqAbs(
            seniorStrat.totalAssets(),
            DEPOSIT_AMOUNT - withdrawAmount,
            1,
            "Senior strat totalAssets reduced by withdrawal"
        );

        // Junior strat (Spark) untouched
        assertApproxEqAbs(juniorStrat.totalAssets(), DEPOSIT_AMOUNT, 1, "Junior strat Spark unchanged");

        // Debt recorded
        assertApproxEqAbs(_debtToSenior(), withdrawAmount, 2, "juniorDebtToSenior tracks borrowed amount");
    }

    function test_Integration_JrtWithdraw_FallsBackToSpark_WhenMidasInsufficient() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT); // 1000 in Spark

        uint256 srtDeposit = 300e6; // only 300 USDC in Midas
        _depositToSrt(alice, srtDeposit);

        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2; // 500 > 300

        uint256 aliceBalBefore = baseAsset.balanceOf(alice);

        vm.startPrank(alice);
        jrtVault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        // Midas (senior) provides 300 async; Spark (junior/own strat) provides 200 instantly
        ICooldown.TBalanceState memory state = unstakeCooldown.balanceOf(IERC20(address(mHYPER)), address(alice));

        assertEq(baseAsset.balanceOf(alice) - aliceBalBefore, withdrawAmount - state.pending, "Alice receives Spark portion immediately");

        // Senior strat (Midas) fully drained
        assertApproxEqAbs(seniorStrat.totalAssets(), 0, 1, "Senior strat fully drained");

        // Junior strat (Spark) provided the remainder
        uint256 remainderFromJunior = withdrawAmount - srtDeposit;
        assertApproxEqAbs(
            juniorStrat.totalAssets(),
            DEPOSIT_AMOUNT - remainderFromJunior,
            1,
            "Junior strat reduced by remainder"
        );

        assertEq(_debtToSenior(), srtDeposit, "Debt equals full senior amount borrowed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Debt repayment
    // ─────────────────────────────────────────────────────────────────────────

    function test_Integration_RepaySeniorDebtToJunior_RestoresStratAssets() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // SRT borrows 500 from the Spark (junior) strat — instant
        uint256 borrowAmount = DEPOSIT_AMOUNT / 2;
        vm.startPrank(alice);
        srtVault.withdraw(borrowAmount, alice, alice);
        vm.stopPrank();

        uint256 juniorDebt = _debtToJunior();
        assertApproxEqAbs(juniorDebt, borrowAmount, 2);

        uint256 juniorAssetsBefore = juniorStrat.totalAssets();
        uint256 seniorAssetsBefore = seniorStrat.totalAssets();

        // Repay: moves juniorDebt from Midas strat (idx 1) → Spark strat (idx 0)
        // Source is Midas (async) — rebalancer goes through cooldown
        vm.startPrank(owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        rebalancer.initiateRebalance(1, 0, address(baseAsset), address(baseAsset), juniorDebt);
        vm.stopPrank();

        ICooldown.TBalanceState memory state = unstakeCooldown.balanceOf(IERC20(address(mHYPER)), address(rebalancer));
        console2.log("state.pending: ", state.pending);

        vm.warp(block.timestamp + 1 weeks);
        redemptionVault.fulfillRequest(0); // simulate Midas admin approval
        vm.prank(owner);
        rebalancer.completeRebalance(0, 0);

        assertApproxEqAbs(state.pending, borrowAmount, 2, "Pending amount should be the borrowed amount");

        assertEq(_debtToJunior(), 0, "Debt cleared after repayment");
        assertApproxEqAbs(
            juniorStrat.totalAssets(),
            juniorAssetsBefore + borrowAmount,
            1,
            "Junior strat restored"
        );
        assertApproxEqAbs(
            seniorStrat.totalAssets(),
            seniorAssetsBefore - borrowAmount,
            1,
            "Senior strat decremented"
        );
    }

    function test_Integration_RepayJuniorDebtToSenior_RestoresStratAssets() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // JRT borrows 500 from the Midas (senior) strat — async
        uint256 borrowAmount = DEPOSIT_AMOUNT / 2;
        vm.startPrank(alice);
        jrtVault.withdraw(borrowAmount, alice, alice);
        vm.stopPrank();

        uint256 seniorDebt = _debtToSenior();
        assertApproxEqAbs(seniorDebt, borrowAmount, 2);

        // Complete alice's Midas cooldown before recording baseline assets
        vm.warp(block.timestamp + 1 weeks);
        redemptionVault.fulfillRequest(0); // simulate Midas admin approval
        unstakeCooldown.finalize(IERC20(address(mHYPER)), address(alice));

        uint256 juniorAssetsBefore = juniorStrat.totalAssets();
        uint256 seniorAssetsBefore = seniorStrat.totalAssets();

        // Repay: moves borrowAmount from Spark strat (idx 0) → Midas strat (idx 1)
        // Source is Spark (instant) — no cooldown needed
        vm.startPrank(owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        rebalancer.initiateRebalance(0, 1, address(baseAsset), address(baseAsset), borrowAmount);
        vm.stopPrank();

        assertEq(_debtToSenior(), 0, "Debt cleared after repayment");
        assertApproxEqAbs(
            seniorStrat.totalAssets(),
            seniorAssetsBefore + borrowAmount,
            1,
            "Senior strat restored"
        );
        assertApproxEqAbs(
            juniorStrat.totalAssets(),
            juniorAssetsBefore - borrowAmount,
            1,
            "Junior strat decremented"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // initiateRebalanceByDebt — auto-resolved direction and amount
    // ─────────────────────────────────────────────────────────────────────────

    function test_Integration_InitiateRebalanceByDebt_Reverts_WhenNoDebt() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        vm.startPrank(owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        vm.expectRevert("NoDeficit");
        rebalancer.initiateRebalanceByDebt(address(baseAsset), address(baseAsset));
        vm.stopPrank();
    }

    // SRT borrowed Spark liquidity (toJunior) → rebalancer routes Midas→Spark automatically (async).
    function test_Integration_InitiateRebalanceByDebt_ToJunior_AsyncMidasRebalance() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        uint256 borrowAmount = DEPOSIT_AMOUNT / 2;
        vm.startPrank(alice);
        srtVault.withdraw(borrowAmount, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(_debtToJunior(), borrowAmount, 2, "Debt to junior recorded");

        uint256 juniorAssetsBefore = juniorStrat.totalAssets();
        uint256 seniorAssetsBefore = seniorStrat.totalAssets();

        // No manual direction or amount
        vm.startPrank(owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        rebalancer.initiateRebalanceByDebt(address(baseAsset), address(baseAsset));
        vm.stopPrank();

        assertEq(rebalancer.pendingCount(), 1, "Rebalance pending in Midas cooldown");

        vm.warp(block.timestamp + 1 weeks);
        redemptionVault.fulfillRequest(0);
        vm.prank(owner);
        rebalancer.completeRebalance(0, 0);

        assertEq(_debtToJunior(), 0, "Debt cleared after rebalance completes");
        assertApproxEqAbs(juniorStrat.totalAssets(), juniorAssetsBefore + borrowAmount, 1, "Junior strat restored");
        assertApproxEqAbs(seniorStrat.totalAssets(), seniorAssetsBefore - borrowAmount, 1, "Senior strat decremented");
    }

    // JRT borrowed Midas liquidity (toSenior) → rebalancer routes Spark→Midas automatically (instant).
    function test_Integration_InitiateRebalanceByDebt_ToSenior_InstantSparkRebalance() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        uint256 borrowAmount = DEPOSIT_AMOUNT / 2;
        vm.startPrank(alice);
        jrtVault.withdraw(borrowAmount, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(_debtToSenior(), borrowAmount, 2, "Debt to senior recorded");

        // Settle alice's async Midas cooldown before snapshotting baseline
        vm.warp(block.timestamp + 1 weeks);
        redemptionVault.fulfillRequest(0);
        unstakeCooldown.finalize(IERC20(address(mHYPER)), address(alice));

        uint256 juniorAssetsBefore = juniorStrat.totalAssets();
        uint256 seniorAssetsBefore = seniorStrat.totalAssets();

        // No manual direction or amount
        vm.startPrank(owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        rebalancer.initiateRebalanceByDebt(address(baseAsset), address(baseAsset));
        vm.stopPrank();

        // Spark is liquid — rebalance completes in same tx, no pending
        assertEq(rebalancer.pendingCount(), 0, "No pending rebalance Spark is instant");
        assertApproxEqAbs(seniorStrat.totalAssets(), seniorAssetsBefore + borrowAmount, 1, "Senior strat restored");
        assertApproxEqAbs(juniorStrat.totalAssets(), juniorAssetsBefore - borrowAmount, 1, "Junior strat decremented");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // initiateRebalance debt cap
    // ─────────────────────────────────────────────────────────────────────────

    function test_Integration_InitiateRebalance_Reverts_WhenExceedsDebtToJunior() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        uint256 borrowAmount = DEPOSIT_AMOUNT / 2; // 500
        vm.startPrank(alice);
        srtVault.withdraw(borrowAmount, alice, alice);
        vm.stopPrank();

        (, uint256 deficitAmount,,) = strategy.imbalances();
        assertApproxEqAbs(deficitAmount, borrowAmount, 2, "Junior deficit recorded");

        vm.startPrank(owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        vm.expectRevert("ExceedsDeficit");
        rebalancer.initiateRebalance(1, 0, address(baseAsset), address(baseAsset), deficitAmount + 1);
        vm.stopPrank();
    }

    function test_Integration_InitiateRebalance_Reverts_WhenExceedsDebtToSenior() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        uint256 borrowAmount = DEPOSIT_AMOUNT / 2; // 500
        vm.startPrank(alice);
        jrtVault.withdraw(borrowAmount, alice, alice);
        vm.stopPrank();

        uint256 seniorDebtCap = _debtToSenior();
        assertApproxEqAbs(seniorDebtCap, borrowAmount, 2, "Debt to senior recorded");

        vm.startPrank(owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        vm.expectRevert("ExceedsDeficit");
        rebalancer.initiateRebalance(0, 1, address(baseAsset), address(baseAsset), seniorDebtCap + 1);
        vm.stopPrank();
    }

    // No swap path exists, so withdrawToken must equal depositToken; a mismatch reverts before
    // any withdrawal, preventing funds from being withdrawn in one token while the pending entry
    // waits on another that never arrives.
    function test_Integration_InitiateRebalance_Reverts_WhenTokenMismatch() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // Create a junior deficit / senior surplus so the imbalance checks pass and execution
        // reaches the withdrawToken == depositToken guard.
        vm.prank(alice);
        srtVault.withdraw(DEPOSIT_AMOUNT / 2, alice, alice);
        (, uint256 deficitAmount,,) = strategy.imbalances();

        address otherToken = makeAddr("otherToken");

        vm.startPrank(owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        vm.expectRevert("TokenMismatch");
        rebalancer.initiateRebalance(1, 0, address(baseAsset), otherToken, deficitAmount);
        vm.stopPrank();
    }

    // A deferred Midas->Spark rebalance whose Midas redemption is rejected returns the mHYPER (not
    // USDC), so completeRebalance can never settle it. cancelPendingRebalances recovers the returned
    // mHYPER back into Midas and reverses the pending credit, atomically restoring the accounting.
    function test_Integration_CancelRebalances_RecoversCanceledRedemption() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);   // 1000 in Spark
        _depositToSrt(alice, DEPOSIT_AMOUNT);   // 1000 in Midas

        uint256 midasBefore = seniorStrat.totalAssets();

        // SRT borrows Spark liquidity -> creates a toJunior debt, repaid via a deferred Midas->Spark rebalance.
        uint256 borrowAmount = DEPOSIT_AMOUNT / 2; // 500
        vm.prank(alice);
        srtVault.withdraw(borrowAmount, alice, alice);
        uint256 debt = _debtToJunior();

        vm.startPrank(owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        rebalancer.initiateRebalance(1, 0, address(baseAsset), address(baseAsset), debt);
        vm.stopPrank();

        assertEq(rebalancer.pendingCount(), 1, "rebalance is pending");
        (uint256 pendingToJunior,) = rebalancer.pendingToStrats();
        assertApproxEqAbs(pendingToJunior, debt, 2, "pending credits junior");
        // Midas is down by the in-flight amount (mHYPER moved into the redemption queue).
        assertApproxEqAbs(seniorStrat.totalAssets(), midasBefore - debt, 2, "midas reduced while in flight");

        // Midas rejects the redemption -> mHYPER is returned to the cooldown proxy (no USDC paid).
        redemptionVault.rejectRequest(redemptionVault.currentRequestId());

        // completeRebalance can never settle it (depositToken/USDC never arrives). minAssets = debt
        // ensures it reverts instead of completing with a zero deposit.
        vm.warp(block.timestamp + 1 weeks);
        vm.prank(owner);
        vm.expectRevert();
        rebalancer.completeRebalance(0, debt);

        // Owner recovers: mHYPER returns to Midas, credit reversed, entry removed — all atomic.
        vm.prank(owner);
        rebalancer.cancelRebalance(0, 0);

        assertEq(rebalancer.pendingCount(), 0, "entry removed");
        (pendingToJunior,) = rebalancer.pendingToStrats();
        assertEq(pendingToJunior, 0, "pending credit reversed");
        assertApproxEqAbs(seniorStrat.totalAssets(), midasBefore, 2, "midas totalAssets restored after recovery");
    }

    // Two deferred Midas->Spark rebalances, BOTH rejected by Midas. Cancelling only ONE must not
    // double-count the other: finalize() drains BOTH proxies' shares into the rebalancer, but only
    // entry 0's credit/entry is removed — entry 1 must remain counted exactly once in both
    // pendingToStrats() and totalAssets().
    function test_Integration_CancelRebalance_TwoCanceled_NoDoubleCount() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);       // 1000 in Spark
        _depositToSrt(alice, DEPOSIT_AMOUNT * 4);   // 4000 in Midas (large enough that the 30% floor target covers the rebalances)

        // SRT borrows all Spark liquidity -> junior drops below the floor; floor target (0.3 * 4000 navTotal
        // = 1200) gives ~1200 of junior deficit / senior surplus, enough for two Midas->Spark rebalances of 500 each.
        vm.prank(alice);
        srtVault.withdraw(DEPOSIT_AMOUNT, alice, alice);

        // Two same-direction deferred rebalances (separate blocks -> separate cooldown requests).
        vm.startPrank(owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        rebalancer.initiateRebalance(1, 0, address(baseAsset), address(baseAsset), DEPOSIT_AMOUNT / 2);
        vm.warp(block.timestamp + 1);
        rebalancer.initiateRebalance(1, 0, address(baseAsset), address(baseAsset), DEPOSIT_AMOUNT / 2);
        vm.stopPrank();

        assertEq(rebalancer.pendingCount(), 2, "two pending rebalances");
        (uint256 toJuniorBefore,) = rebalancer.pendingToStrats();
        assertApproxEqAbs(toJuniorBefore, DEPOSIT_AMOUNT, 2, "both entries credit junior (1000)");
        assertApproxEqAbs(rebalancer.totalAssets(), DEPOSIT_AMOUNT, 2, "totalAssets counts both (1000)");

        // Midas rejects BOTH redemptions -> mHYPER returned to both cooldown proxies.
        redemptionVault.rejectRequest(0);
        redemptionVault.rejectRequest(1);
        vm.warp(block.timestamp + 1 weeks);

        // Cancel only ONE. finalize() inside drains BOTH proxies' shares into the rebalancer.
        vm.prank(owner);
        rebalancer.cancelRebalance(0, 0);

        // Entry 1 must still be counted exactly once — no double counting from the shared drain.
        assertEq(rebalancer.pendingCount(), 1, "one entry remains");
        (uint256 toJuniorAfter,) = rebalancer.pendingToStrats();
        assertApproxEqAbs(toJuniorAfter, DEPOSIT_AMOUNT / 2, 2, "only entry 1 credits junior (500), not double counted");
        assertApproxEqAbs(rebalancer.totalAssets(), DEPOSIT_AMOUNT / 2, 2, "totalAssets counts only entry 1 (500)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Oracle-gated discrete accounting
    // ─────────────────────────────────────────────────────────────────────────

    function test_Integration_MidasStrat_TotalAssets_StaleOracle_ReturnsLatestNav() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT); // SRT → Midas (seniorStrat)

        uint256 checkpoint = block.timestamp;
        uint256 latestNav = seniorStrat.totalAssets(); // 1000e6

        // Oracle not updated since checkpoint → totalAssets(latestNav, checkpoint) returns latestNav
        assertEq(
            seniorStrat.totalAssets(latestNav, checkpoint + 1),
            latestNav,
            "Stale oracle: should return latestNav"
        );
    }

    function test_Integration_MidasStrat_TotalAssets_FreshOracle_ReturnsCurrent() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToSrt(alice, DEPOSIT_AMOUNT); // SRT → Midas (seniorStrat)

        uint256 checkpoint = block.timestamp;

        // Advance time and push a new oracle round at $1.05 per mHYPER
        vm.warp(block.timestamp + 1 days);
        oracle.setRoundData(int256(1.05e8)); // 1.05 in 8-dec Chainlink

        uint256 latestNav = DEPOSIT_AMOUNT; // old nav
        uint256 expected = DEPOSIT_AMOUNT * 105 / 100; // 1050e6

        assertApproxEqAbs(
            seniorStrat.totalAssets(latestNav, checkpoint),
            expected,
            1e3,
            "Fresh oracle: should reflect updated mHYPER price"
        );
    }

    function test_Integration_SparkStrat_TotalAssets_AlwaysFresh() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT); // JRT → Spark (juniorStrat)
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        uint256 staleNav = 1; // bogus latestNav
        uint256 past = 1; // timestamp in the past

        // Spark strat is continuous — always returns current, ignores latestNav/timestamp
        assertEq(
            juniorStrat.totalAssets(staleNav, past),
            DEPOSIT_AMOUNT,
            "Spark strat always returns fresh totalAssets"
        );
    }

    function test_Rebalancer_DoubleCompleteRebalance_SameShareToken_PermanentStateCorruptionFixed() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT); // 1000e6 in Spark
        _depositToSrt(alice, DEPOSIT_AMOUNT * 4); // 4000e6 in Midas (senior, idx 1)

        // SRT borrows all Spark liquidity -> junior drops below the floor; floor target (0.3 * 4000 navTotal
        // = 1200) gives ~1200 of junior deficit / senior surplus, enough for two Midas->Spark rebalances of 500 each.
        vm.prank(alice);
        srtVault.withdraw(DEPOSIT_AMOUNT, alice, alice);

        vm.prank(owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);

        // Two same-direction deferred rebalances: Midas (1) -> Spark (0)
        // Midas has a cooldown so both ether it
        vm.startPrank(owner);
        rebalancer.initiateRebalance(1, 0, address(baseAsset), address(baseAsset), DEPOSIT_AMOUNT / 2);
        vm.warp(block.timestamp + 1);
        rebalancer.initiateRebalance(1, 0, address(baseAsset), address(baseAsset), DEPOSIT_AMOUNT / 2);
        vm.stopPrank();

        assertEq(rebalancer.pendingCount(), 2, "two pending rebalances");
        (uint256 toJunior,) = rebalancer.pendingToStrats();
        assertEq(toJunior, DEPOSIT_AMOUNT, "_pendingToStrat[0] should be 1000e6");

        // Mature cooldowns and fullfill requests
        vm.warp(block.timestamp + 1 weeks);
        redemptionVault.fulfillRequest(0);
        redemptionVault.fulfillRequest(1);

        // Before any completeRebalance: both proxies are claimable in unstakeCooldown.
        (toJunior,) = rebalancer.pendingToStrats();
        console2.log("Before:  toJunior=%d  rebalancer.totalAssets=%d  strategy.totalAssets=%d", toJunior, rebalancer.totalAssets(), strategy.totalAssets());
        assertEq(rebalancer.totalAssets(), DEPOSIT_AMOUNT, "totalAssets: both proxies claimable (1000e6)");

        // First completeRebalance: finalize drains both proxies at once (1000e6), deposits only
        // 500e6 (capped at pending.baseAssets), leaves 500e6 raw USDC in the rebalancer.
        vm.prank(owner);
        rebalancer.completeRebalance(0, 0);

        (toJunior,) = rebalancer.pendingToStrats();
        console2.log("Between: toJunior=%d   rebalancer.totalAssets=%d  strategy.totalAssets=%d", toJunior, rebalancer.totalAssets(), strategy.totalAssets());
        assertEq(toJunior, DEPOSIT_AMOUNT / 2, "_pendingToStrat[0] decremented by first entry");
        assertEq(rebalancer.pendingCount(), 1, "one pending entry still to be processed");
        // Between calls: cooldown is empty but 500e6 sits raw in the rebalanecr
        // picks it up via the depositToken.balanceOf check.
        assertEq(rebalancer.totalAssets(), DEPOSIT_AMOUNT / 2, "totalAssets: 500e6 pre-loaded in rebalancer");

        // Second completeRebalance: shareToken cooldown is empty, 500e6 pre-loaded from sibling drain.
        // Skips finalize, deposits the remaining 500e6, clears the entry cleanly.
        vm.prank(owner);
        rebalancer.completeRebalance(0, 0);

        (toJunior,) = rebalancer.pendingToStrats();
        console2.log("After:   toJunior=%d  rebalancer.totalAssets=%d  strategy.totalAssets=%d", toJunior, rebalancer.totalAssets(), strategy.totalAssets());
        assertEq(toJunior, 0, "_pendingToStrat[0] fully cleared");
        assertEq(rebalancer.pendingCount(), 0, "no stuck entries");
        assertEq(rebalancer.totalAssets(), 0, "totalAssets: zero after all entries settled");
    }

    // Spark (junior) USDC cooldown — regression for the isJrt() withdrawal DoS

    // A JRT withdrawal that falls back to the Spark (secondary) strat must not revert when
    // Spark cooldowns are enabled. Spark's cdo is the IsolatedStrategy, which does not implement
    // isJrt(); the strat catches that and applies the SRT cooldown instead of DoSing withdrawals.
    function test_Integration_SparkCooldown_JrtWithdraw_HeldThenClaimable() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT); // 1000 in Spark; Midas left empty so the JRT withdrawal routes entirely to Spark

        uint256 jrtCooldown = 2 days;
        uint256 srtCooldown = 1 days;
        vm.startPrank(owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        juniorStrat.setCooldowns(jrtCooldown, srtCooldown);
        vm.stopPrank();

        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2; // 500
        uint256 aliceBalBefore = baseAsset.balanceOf(alice);
        uint256 t = block.timestamp;

        vm.prank(alice);
        jrtVault.withdraw(withdrawAmount, alice, alice);

        // Funds are held in the cooldown, not delivered immediately.
        assertEq(baseAsset.balanceOf(alice), aliceBalBefore, "Alice receives nothing until cooldown elapses");

        ICooldown.TBalanceState memory state = erc20Cooldown.balanceOf(IERC20(address(baseAsset)), alice);
        assertEq(state.pending, withdrawAmount, "Full Spark withdrawal pending in cooldown");
        assertEq(state.claimable, 0, "Nothing claimable yet");
        // isJrt() resolves through the MultiStrategy passthrough, so a JRT withdrawal correctly
        // applies the JRT cooldown (the old try/catch mis-applied the SRT one on the parent revert).
        assertEq(state.nextUnlockAt, t + jrtCooldown, "JRT cooldown applied");

        // After the cooldown elapses, alice claims the full amount.
        vm.warp(t + jrtCooldown + 1);
        erc20Cooldown.finalize(IERC20(address(baseAsset)), alice);
        assertEq(baseAsset.balanceOf(alice) - aliceBalBefore, withdrawAmount, "Alice claims the full amount after cooldown");
    }

    // The rebalancer withdraws with tranche == address(0); that path must skip the Spark cooldown
    // even when cooldowns are enabled, otherwise rebalanced funds would be parked in the cooldown
    // instead of reaching the destination strat (the instant Spark->Midas rebalance would be
    // misdetected as deferred).
    function test_Integration_SparkCooldown_RebalancePath_SkipsCooldown() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT); // 1000 in Spark
        _depositToSrt(alice, DEPOSIT_AMOUNT); // 1000 in Midas

        // JRT borrows 500 from Midas (senior) -> creates a senior debt repaid via a Spark->Midas rebalance.
        uint256 borrowAmount = DEPOSIT_AMOUNT / 2;
        vm.prank(alice);
        jrtVault.withdraw(borrowAmount, alice, alice);

        // Settle alice's async Midas cooldown.
        vm.warp(block.timestamp + 1 weeks);
        redemptionVault.fulfillRequest(0);
        unstakeCooldown.finalize(IERC20(address(mHYPER)), address(alice));

        // Enable Spark cooldowns, then rebalance Spark(0)->Midas(1) — the instant path.
        vm.startPrank(owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        juniorStrat.setCooldowns(2 days, 1 days);
        rebalancer.initiateRebalance(0, 1, address(baseAsset), address(baseAsset), borrowAmount);
        vm.stopPrank();

        // Rebalance completed in the same tx — the cooldown did not trap the funds.
        assertEq(rebalancer.pendingCount(), 0, "Spark rebalance is instant, no pending");
        assertEq(_debtToSenior(), 0, "Senior debt cleared");

        // Nothing got parked in the cooldown for the rebalancer.
        ICooldown.TBalanceState memory state = erc20Cooldown.balanceOf(IERC20(address(baseAsset)), address(rebalancer));
        assertEq(state.pending, 0, "No cooldown applied on the rebalance path");
        assertEq(state.claimable, 0, "No cooldown applied on the rebalance path");
    }

    // Helpers

    function _depositToJrt(address user, uint256 amount) internal {
        vm.startPrank(user);
        baseAsset.approve(address(jrtVault), amount);
        jrtVault.deposit(address(baseAsset), amount, user);
        vm.stopPrank();
    }

    function _depositToSrt(address user, uint256 amount) internal {
        vm.startPrank(user);
        baseAsset.approve(address(srtVault), amount);
        srtVault.deposit(address(baseAsset), amount, user);
        vm.stopPrank();
    }
}
