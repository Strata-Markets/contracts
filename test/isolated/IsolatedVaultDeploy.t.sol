// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlManager } from "../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../contracts/tranches/Tranche.sol";
import { DiscreteAccounting as Accounting } from "../../contracts/tranches/DiscreteAccounting.sol";
import { IsolatedStrategy } from "../../contracts/tranches/strategies/IsolatedStrategy.sol";
import { IAccounting } from "../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import { MockUSDe } from "../../contracts/test/MockUSDe.sol";
import { MockAprPairFeed } from "../../contracts/test/MockAprPairFeed.sol";
import { MockSingleStrategy } from "../../contracts/test/MockSingleStrategy.sol";
import { MockUnstakeCooldown } from "../../contracts/test/MockUnstakeCooldown.sol";
import { IUnstakeCooldown } from "../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import { Rebalancer } from "../../contracts/tranches/strategies/base/Rebalancer.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract IsolatedVaultDeploy is Test {
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    address internal owner;

    MockUSDe internal baseAsset;
    AccessControlManager internal acm;
    StrataCDO internal cdo;
    Tranche internal jrtVault;
    Tranche internal srtVault;
    MockSingleStrategy internal juniorStrat;
    MockSingleStrategy internal seniorStrat;
    MockAprPairFeed internal aprFeed;
    IsolatedStrategy internal strategy;
    Rebalancer internal rebalancer;
    Accounting internal accounting;

    function setUp() public virtual {
        owner = makeAddr("isolatedOwner");
        vm.label(owner, "IsolatedOwner");
        vm.deal(owner, 100 ether);
    }

    function _deployIsolatedStack() internal {
        vm.startPrank(owner);

        // 1. deploy base asset
        baseAsset = new MockUSDe();
        vm.label(address(baseAsset), "BaseAsset");

        // 2. deploy access control manager
        acm = new AccessControlManager(owner);
        vm.label(address(acm), "AccessControlManager");


        // 3. deploy cdo
        StrataCDO cdoImpl = new StrataCDO(IERC20Metadata(baseAsset));
        cdo = StrataCDO(
            address(new ERC1967Proxy(address(cdoImpl), abi.encodeWithSelector(StrataCDO.initialize.selector, owner, address(acm))))
        );
        vm.label(address(cdo), "StrataCDO");

        // 4. deploy tranches
        jrtVault = _deployTranche("JRT", "Junior Tranche");
        srtVault = _deployTranche("SRT", "Senior Tranche");


        // 5. deploy strats
        juniorStrat = new MockSingleStrategy(baseAsset);
        seniorStrat = new MockSingleStrategy(baseAsset);
        vm.label(address(juniorStrat), "JuniorStrat");
        vm.label(address(seniorStrat), "SeniorStrat");

        // 6. deploy apr feed
        aprFeed = new MockAprPairFeed();
        vm.label(address(aprFeed), "MockAprPairFeed");

        // 7. deploy isolated strategy
        IsolatedStrategy strategyImpl = new IsolatedStrategy();
        strategy = IsolatedStrategy(
            address(
                new ERC1967Proxy(
                    address(strategyImpl),
                    abi.encodeWithSelector(
                        IsolatedStrategy.initialize.selector,
                        owner,
                        address(acm),
                        IStrataCDO(address(cdo)),
                        juniorStrat,
                        seniorStrat,
                        3e17 // juniorAllocationFloor: 30%
                    )
                )
            )
        );
        vm.label(address(strategy), "IsolatedStrategy");

        // 8. deploy rebalancer
        MockUnstakeCooldown mockUnstakeCooldown = new MockUnstakeCooldown();
        Rebalancer rebalancerImpl = new Rebalancer();
        rebalancer = Rebalancer(address(new ERC1967Proxy(
            address(rebalancerImpl),
            abi.encodeWithSelector(Rebalancer.initialize.selector, owner, address(acm), address(strategy), address(mockUnstakeCooldown))
        )));
        strategy.setRebalancer(rebalancer);
        vm.label(address(rebalancer), "Rebalancer");

        // 9. deploy accounting
        Accounting accountingImpl = new Accounting(18, true);
        accounting = Accounting(
            address(
                new ERC1967Proxy(
                    address(accountingImpl),
                    abi.encodeWithSelector(
                        Accounting.initialize.selector,
                        owner,
                        address(acm),
                        IStrataCDO(address(cdo)),
                        aprFeed
                    )
                )
            )
        );
        vm.label(address(accounting), "Accounting");

        acm.grantRole(PAUSER_ROLE, owner);

        strategy.setAccounting(IAccounting(address(accounting)));
        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strategy)), ITranche(address(jrtVault)), ITranche(address(srtVault)));
        cdo.setActionStates(address(0), true, true);

        vm.stopPrank();
    }

    function _debtToJunior() internal view returns (uint256 d) { (d,) = strategy.debts(); }
    function _debtToSenior() internal view returns (uint256 d) { (, d) = strategy.debts(); }

    function _deployTranche(string memory symbol, string memory name) internal returns (Tranche) {
        Tranche trancheImpl = new Tranche();
        address proxy = address(
            new ERC1967Proxy(
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
            )
        );
        vm.label(proxy, symbol);
        return Tranche(proxy);
    }
}
