// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { RiskPremiumPower } from "../../../contracts/tranches/accounting/premium/RiskPremiumPower.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { IERC20Cooldown } from "../../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import { ERC20Cooldown } from "../../../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import { CooldownBase } from "../../../contracts/tranches/base/cooldown/CooldownBase.sol";
import { NestOpalStrategy } from "../../../contracts/tranches/strategies/nest/NestOpalStrategy.sol";
import { NestAccountantAprProvider } from "../../../contracts/tranches/strategies/nest/NestAccountantAprProvider.sol";
import { INestAccountant, IAprSnapshotProvider } from "../../../contracts/tranches/strategies/nest/interfaces/INestContracts.sol";
import { MockNestAccountant } from "../../../contracts/test/nest/MockNestContracts.sol";
import { MockNOpal } from "../../../contracts/test/nest/MockNestOpalContracts.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";

/// @notice A same-block accountant rate decrease must be reconciled before a Junior redemption.
/// @dev Real Nest strategy and APR provider with mocked accountant/token, conservative MTM accounting,
///      benchmark disabled and zero Senior floor. Compares same-block and next-block exits.
contract NestSameBlockDecreaseExitAvoidsLossTest is Test {
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");

    uint256 constant T0 = 1_700_000_000;
    uint256 constant RATE0 = 1_099_083; // live nOPAL accountant rate, 6 decimals
    uint256 constant RATE1 = RATE0 * 10_004 / 10_000; // +0.04%, inside the accountant's upper bound
    uint256 constant RATE2 = RATE1 * 9_996 / 10_000; // -0.04%, inside the accountant's lower bound

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    MTMAccounting accounting;
    MockAprPairFeed feed;
    MockNOpal nOpal;
    MockNestAccountant nestAccountant;
    NestOpalStrategy nest;
    NestAccountantAprProvider provider;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.warp(T0);
        MockERC20 usdc = new MockERC20("USDC", 6);
        nOpal = new MockNOpal();
        nestAccountant = new MockNestAccountant(address(usdc), RATE0);
        IERC20Metadata asset = IERC20Metadata(address(nOpal));

        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(asset, ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche(asset, "JRT");
        srt = _tranche(asset, "SRT");

        feed = new MockAprPairFeed();
        // 8% benchmark target, 10% base APR (SD7x12)
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp));

        // navDecimals, benchmark, navAtReconciliation, ratesForReconciliation,
        // juniorCoversPaidSrtProjection, conservativePrice, mtmProjection
        accounting = MTMAccounting(address(new ERC1967Proxy(
            address(new MTMAccounting(6, false, true, false, false, true, true)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector,
                address(this),
                address(acm),
                IStrataCDO(address(cdo)),
                IAprPairFeed(address(feed))
            )
        )));

        acm.grantRole(PAUSER_ROLE, address(this));
        acm.grantRole(UPDATER_FEED_ROLE, address(this));
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, address(this));
        acm.grantRole(RESERVE_MANAGER_ROLE, address(this));

        address erc20Cd = address(new ERC1967Proxy(
            address(new ERC20Cooldown()),
            abi.encodeWithSelector(CooldownBase.initialize.selector, address(this), address(acm))
        ));
        nest = NestOpalStrategy(address(new ERC1967Proxy(
            address(new NestOpalStrategy(
                IERC20(address(nOpal)), IERC20(address(usdc)), INestAccountant(address(nestAccountant))
            )),
            abi.encodeWithSelector(
                NestOpalStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IERC20Cooldown(erc20Cd)
            )
        )));
        acm.grantRole(keccak256("COOLDOWN_WORKER_ROLE"), address(nest));

        cdo.configure(IAccounting(address(accounting)), IStrategy(address(nest)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        accounting.setRiskModel(new RiskPremiumPower(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18)));

        _depositN(jrt, alice, 400_000_000_000);
        _depositN(srt, bob, 600_000_000_000);

        // APR provider seeded with ten daily snapshots at the current rate, as the Nest deployment configures it
        NestAccountantAprProvider.TRound[10] memory rounds;
        for (uint256 i = 0; i < 10; i++) {
            rounds[i] = NestAccountantAprProvider.TRound({
                answer: uint96(RATE0),
                updatedAt: uint64(T0 - (9 - i) * 1 days)
            });
        }
        provider = new NestAccountantAprProvider(INestAccountant(address(nestAccountant)), rounds);
        nest.setAprProvider(IAprSnapshotProvider(address(provider)));
    }

    function _tranche(IERC20Metadata asset, string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(true)),
            abi.encodeWithSelector(
                Tranche.initialize.selector,
                address(this), address(acm), name, name, IERC20(address(asset)), IStrataCDO(address(cdo))
            )
        )));
    }

    function _depositN(Tranche t, address user, uint256 amount) internal returns (uint256 shares) {
        nOpal.mint(user, amount);
        vm.startPrank(user);
        IERC20(address(nOpal)).approve(address(t), amount);
        shares = t.deposit(address(nOpal), amount, user);
        vm.stopPrank();
    }

    function _nextBlock() internal {
        vm.warp(vm.getBlockTimestamp() + 12);
        vm.roll(block.number + 1);
    }

    function _jrtRedeemablePps() internal view returns (uint256) {
        return Math.mulDiv(jrt.totalAssetsRedeemable(), 1e18, jrt.totalSupply());
    }

    // A positive accountant update is reconciled by the first flow of a later block, then the accountant
    // publishes a meaningful decrease in that same block (one hour after its previous update)
    function _reconcileThenDecreaseInOneBlock() internal {
        vm.warp(T0 + 1 days);
        vm.roll(block.number + 1);
        nestAccountant.setExchangeRate(RATE1);

        vm.warp(T0 + 1 days + 1 hours);
        vm.roll(block.number + 1);
        _depositN(jrt, carol, 1_000_000_000);
        assertEq(accounting.lastReconciliation(), vm.getBlockTimestamp(), "first flow reconciled in this block");

        nestAccountant.setExchangeRate(RATE2);
        assertTrue(provider.isMeaningfulUpdate(uint96(RATE2), uint64(vm.getBlockTimestamp())), "meaningful decrease");
        assertTrue(provider.isNegativeChange(uint96(RATE2)), "negative change");
    }

    function test_sameBlockRateDecreaseExitIncludesLoss() public {
        _reconcileThenDecreaseInOneBlock();

        uint256 storedNav = accounting.nav();
        uint256 liveNav = nest.totalAssets();
        assertLt(liveNav, storedNav, "live NAV already carries the decrease");
        (uint256 settled,, uint256 mark,) = nest.totalAssetsSnapshot(storedNav, accounting.lastReconciliation());
        assertEq(settled, liveNav, "same-block loss overrides the cooldown");
        assertEq(mark, liveNav, "both observations include the loss");

        uint256 shares = jrt.balanceOf(alice) / 10;
        uint256 lossAdjustedQuote = jrt.previewRedeem(shares);
        uint256 snap = vm.snapshotState();

        // Exit in the decrease block, after the decrease
        vm.prank(alice);
        uint256 tokensSameBlock = jrt.redeem(address(nOpal), shares, alice, alice);
        _nextBlock();
        vm.prank(address(jrt));
        cdo.updateAccounting();
        uint256 ppsAfterSameBlockExit = _jrtRedeemablePps();

        vm.revertToState(snap);

        // The same exit one block later, once the decrease is visible
        _nextBlock();
        vm.prank(alice);
        uint256 tokensNextBlock = jrt.redeem(address(nOpal), shares, alice, alice);
        uint256 ppsAfterNextBlockExit = _jrtRedeemablePps();

        console2.log("nOPAL paid in the decrease block", tokensSameBlock);
        console2.log("nOPAL paid one block later", tokensNextBlock);
        console2.log("remaining Junior PPS, exit in the decrease block", ppsAfterSameBlockExit);
        console2.log("remaining Junior PPS, exit one block later", ppsAfterNextBlockExit);

        assertApproxEqAbs(tokensSameBlock, Math.mulDiv(lossAdjustedQuote, 1e6, RATE2, Math.Rounding.Ceil), 2,
            "loss-adjusted quote at current rate");
        assertApproxEqAbs(tokensSameBlock, tokensNextBlock, 2, "same-block exit cannot avoid the loss");
        assertApproxEqAbs(ppsAfterSameBlockExit, ppsAfterNextBlockExit, 2, "remaining Junior retains the same value");
    }
}
