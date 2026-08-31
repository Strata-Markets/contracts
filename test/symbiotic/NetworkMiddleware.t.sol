// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { NetworkMiddleware } from "../../contracts/tranches/symbiotic/NetworkMiddleware.sol";
import { IAppAdapter } from "../../contracts/tranches/symbiotic/interfaces/IAppAdapter.sol";
import { IStrataAccounting } from "../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { IOracleAdapter } from "../../contracts/tranches/symbiotic/interfaces/IOracleAdapter.sol";
import { MockERC20 } from "../../contracts/test/MockERC20.sol";
import { MockOracleAdapter } from "../../contracts/test/MockOracleAdapter.sol";

/// @notice Minimal AppAdapter mock: tracks slashable stake, caps slashes to it, records calls.
contract MockAppAdapter {
    address public asset;
    uint256 public slashable;

    uint256 public lastSlashAmount;
    uint256 public lastReleaseAmount;
    address public lastRewardToken;
    uint256 public lastRewardAmount;

    constructor(address asset_) {
        asset = asset_;
    }

    function setSlashable(uint256 amount) external {
        slashable = amount;
    }

    function slash(uint256 amount) external {
        uint256 executed = amount > slashable ? slashable : amount;
        require(executed > 0, "InsufficientSlash");
        slashable -= executed;
        lastSlashAmount = executed;
    }

    function release(uint256 amount) external {
        uint256 executed = amount > slashable ? slashable : amount;
        slashable -= executed;
        lastReleaseAmount = executed;
    }

    function reward(address token, uint256 amount) external {
        lastRewardToken = token;
        lastRewardAmount = amount;
    }

    function burner() external pure returns (address) { return address(0); }
    function duration() external pure returns (uint48) { return 0; }
    function operator() external pure returns (address) { return address(0); }
    function subnetwork() external pure returns (bytes32) { return bytes32(0); }
    function stake() external view returns (uint256) { return slashable; }
    function stakeAt(uint48) external view returns (uint256) { return slashable; }
}

/// @notice Minimal accounting mock exposing a settable coverage deficit.
contract MockStrataAccounting is IStrataAccounting {
    uint256 public insuranceAmount;
    uint256 public premiumBps;

    function setInsuranceAmount(uint256 deficit) external {
        insuranceAmount = deficit;
    }

    /// @dev Mirrors the real accounting: only the middleware may set the premium.
    function setPremiumBps(uint256 bps) external {
        premiumBps = bps;
    }
}

contract NetworkMiddlewareTest is Test {

    // Mirrors of the middleware's events for expectEmit
    event MarketSet(address indexed cdo, address accounting, address baseAsset, uint256 bufferBps, bool enabled);
    event CoverageSlashed(address indexed cdo, uint256 requested, uint256 slashed);
    event TrueUpConfirmed(address indexed cdo, uint256 amount);

    uint256 constant UNIBTC_PRICE = 60_000e18; // $60k, 18 decimals
    uint256 constant SLASHABLE = 100e8;        // 100 uniBTC slashable stake

    address owner = makeAddr("owner");
    address cdo = makeAddr("cdo");
    address stranger = makeAddr("stranger");

    MockERC20 usde;    // 18 decimals base asset
    MockERC20 unibtc;  // 8 decimals vault asset
    MockAppAdapter adapter;
    MockStrataAccounting accounting;
    MockOracleAdapter oracle;
    NetworkMiddleware middleware;

    function setUp() public {
        usde = new MockERC20("USDe", 18);
        unibtc = new MockERC20("uniBTC", 8);

        adapter = new MockAppAdapter(address(unibtc));
        adapter.setSlashable(SLASHABLE);

        accounting = new MockStrataAccounting();

        oracle = new MockOracleAdapter();
        oracle.setPrice(address(unibtc), UNIBTC_PRICE, 18);
        // USDe defaults to $1 in the mock oracle

        NetworkMiddleware impl = new NetworkMiddleware();
        middleware = NetworkMiddleware(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(NetworkMiddleware.initialize, (owner, address(adapter), address(oracle)))
        )));

        vm.prank(owner);
        middleware.setMarket(cdo, accounting, address(usde), 0, true);
    }

    /// @dev Expected conversion: baseAssets(18 dec, $1) -> uniBTC(8 dec, $60k), floor.
    function expectedVaultAmount(uint256 baseAssets) internal pure returns (uint256) {
        // baseAssets * 1e18 * 10^(8+18) / (60_000e18 * 10^(18+18))
        return baseAssets * 1e18 / UNIBTC_PRICE / 1e10;
    }

    function test_setMarket_storesFieldsAndEmits() public {
        address cdo2 = makeAddr("cdo2");
        vm.expectEmit(true, false, false, true);
        emit MarketSet(cdo2, address(accounting), address(usde), 0, true);
        vm.prank(owner);
        middleware.setMarket(cdo2, accounting, address(usde), 0, true);

        (IStrataAccounting acc, address baseAsset,,, bool enabled,) = middleware.markets(cdo2);
        assertEq(address(acc), address(accounting));
        assertEq(baseAsset, address(usde));
        assertTrue(enabled);
    }

    function test_setMarket_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        middleware.setMarket(cdo, accounting, address(usde), 0, true);
    }

    function test_setMarketPremiumBps_forwardsToAccounting() public {
        vm.prank(owner);
        middleware.setMarketPremiumBps(cdo, 0.1e18);
        assertEq(accounting.premiumBps(), 0.1e18, "premium should be set on the market's accounting");
    }

    function test_setMarketPremiumBps_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        middleware.setMarketPremiumBps(cdo, 0.1e18);
    }

    function test_slash_convertsDeficitAndBooks() public {
        uint256 deficit = 60_000e18; // $60k deficit = 1 uniBTC
        accounting.setInsuranceAmount(deficit);

        uint256 expected = expectedVaultAmount(deficit);
        assertEq(expected, 1e8); // sanity: exactly 1 uniBTC

        vm.expectEmit(true, false, false, true);
        emit CoverageSlashed(cdo, expected, expected);
        vm.prank(owner);
        middleware.slash(cdo);

        (,, uint256 totalSlashed, uint256 pendingTrueUp,,) = middleware.markets(cdo);
        assertEq(adapter.lastSlashAmount(), expected);
        assertEq(totalSlashed, expected);
        assertEq(pendingTrueUp, expected);
    }

    function test_slash_decimalConversionFloors() public {
        uint256 deficit = 1000e18; // $1000 -> 0.016666.. uniBTC
        accounting.setInsuranceAmount(deficit);

        vm.prank(owner);
        middleware.slash(cdo);

        // 1000/60000 BTC in 8 decimals, floored
        assertEq(adapter.lastSlashAmount(), 1666666);
    }

    function test_slash_cappedByAdapterSlashable() public {
        adapter.setSlashable(0.5e8); // only 0.5 uniBTC available
        accounting.setInsuranceAmount(60_000e18); // wants 1 uniBTC

        vm.prank(owner);
        middleware.slash(cdo);

        (,, uint256 totalSlashed, uint256 pendingTrueUp,,) = middleware.markets(cdo);
        // Only the executed amount is booked
        assertEq(totalSlashed, 0.5e8);
        assertEq(pendingTrueUp, 0.5e8);
    }

    function test_slash_noDoubleSlashForSameDeficit() public {
        accounting.setInsuranceAmount(60_000e18);

        vm.prank(owner);
        middleware.slash(cdo);

        // Deficit unchanged in accounting (true-up not done yet): a second slash must revert
        vm.expectRevert(NetworkMiddleware.NoSlashableAmount.selector);
        vm.prank(owner);
        middleware.slash(cdo);
    }

    function test_slash_slashesOnlyNewDeficit() public {
        accounting.setInsuranceAmount(60_000e18);
        vm.prank(owner);
        middleware.slash(cdo);

        // Deficit grows by another $30k before any true-up
        accounting.setInsuranceAmount(90_000e18);
        vm.prank(owner);
        middleware.slash(cdo);

        (,, uint256 totalSlashed, uint256 pendingTrueUp,,) = middleware.markets(cdo);
        assertEq(totalSlashed, 1.5e8);
        assertEq(pendingTrueUp, 1.5e8);
    }

    function test_slash_revertsWhenNoDeficit() public {
        vm.expectRevert(NetworkMiddleware.NoSlashableAmount.selector);
        vm.prank(owner);
        middleware.slash(cdo);
    }

    function test_slash_revertsWhenMarketDisabled() public {
        vm.prank(owner);
        middleware.setMarket(cdo, accounting, address(usde), 0, false);

        accounting.setInsuranceAmount(60_000e18);
        vm.expectRevert(abi.encodeWithSelector(NetworkMiddleware.MarketNotEnabled.selector, cdo));
        vm.prank(owner);
        middleware.slash(cdo);
    }

    function test_slash_revertsForUnknownMarket() public {
        vm.expectRevert(abi.encodeWithSelector(NetworkMiddleware.MarketNotEnabled.selector, stranger));
        vm.prank(owner);
        middleware.slash(stranger);
    }

    function test_slash_onlyOwner() public {
        accounting.setInsuranceAmount(60_000e18);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        middleware.slash(cdo);
    }

    function test_slash_revertsWhenPaused() public {
        accounting.setInsuranceAmount(60_000e18);
        vm.prank(owner);
        middleware.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(owner);
        middleware.slash(cdo);
    }

    function test_confirmTrueUp_byCdoReducesPendingTrueUp() public {
        accounting.setInsuranceAmount(60_000e18);
        vm.prank(owner);
        middleware.slash(cdo);

        // CDO reports a true-up of $30k (base assets) = 0.5 uniBTC
        vm.expectEmit(true, false, false, true);
        emit TrueUpConfirmed(cdo, 30_000e18);
        vm.prank(cdo);
        middleware.confirmTrueUp(cdo, 30_000e18);

        (,,, uint256 pendingTrueUp,,) = middleware.markets(cdo);
        assertEq(pendingTrueUp, 0.5e8);
    }

    function test_confirmTrueUp_byOwnerAllowed() public {
        accounting.setInsuranceAmount(60_000e18);
        vm.prank(owner);
        middleware.slash(cdo);

        vm.prank(owner);
        middleware.confirmTrueUp(cdo, 60_000e18);

        (,,, uint256 pendingTrueUp,,) = middleware.markets(cdo);
        assertEq(pendingTrueUp, 0);
    }

    function test_confirmTrueUp_unauthorizedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(NetworkMiddleware.NotAuthorized.selector, stranger));
        vm.prank(stranger);
        middleware.confirmTrueUp(cdo, 1e18);
    }

    function test_confirmTrueUp_saturatesOnOverConfirm() public {
        accounting.setInsuranceAmount(60_000e18);
        vm.prank(owner);
        middleware.slash(cdo);

        // Confirm more value than was slashed (price moved); must clamp to zero, not revert
        vm.prank(cdo);
        middleware.confirmTrueUp(cdo, 120_000e18);

        (,,, uint256 pendingTrueUp,,) = middleware.markets(cdo);
        assertEq(pendingTrueUp, 0);
    }

    function test_confirmTrueUp_reopensSlashCapacity() public {
        accounting.setInsuranceAmount(60_000e18);
        vm.prank(owner);
        middleware.slash(cdo);

        // True-up completes but the accounting deficit is not yet reduced: still no re-slash
        vm.prank(cdo);
        middleware.confirmTrueUp(cdo, 60_000e18);

        // Once accounting clears the deficit, and a NEW deficit appears, slashing works again
        accounting.setInsuranceAmount(0);
        vm.expectRevert(NetworkMiddleware.NoSlashableAmount.selector);
        vm.prank(owner);
        middleware.slash(cdo);

        accounting.setInsuranceAmount(30_000e18);
        vm.prank(owner);
        middleware.slash(cdo);

        (,, uint256 totalSlashed,,,) = middleware.markets(cdo);
        assertEq(totalSlashed, 1.5e8);
    }

    function test_release_forwardsToAdapter() public {
        vm.prank(owner);
        middleware.release(1e8);
        assertEq(adapter.lastReleaseAmount(), 1e8);
    }

    function test_release_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        middleware.release(1e8);
    }

    function test_pause_unpause() public {
        vm.prank(owner);
        middleware.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(owner);
        middleware.release(1e8);

        vm.prank(owner);
        middleware.unpause();

        vm.prank(owner);
        middleware.release(1e8);
        assertEq(adapter.lastReleaseAmount(), 1e8);
    }

    function test_initialize_setsOwnerAndAdapter() public view {
        assertEq(middleware.owner(), owner);
        assertEq(address(middleware.appAdapter()), address(adapter));
    }

    function test_initialize_cannotRunTwice() public {
        vm.expectRevert();
        middleware.initialize(stranger, address(adapter), address(oracle));
    }
}
