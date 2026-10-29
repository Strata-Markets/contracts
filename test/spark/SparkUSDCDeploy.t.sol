// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISharesCooldown} from "../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AccessControlManager} from "../../contracts/governance/AccessControlManager.sol";
import {StrataCDO} from "../../contracts/tranches/StrataCDO.sol";
import {Tranche} from "../../contracts/tranches/Tranche.sol";
import {Accounting} from "../../contracts/tranches/Accounting.sol";
import {AprPairFeed} from "../../contracts/tranches/oracles/AprPairFeed.sol";

import {SparkUSDCStrategy} from "../../contracts/tranches/strategies/spark/SparkUSDCStrategy.sol";
import {SparkAprPairProvider} from "../../contracts/tranches/strategies/spark/SparkAprPairProvider.sol";
import {ISparkVault} from "../../contracts/tranches/strategies/spark/ISparkVault.sol";
import {IsUSDe} from "../../contracts/tranches/strategies/ethena/IsUSDe.sol";

import {ERC20Cooldown} from "../../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import {CooldownBase} from "../../contracts/tranches/base/cooldown/CooldownBase.sol";
import {IAccounting} from "../../contracts/tranches/interfaces/IAccounting.sol";
import {IStrategy} from "../../contracts/tranches/interfaces/IStrategy.sol";
import {ITranche} from "../../contracts/tranches/interfaces/ITranche.sol";
import {IStrataCDO} from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IAprPairFeed} from "../../contracts/tranches/interfaces/IAprPairFeed.sol";

import {MockERC20} from "../../contracts/test/MockERC20.sol";
import {MockSparkVault} from "../../contracts/test/MockSparkVault.sol";
import {MockStakedUSDe} from "../../contracts/test/MockStakedUSDe.sol";

contract SparkUSDCDeploy is Test {
    // USDC has 6 decimals on mainnet — mirror that in the mock.
    uint8 constant USDC_DECIMALS = 6;

    // Roles
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_CDO_APR_ROLE = keccak256("UPDATER_CDO_APR_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");
    bytes32 constant COOLDOWN_WORKER_ROLE = keccak256("COOLDOWN_WORKER_ROLE");

    // Deployed contracts
    address internal owner;
    MockERC20 internal usdc;
    MockSparkVault internal spVault;
    IsUSDe internal sUSDe;

    AccessControlManager internal acm;
    StrataCDO internal cdo;
    Tranche internal jrtVault;
    Tranche internal srtVault;
    ERC20Cooldown internal erc20Cooldown;
    SparkUSDCStrategy internal strategy;
    SparkAprPairProvider internal provider;
    AprPairFeed internal feed;
    Accounting internal accounting;

    function setUp() public virtual {
        owner = makeAddr("strataOwner");
        vm.label(owner, "DeployerOwner");
        vm.deal(owner, 100 ether);

        // Deploy USDC mock with 6 decimals and the Spark Vault mock on top of it.
        vm.startPrank(owner);
        usdc = new MockERC20("USDC", USDC_DECIMALS);
        vm.label(address(usdc), "USDC");
        spVault = new MockSparkVault(IERC20(address(usdc)));
        vm.label(address(spVault), "spUSDC");

        // Stand up a MockStakedUSDe for the APR provider's target-APR input.
        sUSDe = IsUSDe(address(new MockStakedUSDe(IERC20(address(usdc)), owner, owner)));
        vm.label(address(sUSDe), "sUSDe");
        vm.stopPrank();
    }

    function testDeploySparkStackMatchesScript() public {
        _deployStrataStack();

        assertEq(address(cdo.strategy()), address(strategy));
        assertEq(address(cdo.jrtVault()), address(jrtVault));
        assertEq(address(cdo.srtVault()), address(srtVault));
        assertEq(jrtVault.asset(), address(usdc));
        assertEq(srtVault.asset(), address(usdc));

        assertEq(address(strategy.spVault()), address(spVault));
        assertEq(address(strategy.USDC()), address(usdc));
        assertEq(strategy.usdcCooldownJrt(), 7 days);
        assertEq(strategy.usdcCooldownSrt(), 0);
        assertEq(strategy.VESTING_PERIOD(), 24 hours);

        assertEq(address(feed.provider()), address(provider));
        assertEq(feed.roundStaleAfter(), 4 hours);
        assertEq(address(accounting.aprPairFeed()), address(feed));

        assertTrue(acm.hasRole(PAUSER_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_STRAT_CONFIG_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_FEED_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_CDO_APR_ROLE, address(feed)));

        (bool jrtDepositsEnabled, bool jrtWithdrawalsEnabled) = cdo.actionsJrt();
        (bool srtDepositsEnabled, bool srtWithdrawalsEnabled) = cdo.actionsSrt();
        assertTrue(jrtDepositsEnabled && jrtWithdrawalsEnabled);
        assertTrue(srtDepositsEnabled && srtWithdrawalsEnabled);

        IERC20[] memory supported = strategy.getSupportedTokens();
        assertEq(supported.length, 1);
        assertEq(address(supported[0]), address(usdc));
    }

    function _deployStrataStack() internal {
        vm.startPrank(owner);

        // 1. AccessControlManager
        acm = new AccessControlManager(owner);
        vm.label(address(acm), "AccessControlManager");

        // 2. StrataCDO
        StrataCDO cdoImpl = new StrataCDO(IERC20Metadata(address(usdc)), ISharesCooldown(address(0)));
        cdo = StrataCDO(
            address(
                new ERC1967Proxy(
                    address(cdoImpl),
                    abi.encodeWithSelector(StrataCDO.initialize.selector, owner, address(acm))
                )
            )
        );
        vm.label(address(cdo), "StrataCDO");

        // 3. Tranches
        jrtVault = _deployTranche("JRT", "Junior Tranche");
        srtVault = _deployTranche("SRT", "Senior Tranche");

        // 4. ERC20Cooldown (USDC AssetsLock)
        ERC20Cooldown erc20CooldownImpl = new ERC20Cooldown();
        erc20Cooldown = ERC20Cooldown(
            address(
                new ERC1967Proxy(
                    address(erc20CooldownImpl),
                    abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
                )
            )
        );
        vm.label(address(erc20Cooldown), "ERC20Cooldown");

        // 5. Strategy
        SparkUSDCStrategy strategyImpl = new SparkUSDCStrategy(ISparkVault(address(spVault)));
        strategy = SparkUSDCStrategy(
            address(
                new ERC1967Proxy(
                    address(strategyImpl),
                    abi.encodeWithSelector(
                        SparkUSDCStrategy.initialize.selector,
                        owner,
                        address(acm),
                        IStrataCDO(address(cdo)),
                        erc20Cooldown
                    )
                )
            )
        );
        vm.label(address(strategy), "SparkUSDCStrategy");

        // 6. APR provider (target APR from sUSDe vesting, base APR from Spark strategy)
        provider = new SparkAprPairProvider(sUSDe, strategy);
        vm.label(address(provider), "SparkAprPairProvider");

        // 7. AprPairFeed
        AprPairFeed feedImpl = new AprPairFeed();
        feed = AprPairFeed(
            address(
                new ERC1967Proxy(
                    address(feedImpl),
                    abi.encodeWithSelector(
                        AprPairFeed.initialize.selector,
                        owner,
                        address(acm),
                        provider,
                        uint256(4 hours),
                        "Spark CDO APR Pair"
                    )
                )
            )
        );
        vm.label(address(feed), "AprPairFeed");

        // 10. Accounting
        Accounting accountingImpl = new Accounting(6);
        accounting = Accounting(
            address(
                new ERC1967Proxy(
                    address(accountingImpl),
                    abi.encodeWithSelector(
                        Accounting.initialize.selector,
                        owner,
                        address(acm),
                        IStrataCDO(address(cdo)),
                        IAprPairFeed(address(feed))
                    )
                )
            )
        );
        vm.label(address(accounting), "Accounting");

        // 11. Grant roles
        _grantRole(PAUSER_ROLE, owner);
        _grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        _grantRole(UPDATER_FEED_ROLE, owner);
        _grantRole(UPDATER_CDO_APR_ROLE, address(feed));
        _grantRole(COOLDOWN_WORKER_ROLE, address(strategy));

        // 12. Configure CDO
        cdo.configure(
            IAccounting(address(accounting)),
            IStrategy(address(strategy)),
            ITranche(address(jrtVault)),
            ITranche(address(srtVault))
        );

        // 13. Strategy cooldowns: 7d JRT / 0s SRT for USDC AssetsLock
        strategy.setCooldowns(7 days, 0);

        // 14. Enable actions
        cdo.setActionStates(address(jrtVault), true, true);
        cdo.setActionStates(address(srtVault), true, true);

        // 15. Reserve basis points
        accounting.setReserveBps(0.02e18);

        vm.stopPrank();
    }

    function _deployTranche(string memory name, string memory symbol) internal returns (Tranche) {
        Tranche trancheImpl = new Tranche(false);
        address proxy = address(
            new ERC1967Proxy(
                address(trancheImpl),
                abi.encodeWithSelector(
                    Tranche.initialize.selector,
                    owner,
                    address(acm),
                    name,
                    symbol,
                    IERC20(address(usdc)),
                    IStrataCDO(address(cdo))
                )
            )
        );
        vm.label(proxy, string.concat(name, "_Tranche"));
        return Tranche(proxy);
    }

    function _grantRole(bytes32 role, address grantee) internal {
        acm.grantRole(role, grantee);
    }
}
