// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { AprPairFeed } from "../../../contracts/tranches/oracles/AprPairFeed.sol";
import { sUSDeStrategy as SUSDeStrategy } from "../../../contracts/tranches/strategies/ethena/sUSDeStrategy.sol";
import { sUSDeCooldownRequestImpl } from "../../../contracts/tranches/strategies/ethena/sUSDeCooldownRequestImpl.sol";
import { sUSDeAprPairProvider, IsUSDS } from "../../../contracts/tranches/strategies/ethena/sUSDeAprPairProvider.sol";
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

contract StrataProtocolDeploymentBase is Test {
    address public constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    uint256 constant MAINNET_BLOCK = 21_000_000;

    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_CDO_APR_ROLE = keccak256("UPDATER_CDO_APR_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");
    bytes32 constant CDO_OWNER_ROLE = keccak256("CDO_OWNER_ROLE");
    bytes32 constant COOLDOWN_WORKER_ROLE = keccak256("COOLDOWN_WORKER_ROLE");

    address internal owner;
    AccessControlManager internal acm;
    StrataCDO internal cdo;
    Tranche internal jrtVault;
    Tranche internal srtVault;
    ERC20Cooldown internal erc20Cooldown;
    UnstakeCooldown internal unstakeCooldown;
    sUSDeCooldownRequestImpl internal cooldownImpl;
    SUSDeStrategy internal strategy;
    sUSDeAprPairProvider internal provider;
    AprPairFeed internal feed;
    Accounting internal accounting;

    function setUp() public {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl, MAINNET_BLOCK);
        vm.selectFork(forkId);

        owner = makeAddr("strataOwner");
        vm.label(owner, "DeployerOwner");
        vm.label(USDE, "USDe");
        vm.label(SUSDE, "sUSDe");
        vm.label(SUSDS, "sUSDs");
        vm.deal(owner, 100 ether);
    }

    function testDeployEthenaStackMatchesScript() public {
        _deployStrataStack();

        assertEq(address(cdo.strategy()), address(strategy));
        assertEq(address(cdo.jrtVault()), address(jrtVault));
        assertEq(address(cdo.srtVault()), address(srtVault));
        assertEq(jrtVault.asset(), USDE);
        assertEq(srtVault.asset(), USDE);

        assertEq(address(strategy.sUSDe()), SUSDE);
        assertEq(address(strategy.USDe()), USDE);
        assertEq(strategy.sUSDeCooldownJrt(), 7 days);
        assertEq(strategy.sUSDeCooldownSrt(), 0);

        assertEq(address(feed.provider()), address(provider));
        assertEq(feed.roundStaleAfter(), 4 hours);
        assertEq(address(accounting.aprPairFeed()), address(feed));

        assertEq(address(unstakeCooldown.implementations(SUSDE)), address(cooldownImpl));

        assertTrue(acm.hasRole(PAUSER_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_STRAT_CONFIG_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_FEED_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_CDO_APR_ROLE, address(feed)));

        (bool jrtDepositsEnabled, bool jrtWithdrawalsEnabled) = cdo.actionsJrt();
        (bool srtDepositsEnabled, bool srtWithdrawalsEnabled) = cdo.actionsSrt();
        assertTrue(jrtDepositsEnabled && jrtWithdrawalsEnabled);
        assertTrue(srtDepositsEnabled && srtWithdrawalsEnabled);

        IERC20[] memory supported = strategy.getSupportedTokens();
        assertEq(supported.length, 2);
        assertEq(address(supported[0]), SUSDE);
        assertEq(address(supported[1]), USDE);
    }

    function _deployStrataStack() internal {
        //vm.startPrank(IsUSDe(sUSDe).owner());

        vm.startPrank(owner);

        acm = new AccessControlManager(owner);
        vm.label(address(acm), "AccessControlManager");

        StrataCDO cdoImpl = new StrataCDO(IERC20Metadata(USDE));
        vm.label(address(cdoImpl), "StrataCDO_Impl");
        cdo = StrataCDO(
            address(
                new ERC1967Proxy(
                    address(cdoImpl),
                    abi.encodeWithSelector(StrataCDO.initialize.selector, owner, address(acm))
                )
            )
        );
        vm.label(address(cdo), "StrataCDO");

        jrtVault = _deployTranche("JRT", "Junior Tranch");
        srtVault = _deployTranche("SRT", "Senior Tranch");

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

        cooldownImpl = new sUSDeCooldownRequestImpl(IsUSDe(SUSDE));
        vm.label(address(cooldownImpl), "sUSDeCooldownRequestImpl");
        address[] memory tokens = new address[](1);
        tokens[0] = SUSDE;
        IUnstakeHandler[] memory handlers = new IUnstakeHandler[](1);
        handlers[0] = IUnstakeHandler(address(cooldownImpl));
        unstakeCooldown.setImplementations(tokens, handlers);

        SUSDeStrategy strategyImpl = new SUSDeStrategy(IERC4626(SUSDE));
        vm.label(address(strategyImpl), "sUSDeStrategy_Impl");
        strategy = SUSDeStrategy(
            address(
                new ERC1967Proxy(
                    address(strategyImpl),
                    abi.encodeWithSelector(
                        SUSDeStrategy.initialize.selector,
                        owner,
                        address(acm),
                        IStrataCDO(address(cdo)),
                        erc20Cooldown,
                        unstakeCooldown
                    )
                )
            )
        );
        vm.label(address(strategy), "sUSDeStrategy");

        provider = new sUSDeAprPairProvider(IsUSDS(SUSDS), IsUSDe(SUSDE));
        vm.label(address(provider), "sUSDeAprPairProvider");

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
                        "Ethena CDO APR Pair"
                    )
                )
            )
        );
        vm.label(address(feed), "AprPairFeed");

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

        _grantRole(PAUSER_ROLE, owner);
        _grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        _grantRole(UPDATER_FEED_ROLE, owner);
        _grantRole(UPDATER_CDO_APR_ROLE, address(feed));
        _grantRole(COOLDOWN_WORKER_ROLE, address(strategy));

        cdo.configure(
            IAccounting(address(accounting)),
            IStrategy(address(strategy)),
            ITranche(address(jrtVault)),
            ITranche(address(srtVault))
        );

        strategy.setCooldowns(7 days, 0);

        cdo.setActionStates(address(jrtVault), true, true);
        cdo.setActionStates(address(srtVault), true, true);

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
                    IERC20(USDE),
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
