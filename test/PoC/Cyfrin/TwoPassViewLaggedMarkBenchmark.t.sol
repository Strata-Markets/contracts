// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { RiskPremiumPower } from "../../../contracts/tranches/accounting/premium/RiskPremiumPower.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { Strategy } from "../../../contracts/tranches/Strategy.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";

/// @notice SIP-10 strategy that stamps its settled NAV and its live mark with the times they were observed, so
///         the live mark can be newer than the settled observation but older than the current block. Token
///         handling follows `MockMTMStrategy`
contract LaggedMarkStrategy is Strategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    uint256 public liveAssets;
    uint256 public liveAt;
    uint256 public settledAssets;
    uint256 public settledAt;

    constructor(IERC20 token_) Strategy(address(token_), address(token_)) {
        token = token_;
    }

    function initialize(address owner_, address acm_, IStrataCDO cdo_) public initializer {
        AccessControlled_init(owner_, acm_);
        cdo = cdo_;
    }

    // A settled NAV observed now; the live mark equals it at that moment
    function publishSettled(uint256 nav_) external {
        settledAssets = nav_;
        settledAt = block.timestamp;
        liveAssets = nav_;
        liveAt = block.timestamp;
    }

    // A live mark observed now
    function setLive(uint256 nav_) external {
        liveAssets = nav_;
        liveAt = block.timestamp;
    }

    function deposit(
        address,
        address token_,
        uint256 tokenAmount,
        uint256 baseAssets,
        address owner
    ) public override returns (uint256) {
        require(token_ == address(token), "UnsupportedToken");
        token.safeTransferFrom(owner, address(this), tokenAmount);
        liveAssets += baseAssets;
        return baseAssets;
    }

    function withdraw(
        address,
        address token_,
        uint256 tokenAmount,
        uint256 baseAssets,
        address,
        address receiver
    ) public override returns (uint256) {
        return _withdrawTokens(token_, tokenAmount, baseAssets, receiver);
    }

    function withdraw(
        address,
        address token_,
        uint256 tokenAmount,
        uint256 baseAssets,
        address,
        address receiver,
        bool
    ) public override returns (uint256) {
        return _withdrawTokens(token_, tokenAmount, baseAssets, receiver);
    }

    function _withdrawTokens(
        address token_,
        uint256 tokenAmount,
        uint256 baseAssets,
        address receiver
    ) internal returns (uint256) {
        require(token_ == address(token), "UnsupportedToken");
        liveAssets -= baseAssets;
        token.safeTransfer(receiver, tokenAmount);
        return tokenAmount;
    }

    function totalAssets() public view override returns (uint256) {
        return liveAssets;
    }

    function totalAssets(uint256 latestNav, uint256 anchor) public view override returns (uint256) {
        return settledAt > anchor ? settledAssets : latestNav;
    }

    // After a settlement both observations carry their own times; otherwise the default snapshot rules apply
    function totalAssetsSnapshot(
        uint256 latestNav,
        uint256 anchor
    ) external view override returns (uint256 navT1, uint256 navT1Time, uint256 navMTM, uint256 navMTMTime) {
        navMTM = liveAssets;
        if (settledAt > anchor) {
            navT1 = settledAssets;
            navT1Time = settledAt;
            navMTMTime = liveAt;
        } else {
            navMTMTime = block.timestamp;
            navT1 = latestNav;
            if (anchor >= navMTMTime) {
                navMTM = navT1;
            }
            navT1Time = navMTM != navT1 ? anchor : navMTMTime;
        }
    }

    function reduceReserve(address token_, uint256 tokenAmount, address receiver) external {
        require(token_ == address(token), "UnsupportedToken");
        liveAssets -= tokenAmount;
        token.safeTransfer(receiver, tokenAmount);
    }

    function supportsToken(address token_) external view returns (bool) {
        return token_ == address(token);
    }

    function getSupportedTokens() external view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = token;
    }

    function convertToAssets(address token_, uint256 tokenAmount, Math.Rounding) public view override returns (uint256) {
        require(token_ == address(token), "UnsupportedToken");
        return tokenAmount;
    }

    function convertToTokens(address token_, uint256 baseAssets, Math.Rounding) public view override returns (uint256) {
        require(token_ == address(token), "UnsupportedToken");
        return baseAssets;
    }

    function ensureRedeemable(address, address, uint256) external view {}
}

/// @notice Full Strata stack (StrataCDO, two conservative-price Tranches, MTMAccounting in MTM projection mode
///         with the reconciliation anchor) over a strategy whose live mark lies between its settled observation
///         and the current block. `MTMAccounting::totalAssets` previews the two-pass checkpoint that
///         `updateAccounting` executes in the same block
contract TwoPassViewLaggedMarkBenchmarkTest is Test {
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    MTMAccounting accounting;
    MockAprPairFeed feed;
    MockERC20 token;
    LaggedMarkStrategy strategy;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function _deploy(bool benchmark) internal {
        vm.warp(1_700_000_000);
        token = new MockERC20("BASE", 18);
        IERC20Metadata asset = IERC20Metadata(address(token));

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
            address(new MTMAccounting(18, benchmark, true, false, false, true, true)),
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

        strategy = LaggedMarkStrategy(address(new ERC1967Proxy(
            address(new LaggedMarkStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                LaggedMarkStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo))
            )
        )));

        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        accounting.setRiskModel(new RiskPremiumPower(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18)));

        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
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

    function _deposit(Tranche t, address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        t.deposit(amount, user);
        vm.stopPrank();
    }

    // Settled NAV observed 10 days after the stored checkpoint, live mark observed on day 20, read on day 30
    function _laggedMark() internal {
        uint256 checkpoint = accounting.indexTimestamp();
        vm.warp(checkpoint + 10 days);
        vm.roll(block.number + 1);
        strategy.publishSettled(2001e18);
        uint256 settledTime = vm.getBlockTimestamp();

        vm.warp(checkpoint + 20 days);
        vm.roll(block.number + 1);
        strategy.setLive(2002e18);
        uint256 markTime = vm.getBlockTimestamp();

        vm.warp(checkpoint + 30 days);
        vm.roll(block.number + 1);
        uint256 nowTime = vm.getBlockTimestamp();

        (, uint256 navT1Time,, uint256 navMTMTime) = strategy.totalAssetsSnapshot(accounting.nav(), accounting.lastReconciliation());
        assertEq(navT1Time, settledTime, "settled observation stamped with its own time");
        assertGt(navT1Time, checkpoint, "after the stored index checkpoint");
        assertEq(navMTMTime, markTime, "live mark stamped with its own time");
        assertGt(navMTMTime, navT1Time, "live mark is newer than the settled observation");
        assertLt(navMTMTime, nowTime, "live mark is older than the block");
    }

    // Previews the two-pass checkpoint, then executes it and reads the stored result in the same block
    function _previewThenExecute()
        internal
        returns (uint256 jrtView, uint256 srtView, uint256 jrtExec, uint256 srtExec)
    {
        (jrtView, srtView,) = accounting.totalAssets();
        (uint256 juniorLive, uint256 seniorLive,,) = accounting.totalAssetsLiveAndSettled();
        assertEq(juniorLive, jrtView, "combined Junior live view agrees");
        assertEq(seniorLive, srtView, "combined Senior live view agrees");
        vm.prank(address(jrt));
        cdo.updateAccounting();
        jrtExec = accounting.jrtNavProjected();
        srtExec = accounting.srtBaseNav();
    }

    function test_TwoPassLaggedMarkMatchesExecutionWithBenchmark() public {
        _deploy(true);
        _laggedMark();
        _assertPreviewMatchesExecution();
    }

    function test_TwoPassLaggedMarkMatchesExecutionWithoutBenchmark() public {
        _deploy(false);
        _laggedMark();
        _assertPreviewMatchesExecution();
    }

    function test_TwoPassLaggedMarkAfterPriorBenchmarkAccrual() public {
        _deploy(true);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(address(jrt));
        cdo.updateAccounting();
        assertGt(accounting.srtPnLBenchmark(), 0, "prior benchmark accrued");
        _laggedMark();
        _assertPreviewMatchesExecution();
    }

    function _assertPreviewMatchesExecution() internal {
        (uint256 jrtView, uint256 srtView, uint256 jrtExec, uint256 srtExec) = _previewThenExecute();
        assertEq(accounting.indexTimestamp(), vm.getBlockTimestamp(), "execution accrues through the current block");
        assertApproxEqAbs(srtView, srtExec, 1, "Senior view matches execution");
        assertApproxEqAbs(jrtView, jrtExec, 1, "Junior view matches execution");
    }
}
