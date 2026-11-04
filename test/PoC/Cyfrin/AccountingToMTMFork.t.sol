// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";
import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UD60x18} from "@prb/math/src/ud60x18/ValueType.sol";
import {StrataCDO} from "../../../contracts/tranches/StrataCDO.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {RiskPremiumStatic} from "../../../contracts/tranches/accounting/premium/RiskPremiumStatic.sol";
import {IRiskPremiumModel} from "../../../contracts/tranches/accounting/premium/IRiskPremiumModel.sol";
import {RiskPremiumPower} from "../../../contracts/tranches/accounting/premium/RiskPremiumPower.sol";
import {ISharesCooldown} from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";

interface ILegacyMigrationAccounting {
    function cdo() external view returns (address);
    function owner() external view returns (address);
    function nav() external view returns (uint256);
    function riskX() external view returns (UD60x18);
    function riskY() external view returns (UD60x18);
    function riskK() external view returns (UD60x18);
    function updateAccounting() external;
}
interface IForkMigrationNavSource {
    function liveNav() external view returns (uint256);
    function epochDuration() external view returns (uint256);
    function recordFlow(uint256 assetsIn, uint256 assetsOut) external;
}
interface IForkMigrationTranche {
    function asset() external view returns (address);
}

/// @dev Test-only implementation at the deployed strategy proxy. No storage is changed:
///      deterministic NAV and epoch configuration live in the test, not in the strategy's slots.
///      This tests the accounting migration, not underlying Saturn/Midas/Nest investment mechanics.
contract ForkMigrationEpochStrategy {
    using SafeERC20 for IERC20;
    IForkMigrationNavSource immutable source;
    constructor(IForkMigrationNavSource source_) { source = source_; }
    function totalAssets() external view returns (uint256) { return source.liveNav(); }
    function totalAssets(uint256 settled, uint256 anchor) external view returns (uint256) {
        return block.timestamp - anchor >= source.epochDuration() ? source.liveNav() : settled;
    }
    function totalAssetsSnapshot(uint256 settled, uint256 anchor)
        external view returns (uint256, uint256, uint256, uint256)
    {
        uint256 live = source.liveNav();
        if (block.timestamp - anchor >= source.epochDuration()) {
            return (live, block.timestamp, live, block.timestamp);
        }
        return (settled, anchor, live, block.timestamp);
    }
    function convertToAssets(address, uint256 amount, Math.Rounding) external pure returns (uint256) { return amount; }
    function convertToTokens(address, uint256 amount, Math.Rounding) external pure returns (uint256) { return amount; }
    function depositFeeBps(address) external pure returns (uint256) { return 0; }
    function depositFeeBps(address, address, uint256) external pure returns (uint256) { return 0; }
    function maxDeposit(address, address, uint256) external pure returns (uint256) { return type(uint256).max; }
    function maxWithdraw(address, address, uint256) external pure returns (uint256) { return type(uint256).max; }
    function deposit(address, address token, uint256 amount, uint256 assets, address owner) external returns (uint256) {
        IERC20(token).safeTransferFrom(owner, address(this), amount);
        source.recordFlow(assets, 0);
        return assets;
    }
    function withdraw(address, address token, uint256 amount, uint256 assets, address, address receiver, bool) external returns (uint256) {
        source.recordFlow(0, assets);
        IERC20(token).safeTransfer(receiver, amount);
        return amount;
    }
    function getRate() external pure returns (uint256) { return 1e18; }
}

/// @notice Replays upgrades on deployed mainnet proxies, preserving their balances and storage.
/// @dev Requires MAINNET_RPC_URL with archive access. All upgrades use the real ProxyAdmin owner.
contract AccountingToMTMForkTest is Test, IForkMigrationNavSource {
    uint256 constant FORK_BLOCK = 26_044_232;
    address constant SATURN = 0x180f7b3b807FA91EDb6e864802e4664D6Ee8Cf88;
    // MHyperAccountingProxy in deployments/mhyper/deployments-eth.json.
    address constant MHYPER = 0xAf32D44D510B82b64f13602f4A22c6A7FfF2b228;
    // NestOpalAccountingProxy in deployments/nestopal/deployments-eth.json.
    address constant NESTOPAL = 0xB6F3d2deF3058d4Faf07E7104DE2f69c638f2BF7;
    // AccessControlManager constructor admin, verified to retain DEFAULT_ADMIN_ROLE at FORK_BLOCK.
    address constant NESTOPAL_ROLE_ADMIN = 0x4be3749a0F6557b8fd98F3967e859DbD7C694eF4;
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    // Legacy accounting storage layout, including inherited storage and gaps.
    uint256 constant JRT_BASE_NAV_SLOT = 108;
    uint256 constant SRT_BASE_NAV_SLOT = 109;
    uint256 constant RESERVE_NAV_SLOT = 110;
    uint256 constant NAV_TARGET_INDEX_SLOT = 118;
    uint256 constant JRT_NAV_PROJECTED_SLOT = 120;
    // Covers slots 0 through 148, including srtBoughtProjected.
    uint256 constant ACCOUNTING_STORAGE_SLOT_COUNT = 149;

    uint256 public liveNav;
    uint256 public epochDuration;
    uint256 internal upgradeDelay;
    bool internal flowsDuringUpgrade;
    address internal fixtureStrategy;

    function recordFlow(uint256 assetsIn, uint256 assetsOut) external {
        require(msg.sender == fixtureStrategy, "Only test strategy");
        liveNav = liveNav + assetsIn - assetsOut;
    }

    function _gapFlows(StrataCDO cdo, address token, uint256 start) internal {
        // Saturn Junior exits enter a 28-day lock at this fork; use its liquid Senior route.
        IERC4626 tranche = IERC4626(address(cdo) == ILegacyMigrationAccounting(SATURN).cdo()
            ? address(cdo.srtVault()) : address(cdo.jrtVault()));
        address user = makeAddr("migration depositor");
        uint256 amount = 100 * 10 ** IERC20Metadata(token).decimals();
        deal(token, user, amount);
        // The replacement strategy accepts the base token directly (including Nest's alternate route).
        vm.prank(address(tranche));
        IERC20(token).approve(fixtureStrategy, type(uint256).max);
        vm.warp(start + 20 minutes);
        vm.startPrank(user);
        IERC20(token).approve(address(tranche), amount);
        uint256 shares = tranche.deposit(amount, user);
        vm.stopPrank();
        assertGt(shares, 0);
        assertEq(IERC20(token).balanceOf(user), 0);
        vm.warp(start + 40 minutes);
        vm.prank(user);
        uint256 assetsOut = tranche.redeem(shares / 2, user, user);
        assertGt(assetsOut, 0);
        assertEq(IERC20(token).balanceOf(user), assetsOut);
        assertEq(tranche.balanceOf(user), shares - shares / 2);
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);
    }

    function _upgrade(address proxy, address implementation, bytes memory data) internal {
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(proxy, ADMIN_SLOT)))));
        vm.prank(admin.owner());
        admin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), implementation, data);
    }

    // Legacy deployments expose these NAV fields only through storage.
    function _stored(address proxy, uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(proxy, bytes32(slot)));
    }

    function _checkpoint(address accounting) internal {
        vm.prank(ILegacyMigrationAccounting(accounting).cdo());
        ILegacyMigrationAccounting(accounting).updateAccounting();
    }

    function _implementation(address accounting, bool liveProjection) internal returns (MTMAccounting) {
        StrataCDO cdo = StrataCDO(ILegacyMigrationAccounting(accounting).cdo());
        address token = IForkMigrationTranche(address(cdo.jrtVault())).asset();
        return new MTMAccounting(IERC20Metadata(token).decimals(), accounting == SATURN, true, false, true, true, liveProjection);
    }

    function test_saturnV1UpgradeSeedsProjectionState() public {
        assertEq(uint64(uint256(vm.load(SATURN, INITIALIZABLE_SLOT))), 1);
        _checkpoint(SATURN);
        ILegacyMigrationAccounting old = ILegacyMigrationAccounting(SATURN);
        uint256 navBefore = old.nav();
        uint256 juniorBefore = _stored(address(old), JRT_BASE_NAV_SLOT);
        uint256 seniorBefore = _stored(address(old), SRT_BASE_NAV_SLOT);
        uint256 reserveBefore = _stored(address(old), RESERVE_NAV_SLOT);
        assertGt(navBefore, 0);
        MTMAccounting implementation = _implementation(SATURN, true);
        _upgrade(SATURN, address(implementation), abi.encodeCall(MTMAccounting.initializeV3, ()));
        MTMAccounting m = MTMAccounting(SATURN);
        assertEq(uint64(uint256(vm.load(SATURN, INITIALIZABLE_SLOT))), 3);
        assertEq(m.nav(), navBefore);
        assertEq(m.jrtBaseNav(), juniorBefore);
        assertEq(m.srtBaseNav(), seniorBefore);
        assertEq(m.reserveNav(), reserveBefore);
        assertEq(m.navTargetIndex(), 1e18);
        assertEq(m.navTimestamp(), block.timestamp);
        assertEq(m.lastReconciliation(), block.timestamp);
        assertEq(m.jrtNavProjected(), juniorBefore);
        assertEq(m.lastAccrual(), block.timestamp);
        assertEq(m.epochStart(), block.timestamp);
    }

    function _epochUpgrade(address proxy, bool hasProjectionState) internal returns (MTMAccounting m) {
        ILegacyMigrationAccounting old = ILegacyMigrationAccounting(proxy);
        StrataCDO cdo = StrataCDO(old.cdo());
        address token = IForkMigrationTranche(address(cdo.jrtVault())).asset();
        // Preserve both markets' premiums, including Saturn's fixed 100% premium.
        IRiskPremiumModel model;
        if (hasProjectionState) {
            model = new RiskPremiumPower(old.riskX(), old.riskY(), old.riskK());
        } else {
            assertEq(old.riskX().unwrap(), 1e18);
            assertEq(old.riskY().unwrap(), 0);
            model = new RiskPremiumStatic(UD60x18.wrap(1e18));
        }
        // Force a genuine predecessor reconciliation before migration; Discrete/DYS must unwind
        // embedded projection. Strategy NAV is controlled only in this test fixture.
        liveNav = old.nav() + 10 ** IERC20Metadata(token).decimals();
        epochDuration = 0;
        fixtureStrategy = address(cdo.strategy());
        _upgrade(address(cdo.strategy()), address(new ForkMigrationEpochStrategy(this)), "");
        _checkpoint(proxy);
        assertEq(old.nav(), liveNav);
        uint256 junior = _stored(address(old), JRT_BASE_NAV_SLOT);
        uint256 senior = _stored(address(old), SRT_BASE_NAV_SLOT);
        uint256 reserve = _stored(address(old), RESERVE_NAV_SLOT);
        uint256 oldIndex;
        if (hasProjectionState) {
            oldIndex = _stored(proxy, NAV_TARGET_INDEX_SLOT);
            assertGt(oldIndex, 0);
            assertEq(_stored(proxy, JRT_NAV_PROJECTED_SLOT), junior, "predecessor projection settled before migration");
        }
        uint256 checkpointTime = block.timestamp;
        if (flowsDuringUpgrade) {
            _gapFlows(cdo, token, checkpointTime);
            junior = _stored(proxy, JRT_BASE_NAV_SLOT);
            senior = _stored(proxy, SRT_BASE_NAV_SLOT);
            reserve = _stored(proxy, RESERVE_NAV_SLOT);
            oldIndex = _stored(proxy, NAV_TARGET_INDEX_SLOT);
        }
        uint256 projectedJunior = _stored(proxy, JRT_NAV_PROJECTED_SLOT);
        vm.warp(checkpointTime + upgradeDelay);
        // Legacy CDOs predate the snapshot API. Upgrade the real CDO proxy without reinitializing.
        _upgrade(address(cdo), address(new StrataCDO(IERC20Metadata(token), ISharesCooldown(address(0)))), "");
        uint64 version = uint64(uint256(vm.load(proxy, INITIALIZABLE_SLOT)));
        bytes32[] memory beforeState = new bytes32[](ACCOUNTING_STORAGE_SLOT_COUNT);
        if (version == 3) {
            for (uint256 i; i < beforeState.length; ++i) {
                beforeState[i] = vm.load(proxy, bytes32(i));
            }
        }
        bytes memory initialization = version < 3 ? abi.encodeCall(MTMAccounting.initializeV3, ()) : bytes("");
        _upgrade(proxy, address(_implementation(proxy, true)), initialization);
        if (version == 3) {
            for (uint256 i; i < beforeState.length; ++i) {
                assertEq(vm.load(proxy, bytes32(i)), beforeState[i], "V3 implementation swap preserves storage");
            }
            assertEq(uint64(uint256(vm.load(proxy, INITIALIZABLE_SLOT))), 3);
        }
        m = MTMAccounting(proxy);
        epochDuration = 1 days;
        assertEq(m.nav(), liveNav);
        assertEq(m.jrtBaseNav(), junior);
        assertEq(m.srtBaseNav(), senior);
        assertEq(m.reserveNav(), reserve);
        assertEq(m.jrtNavProjected(), hasProjectionState ? projectedJunior : junior);
        assertEq(m.navTargetIndex(), hasProjectionState ? oldIndex : 1e18);
        if (!flowsDuringUpgrade) {
            assertEq(m.lastReconciliation(), hasProjectionState ? checkpointTime : block.timestamp);
            assertEq(m.srtPnLProjected(), 0);
        }
        // Activate the selected external premium before starting the first epoch.
        AccessControlManager acm = AccessControlManager(address(m.acm()));
        address configOperator = m.owner();
        bytes32 configRole = keccak256("UPDATER_STRAT_CONFIG_ROLE");
        if (!acm.hasRole(configRole, configOperator)) {
            address roleAdmin = proxy == NESTOPAL ? NESTOPAL_ROLE_ADMIN : configOperator;
            assertTrue(acm.hasRole(bytes32(0), roleAdmin), "configured role admin must be authorized");
            vm.prank(roleAdmin);
            acm.grantRole(configRole, configOperator);
        }
        vm.prank(configOperator);
        m.setRiskModel(model);
    }

    function _checkFirstEpoch(address proxy, bool hasProjectionState) internal {
        MTMAccounting m = _epochUpgrade(proxy, hasProjectionState);
        uint256 start = block.timestamp;
        uint256 epochAnchor = m.lastReconciliation();
        uint256 settled = m.nav();
        uint256 junior = m.jrtNavProjected() + uint256(m.srtPnLProjected());
        // Setting the model checkpoints elapsed projection after a delayed upgrade.
        assertGe(m.srtPnLProjected(), 0);
        uint256 senior = m.srtBaseNav() - uint256(m.srtPnLProjected());
        uint256 reserve = m.reserveNav();
        vm.warp(start + 1 hours);
        liveNav = settled - junior / 10;
        _checkpoint(proxy);
        assertEq(m.nav(), settled, "intraday dip must not reconcile");
        assertEq(m.lastReconciliation(), epochAnchor);
        assertLt(m.jrtNavProjected(), junior);
        vm.warp(start + 2 hours);
        liveNav = settled;
        _checkpoint(proxy);
        assertEq(m.nav(), settled);
        assertEq(m.lastReconciliation(), epochAnchor);
        assertGe(m.srtPnLProjected(), 0);
        uint256 projection = uint256(m.srtPnLProjected());
        assertEq(m.jrtNavProjected() + projection, junior, "temporary loss reverses; target yield remains projected");
        assertEq(m.srtBaseNav() - projection, senior);
        // Final settled profit: check the first reconciliation against proportional allocation,
        // including the deployed reserve fee and selected premium, not just preview == execution.
        uint256 gain = settled / 1000;
        liveNav = settled + gain;
        uint256 fee = Math.mulDiv(Math.min(gain, Math.saturatingSub(liveNav, m.feeWatermarkNav())), m.reserveBps(), 1e18);
        uint256 risk = m.riskPremiumModel().riskPremium(UD60x18.wrap(senior * 1e18 / (senior + junior))).unwrap();
        uint256 seniorGain = Math.mulDiv(gain, (1e18 - risk) * senior, 1e18 * settled);
        if (!hasProjectionState) {
            assertTrue(m.useBenchmarkProjection());
            assertEq(risk, 1e18);
            assertEq(m.aprSrt().unwrap(), m.aprTarget().unwrap());
            assertGt(m.aprTarget().unwrap(), 0, "Saturn must have a target APR");
            uint256 index = m.benchmarkIndex();
            uint256 factor = m.aprTarget().unwrap() * (epochAnchor + 1 days - m.indexTimestamp()) / 365 days;
            uint256 nextIndex = index * (1e18 + factor) / 1e18;
            seniorGain = m.srtPnLBenchmark() + m.srtBaseNav() * nextIndex / index - m.srtBaseNav();
        }
        vm.warp(epochAnchor + 1 days);
        _checkpoint(proxy);
        assertEq(m.lastReconciliation(), block.timestamp);
        assertEq(m.nav(), liveNav);
        assertApproxEqAbs(m.srtBaseNav(), senior + seniorGain, 2);
        assertApproxEqAbs(m.jrtBaseNav(), junior + gain - fee - seniorGain, 2);
        assertEq(m.reserveNav(), reserve + fee);
        assertEq(m.srtPnLProjected(), 0);
        assertEq(m.srtNavTime(), 0);
        assertEq(m.jrtNavProjected(), m.jrtBaseNav());
        uint256 s = m.srtBaseNav();
        _checkpoint(proxy);
        assertEq(m.srtBaseNav(), s, "same-block repeat must not settle twice");
    }

    function test_nestOpalDysFirstDailyMtmReconciliation() public {
        assertEq(uint64(uint256(vm.load(NESTOPAL, INITIALIZABLE_SLOT))), 3, "deployed DYS initializer version");
        assertGt(_stored(NESTOPAL, NAV_TARGET_INDEX_SLOT), 0, "DYS already has a strategy target index");
        _checkFirstEpoch(NESTOPAL, true);
        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        MTMAccounting(NESTOPAL).initializeV3();
    }

    function test_saturnUpgradeOneHourAfterCheckpoint() public {
        upgradeDelay = 1 hours;
        _checkFirstEpoch(SATURN, false);
    }

    function test_mhyperUpgradeOneHourAfterReconciliation() public {
        upgradeDelay = 1 hours;
        _checkFirstEpoch(MHYPER, true);
    }

    function test_nestOpalUpgradeOneHourAfterReconciliation() public {
        upgradeDelay = 1 hours;
        _checkFirstEpoch(NESTOPAL, true);
    }

    function test_saturnFirstDailyMtmReconciliation() public { _checkFirstEpoch(SATURN, false); }
    function test_mhyperDiscreteFirstDailyMtmReconciliation() public { _checkFirstEpoch(MHYPER, true); }
    function _checkUpgradeWithFlows(address proxy, bool hasProjectionState) internal {
        upgradeDelay = 1 hours;
        flowsDuringUpgrade = true;
        MTMAccounting m = _epochUpgrade(proxy, hasProjectionState);
        assertGt(m.navTargetIndex(), 0);
        assertGt(m.lastReconciliation(), 0);
        assertEq(m.lastAccrual(), block.timestamp);
        uint256 settled = m.nav();
        vm.warp(block.timestamp + 1 hours);
        liveNav = settled - settled / 1000;
        _checkpoint(proxy);
        assertEq(m.nav(), settled, "live dip must not reconcile");
        liveNav = settled + settled / 1000;
        vm.warp(m.lastReconciliation() + 1 days);
        _checkpoint(proxy);
        assertEq(m.nav(), liveNav);
        assertEq(m.lastReconciliation(), block.timestamp);
        assertEq(m.srtPnLProjected(), 0);
        assertEq(m.jrtNavProjected(), m.jrtBaseNav());
        assertApproxEqAbs(m.jrtBaseNav() + m.srtBaseNav() + m.reserveNav() + m.underwriterFeeNav(), liveNav, 2, "settled buckets conserve assets");
        uint256 senior = m.srtBaseNav();
        uint256 junior = m.jrtBaseNav();
        _checkpoint(proxy);
        assertEq(m.srtBaseNav(), senior);
        assertEq(m.jrtBaseNav(), junior);
    }

    function test_saturnUpgradeWithDepositAndRedemption() public { _checkUpgradeWithFlows(SATURN, false); }
    function test_mhyperUpgradeWithDepositAndRedemption() public { _checkUpgradeWithFlows(MHYPER, true); }
    function test_nestOpalUpgradeWithDepositAndRedemption() public { _checkUpgradeWithFlows(NESTOPAL, true); }
}
