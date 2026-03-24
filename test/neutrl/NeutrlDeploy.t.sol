// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AccessControlManager} from "../../contracts/governance/AccessControlManager.sol";
import {StrataCDO} from "../../contracts/tranches/StrataCDO.sol";
import {Tranche} from "../../contracts/tranches/Tranche.sol";
import {Accounting} from "../../contracts/tranches/Accounting.sol";
import {AprPairFeed} from "../../contracts/tranches/oracles/AprPairFeed.sol";
import {sNUSDStrategy as SNUSDStrategy} from "../../contracts/tranches/strategies/neutrl/sNUSDStrategy.sol";
import {sNUSDCooldownRequestImpl} from "../../contracts/tranches/strategies/neutrl/sNUSDCooldownRequestImpl.sol";
import {sNUSDAprPairProvider} from "../../contracts/tranches/strategies/neutrl/sNUSDAprPairProvider.sol";
import {IsNUSD} from "../../contracts/tranches/strategies/neutrl/IsNUSD.sol";
import {IsUSDe} from "../../contracts/tranches/strategies/ethena/IsUSDe.sol";
import {ERC20Cooldown} from "../../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import {UnstakeCooldown} from "../../contracts/tranches/base/cooldown/UnstakeCooldown.sol";
import {CooldownBase} from "../../contracts/tranches/base/cooldown/CooldownBase.sol";
import {IUnstakeHandler} from "../../contracts/tranches/interfaces/cooldown/IUnstakeHandler.sol";
import {IAccounting} from "../../contracts/tranches/interfaces/IAccounting.sol";
import {IStrategy} from "../../contracts/tranches/interfaces/IStrategy.sol";
import {ITranche} from "../../contracts/tranches/interfaces/ITranche.sol";
import {IStrataCDO} from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IAprPairFeed} from "../../contracts/tranches/interfaces/IAprPairFeed.sol";

contract NeutrlDeploy is Test {
    // Mainnet addresses
    address public constant NUSD = 0xE556ABa6fe6036275Ec1f87eda296BE72C811BCE;
    address public constant sNUSD = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313;
    // sUSDe is used for target APR in the sNUSDAprPairProvider
    address public constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    // sNUSD was deployed at block 23495849
    uint256 constant MAINNET_BLOCK = 23495900;

    // Roles
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_CDO_APR_ROLE = keccak256("UPDATER_CDO_APR_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");
    bytes32 constant CDO_OWNER_ROLE = keccak256("CDO_OWNER_ROLE");
    bytes32 constant COOLDOWN_WORKER_ROLE = keccak256("COOLDOWN_WORKER_ROLE");

    // Deployed contracts
    address internal owner;
    AccessControlManager internal acm;
    StrataCDO internal cdo;
    Tranche internal jrtVault;
    Tranche internal srtVault;
    ERC20Cooldown internal erc20Cooldown;
    UnstakeCooldown internal unstakeCooldown;
    sNUSDCooldownRequestImpl internal cooldownImpl;
    SNUSDStrategy internal strategy;
    sNUSDAprPairProvider internal provider;
    AprPairFeed internal feed;
    Accounting internal accounting;

    function setUp() public virtual {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");

        uint256 forkId = vm.createFork(rpcUrl, MAINNET_BLOCK);
        vm.selectFork(forkId);

        owner = makeAddr("strataOwner");
        vm.label(owner, "DeployerOwner");
        vm.label(NUSD, "NUSD");
        vm.label(sNUSD, "sNUSD");
        vm.label(SUSDE, "sUSDe");
        vm.deal(owner, 100 ether);
    }

    function testDeployNeutrlStackMatchesScript() public {
        _deployStrataStack();

        // Verify CDO configuration
        assertEq(address(cdo.strategy()), address(strategy));
        assertEq(address(cdo.jrtVault()), address(jrtVault));
        assertEq(address(cdo.srtVault()), address(srtVault));
        assertEq(jrtVault.asset(), NUSD);
        assertEq(srtVault.asset(), NUSD);

        // Verify strategy configuration
        assertEq(address(strategy.sNUSD()), sNUSD);
        assertEq(address(strategy.NUSD()), NUSD);
        assertEq(strategy.sNUSDCooldownJrt(), 7 days);
        assertEq(strategy.sNUSDCooldownSrt(), 0);

        // Verify feed configuration
        assertEq(address(feed.provider()), address(provider));
        assertEq(feed.roundStaleAfter(), 4 hours);
        assertEq(address(accounting.aprPairFeed()), address(feed));

        // Verify cooldown implementation
        assertEq(address(unstakeCooldown.implementations(sNUSD)), address(cooldownImpl));

        // Verify roles
        assertTrue(acm.hasRole(PAUSER_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_STRAT_CONFIG_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_FEED_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_CDO_APR_ROLE, address(feed)));

        // Verify action states
        (bool jrtDepositsEnabled, bool jrtWithdrawalsEnabled) = cdo.actionsJrt();
        (bool srtDepositsEnabled, bool srtWithdrawalsEnabled) = cdo.actionsSrt();
        assertTrue(jrtDepositsEnabled && jrtWithdrawalsEnabled);
        assertTrue(srtDepositsEnabled && srtWithdrawalsEnabled);

        // Verify supported tokens
        IERC20[] memory supported = strategy.getSupportedTokens();
        assertEq(supported.length, 2);
        assertEq(address(supported[0]), sNUSD);
        assertEq(address(supported[1]), NUSD);
    }

    function _deployStrataStack() internal {
        vm.startPrank(owner);

        // 1. Deploy AccessControlManager
        acm = new AccessControlManager(owner);
        vm.label(address(acm), "AccessControlManager");

        // 2. Deploy StrataCDO
        StrataCDO cdoImpl = new StrataCDO(IERC20Metadata(NUSD));
        vm.label(address(cdoImpl), "StrataCDO_Impl");
        cdo = StrataCDO(
            address(
                new ERC1967Proxy(
                    address(cdoImpl), abi.encodeWithSelector(StrataCDO.initialize.selector, owner, address(acm))
                )
            )
        );
        vm.label(address(cdo), "StrataCDO");

        // 3. Deploy Tranches
        jrtVault = _deployTranche("JRT", "Junior Tranche");
        srtVault = _deployTranche("SRT", "Senior Tranche");

        // 4. Deploy ERC20Cooldown
        ERC20Cooldown erc20CooldownImpl = new ERC20Cooldown();
        vm.label(address(erc20CooldownImpl), "ERC20Cooldown_Impl");
        erc20Cooldown = ERC20Cooldown(
            address(
                new ERC1967Proxy(
                    address(erc20CooldownImpl),
                    abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
                )
            )
        );
        vm.label(address(erc20Cooldown), "ERC20Cooldown");

        // 5. Deploy UnstakeCooldown
        UnstakeCooldown unstakeCooldownImpl = new UnstakeCooldown();
        vm.label(address(unstakeCooldownImpl), "UnstakeCooldown_Impl");
        unstakeCooldown = UnstakeCooldown(
            address(
                new ERC1967Proxy(
                    address(unstakeCooldownImpl),
                    abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
                )
            )
        );
        vm.label(address(unstakeCooldown), "UnstakeCooldown");

        // 6. Deploy sNUSDCooldownRequestImpl and set implementation
        cooldownImpl = new sNUSDCooldownRequestImpl(IsNUSD(sNUSD));
        vm.label(address(cooldownImpl), "sNUSDCooldownRequestImpl");
        address[] memory tokens = new address[](1);
        tokens[0] = sNUSD;
        IUnstakeHandler[] memory handlers = new IUnstakeHandler[](1);
        handlers[0] = IUnstakeHandler(address(cooldownImpl));
        unstakeCooldown.setImplementations(tokens, handlers);

        // 7. Deploy sNUSDStrategy
        SNUSDStrategy strategyImpl = new SNUSDStrategy(IERC4626(sNUSD));
        vm.label(address(strategyImpl), "sNUSDStrategy_Impl");
        strategy = SNUSDStrategy(
            address(
                new ERC1967Proxy(
                    address(strategyImpl),
                    abi.encodeWithSelector(
                        SNUSDStrategy.initialize.selector,
                        owner,
                        address(acm),
                        IStrataCDO(address(cdo)),
                        erc20Cooldown,
                        unstakeCooldown
                    )
                )
            )
        );
        vm.label(address(strategy), "sNUSDStrategy");

        // 8. Deploy sNUSDAprPairProvider (uses sUSDe for target APR, sNUSD for base APR)
        provider = new sNUSDAprPairProvider(IsUSDe(SUSDE), IsNUSD(sNUSD));
        vm.label(address(provider), "sNUSDAprPairProvider");

        // 9. Deploy AprPairFeed
        AprPairFeed feedImpl = new AprPairFeed();
        vm.label(address(feedImpl), "AprPairFeed_Impl");
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
                        "Neutrl CDO APR Pair"
                    )
                )
            )
        );
        vm.label(address(feed), "AprPairFeed");

        // 10. Deploy Accounting
        Accounting accountingImpl = new Accounting(18);
        vm.label(address(accountingImpl), "Accounting_Impl");
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

        // 13. Set strategy cooldowns
        strategy.setCooldowns(7 days, 0);

        // 14. Enable actions on tranches
        cdo.setActionStates(address(jrtVault), true, true);
        cdo.setActionStates(address(srtVault), true, true);

        // 15. Set reserve basis points
        accounting.setReserveBps(0.02e18);

        vm.stopPrank();
    }

    function _deployTranche(string memory name, string memory symbol) internal returns (Tranche) {
        Tranche trancheImpl = new Tranche();
        vm.label(address(trancheImpl), string.concat(name, "_Tranche_Impl"));

        address proxy = address(
            new ERC1967Proxy(
                address(trancheImpl),
                abi.encodeWithSelector(
                    Tranche.initialize.selector,
                    owner,
                    address(acm),
                    name,
                    symbol,
                    IERC20(NUSD),
                    IStrataCDO(address(cdo))
                )
            )
        );

        string memory label = string.concat(name, "_Tranche");
        vm.label(proxy, label);
        return Tranche(proxy);
    }

    function _grantRole(bytes32 role, address grantee) internal {
        acm.grantRole(role, grantee);
    }
}
