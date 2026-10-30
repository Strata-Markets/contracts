// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { RiskPremiumPower } from "../../../contracts/tranches/accounting/premium/RiskPremiumPower.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
import { InsuranceVault } from "../../../contracts/tranches/symbiotic/InsuranceVault.sol";
import { IInsuranceVault } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import { IInsuranceMiddleware } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import { MockInsurancePool } from "../../symbiotic/mocks/MockInsurancePool.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";

/// @notice Test strategy with operator-controlled daily or immediate reconciliation.
contract ZeroEpochSettlementStrategy is Strategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    uint256 public liveAssets;
    uint256 public epochDuration = 1 days;

    constructor(IERC20 token_) Strategy(address(token_), address(token_)) {
        token = token_;
    }

    function initialize(address owner_, address acm_, IStrataCDO cdo_) public initializer {
        AccessControlled_init(owner_, acm_);
        cdo = cdo_;
    }

    function setEpochDuration(uint256 duration) external onlyOwner {
        epochDuration = duration;
    }

    function setLive(uint256 nav_) external {
        liveAssets = nav_;
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
        return epochDuration == 0 || block.timestamp - anchor >= epochDuration ? liveAssets : latestNav;
    }

    function totalAssetsSnapshot(uint256 latestNav, uint256 anchor)
        external view override returns (uint256 navT1, uint256 navT1Time, uint256 navMTM, uint256 navMTMTime)
    {
        navMTM = liveAssets;
        navMTMTime = block.timestamp;
        if (epochDuration == 0 || block.timestamp - anchor >= epochDuration) {
            return (navMTM, navMTMTime, navMTM, navMTMTime);
        }
        // Preserve a consistent snapshot for same-timestamp flows in the open epoch.
        if (anchor == block.timestamp) {
            return (latestNav, anchor, latestNav, anchor);
        }
        return (latestNav, anchor, navMTM, navMTMTime);
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

/// @notice Full CDO, tranches and insurance vault; pool capacity and strategy NAV are mocked.
contract ZeroEpochDepegSettlementTest is Test {
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
    ZeroEpochSettlementStrategy strategy;
    MockInsurancePool pool;
    InsuranceVault vault;
    MockERC20 coverage;


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
        // No benchmark; isolate valuation-loss coverage.
        feed.updateRoundData(0, 100_000_000_000, uint64(block.timestamp));

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

        strategy = ZeroEpochSettlementStrategy(address(new ERC1967Proxy(
            address(new ZeroEpochSettlementStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(
                ZeroEpochSettlementStrategy.initialize.selector,
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

    function setUp() public {
        _deploy(false);
        // Proxy storage must be configured explicitly.
        strategy.setEpochDuration(1 days);
        pool = new MockInsurancePool();
        pool.setCapacity(1_000_000e18);
        coverage = new MockERC20("USD", 18);
        vault = InsuranceVault(address(new ERC1967Proxy(
            address(new InsuranceVault()),
            abi.encodeCall(InsuranceVault.initialize, (address(this), address(acm), IStrataCDO(address(cdo)), address(coverage)))
        )));
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(vault)));
        cdo.setValuationKeeper(address(this));
        cdo.setValuationPrice(0.4e18);
        assertEq(accounting.insuranceAmount(), 501e18);
    }

    function _checkpoint() internal {
        vm.prank(address(srt));
        cdo.updateAccounting();
    }

    function test_zeroEpochReconcilesFundsAndRedeemsInSameBlock() public {
        vm.warp(block.timestamp + 12 hours);
        strategy.setLive(1900e18);
        _checkpoint();
        assertEq(accounting.nav(), 2000e18, "24h epoch retains settled NAV");
        assertEq(accounting.insuranceAmount(), 501e18, "live loss not covered yet");
        (, uint256 seniorLive,) = accounting.totalAssets();
        assertEq(seniorLive, 2400e18);

        cdo.setActionStates(address(srt), false, false);
        strategy.setEpochDuration(0);
        // No warp: the new snapshot must reconcile immediately, even after a same-block checkpoint.
        (uint256 settled, uint256 settledTime, uint256 live, uint256 liveTime) =
            strategy.totalAssetsSnapshot(accounting.nav(), accounting.lastReconciliation());
        assertEq(settled, 1900e18);
        assertEq(live, settled);
        assertEq(settledTime, block.timestamp);
        assertEq(liveTime, settledTime);
        _checkpoint();
        assertEq(accounting.nav(), 1900e18);
        assertEq(accounting.insuranceAmount(), 601e18);
        assertEq(pool.capacity(), 1_000_000e18 - 601e18);
        (, seniorLive,) = accounting.totalAssets();
        assertEq(seniorLive, 2500e18);
        _checkpoint();
        assertEq(accounting.insuranceAmount(), 601e18, "same state does not reslash");

        uint256 funding = 601e18 * 4 / 10;
        coverage.mint(address(this), funding);
        coverage.approve(address(cdo), funding);
        cdo.fundInsuranceClaim(address(coverage), funding);
        assertEq(vault.fundedCoverage(), funding);
        cdo.setActionStates(address(srt), false, true);
        uint256 shares = srt.balanceOf(bob) / 10;
        vm.prank(bob);
        srt.redeem(shares, bob, bob);
        assertApproxEqAbs(token.balanceOf(bob), 189.9e18, 10);
        assertApproxEqAbs(coverage.balanceOf(bob), 24.04e18, 10);
        assertApproxEqAbs(token.balanceOf(bob) * 4 / 10 + coverage.balanceOf(bob), 100e18, 10,
            "10% Senior receives its protected USD value");
        (, seniorLive,) = accounting.totalAssets();
        assertApproxEqAbs(seniorLive, 2250e18, 10);
    }

    function test_dailyEpochReconcilesAtExactBoundary() public {
        uint256 anchor = accounting.lastReconciliation();
        strategy.setLive(1900e18);
        vm.warp(anchor + 1 days - 1);
        _checkpoint();
        assertEq(accounting.nav(), 2000e18);
        vm.warp(anchor + 1 days);
        _checkpoint();
        assertEq(accounting.nav(), 1900e18);
        assertEq(accounting.insuranceAmount(), 601e18);
    }

    function test_zeroEpochCoversNewLossInCheckpointBlock() public {
        strategy.setEpochDuration(0);
        strategy.setLive(1900e18);
        _checkpoint();
        assertEq(accounting.insuranceAmount(), 601e18);
        strategy.setLive(1800e18);
        _checkpoint();
        assertEq(accounting.nav(), 1800e18);
        assertEq(accounting.insuranceAmount(), 701e18);
    }
}
