// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AccessControlManager} from "../../contracts/governance/AccessControlManager.sol";
import {StrataCDO} from "../../contracts/tranches/StrataCDO.sol";
import {Tranche} from "../../contracts/tranches/Tranche.sol";
import {Accounting} from "../../contracts/tranches/Accounting.sol";
import {NestOpalStrategy} from "../../contracts/tranches/strategies/nest/NestOpalStrategy.sol";
import {NestOpalDepositAdapter} from "../../contracts/tranches/strategies/nest/NestOpalDepositAdapter.sol";
import {INestAccountant, INestVaultPredicateProxy} from "../../contracts/tranches/strategies/nest/interfaces/INestContracts.sol";
import {ERC20Cooldown} from "../../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import {CooldownBase} from "../../contracts/tranches/base/cooldown/CooldownBase.sol";
import {IERC20Cooldown} from "../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import {IAccounting} from "../../contracts/tranches/interfaces/IAccounting.sol";
import {IStrategy} from "../../contracts/tranches/interfaces/IStrategy.sol";
import {ITranche} from "../../contracts/tranches/interfaces/ITranche.sol";
import {IErrors} from "../../contracts/tranches/interfaces/IErrors.sol";
import {IStrataCDO} from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import {TrancheDepositor} from "../../contracts/tranches/TrancheDepositor.sol";
import {IAdapter} from "../../contracts/tranches/interfaces/IAdapter.sol";

import {MockNestAccountant} from "../../contracts/test/nest/MockNestContracts.sol";
import {MockNOpal, MockNestPredicateProxy} from "../../contracts/test/nest/MockNestOpalContracts.sol";
import {MockERC20} from "../../contracts/test/MockERC20.sol";

/// @title NestOpalDeploy
/// @notice Base deployment contract for Nest nOPAL strategy tests
/// @dev Deploys the full Strata stack with mock Nest contracts (no fork required)
contract NestOpalDeploy is Test {
    // Roles
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_CDO_APR_ROLE = keccak256("UPDATER_CDO_APR_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");
    bytes32 constant CDO_OWNER_ROLE = keccak256("CDO_OWNER_ROLE");
    bytes32 constant COOLDOWN_WORKER_ROLE = keccak256("COOLDOWN_WORKER_ROLE");
    bytes32 constant DEPOSITOR_CONFIG_ROLE = keccak256("DEPOSITOR_CONFIG_ROLE");

    // Mock external contracts
    MockERC20 internal usdc;
    MockNOpal internal nOpal;
    MockNestAccountant internal nestAccountant;
    MockNestPredicateProxy internal predicateProxy;

    // Strata contracts
    address internal owner;
    AccessControlManager internal acm;
    StrataCDO internal cdo;
    Tranche internal jrtVault;
    Tranche internal srtVault;
    ERC20Cooldown internal erc20Cooldown;
    NestOpalStrategy internal strategy;
    Accounting internal accounting;
    NestOpalDepositAdapter internal opalAdapter;
    TrancheDepositor internal depositor;

    // Constants matching mainnet nOPAL
    uint256 constant INITIAL_RATE = 1068582; // ~1.068582 USDC/nOPAL (6 decimals)
    uint256 constant ONE_USDC = 1e6;
    uint256 constant ONE_NOPAL = 1e6;

    function setUp() public virtual {
        owner = makeAddr("strataOwner");
        vm.label(owner, "DeployerOwner");
        vm.deal(owner, 100 ether);
    }

    function _deployNestOpalStack() internal {
        vm.startPrank(owner);

        // ══════════ Deploy mock external contracts ══════════

        usdc = new MockERC20("USDC", 6);
        vm.label(address(usdc), "USDC");

        nOpal = new MockNOpal();
        vm.label(address(nOpal), "nOPAL");

        nestAccountant = new MockNestAccountant(address(usdc), INITIAL_RATE);
        vm.label(address(nestAccountant), "NestAccountant");

        predicateProxy = new MockNestPredicateProxy(nOpal, nestAccountant);
        vm.label(address(predicateProxy), "PredicateProxy");

        // ══════════ Deploy Strata infrastructure ══════════

        // 1. AccessControlManager
        acm = new AccessControlManager(owner);
        vm.label(address(acm), "AccessControlManager");

        // 2. StrataCDO (nOPAL is the base asset for the CDO)
        StrataCDO cdoImpl = new StrataCDO(IERC20Metadata(address(nOpal)));
        cdo = StrataCDO(
            address(new ERC1967Proxy(
                address(cdoImpl),
                abi.encodeWithSelector(StrataCDO.initialize.selector, owner, address(acm))
            ))
        );
        vm.label(address(cdo), "StrataCDO");

        // 3. Tranche vaults
        jrtVault = _deployTranche("JRT", "Junior Tranche");
        srtVault = _deployTranche("SRT", "Senior Tranche");

        // 4. ERC20Cooldown
        ERC20Cooldown cooldownImpl = new ERC20Cooldown();
        erc20Cooldown = ERC20Cooldown(
            address(new ERC1967Proxy(
                address(cooldownImpl),
                abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
            ))
        );
        vm.label(address(erc20Cooldown), "ERC20Cooldown");

        // 5. NestOpalStrategy
        NestOpalStrategy strategyImpl = new NestOpalStrategy(
            IERC20(address(nOpal)),
            IERC20(address(usdc)),
            INestAccountant(address(nestAccountant))
        );
        strategy = NestOpalStrategy(
            address(new ERC1967Proxy(
                address(strategyImpl),
                abi.encodeWithSelector(
                    NestOpalStrategy.initialize.selector,
                    owner,
                    address(acm),
                    IStrataCDO(address(cdo)),
                    IERC20Cooldown(address(erc20Cooldown))
                )
            ))
        );
        vm.label(address(strategy), "NestOpalStrategy");

        // 6. NestOpalDepositAdapter (NestVaultPredicateProxy)
        opalAdapter = new NestOpalDepositAdapter(
            INestVaultPredicateProxy(address(predicateProxy)),
            address(0xdead), // nestVault address (mock doesn't use it)
            address(nOpal)
        );
        vm.label(address(opalAdapter), "NestOpalDepositAdapter");

        // 7. Accounting (6 decimals to match USDC/nOPAL)
        Accounting accountingImpl = new Accounting(6);
        accounting = Accounting(
            address(new ERC1967Proxy(
                address(accountingImpl),
                abi.encodeWithSelector(
                    Accounting.initialize.selector,
                    owner,
                    address(acm),
                    IStrataCDO(address(cdo)),
                    address(0) // no APR feed for now
                )
            ))
        );
        vm.label(address(accounting), "Accounting");

        // 8. TrancheDepositor
        TrancheDepositor depositorImpl = new TrancheDepositor();
        depositor = TrancheDepositor(
            address(new ERC1967Proxy(
                address(depositorImpl),
                abi.encodeWithSelector(TrancheDepositor.initialize.selector, owner, address(acm))
            ))
        );
        vm.label(address(depositor), "TrancheDepositor");

        // ══════════ Grant roles ══════════

        acm.grantRole(PAUSER_ROLE, owner);
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        acm.grantRole(COOLDOWN_WORKER_ROLE, address(strategy));
        acm.grantRole(DEPOSITOR_CONFIG_ROLE, owner);

        // ══════════ Configure CDO ══════════

        cdo.configure(
            IAccounting(address(accounting)),
            IStrategy(address(strategy)),
            ITranche(address(jrtVault)),
            ITranche(address(srtVault))
        );

        // ══════════ Enable tranches ══════════

        cdo.setActionStates(address(jrtVault), true, true);
        cdo.setActionStates(address(srtVault), true, true);

        // ══════════ Configure adapter on depositor ══════════

        // Register nOPAL as a supported meta token for both tranches
        depositor.addCdo(IStrataCDO(address(cdo)));

        TrancheDepositor.TAdapterConfig memory adapterConfig = TrancheDepositor.TAdapterConfig({
            adapter: IAdapter(address(opalAdapter)),
            tokenOut: address(nOpal),
            minimumReturnPercentage: 900 // 90% min output
        });
        depositor.addCdoAdapterSwap(IStrataCDO(address(cdo)), address(usdc), adapterConfig);

        vm.stopPrank();
    }

    function _deployTranche(string memory name, string memory symbol) internal returns (Tranche) {
        Tranche trancheImpl = new Tranche(false);
        address proxy = address(new ERC1967Proxy(
            address(trancheImpl),
            abi.encodeWithSelector(
                Tranche.initialize.selector,
                owner,
                address(acm),
                name,
                symbol,
                IERC20(address(nOpal)),
                IStrataCDO(address(cdo))
            )
        ));
        vm.label(proxy, string.concat(name, "_Tranche"));
        return Tranche(proxy);
    }

    // ══════════ Test helpers ══════════

    function _mintNOpal(address to, uint256 amount) internal {
        nOpal.mint(to, amount);
    }

    function _mintUSDC(address to, uint256 amount) internal {
        usdc.mint(to, amount);
    }

    function _depositToJrt(address user, uint256 amount) internal {
        vm.startPrank(user);
        IERC20(address(nOpal)).approve(address(jrtVault), amount);
        jrtVault.deposit(address(nOpal), amount, user);
        vm.stopPrank();
    }

    function _depositToSrt(address user, uint256 amount) internal {
        vm.startPrank(user);
        IERC20(address(nOpal)).approve(address(srtVault), amount);
        srtVault.deposit(address(nOpal), amount, user);
        vm.stopPrank();
    }
}
