// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
import { IRiskPremiumModel } from "../../../contracts/tranches/accounting/premium/IRiskPremiumModel.sol";
import { RiskPremiumPower } from "../../../contracts/tranches/accounting/premium/RiskPremiumPower.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { StrataCDO } from "../../../contracts/tranches/StrataCDO.sol";
import { Tranche } from "../../../contracts/tranches/Tranche.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IAccounting } from "../../../contracts/tranches/interfaces/IAccounting.sol";
import { IStrategy } from "../../../contracts/tranches/interfaces/IStrategy.sol";
import { ITranche } from "../../../contracts/tranches/interfaces/ITranche.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { ISharesCooldown } from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import { InsuranceMiddleware } from "../../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { InsuranceVault } from "../../../contracts/tranches/symbiotic/InsuranceVault.sol";
import { IInsuranceMiddleware } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import { IInsuranceVault } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import { IInsurancePool } from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import { IStrataAccounting } from "../../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockOracleAdapter } from "../../../contracts/test/MockOracleAdapter.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockMTMStrategy } from "../../../contracts/test/MockMTMStrategy.sol";
import { MockAppAdapter } from "../../symbiotic/NetworkMiddleware.t.sol";
import { MockInsurancePool } from "../../symbiotic/mocks/MockInsurancePool.sol";

interface IResyncAccounting {
    function setValuationPrice(uint128 price) external returns (bool);
    function setInsurancePool(IInsurancePool pool) external;
    function setFloorRate(uint256 rate) external;
    function setRiskModel(IRiskPremiumModel model) external;
    function updateBalanceFlow(uint256, uint256, uint256, uint256) external returns (uint256);
    function updateAccounting() external;
    function insuranceAmount() external view returns (uint256);
    function srtInsuranceFundNav() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
    function totalAssetsSettled() external view returns (uint256, uint256, uint256);
}

/// @notice Part (a): real MTMAccounting + real InsuranceMiddleware, the test contract plays the CDO and the strategy
///         MockAppAdapter stands in for the Symbiotic app adapter; vault asset priced at $1 so vault units == USD
contract DepegMTMOscillationReslashTest is Test {
    IResyncAccounting a;
    InsuranceMiddleware middleware;
    MockAppAdapter adapter;
    AccessControlManager acm;
    uint256 tvl; // settled strategy NAV
    uint256 mtm; // live mark (0 = same as tvl)

    // CDO / strategy / APR feed surface used by the accounting
    function totalStrategyAssets() external view returns (uint256) { return tvl; }
    function totalStrategyAssets(uint256, uint256) external view returns (uint256) { return tvl; }
    function totalStrategyAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        if (mtm == 0 || mtm == tvl) return (tvl, block.timestamp, tvl, block.timestamp);
        return (tvl, block.timestamp - 1, mtm, block.timestamp);
    }
    function getRate() external pure returns (uint256) { return 1e18; }
    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound({ aprTarget: 0, aprBase: 100_000_000_000, updatedAt: uint64(block.timestamp), answeredInRound: 1 });
    }

    function setUp() public {
        vm.mockCall(address(this), abi.encodeWithSignature("insuranceVault()"), abi.encode(address(0)));
        vm.warp(1_750_000_000);
        acm = new AccessControlManager(address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        MockERC20 base = new MockERC20("BASE", 18);
        MockERC20 coll = new MockERC20("COLL", 18);
        adapter = new MockAppAdapter(address(coll));
        adapter.setSlashable(1_000_000e18);
        MockOracleAdapter oracle = new MockOracleAdapter();
        middleware = InsuranceMiddleware(address(new ERC1967Proxy(
            address(new InsuranceMiddleware(address(adapter))),
            abi.encodeCall(InsuranceMiddleware.initialize, (address(this), address(acm), address(oracle)))
        )));
        // benchmark off, navAtReconciliation on (required by MTM projection), rates off,
        // juniorCoversPaidSrtProjection on, conservative off, MTM projection on
        a = IResyncAccounting(address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, true, false, true, false, true)),
            abi.encodeWithSignature("initialize(address,address,address,address)",
                address(this), address(acm), address(this), address(this))
        )));
        middleware.setMarket(address(this), IStrataAccounting(address(a)), address(base), 0, true);
        a.setInsurancePool(IInsurancePool(address(middleware)));
        tvl = 2000e18;
        a.updateBalanceFlow(1000e18, 0, 1000e18, 0); // Junior 1,000 / Senior 1,000
    }

    function _slashed() internal view returns (uint256 s) { (,, s,,,) = middleware.markets(address(this)); }

    function test_MTMMarkOscillationReusesUnfundedClaim() public {
        a.setFloorRate(0.005e18); // Senior shares unrealized losses (floor 0.5%/day)
        a.setValuationPrice(0.4e18); // de-peg push: claim 501 base slashed as 200.4 USD
        uint256 claim0 = a.insuranceAmount();
        uint256 slashed0 = _slashed();
        assertEq(claim0, 501e18);
        assertEq(slashed0, 200.4e18);

        // 5 ordinary updates observe a 2% live mark dip and its recovery before the slash proceeds are funded
        uint256 settled = tvl;
        for (uint256 i; i < 5; ++i) {
            vm.warp(block.timestamp + 1 hours);
            mtm = settled - 40e18; // live mark dips: resync releases credit and claim
            a.updateAccounting();
            vm.warp(block.timestamp + 1 hours);
            mtm = settled; // live mark recovers: the claim reuses the released pending collateral
            a.updateAccounting();
        }

        console.log("claim before / after (base)  ", claim0, a.insuranceAmount());
        console.log("slashed before / after (USD) ", slashed0, _slashed());
        // The claim returns to 501 base without slashing beyond the initial 200.4 USD.
        assertEq(a.insuranceAmount(), claim0, "claim back at its starting value");
        assertEq(_slashed(), slashed0, "released pending collateral is reused");
    }
}

/// @notice Part (b): full stack, StrataCDO + conservative-price Tranches + real InsuranceVault (USDC mock coverage token)
///         MockInsurancePool stands in for the Symbiotic middleware (synchronous slash); zero fees
abstract contract ConservativeExitFixture is Test {
    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    IResyncAccounting accounting;
    MockAprPairFeed feed;
    MockERC20 token;
    MockERC20 usdc;
    MockMTMStrategy strategy;
    MockInsurancePool pool;
    InsuranceVault vault;

    address alice = makeAddr("alice"); // Junior
    address bob = makeAddr("bob"); // Senior, exits
    address carol = makeAddr("carol"); // Senior, stays
    address poker = makeAddr("poker");

    function _deployAccounting() internal virtual returns (address);
    function _epochDuration() internal pure virtual returns (uint256);
    /// @dev Opens a Senior projection while the strategy's settled NAV is unchanged
    function _openProjection() internal virtual;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockERC20("BASE", 18);
        usdc = new MockERC20("USDC", 18);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(IERC20Metadata(address(token)), ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche("JRT");
        srt = _tranche("SRT");
        feed = new MockAprPairFeed();
        feed.updateRoundData(80_000_000_000, 100_000_000_000, uint64(block.timestamp)); // target 8%, base 10%
        accounting = IResyncAccounting(_deployAccounting());
        strategy = MockMTMStrategy(address(new ERC1967Proxy(
            address(new MockMTMStrategy(IERC20(address(token)))),
            abi.encodeWithSelector(MockMTMStrategy.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), address(0), address(0))
        )));
        strategy.setEpochDuration(_epochDuration());
        acm.grantRole(keccak256("PAUSER_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_FEED_ROLE"), address(this));
        acm.grantRole(keccak256("UPDATER_STRAT_CONFIG_ROLE"), address(this));
        acm.grantRole(keccak256("RESERVE_MANAGER_ROLE"), address(this));
        cdo.configure(IAccounting(address(accounting)), IStrategy(address(strategy)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        accounting.setRiskModel(new RiskPremiumPower(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18)));
        cdo.setValuationKeeper(address(this));

        _deposit(jrt, alice, 100e18); // Junior 100
        _deposit(srt, bob, 500e18); // Senior 1,000 (bob 500 + carol 500)
        _deposit(srt, carol, 500e18);

        pool = new MockInsurancePool();
        pool.setCapacity(1_000_000e18);
        vault = InsuranceVault(address(new ERC1967Proxy(address(new InsuranceVault()),
            abi.encodeCall(InsuranceVault.initialize, (address(this), address(acm), IStrataCDO(address(cdo)), address(usdc))))));
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(vault)));
    }

    function _tranche(string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(
            address(new Tranche(true)), // conservative redemption price
            abi.encodeWithSelector(Tranche.initialize.selector,
                address(this), address(acm), name, name, IERC20(address(token)), IStrataCDO(address(cdo)))
        )));
    }

    function _deposit(Tranche t, address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(t), amount);
        t.deposit(amount, user);
        vm.stopPrank();
    }

    function _poke() internal {
        vm.prank(poker);
        jrt.burnSharesAsFee(0, poker);
    }

    /// @dev Pushes the price, funds the whole claim in USDC (18-dec USDC = $) and lets bob redeem all his shares
    function _pushFundAndExit(uint128 price) internal returns (uint256 claim, uint256 seniorView, uint256 bobUsdc, uint256 bobUsd) {
        cdo.setValuationPrice(price);
        claim = accounting.insuranceAmount();
        uint256 amount = claim * price / 1e18 + 1;
        usdc.mint(address(this), amount);
        usdc.approve(address(cdo), amount);
        cdo.fundInsuranceClaim(address(usdc), amount);
        (, seniorView,) = accounting.totalAssetsSettled();

        uint256 shares = srt.balanceOf(bob);
        vm.prank(bob);
        srt.redeem(shares, bob, bob);
        bobUsdc = usdc.balanceOf(bob);
        bobUsd = token.balanceOf(bob) * price / 1e18 + bobUsdc;
        console.log("claim after push (base)    ", claim);
        console.log("conservative Senior view   ", seniorView);
        console.log("bob base / USDC / total USD", token.balanceOf(bob), bobUsdc, bobUsd);
    }

    /// Senior 1,000 (bob 500 + carol 500), Junior 100, Senior projection capped at Junior headroom 99, push to 0.5
    /// bob holds half the Senior and should get his settled $500 (1,000 tokens at 0.5)
    function test_PoC_ConservativeExitPaysProjectionSizedCredit() public {
        _openProjection();
        uint256 projection = accounting.srtBaseNav() - 1000e18;
        assertApproxEqAbs(projection, 99e18, 1e15, "projection capped at Junior headroom 99");
        (uint256 claim, uint256 seniorView, uint256 bobUsdc, uint256 bobUsd) = _pushFundAndExit(0.5e18);
        // push covers the projection: claim 1,099 instead of the settled 901
        assertApproxEqAbs(claim, 1099e18, 1e15, "claim 1,099");
        // conservative view removes the projection but keeps the full credit: 2,099 instead of 2,000
        assertApproxEqAbs(seniorView, 2099e18, 1e15, "conservative Senior view 2,099");
        // expected $500, actual $524.75 (500 base from the strategy + $274.75 USDC from the vault)
        assertApproxEqAbs(bobUsdc, 274.75e18, 1e15, "vault paid $274.75");
        assertApproxEqAbs(bobUsd, 524.75e18, 1e15, "bob paid $524.75 instead of $500");
    }

    /// Control: the identical exit without an open projection pays exactly the settled $500
    function test_PoC_ConservativeExitNoProjectionControl() public {
        (uint256 claim,,, uint256 bobUsd) = _pushFundAndExit(0.5e18);
        assertApproxEqAbs(claim, 901e18, 1e15, "settled claim 901");
        assertApproxEqAbs(bobUsd, 500e18, 1e12, "bob paid $500");
    }
}

contract DepegConservativeExitDYSTest is ConservativeExitFixture {
    function _deployAccounting() internal override returns (address) {
        // benchmark off, navAtReconciliation off, rates off, juniorCoversPaidSrtProjection on, conservative price on
        return address(new ERC1967Proxy(
            address(new DYSAccounting(18, false, false, false, true, true)),
            abi.encodeWithSelector(DYSAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed)))
        ));
    }
    function _epochDuration() internal pure override returns (uint256) { return 3650 days; }
    function _openProjection() internal override {
        vm.warp(block.timestamp + 730 days); // 8% APR on 1,000 for 2y = 160, capped at Junior headroom 99
        _poke();
    }
}

contract DepegConservativeExitMTMTest is ConservativeExitFixture {
    function _deployAccounting() internal override returns (address) {
        // benchmark off, navAtReconciliation on, rates off, juniorCoversPaidSrtProjection on, conservative price on,
        // MTM projection on
        return address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, true, false, true, true, true)),
            abi.encodeWithSelector(MTMAccounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed)))
        ));
    }
    function _epochDuration() internal pure override returns (uint256) { return 1 days; }
    function _openProjection() internal override {
        vm.warp(block.timestamp + 1 hours);
        strategy.setTotalAssets(strategy.totalAssets() + 500e18); // unrealized MTM gain, Senior share capped at 99
        _poke();
    }
}
