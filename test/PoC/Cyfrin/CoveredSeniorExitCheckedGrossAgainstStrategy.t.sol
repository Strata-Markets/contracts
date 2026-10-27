// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IsolatedVaultDeploy} from "../../isolated/IsolatedVaultDeploy.t.sol";
import {MockInsurancePool} from "../../symbiotic/mocks/MockInsurancePool.sol";
import {MockERC20} from "../../../contracts/test/MockERC20.sol";
import {InsuranceVault} from "../../../contracts/tranches/symbiotic/InsuranceVault.sol";
import {IInsuranceVault} from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceVault.sol";
import {IInsuranceMiddleware} from "../../../contracts/tranches/symbiotic/interfaces/IInsuranceMiddleware.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IErrors} from "../../../contracts/tranches/interfaces/IErrors.sol";

/// @notice Regression adapted from Cyfrin f-109: strategy limits apply only to the uninsured exit leg.
/// @dev Real IsolatedStrategy, accounting and insurance vault; external coverage capacity is mocked.
contract CoveredSeniorExitCheckedGrossAgainstStrategyTest is IsolatedVaultDeploy {
    bytes32 constant RESERVE_MANAGER = keccak256("RESERVE_MANAGER_ROLE");

    MockInsurancePool internal pool;
    InsuranceVault internal insuranceVault;
    MockERC20 internal usdc;

    address internal alice = makeAddr("aliceJunior");
    address internal bob = makeAddr("bobSenior");
    address internal carol = makeAddr("carolSenior");
    address internal keeper = makeAddr("keeper");
    address internal multisig = makeAddr("multisig");

    uint256 internal claim;

    function setUp() public override {
        super.setUp();
        _deployIsolatedStack();

        usdc = new MockERC20("USDC", 6);
        pool = new MockInsurancePool();
        pool.setCapacity(type(uint128).max);

        vm.startPrank(owner);
        insuranceVault = InsuranceVault(address(new ERC1967Proxy(
            address(new InsuranceVault()),
            abi.encodeCall(InsuranceVault.initialize, (owner, address(acm), IStrataCDO(address(cdo)), address(usdc)))
        )));
        cdo.setInsuranceConfig(IInsuranceMiddleware(address(pool)), IInsuranceVault(address(insuranceVault)));
        acm.grantRole(RESERVE_MANAGER, multisig);
        vm.stopPrank();

        _deposit(address(jrtVault), alice, 100_000e18);
        _deposit(address(srtVault), bob, 450_000e18);
        _deposit(address(srtVault), carol, 450_000e18);

        // Exogenous loss: both sub-strategies lose 70% of their assets (1,000,000 -> 300,000)
        _scaleSubStrategy(address(juniorStrat), 30);
        _scaleSubStrategy(address(seniorStrat), 30);

        // Any poke books Junior down and the Senior-bound remainder as the claim, then the multisig funds it
        vm.prank(keeper);
        jrtVault.burnSharesAsFee(0, keeper);
        claim = accounting.insuranceAmount();
        uint256 usdcAmount = claim / 1e12 + 1;
        usdc.mint(multisig, usdcAmount);
        vm.startPrank(multisig);
        IERC20(address(usdc)).approve(address(cdo), usdcAmount);
        cdo.fundInsuranceClaim(address(usdc), usdcAmount);
        vm.stopPrank();
    }

    function _deposit(address vault, address user, uint256 amount) internal {
        baseAsset.mint(user, amount);
        vm.startPrank(user);
        IERC20(address(baseAsset)).approve(vault, amount);
        IDepositToken(vault).deposit(address(baseAsset), amount, user);
        vm.stopPrank();
    }

    function _scaleSubStrategy(address strat, uint256 pct) internal {
        uint256 assets = IMockSingle(strat).totalAssetsValue() * pct / 100;
        IMockSingle(strat).setTotalAssets(assets);
        deal(address(baseAsset), strat, assets);
    }

    function _strategyCap(uint256 amount) internal view returns (uint256) {
        return strategy.maxWithdraw(address(srtVault), address(baseAsset), amount);
    }

    function _redeemBob() internal returns (uint256 assets, uint256 slice) {
        uint256 shares = srtVault.balanceOf(bob);
        assets = srtVault.previewRedeem(shares);
        slice = Math.mulDiv(assets, accounting.insuranceAmount(), accounting.srtBaseNav());
        vm.prank(bob);
        srtVault.redeem(address(baseAsset), shares, bob, bob);
        assertEq(srtVault.balanceOf(bob), 0);
        assertEq(baseAsset.balanceOf(bob), assets - slice, "strategy pays only its leg");
        assertEq(usdc.balanceOf(bob), slice / 1e12, "vault pays the covered leg");
    }

    function test_coveredSeniorFullExitFitsNetStrategyLimit() public {
        assertApproxEqAbs(claim, 600_000e18, 1e18);
        assertEq(strategy.totalAssets(), 300_000e18);
        uint256 assets = srtVault.previewRedeem(srtVault.balanceOf(bob));
        assertGt(assets, _strategyCap(assets), "gross exit exceeds available strategy assets");
        assertLt(srtVault.maxWithdraw(address(baseAsset), bob), assets, "token maximum is deliberately conservative");
        _redeemBob();
    }

    function test_lastSeniorExitsInOneTransactionLeavingProtectedShares() public {
        _redeemBob();
        // Retain the existing tranche minimum supply; the strategy cap must not require chunked exits.
        uint256 shares = srtVault.balanceOf(carol) - 0.1e18;
        uint256 assets = srtVault.previewRedeem(shares);
        uint256 slice = Math.mulDiv(assets, accounting.insuranceAmount(), accounting.srtBaseNav());
        assertGt(assets, strategy.totalAssets());
        assertLe(assets - slice, strategy.totalAssets());
        vm.prank(carol);
        srtVault.redeem(address(baseAsset), shares, carol, carol);
        assertEq(srtVault.balanceOf(carol), 0.1e18);
        assertEq(baseAsset.balanceOf(carol), assets - slice);
        assertEq(usdc.balanceOf(carol), slice / 1e12);
    }

    function test_strategyLimitReceivesRequotedTokenAmount() public {
        uint256 assets = srtVault.previewRedeem(srtVault.balanceOf(bob));
        uint256 slice = Math.mulDiv(assets, accounting.insuranceAmount(), accounting.srtBaseNav());
        uint256 leg = assets - slice;
        // Reject any other token amount, while allowing the exact net strategy leg.
        vm.mockCall(address(strategy), abi.encodeWithSelector(strategy.maxWithdraw.selector), abi.encode(uint256(0)));
        vm.mockCall(address(strategy), abi.encodeWithSelector(strategy.maxWithdraw.selector,
            address(srtVault), address(baseAsset), leg), abi.encode(leg));
        _redeemBob();
    }

    function test_insufficientStrategyCapacityRevertsAndRollsBackCoverage() public {
        uint256 shares = srtVault.balanceOf(bob);
        uint256 claimBefore = accounting.insuranceAmount();
        uint256 seniorBefore = accounting.srtBaseNav();
        uint256 fundingBefore = insuranceVault.fundedCoverage();
        vm.mockCall(address(strategy), abi.encodeWithSelector(strategy.maxWithdraw.selector), abi.encode(uint256(0)));
        vm.expectRevert(abi.encodeWithSelector(IErrors.WithdrawalRejectedByStrategy.selector,
            address(srtVault), address(baseAsset)));
        vm.prank(bob);
        srtVault.redeem(address(baseAsset), shares, bob, bob);
        assertEq(accounting.insuranceAmount(), claimBefore);
        assertEq(accounting.srtBaseNav(), seniorBefore);
        assertEq(insuranceVault.fundedCoverage(), fundingBefore);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(baseAsset.balanceOf(bob), 0);
        assertEq(srtVault.balanceOf(bob), shares);
    }

    function test_fullyInsuredExitDoesNotConsultStrategyCapacity() public {
        _scaleSubStrategy(address(juniorStrat), 0);
        _scaleSubStrategy(address(seniorStrat), 0);
        vm.prank(keeper);
        jrtVault.burnSharesAsFee(0, keeper);
        uint256 funding = (accounting.insuranceAmount() - claim) / 1e12 + 1;
        usdc.mint(multisig, funding);
        vm.startPrank(multisig);
        IERC20(address(usdc)).approve(address(cdo), funding);
        cdo.fundInsuranceClaim(address(usdc), funding);
        vm.stopPrank();
        assertEq(strategy.totalAssets(), 0);
        vm.mockCallRevert(address(strategy), abi.encodeWithSelector(strategy.maxWithdraw.selector), bytes("unexpected strategy limit call"));
        _redeemBob();
        assertEq(baseAsset.balanceOf(bob), 0);
    }

}

interface IDepositToken {
    function deposit(address token, uint256 amount, address receiver) external returns (uint256);
}

interface IMockSingle {
    function totalAssetsValue() external view returns (uint256);
    function setTotalAssets(uint256 assets) external;
}
