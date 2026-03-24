pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MockUSDe} from "../contracts/test/MockUSDe.sol";
import {MockStakedUSDe} from "../contracts/test/MockStakedUSDe.sol";
import {MockStakedUSDS} from "../contracts/test/MockStakedUSDS.sol";
import {MockERC4626} from "../contracts/test/MockERC4626.sol";

import {Tranche} from "../contracts/tranches/Tranche.sol";
import {Accounting} from "../contracts/tranches/Accounting.sol";



import { sUSDeCooldownRequestImpl as SUSDeCooldownRequestImpl } from "../contracts/tranches/strategies/ethena/sUSDeCooldownRequestImpl.sol";
import { sUSDeAprPairProvider as SUSDeAprPairProvider, IsUSDS } from "../contracts/tranches/strategies/ethena/sUSDeAprPairProvider.sol";
import { sUSDeStrategy as SUSDeStrategy} from "../contracts/tranches/strategies/ethena/sUSDeStrategy.sol";

import { AccessControlManager } from "../contracts/governance/AccessControlManager.sol";

import { AprPairFeed } from "../contracts/tranches/oracles/AprPairFeed.sol";

import { console2} from "forge-std/console2.sol";

import { StrataCDO} from "../contracts/tranches/StrataCDO.sol";

import { ERC20Cooldown } from "../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import { UnstakeCooldown } from "../contracts/tranches/base/cooldown/UnstakeCooldown.sol";
import { CooldownBase } from "../contracts/tranches/base/cooldown/CooldownBase.sol";


import { IsUSDe } from "../contracts/tranches/strategies/ethena/IsUSDe.sol";
import { IUnstakeHandler } from "../contracts/tranches/interfaces/cooldown/IUnstakeHandler.sol";
import { ITranche } from "../contracts/tranches/interfaces/ITranche.sol";
import { IStrategy } from "../contracts/tranches/interfaces/IStrategy.sol";
import { IAccounting } from "../contracts/tranches/interfaces/IAccounting.sol";

contract CDOTest is Test {

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


    address account;

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
                    address(new Tranche()),
                    abi.encodeWithSelector(Tranche.initialize.selector, owner, address(acm), "jrtVault", "jrtUSDe", IERC20(address(USDe)), address(cdo))
                )
            )
        );
        srtVault = Tranche(
            address(
                new ERC1967Proxy(
                    address(new Tranche()),
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
        cdo.setActionStates(address(0), true, true);

    }


    function test_Flow() public {
        assert(address(USDe) != address(0));

        account = msg.sender;

        // test deposit
        uint256 shares = 1 ether;
        USDe.mint(account, shares);
        USDe.approve(address(jrtVault), shares);
        jrtVault.deposit(address(USDe), shares, address(0xdead));
        assertBalance(jrtVault, address(0xdead), shares, "Deposite shares failed");

        USDe.mint(account, shares);
        USDe.approve(address(jrtVault), shares);
        jrtVault.deposit(address(USDe), shares, account);
        jrtVault.withdraw(address(USDe), shares, account, account);
        assertBalance(USDe, account, 0, "Cooldown period failed");

        vm.warp(block.timestamp + 7 days);
        unstakeCooldown.finalize(sUSDe, account);
        assertBalance(USDe, account, 1 ether, "After-Cooldown period failed");
    }

    function depositGeneric(IERC4626 vault, uint256 amount) internal {
        IERC20 asset = IERC20(vault.asset());
        asset.approve(address(vault), amount);
        vault.deposit(amount, account);
    }

    function assertBalance(IERC20 token, address owner, uint256 amount, string memory message) internal {
        uint256 balance = token.balanceOf(owner);
        assertEq(balance, amount, message);
    }
}
