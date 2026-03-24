pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockUSDe} from "../contracts/test/MockUSDe.sol";
import {MockStakedUSDe} from "../contracts/test/MockStakedUSDe.sol";
import {MockStakedUSDS} from "../contracts/test/MockStakedUSDS.sol";
import {MockERC4626} from "../contracts/test/MockERC4626.sol";

import {Tranche} from "../contracts/tranches/Tranche.sol";
import {Accounting} from "../contracts/tranches/Accounting.sol";
import {TrancheDepositor} from "../contracts/tranches/TrancheDepositor.sol";


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
import { IMetaVault } from "../contracts/tranches/interfaces/IMetaVault.sol";

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

    TrancheDepositor public trancheDepositor;

    // Strategy
    SUSDeStrategy public sUSDeStrategy;
    SUSDeAprPairProvider public sUSDeAprPairProvider;
    UnstakeCooldown public unstakeCooldown;
    ERC20Cooldown public erc20Cooldown;
    SUSDeCooldownRequestImpl public sUSDeCooldownRequestImpl;


    address account;

    function setUp() public {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl, 23_641_000);
        vm.selectFork(forkId);

        address owner = msg.sender;

        vm.startPrank(owner);

        // Prepare Ethena and Ethreal contracts
        USDe = MockUSDe(address(0x4c9EDD5852cd905f086C759E8383e09bff1E68B3));
        sUSDe = MockStakedUSDe(address(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497));
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


        trancheDepositor = TrancheDepositor(
            address(
                new ERC1967Proxy(
                    address(new TrancheDepositor()),
                    abi.encodeWithSelector(TrancheDepositor.initialize.selector, owner, address(acm))
                )
            )
        );

        acm.grantRole(trancheDepositor.DEPOSITOR_CONFIG_ROLE(), owner);
        trancheDepositor.addCdo(cdo);
    }


    function test_Flow() public {
        address router = address(0xE592427A0AEce92De3Edee1F18E0157C05861564);
        IERC20 usdt = IERC20(address(0xdAC17F958D2ee523a2206206994597C13D831ec7));
        address usde = address(0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);

        trancheDepositor.addSwapInfo(address(usdt), TrancheDepositor.TAutoSwap(router, 100, 900));

        address someUsdtHolder = address(0x6AC38D1b2f0c0c3b9E816342b1CA14d91D5Ff60B);
        vm.startPrank(someUsdtHolder);


        SafeERC20.forceApprove(usdt, address(trancheDepositor), type(uint256).max);

        TrancheDepositor.TDepositParams memory params = TrancheDepositor.TDepositParams({
            swapDeadline: 0,
            swapAmountOutMinimum: 0,
            swapTokenOut: usde,
            minShares: 0
        });
        console2.log("Jrt", address(jrtVault));
        console2.log("JrtF", address(cdo.jrtVault()));
        console2.log("Usdt", address(usdt));
        console2.log("Supports", trancheDepositor.tranches(address(jrtVault), address(usde)));
        trancheDepositor.deposit(IMetaVault(address(jrtVault)), usdt, 10e6, someUsdtHolder, params);
    }

}
