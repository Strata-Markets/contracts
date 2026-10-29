// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISharesCooldown} from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UD60x18} from "@prb/math/src/ud60x18/ValueType.sol";

import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";
import {StrataCDO} from "../../../contracts/tranches/StrataCDO.sol";
import {Tranche} from "../../../contracts/tranches/Tranche.sol";
import {DiscreteAccounting} from "../../../contracts/tranches/DiscreteAccounting.sol";
import {IAccounting} from "../../../contracts/tranches/interfaces/IAccounting.sol";
import {IStrategy} from "../../../contracts/tranches/interfaces/IStrategy.sol";
import {ITranche} from "../../../contracts/tranches/interfaces/ITranche.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IAprPairFeed} from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import {IInsuranceMiddleware} from
    "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import {IInsuranceVault} from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import {MockERC20} from "../../../contracts/test/MockERC20.sol";
import {MockAprPairFeed} from "../../../contracts/test/MockAprPairFeed.sol";
import {MockMTMStrategy} from "../../../contracts/test/MockMTMStrategy.sol";
import {MockInsurancePool} from "../../symbiotic/mocks/MockInsurancePool.sol";

/// @notice Regression adapted from the auditor PoC: intermediate projection updates must accrue fees.
contract DiscreteProjectionUnderwriterFeeTest is Test {
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");

    uint256 constant DEP = 1_000_000e18;
    uint256 constant ORACLE_GAIN = 500e18; // daily strategy gain reported by the oracle

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    DiscreteAccounting accounting;
    MockMTMStrategy strategy;
    MockERC20 token;
    MockInsurancePool pool;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_790_000_000);
        token = new MockERC20("BASE", 18);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(
            address(
                new ERC1967Proxy(
                    address(new StrataCDO(token, ISharesCooldown(address(0)))),
                    abi.encodeWithSelector(
                        StrataCDO.initialize.selector, address(this), address(acm)
                    )
                )
            )
        );
        jrt = _tranche("JRT");
        srt = _tranche("SRT");

        MockAprPairFeed feed = new MockAprPairFeed();
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp)); // 8% target, 10% base
        accounting = DiscreteAccounting(
            address(
                new ERC1967Proxy(
                    address(new DiscreteAccounting(18, false)),
                    abi.encodeWithSelector(
                        DiscreteAccounting.initialize.selector,
                        address(this),
                        address(acm),
                        IStrataCDO(address(cdo)),
                        IAprPairFeed(address(feed))
                    )
                )
            )
        );

        strategy = MockMTMStrategy(
            address(
                new ERC1967Proxy(
                    address(new MockMTMStrategy(IERC20(address(token)))),
                    abi.encodeWithSelector(
                        MockMTMStrategy.initialize.selector,
                        address(this),
                        address(acm),
                        IStrataCDO(address(cdo)),
                        address(0),
                        address(0)
                    )
                )
            )
        );
        // Anchor is navTimestamp (refreshed by every update), so the strategy value is always read fresh and
        // NAV moves only when the test moves it, like a Discrete oracle update
        strategy.setEpochDuration(7 days);

        acm.grantRole(keccak256("PAUSER_ROLE"), address(this));
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, address(this));
        cdo.configure(
            IAccounting(address(accounting)),
            IStrategy(address(strategy)),
            ITranche(address(jrt)),
            ITranche(address(srt))
        );
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18)); // risk premium 50%

        // Symbiotic market: the middleware relays a 10% underwriter fee, so 5% of Senior gain is owed
        pool = new MockInsurancePool();
        pool.setCapacity(10_000_000e18);
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(0)));
        vm.prank(address(pool));
        cdo.setUnderwriterFeeBps(0.1e18);

        _deposit(jrt, alice, DEP);
        _deposit(srt, bob, DEP);
    }

    function _tranche(string memory name) internal returns (Tranche) {
        return Tranche(
            address(
                new ERC1967Proxy(
                    address(new Tranche(true)),
                    abi.encodeWithSelector(
                        Tranche.initialize.selector,
                        address(this),
                        address(acm),
                        name,
                        name,
                        IERC20(address(token)),
                        IStrataCDO(address(cdo))
                    )
                )
            )
        );
    }

    function _deposit(Tranche t, address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        t.deposit(amount, user);
        vm.stopPrank();
    }

    function _poke() internal {
        vm.prank(keeper);
        jrt.burnSharesAsFee(0, keeper); // permissionless refresh, same path as any user flow
    }

    /// @dev One oracle day: `pokes` refreshes spread over the day, then the oracle reports the gain
    function _runDay(uint256 pokes)
        internal
        returns (uint256 fee, uint256 jrtNav, uint256 srtNav)
    {
        uint256 start = vm.getBlockTimestamp();
        uint256 step = 1 days / (pokes + 1);
        for (uint256 i = 1; i <= pokes; i++) {
            vm.warp(start + i * step);
            _poke();
            uint256 seniorGain = accounting.srtBaseNav() - DEP;
            assertApproxEqAbs(
                accounting.underwriterFeeNav(),
                seniorGain / 19,
                100,
                "each projection books the 5% fee alongside the 95% net Senior gain"
            );
            assertEq(
                accounting.jrtBaseNav() + accounting.srtBaseNav() + accounting.underwriterFeeNav(),
                2 * DEP
            );
        }
        vm.warp(start + 1 days);
        strategy.setTotalAssets(strategy.totalAssetsValue() + ORACLE_GAIN);
        _poke(); // reconciliation
        fee = accounting.underwriterFeeNav();
        jrtNav = accounting.jrtBaseNav();
        srtNav = accounting.srtBaseNav();
        console.log("pokes during the day", pokes);
        console.log("  underwriterFeeNav", fee);
        console.log("  Junior / Senior NAV", jrtNav, srtNav);
    }

    function test_intermediateUpdatesPreserveUnderwriterFees() public {
        uint256 snap = vm.snapshotState();
        (uint256 feeOnce, uint256 jrtOnce, uint256 srtOnce) = _runDay(0);
        vm.revertToState(snap);
        (uint256 feeHourly, uint256 jrtHourly, uint256 srtHourly) = _runDay(23);

        // Senior earns 8% APR on 1M for one day either way (~219.18) and pays the 5% fee out of it
        assertApproxEqRel(srtOnce - DEP, 219.18e18 * 95 / 100, 0.001e18);
        assertApproxEqRel(
            srtHourly - DEP,
            srtOnce - DEP,
            0.001e18,
            "Senior net gain is the same apart from compounding"
        );
        // hourly index updates compound Senior's accrual, which lifts it by a few hundredths
        console.log("Senior NAV above the single-update run", srtHourly - srtOnce);
        assertGt(srtHourly, srtOnce, "hourly updates compound Senior's accrual");
        assertLt(srtHourly - srtOnce, 0.03e18, "compounding stays below 0.03");

        // Both runs pay the full fee; only the small compounding difference remains.
        assertApproxEqRel(feeOnce, 10.96e18, 0.001e18);
        assertApproxEqRel(feeHourly, feeOnce, 0.001e18);
        assertApproxEqAbs(feeHourly - feeOnce, (srtHourly - srtOnce) / 19, 100);
        assertEq(jrtOnce + srtOnce + feeOnce, 2 * DEP + ORACLE_GAIN);
        assertEq(jrtHourly + srtHourly + feeHourly, 2 * DEP + ORACLE_GAIN);
    }
}
