// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";
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
import { IInsuranceMiddleware } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import { IInsuranceVault } from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import { MockERC20 } from "../../../contracts/test/MockERC20.sol";
import { MockAprPairFeed } from "../../../contracts/test/MockAprPairFeed.sol";
import { MockInsurancePool } from "../../symbiotic/mocks/MockInsurancePool.sol";

import {RiskPremiumStatic} from "../../../contracts/tranches/accounting/premium/RiskPremiumStatic.sol";
import {IRiskPremiumModel} from "../../../contracts/tranches/accounting/premium/IRiskPremiumModel.sol";

interface IAccountingViews {
    function nav() external view returns (uint256);
    function jrtBaseNav() external view returns (uint256);
    function srtBaseNav() external view returns (uint256);
    function reserveNav() external view returns (uint256);
    function underwriterFeeNav() external view returns (uint256);
    function insuranceAmount() external view returns (uint256);
    function feeJrtRetentionBps() external view returns (uint256);
    function feeSrtRetentionBps() external view returns (uint256);
    function reserveBps() external view returns (uint256);
    function setRiskModel(IRiskPremiumModel) external;
    function setFeeRetentionBps(uint256, uint256) external;
    function setReserveBps(uint256) external;
}

/// @dev Minimal 1:1 strategy (base asset == strategy token) whose NAV is set directly, so the PoC can drive
///      exact strategy gains and losses. Settled and live NAV are always equal
contract SettableNavStrategy is IStrategy {
    using SafeERC20 for IERC20;
    IERC20 public immutable token;
    address public cdo;
    uint256 public value;

    constructor(IERC20 token_, address cdo_) { token = token_; cdo = cdo_; }

    function setValue(uint256 v) external { value = v; }

    function deposit(address, address, uint256, uint256, address, bytes memory) external pure returns (uint256) { revert("NI"); }
    function withdraw(address, address, uint256, uint256, address, address, bool, bytes memory) external pure returns (uint256) { revert("NI"); }
    function deposit(address, address token_, uint256 tokenAmount, uint256 baseAssets, address owner) external returns (uint256) {
        require(token_ == address(token), "UnsupportedToken");
        token.safeTransferFrom(owner, address(this), tokenAmount);
        value += baseAssets;
        return baseAssets;
    }
    function withdraw(address, address token_, uint256 tokenAmount, uint256 baseAssets, address, address receiver) external returns (uint256) {
        return _w(token_, tokenAmount, baseAssets, receiver);
    }
    function withdraw(address, address token_, uint256 tokenAmount, uint256 baseAssets, address, address receiver, bool) external returns (uint256) {
        return _w(token_, tokenAmount, baseAssets, receiver);
    }
    function _w(address token_, uint256 tokenAmount, uint256 baseAssets, address receiver) internal returns (uint256) {
        require(token_ == address(token), "UnsupportedToken");
        value -= baseAssets;
        MockERC20(address(token)).mint(address(this), tokenAmount); // keep the mock solvent after synthetic gains
        token.safeTransfer(receiver, tokenAmount);
        return tokenAmount;
    }
    function totalAssets() external view returns (uint256) { return value; }
    function totalAssets(uint256, uint256) public view returns (uint256) { return value; }
    function totalAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        return (value, block.timestamp, value, block.timestamp);
    }
    function reduceReserve(address token_, uint256 tokenAmount, address receiver) external {
        require(token_ == address(token), "UnsupportedToken");
        value -= tokenAmount;
        MockERC20(address(token)).mint(address(this), tokenAmount);
        token.safeTransfer(receiver, tokenAmount);
    }
    function supportsToken(address token_) external view returns (bool) { return token_ == address(token); }
    function getSupportedTokens() external view returns (IERC20[] memory tokens) { tokens = new IERC20[](1); tokens[0] = token; }
    function convertToAssets(address, uint256 a, Math.Rounding) external pure returns (uint256) { return a; }
    function convertToTokens(address, uint256 a, Math.Rounding) external pure returns (uint256) { return a; }
    function ensureRedeemable(address, address, uint256) external view {}
    function shareToken() external view returns (address) { return address(token); }
    function depositFeeBps(address) external pure returns (uint256) { return 0; }
    function depositFeeBps(address, address, uint256) external pure returns (uint256) { return 0; }
    function getCDOAddress() external view returns (address) { return cdo; }
    function maxDeposit(address, address, uint256) external pure returns (uint256) { return type(uint256).max; }
    function maxWithdraw(address, address, uint256) external pure returns (uint256) { return type(uint256).max; }
    function getRate() external pure returns (uint256) { return 1e18; }
    function configure() external {}
}

/// @notice Auditor regression: empty-market updates preserve insurance backing and allow recapitalization.
contract EmptyMarketOrphanedClaimTest is Test {
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");

    AccessControlManager acm;
    StrataCDO cdo;
    Tranche jrt;
    Tranche srt;
    IAccountingViews acc;
    MockERC20 usdc;
    SettableNavStrategy strat;
    MockAprPairFeed feed;
    MockInsurancePool pool;

    address alice = makeAddr("alice"); // Junior
    address bob = makeAddr("bob");     // Senior

    function test_PoC_EmptyMarketOrphanedClaim_DYS() public { _run(false, true, 0.01e18); }
    function test_PoC_EmptyMarketOrphanedClaim_MTM() public { _run(true, true, 0.01e18); }

    /// Control: without the owner's retention reset, the burn moves nothing to reserve and the market never empties
    function test_PoC_EmptyMarketOrphanedClaim_NoRetentionResetControl_DYS() public { _run(false, false, 0.01e18); }
    function test_PoC_EmptyMarketOrphanedClaim_NoRetentionResetControl_MTM() public { _run(true, false, 0.01e18); }

    /// A zero shortfall threshold permits recapitalization; subsequent accounting and redemptions must work.
    function test_PoC_EmptyMarketOrphanedClaim_RecapPreservesNavSplit_DYS() public { _recap(false); }
    function test_PoC_EmptyMarketOrphanedClaim_RecapPreservesNavSplit_MTM() public { _recap(true); }

    function _run(bool mtm, bool resetRetention, uint256 shortfallPrice) internal {
        _deploy(mtm);
        if (shortfallPrice != cdo.jrtShortfallPausePrice()) cdo.setJrtShortfallPausePrice(shortfallPrice);

        // 1. Deposits J = 1000000999999, S = 1000000499999 (six-decimal atoms)
        _deposit(jrt, alice, 1000000999999);
        _deposit(srt, bob, 1000000499999);
        assertEq(jrt.totalSupply(), 1000000999999e12);
        assertEq(srt.totalSupply(), 1000000499999e12);

        // 2. Uninsured loss to NAV = 2100000 (pool capacity is 0)
        strat.setValue(2100000);
        _sync();
        assertEq(acc.jrtBaseNav(), 1e6, "J floored at ONE_ASSET");
        assertEq(acc.srtBaseNav(), 1100000, "S after loss");
        assertEq(acc.insuranceAmount(), 0, "no claim without capacity");

        // 3. Gain of 3818182
        strat.setValue(2100000 + 3818182);
        _sync();
        assertEq(acc.jrtBaseNav(), 3818182, "J after gain");
        assertEq(acc.srtBaseNav(), 2000000, "S after gain");
        assertEq(acc.underwriterFeeNav(), 100000, "underwriter fee after gain");

        // 4. Senior redeems 1e24 shares (exactly its 2000000 NAV), leaving shares above MIN_SHARES worth zero
        vm.prank(bob);
        srt.redeem(1e24, bob, bob);
        assertEq(acc.srtBaseNav(), 0, "S NAV zero");
        assertEq(srt.totalSupply(), 0.499999e18, "Senior shares left");

        // 5. Insurance enabled; second loss to NAV = 1050000 opens a claim with S = 0
        pool.setCapacity(1_000_000e6);
        strat.setValue(1050000);
        _sync();
        assertEq(acc.jrtBaseNav(), 1e6, "J at floor");
        assertEq(acc.srtBaseNav(), 0, "S zero");
        assertEq(acc.underwriterFeeNav(), 100000, "fee intact");
        assertEq(acc.insuranceAmount(), 50000, "claim open with S = 0");
        assertEq(_gap(), 0, "identity holds");

        // Junior depletion auto-set Junior fee retention to 100%
        assertEq(acc.feeJrtRetentionBps(), 1e18, "depletion forced 100% retention");
        if (!resetRetention) {
            // Control: with 100% retention the burn keeps the NAV inside Junior
            vm.prank(alice);
            jrt.burnSharesAsFee(1e24, alice);
            assertEq(acc.jrtBaseNav(), 1e6, "retained: Junior NAV unchanged");
            assertEq(acc.reserveNav(), 0, "nothing moved to reserve");
            _sync();
            assertEq(_gap(), 0, "identity holds without the retention reset");
            return;
        }

        // 6. Owner sets Junior fee retention to 0
        acc.setFeeRetentionBps(0, acc.feeSrtRetentionBps());

        // 7. Junior burns 1e24 shares as fee: the whole Junior NAV (floor included) moves to reserve
        vm.prank(alice);
        uint256 burnt = jrt.burnSharesAsFee(1e24, alice);
        assertEq(burnt, 1e6, "burn moved one asset");
        assertEq(acc.jrtBaseNav(), 0, "J zero");
        assertEq(jrt.totalSupply(), 0.999999e18, "Junior shares left");
        assertEq(acc.reserveNav(), 1e6, "reserve");
        assertEq(acc.insuranceAmount(), 50000, "claim");
        assertEq(_gap(), 0, "still balanced before the next update");

        // 8. The empty-market branch preserves reserve and the outstanding claim.
        _sync();
        console.log("nav     ", acc.nav());
        console.log("reserve ", acc.reserveNav());
        console.log("uwFee   ", acc.underwriterFeeNav());
        console.log("claim   ", acc.insuranceAmount());
        console.logInt(_gap());
        assertEq(acc.insuranceAmount(), 50000, "claim retained");
        assertEq(acc.reserveNav(), 1000000, "reserve preserves insurance backing");
        // J + S + reserve + fee == nav + claim (1100000).
        assertEq(_gap(), 0, "identity preserved");
    }

    function _recap(bool mtm) internal {
        _run(mtm, true, 0);
        address dave = makeAddr("dave");
        _deposit(jrt, dave, 1000e6);
        strat.setValue(strat.value() + 1e6);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(address(jrt));
        (bool ok,) = address(cdo).call(abi.encodeWithSignature("updateAccounting()"));
        // Accounting and redemptions remain available after recapitalization.
        assertTrue(ok, "accounting update succeeds after recap and gain");
        assertEq(_gap(), 0, "identity after recap");
        uint256 daveShares = jrt.balanceOf(dave);
        vm.prank(dave);
        jrt.redeem(daveShares / 2, dave, dave);
    }

    function _deploy(bool mtm) internal {
        vm.warp(1_790_000_000);
        usdc = new MockERC20("USDC", 6);
        acm = new AccessControlManager(address(this));
        cdo = StrataCDO(address(new ERC1967Proxy(
            address(new StrataCDO(IERC20Metadata(address(usdc)), ISharesCooldown(address(0)))),
            abi.encodeWithSelector(StrataCDO.initialize.selector, address(this), address(acm))
        )));
        jrt = _tranche("JRT");
        srt = _tranche("SRT");
        feed = new MockAprPairFeed();
        feed.updateRoundData(0, 0, uint64(block.timestamp)); // zero APR inputs
        address impl = mtm
            ? address(new MTMAccounting(6, false, false, false, false, false, false))
            : address(new DYSAccounting(6, false, false, false, false, false));
        acc = IAccountingViews(address(new ERC1967Proxy(impl, abi.encodeWithSelector(
            DYSAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(cdo)), IAprPairFeed(address(feed))))));
        acm.grantRole(PAUSER_ROLE, address(this));
        acm.grantRole(UPDATER_FEED_ROLE, address(this));
        acm.grantRole(UPDATER_STRAT_CONFIG_ROLE, address(this));
        acm.grantRole(RESERVE_MANAGER_ROLE, address(this));
        strat = new SettableNavStrategy(IERC20(address(usdc)), address(cdo));
        cdo.configure(IAccounting(address(acc)), IStrategy(address(strat)), ITranche(address(jrt)), ITranche(address(srt)));
        cdo.setActionStates(address(jrt), true, true);
        cdo.setActionStates(address(srt), true, true);
        acc.setRiskModel(new RiskPremiumStatic(UD60x18.wrap(0.5e18))); // flat 50% risk premium
        if (acc.reserveBps() != 0) acc.setReserveBps(0);                                    // zero reserve fee
        // Insurance initially unavailable (zero capacity), 20% underwriter fee
        pool = new MockInsurancePool();
        pool.setCapacity(0);
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(0)));
        vm.prank(address(pool));
        cdo.setUnderwriterFeeBps(0.2e18);
    }

    function _tranche(string memory name) internal returns (Tranche) {
        return Tranche(address(new ERC1967Proxy(address(new Tranche(false)), abi.encodeWithSelector(
            Tranche.initialize.selector, address(this), address(acm), name, name, IERC20(address(usdc)), IStrataCDO(address(cdo))))));
    }

    function _deposit(Tranche t, address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(t), amount);
        t.deposit(amount, user);
        vm.stopPrank();
    }

    function _sync() internal {
        vm.warp(block.timestamp + 1 hours);
        vm.prank(address(jrt));
        cdo.updateAccounting();
    }

    // (J + S + reserve + fee) - (nav + claim)
    function _gap() internal view returns (int256) {
        return int256(acc.jrtBaseNav() + acc.srtBaseNav() + acc.reserveNav() + acc.underwriterFeeNav())
            - int256(acc.nav() + acc.insuranceAmount());
    }
}
