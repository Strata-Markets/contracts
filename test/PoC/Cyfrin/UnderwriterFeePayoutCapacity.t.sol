// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISharesCooldown} from "../../../contracts/tranches/interfaces/cooldown/ISharesCooldown.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StrataCDO} from "../../../contracts/tranches/StrataCDO.sol";
import {IAccounting} from "../../../contracts/tranches/interfaces/IAccounting.sol";
import {IStrategy} from "../../../contracts/tranches/interfaces/IStrategy.sol";
import {MockERC20} from "../../../contracts/test/MockERC20.sol";
import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";
import {MockInsurancePool} from "../../symbiotic/mocks/MockInsurancePool.sol";
import {IInsurancePool} from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import {ITerminalLossAccounting, TerminalAccounting, TerminalDiscrete, TerminalDYS, TerminalMTM} from "./ProtectedFeesTerminalLoss.t.sol";

contract FeePayoutCDO is StrataCDO {
    constructor(MockERC20 token) StrataCDO(token, ISharesCooldown(address(0))) {}
    // Wire real accounting to a controlled strategy without unrelated tranche setup.
    function setup(IAccounting accounting_, IStrategy strategy_, address receiver) external {
        accounting = accounting_;
        strategy = strategy_;
        manualUnderwriterFeeDistribution = true;
        underwriterFeeRewardSafe = receiver;
    }
}

contract FeePayoutStrategy {
    MockERC20 public token;
    uint256 public assets;
    constructor(MockERC20 token_) { token = token_; }
    function setAssets(uint256 value) external { assets = value; }
    function totalAssets() external view returns (uint256) { return assets; }
    function totalAssets(uint256, uint256) external view returns (uint256) { return assets; }
    function totalAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        return (assets, block.timestamp, assets, block.timestamp);
    }
    function convertToTokens(address, uint256 value, Math.Rounding) external pure returns (uint256) { return value / 1e12; }
    function convertToAssets(address, uint256 value, Math.Rounding) external pure returns (uint256) { return value * 1e12; }
    function reduceReserve(address, uint256 amount, address receiver) external {
        assets -= amount * 1e12;
        token.transfer(receiver, amount);
    }
}

contract UnderwriterFeePayoutCapacityTest is Test {
    function _check(uint256 variant, uint256 remainingAssets) internal {
        vm.warp(1_790_000_000);
        MockERC20 token = new MockERC20("USDC", 6);
        AccessControlManager acm = new AccessControlManager(address(this));
        acm.grantRole(keccak256("RESERVE_MANAGER_ROLE"), address(this));
        FeePayoutCDO cdo = FeePayoutCDO(address(new ERC1967Proxy(address(new FeePayoutCDO(token)),
            abi.encodeCall(StrataCDO.initialize, (address(this), address(acm))))));
        address impl;
        if (variant == 0) { impl = address(new TerminalAccounting()); }
        else if (variant == 1) { impl = address(new TerminalDiscrete()); }
        else if (variant == 2) { impl = address(new TerminalDYS()); }
        else { impl = address(new TerminalMTM()); }
        ITerminalLossAccounting accounting = ITerminalLossAccounting(address(new ERC1967Proxy(impl,
            abi.encodeWithSignature("initialize(address,address,address,address)", address(this), address(acm), address(cdo), address(0)))));
        FeePayoutStrategy strategy = new FeePayoutStrategy(token);
        address receiver = address(0xBEEF);
        cdo.setup(IAccounting(address(accounting)), IStrategy(address(strategy)), receiver);
        accounting.seed(1000e18, 1000e18, 0, 0, 0, 0, 0, 1e18);
        accounting.seedFee(100e18);
        MockInsurancePool pool = new MockInsurancePool();
        pool.setCapacity(3000e18);
        strategy.setAssets(2100e18);
        vm.prank(address(cdo));
        accounting.setInsurancePool(IInsurancePool(address(pool)));
        strategy.setAssets(remainingAssets);
        token.mint(address(strategy), remainingAssets / 1e12);
        // The loss has not yet been checkpointed: payUnderwriterFee must settle before sizing.
        cdo.payUnderwriterFee(address(token));
        uint256 paid = Math.min(100e18, remainingAssets) / 1e12 * 1e12;
        assertEq(token.balanceOf(receiver), paid / 1e12);
        assertEq(accounting.nav(), remainingAssets - paid);
        assertEq(strategy.assets(), remainingAssets - paid);
        assertEq(accounting.underwriterFeeNav(), 100e18 - paid, "unpaid fees and rounding dust remain owed");
        assertEq(accounting.nav() + accounting.insuranceAmount(), accounting.jrtBaseNav() +
            accounting.srtBaseNav() + accounting.reserveNav() + accounting.underwriterFeeNav());
        (bool ok, bytes memory result) = address(accounting).staticcall(abi.encodeWithSignature("feeWatermarkNav()"));
        assertTrue(ok);
        assertEq(abi.decode(result, (uint256)), 2100e18 - paid, "payout preserves the existing loss deficit");
        if (remainingAssets == paid || paid == 100e18) {
            vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
            cdo.payUnderwriterFee(address(token));
            assertEq(accounting.underwriterFeeNav(), 100e18 - paid);
        }
    }
    function test_AllVariantsFullPayout() public { for (uint256 i; i < 4; ++i) { _check(i, 2100e18); } }
    function test_AllVariantsPartialPayout() public { for (uint256 i; i < 4; ++i) { _check(i, 50e18); } }
    function test_AllVariantsPartialPayoutRounding() public { for (uint256 i; i < 4; ++i) { _check(i, 50e18 + 123); } }
}
