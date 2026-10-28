// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { InsuranceMiddleware } from "../../contracts/tranches/symbiotic/InsuranceMiddleware.sol";
import { InsuranceVault } from "../../contracts/tranches/symbiotic/InsuranceVault.sol";
import { IStrataCDO } from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAppAdapter } from "../../contracts/tranches/symbiotic/interfaces/IAppAdapter.sol";
import { IStrataAccounting } from "../../contracts/tranches/symbiotic/interfaces/IStrataAccounting.sol";
import { IOracleAdapter } from "../../contracts/tranches/symbiotic/interfaces/IOracleAdapter.sol";
import { MockERC20 } from "../../contracts/test/MockERC20.sol";
import { MockOracleAdapter } from "../../contracts/test/MockOracleAdapter.sol";

/// @notice Minimal AppAdapter mock: tracks slashable stake, caps slashes to it, records calls.
contract MockAppAdapter {
    address public asset;
    uint256 public slashable;
    /// @dev Guaranteed stake for the next duration. 0 = mirror `slashable` (default).
    uint256 public stakeOverride;

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

    function setStake(uint256 amount) external {
        stakeOverride = amount;
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
    function stake() public view returns (uint256) { return stakeOverride == 0 ? slashable : stakeOverride; }
    function stakeAt(uint48) external view returns (uint256) { return stake(); }
}

/// @notice Minimal accounting mock exposing a settable coverage deficit.
contract MockStrataAccounting is IStrataAccounting {
    uint256 public insuranceAmount;
    uint256 public underwriterFeeBps;
    uint128 public valuationPrice = 1e18;
    function setValuationPrice(uint128 price) external { valuationPrice = price; }

    function setInsuranceAmount(uint256 deficit) external {
        insuranceAmount = deficit;
    }

    /// @dev Mirrors the real accounting: only the CDO may set the underwriter fee.
    function setUnderwriterFeeBps(uint256 bps) external {
        underwriterFeeBps = bps;
    }
}

/// @notice Minimal CDO mock. The middleware sets the underwriter fee on the CDO, which forwards it
///         to its accounting contract; accounting itself only accepts the call from the CDO.
contract MockStrataCDO {
    MockStrataAccounting public accounting;
    address public insuranceVault;
    uint256 public baseAssetDecimals = 18;
    function setInsuranceVault(address vault) external { insuranceVault = vault; }
    function setBaseAssetDecimals(uint256 value) external { baseAssetDecimals = value; }

    constructor(MockStrataAccounting accounting_) {
        accounting = accounting_;
    }

    function setUnderwriterFeeBps(uint256 bps) external {
        accounting.setUnderwriterFeeBps(bps);
    }
}

contract InsuranceMiddlewareTest is Test {

    // Mirrors of the middleware's events for expectEmit
    event MarketSet(address indexed cdo, address accounting, address baseAsset, uint256 bufferBps, bool enabled);
    event CoverageSlashed(address indexed cdo, uint256 requested, uint256 slashed);
    event InsuranceClaimFundingConfirmed(address indexed cdo, uint256 amount);
    event SlashedCollateralReturned(address indexed cdo, uint256 amount);

    uint256 constant UNIBTC_PRICE = 60_000e18; // $60k, 18 decimals
    uint256 constant SLASHABLE = 100e8;        // 100 uniBTC slashable stake

    address owner = makeAddr("owner");
    address cdo; // MockStrataCDO, deployed in setUp once accounting exists
    address acm = makeAddr("acm");
    address stranger = makeAddr("stranger");

    MockERC20 usde;    // 18 decimals base asset
    MockERC20 unibtc;  // 8 decimals vault asset
    MockAppAdapter adapter;
    MockStrataAccounting accounting;
    MockOracleAdapter oracle;
    InsuranceMiddleware middleware;

    function setUp() public {
        usde = new MockERC20("USDe", 18);
        unibtc = new MockERC20("uniBTC", 8);

        adapter = new MockAppAdapter(address(unibtc));
        adapter.setSlashable(SLASHABLE);

        accounting = new MockStrataAccounting();

        oracle = new MockOracleAdapter();
        oracle.setPrice(address(unibtc), UNIBTC_PRICE, 18);
        // Base assets use accounting.valuationPrice; only uniBTC needs an oracle price.

        InsuranceMiddleware impl = new InsuranceMiddleware(address(adapter));
        middleware = InsuranceMiddleware(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(InsuranceMiddleware.initialize, (owner, acm, address(oracle)))
        )));

        cdo = address(new MockStrataCDO(accounting));

        vm.prank(owner);
        middleware.setMarket(cdo, accounting, address(usde), 0, true);
    }

    /// @dev Expected conversion: baseAssets(18 dec, $1) -> uniBTC(8 dec, $60k), floor.
    function expectedVaultAmount(uint256 baseAssets) internal pure returns (uint256) {
        // baseAssets * 1e18 * 10^(8+18) / (60_000e18 * 10^(18+18))
        return baseAssets * 1e18 / UNIBTC_PRICE / 1e10;
    }

    /// @dev Inverse of {expectedVaultAmount}: uniBTC(8 dec) -> USDe(18 dec, $1).
    function expectedBaseAmount(uint256 vaultAmount) internal pure returns (uint256) {
        return vaultAmount * UNIBTC_PRICE / 1e18 * 1e10;
    }

    function testFuzz_valuationPriceControlsCapacityAndSlash(bool lowOraclePrice, bool sixDecimals) public {
        MockERC20 base = sixDecimals ? new MockERC20("BASE6", 6) : usde;
        uint256 unit = sixDecimals ? 1e6 : 1e18;
        MockStrataCDO(cdo).setBaseAssetDecimals(sixDecimals ? 6 : 18);
        vm.prank(owner);
        middleware.setMarket(cdo, accounting, address(base), 0, true);
        accounting.setValuationPrice(0.5e18);
        oracle.setPrice(address(base), lowOraclePrice ? 0.2e18 : 1.4e18, 18);
        oracle.setPrice(address(unibtc), 60_000e8, 8);
        adapter.setSlashable(1e8);

        // One BTC covers 120,000 base tokens at the stored $0.50 valuation.
        assertEq(middleware.request(cdo, 180_000 * unit), 120_000 * unit);
        vm.prank(address(accounting));
        assertEq(middleware.coverAndSlash(cdo, 180_000 * unit), 120_000 * unit);
        assertEq(adapter.lastSlashAmount(), 1e8);
        assertEq(middleware.slashedClaimBase(cdo), 120_000 * unit);
    }

    function test_depegFundingAndReturnUseValuationWithoutBaseOracle() public {
        accounting.setValuationPrice(0.5e18);
        vm.mockCallRevert(address(oracle), abi.encodeCall(IOracleAdapter.getPrice, (address(usde))), "NoBaseFeed");
        vm.prank(owner);
        middleware.setMarket(cdo, accounting, address(usde), 1000, true);
        _coverTo(cdo, accounting, 60_000e18);
        assertEq(adapter.lastSlashAmount(), 0.55e8, "$30,000 plus 10% buffer");

        _fundVault(15_000e18);
        vm.prank(cdo);
        middleware.confirmInsuranceClaimFunding(cdo, 30_000e18);
        (,,, uint256 pending,,) = middleware.markets(cdo);
        assertEq(pending, 0.3e8);

        // The remaining $15,000 claim needs 0.275 BTC including its buffer.
        vm.expectRevert(InsuranceMiddleware.InvalidReturnedAmount.selector);
        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 0.025e8 + 1);
        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 0.025e8);
        (,,, pending,,) = middleware.markets(cdo);
        assertEq(pending, 0.275e8);
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

    function test_setMarketUnderwriterFeeBps_forwardsToAccounting() public {
        vm.prank(owner);
        middleware.setMarketUnderwriterFeeBps(cdo, 0.1e18);
        assertEq(accounting.underwriterFeeBps(), 0.1e18, "underwriter fee should be set on the market's accounting");
    }

    function test_setMarketUnderwriterFeeBps_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        middleware.setMarketUnderwriterFeeBps(cdo, 0.1e18);
    }

    function test_request_coversLossWithinCapacity() public view {
        // No outstanding claim: capacity is the full slashable stake (~$6M), so a small loss is
        // fully coverable.
        uint256 covered = middleware.request(cdo, 1000e18);
        assertEq(covered, 1000e18);
    }

    function test_request_cappedByStakeCapacity() public view {
        // A loss beyond the pool's base-asset capacity is capped to it.
        uint256 capacityBase = expectedBaseAmount(SLASHABLE); // 100 uniBTC -> $6M
        uint256 covered = middleware.request(cdo, capacityBase + 1_000e18);
        assertEq(covered, capacityBase);
    }

    function test_request_sizesOffSlashableNotStake() public {
        // Coverage is slashed synchronously in the same tx it is booked (coverAndSlash), so capacity
        // is sized off live slashable(), not stake(). Sizing off stake() would let a curator grief
        // coverage to zero by announcing a deallocation while slashable() is still live.
        adapter.setSlashable(1e8);   // 1 uniBTC slashable right now
        adapter.setStake(100e8);     // stake() higher, but irrelevant

        uint256 covered = middleware.request(cdo, type(uint128).max);
        assertEq(covered, expectedBaseAmount(1e8), "capacity should follow slashable(), not stake()");
    }

    function test_request_deBuffersByMarketBuffer() public {
        // A market with a 10% swap buffer reports 1/1.1 of the raw capacity: covering B base pulls
        // bufferedVault(B) = 1.1 * toVaultAsset(B) from the shared stake when slashed.
        uint256 bufferBps = 1_000; // 10% (BPS = 10_000)
        MockStrataAccounting accountingB = new MockStrataAccounting();
        address cdoB = address(new MockStrataCDO(accountingB));
        vm.prank(owner);
        middleware.setMarket(cdoB, accountingB, address(usde), bufferBps, true);

        uint256 rawCapacity = expectedBaseAmount(SLASHABLE);
        uint256 covered = middleware.request(cdoB, type(uint128).max);

        assertEq(covered, rawCapacity * 10_000 / (10_000 + bufferBps));
        assertLt(covered, rawCapacity, "buffer must reduce reported capacity");
    }

    function test_request_committedClaimReservesBufferedStake() public {
        // An outstanding claim on the buffered market reserves the buffered vault it will pull, so
        // the remaining capacity offered to a fresh request drops by that buffered amount.
        uint256 bufferBps = 1_000; // 10%
        MockStrataAccounting accountingB = new MockStrataAccounting();
        address cdoB = address(new MockStrataCDO(accountingB));
        vm.prank(owner);
        middleware.setMarket(cdoB, accountingB, address(usde), bufferBps, true);

        uint256 claimBase = 60_000e18; // 1 uniBTC raw -> 1.1 uniBTC buffered reserved
        accountingB.setInsuranceAmount(claimBase);

        uint256 reservedVault = expectedVaultAmount(claimBase) * (10_000 + bufferBps) / 10_000;
        uint256 expectedCapacity = expectedBaseAmount(SLASHABLE - reservedVault)
            * 10_000 / (10_000 + bufferBps);

        uint256 covered = middleware.request(cdoB, type(uint128).max);
        assertEq(covered, expectedCapacity);
    }

    function test_coverAndSlash_appliesBuffer() public {
        // Slash sizes the claim up by the buffer: a 1 uniBTC raw deficit slashes 1.1 uniBTC.
        uint256 bufferBps = 1_000; // 10%
        MockStrataAccounting accountingB = new MockStrataAccounting();
        address cdoB = address(new MockStrataCDO(accountingB));
        vm.prank(owner);
        middleware.setMarket(cdoB, accountingB, address(usde), bufferBps, true);

        _coverTo(cdoB, accountingB, 60_000e18);

        assertEq(adapter.lastSlashAmount(), 1e8 * (10_000 + bufferBps) / 10_000); // 1.1 uniBTC
        assertEq(middleware.slashedClaimBase(cdoB), 60_000e18);
    }

    function test_coverAndSlash_convertsDeficitAndBooks() public {
        uint256 deficit = 60_000e18; // $60k deficit = 1 uniBTC

        uint256 expected = expectedVaultAmount(deficit);
        assertEq(expected, 1e8); // sanity: exactly 1 uniBTC

        vm.expectEmit(true, false, false, true);
        emit CoverageSlashed(cdo, deficit, expected);
        _coverTo(cdo, accounting, deficit);

        (,, uint256 totalSlashed, uint256 pendingInsuranceClaimFunding,,) = middleware.markets(cdo);
        assertEq(adapter.lastSlashAmount(), expected);
        assertEq(totalSlashed, expected);
        assertEq(pendingInsuranceClaimFunding, expected);
    }

    function test_coverAndSlash_slashesAndReturnsCovered() public {
        // The market's accounting calls it; a $60k loss = 1 uniBTC slashed, fully covered.
        vm.prank(address(accounting));
        uint256 covered = middleware.coverAndSlash(cdo, 60_000e18);

        assertEq(covered, 60_000e18, "full coverage returns the requested base");
        assertEq(middleware.slashedClaimBase(cdo), covered);
        assertEq(adapter.lastSlashAmount(), 1e8, "1 uniBTC slashed");
        (,, uint256 totalSlashed, uint256 pendingInsuranceClaimFunding,,) = middleware.markets(cdo);
        assertEq(totalSlashed, 1e8);
        assertEq(pendingInsuranceClaimFunding, 1e8);
    }

    function test_coverAndSlash_onlyAccounting() public {
        vm.expectRevert(abi.encodeWithSelector(InsuranceMiddleware.NotAuthorized.selector, stranger));
        vm.prank(stranger);
        middleware.coverAndSlash(cdo, 60_000e18);
    }

    function test_coverAndSlash_partialWhenSlashableLow() public {
        // Only 0.5 uniBTC slashable but $60k (1 uniBTC) requested: covers the de-buffered half.
        adapter.setSlashable(0.5e8);

        vm.prank(address(accounting));
        uint256 covered = middleware.coverAndSlash(cdo, 60_000e18);

        assertEq(adapter.lastSlashAmount(), 0.5e8, "only what was slashable");
        assertEq(covered, 30_000e18, "covered is the de-buffered slashed base");
        assertEq(middleware.slashedClaimBase(cdo), covered);
    }

    function test_coverAndSlash_decimalConversionFloors() public {
        uint256 deficit = 1000e18; // $1000 -> 0.016666.. uniBTC
        _coverTo(cdo, accounting, deficit);

        // 1000/60000 BTC in 8 decimals, floored
        assertEq(adapter.lastSlashAmount(), 1666666);
    }

    function test_coverAndSlash_slashesOnlyNewDeficit() public {
        _coverTo(cdo, accounting, 60_000e18);

        // Deficit grows by another $30k before any insurance claim funding
        _coverTo(cdo, accounting, 90_000e18);

        (,, uint256 totalSlashed, uint256 pendingInsuranceClaimFunding,,) = middleware.markets(cdo);
        assertEq(totalSlashed, 1.5e8);
        assertEq(pendingInsuranceClaimFunding, 1.5e8);
    }

    function _coverTo(address marketCdo, MockStrataAccounting acc, uint256 targetClaim) internal {
        uint256 oldClaim = acc.insuranceAmount();
        vm.prank(address(acc));
        uint256 covered = middleware.coverAndSlash(marketCdo, targetClaim - oldClaim);
        acc.setInsuranceAmount(oldClaim + covered);
    }

    function _slashThenRecover() internal {
        _coverTo(cdo, accounting, 60_000e18);
        accounting.setInsuranceAmount(0);
        vm.prank(address(accounting));
        middleware.syncInsuranceClaim(cdo);
    }

    function test_confirmSlashedCollateralReturned_partialThenFullPreservesHistory() public {
        _slashThenRecover();
        uint256 capacity = adapter.slashable();
        // Confirmation uses collateral units, independent of subsequent oracle changes.
        oracle.setPrice(address(unibtc), 2 * UNIBTC_PRICE, 18);
        vm.expectEmit(true, false, false, true, address(middleware));
        emit SlashedCollateralReturned(cdo, 0.4e8);
        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 0.4e8);
        (,, uint256 total, uint256 pending,,) = middleware.markets(cdo);
        assertEq(total, 1e8);
        assertEq(pending, 0.6e8);

        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 0.6e8);
        (,, total, pending,,) = middleware.markets(cdo);
        assertEq(total, 1e8);
        assertEq(pending, 0);
        assertEq(middleware.slashedClaimBase(cdo), 0);
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(adapter.slashable(), capacity);
        vm.expectRevert(InsuranceMiddleware.InvalidReturnedAmount.selector);
        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 1);
    }

    function test_confirmSlashedCollateralReturned_onlyOwner() public {
        _slashThenRecover();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        middleware.confirmSlashedCollateralReturned(cdo, 1e8);
    }

    function test_confirmSlashedCollateralReturned_rejectsLiveClaim() public {
        _slashThenRecover();
        accounting.setInsuranceAmount(1);
        vm.expectRevert(InsuranceMiddleware.InvalidReturnedAmount.selector);
        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 1e8);
    }

    function test_confirmSlashedCollateralReturned_partialRecoveryReservesBuffer() public {
        vm.prank(owner);
        middleware.setMarket(cdo, accounting, address(usde), 1000, true);
        _coverTo(cdo, accounting, 60_000e18);
        accounting.setInsuranceAmount(30_000e18);
        vm.prank(address(accounting));
        middleware.syncInsuranceClaim(cdo);
        vm.expectRevert(InsuranceMiddleware.InvalidReturnedAmount.selector);
        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 0.55e8 + 1);
        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 0.55e8);
        (,, uint256 total, uint256 pending,,) = middleware.markets(cdo);
        assertEq(total, 1.1e8);
        assertEq(pending, 0.55e8);
        assertEq(middleware.slashedClaimBase(cdo), 30_000e18);
    }

    function test_confirmSlashedCollateralReturned_reservesAtCurrentPrice() public {
        _slashThenRecover();
        accounting.setInsuranceAmount(30_000e18);
        oracle.setPrice(address(unibtc), UNIBTC_PRICE / 2, 18);
        vm.expectRevert(InsuranceMiddleware.InvalidReturnedAmount.selector);
        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 1);
    }

    function test_confirmSlashedCollateralReturned_deductsFundedCoverage() public {
        _slashThenRecover();
        accounting.setInsuranceAmount(30_000e18);
        _fundVault(12_000e18);
        vm.prank(cdo);
        middleware.confirmInsuranceClaimFunding(cdo, 12_000e18);
        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 0.5e8);
        (,,, uint256 pending,,) = middleware.markets(cdo);
        assertEq(pending, 0.3e8);
        vm.expectRevert(InsuranceMiddleware.InvalidReturnedAmount.selector);
        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 1);
    }

    function test_confirmSlashedCollateralReturned_roundsReserveUp() public {
        _slashThenRecover();
        accounting.setValuationPrice(0.5e18);
        accounting.setInsuranceAmount(1);
        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 1e8 - 1);
        (,,, uint256 pending,,) = middleware.markets(cdo);
        assertEq(pending, 1);
    }

    function test_confirmSlashedCollateralReturned_rejectsInvalidAmounts() public {
        _slashThenRecover();
        vm.expectRevert(InsuranceMiddleware.InvalidReturnedAmount.selector);
        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 0);
        vm.expectRevert(InsuranceMiddleware.InvalidReturnedAmount.selector);
        vm.prank(owner);
        middleware.confirmSlashedCollateralReturned(cdo, 1e8 + 1);
        (,,, uint256 pending,,) = middleware.markets(cdo);
        assertEq(pending, 1e8);
    }

    function test_confirmInsuranceClaimFunding_byCdoReducesPendingInsuranceClaimFunding() public {
        _coverTo(cdo, accounting, 60_000e18);

        // CDO reports insurance claim funding of $30k (base assets) = 0.5 uniBTC
        vm.expectEmit(true, false, false, true);
        emit InsuranceClaimFundingConfirmed(cdo, 30_000e18);
        vm.prank(cdo);
        middleware.confirmInsuranceClaimFunding(cdo, 30_000e18);

        (,,, uint256 pendingInsuranceClaimFunding,,) = middleware.markets(cdo);
        assertEq(pendingInsuranceClaimFunding, 0.5e8);
    }

    function test_confirmInsuranceClaimFunding_byOwnerAllowed() public {
        _coverTo(cdo, accounting, 60_000e18);

        vm.prank(owner);
        middleware.confirmInsuranceClaimFunding(cdo, 60_000e18);

        (,,, uint256 pendingInsuranceClaimFunding,,) = middleware.markets(cdo);
        assertEq(pendingInsuranceClaimFunding, 0);
    }

    function test_confirmInsuranceClaimFunding_unauthorizedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(InsuranceMiddleware.NotAuthorized.selector, stranger));
        vm.prank(stranger);
        middleware.confirmInsuranceClaimFunding(cdo, 1e18);
    }

    function test_confirmInsuranceClaimFunding_saturatesOnOverConfirm() public {
        _coverTo(cdo, accounting, 60_000e18);

        // Confirm more value than was slashed (price moved); must clamp to zero, not revert
        vm.prank(cdo);
        middleware.confirmInsuranceClaimFunding(cdo, 120_000e18);

        (,,, uint256 pendingInsuranceClaimFunding,,) = middleware.markets(cdo);
        assertEq(pendingInsuranceClaimFunding, 0);
    }

    function test_fundingDoesNotChangeCapacity() public {
        _coverTo(cdo, accounting, 60_000e18);
        uint256 available = middleware.request(cdo, type(uint128).max);
        vm.prank(cdo);
        middleware.confirmInsuranceClaimFunding(cdo, 60_000e18);
        assertEq(middleware.slashedClaimBase(cdo), 60_000e18);
        assertEq(middleware.request(cdo, type(uint128).max), available);
    }

    function test_syncInsuranceClaim_onlyAccounting() public {
        vm.expectRevert(abi.encodeWithSelector(InsuranceMiddleware.NotAuthorized.selector, stranger));
        vm.prank(stranger);
        middleware.syncInsuranceClaim(cdo);
    }

    function test_settledBackingCannotHideLaterUnslashedClaim() public {
        _coverTo(cdo, accounting, 60_000e18);
        accounting.setInsuranceAmount(20_000e18);
        vm.prank(address(accounting));
        middleware.syncInsuranceClaim(cdo);
        assertEq(middleware.slashedClaimBase(cdo), 20_000e18);
        _coverTo(cdo, accounting, 40_000e18);
        assertEq(middleware.slashedClaimBase(cdo), 40_000e18);
        assertEq(adapter.lastSlashAmount(), uint256(20_000e18) * 1e8 / UNIBTC_PRICE);
    }

    function test_newClaimAfterRecoverySlashesAgain() public {
        _coverTo(cdo, accounting, 60_000e18);

        // Insurance claim funding completes but the accounting deficit is not yet reduced: still no re-slash
        vm.prank(cdo);
        middleware.confirmInsuranceClaimFunding(cdo, 60_000e18);

        // Once accounting clears the deficit, and a NEW deficit appears, slashing works again
        accounting.setInsuranceAmount(0);
        vm.prank(address(accounting));
        middleware.syncInsuranceClaim(cdo);

        _coverTo(cdo, accounting, 30_000e18);

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


    function test_initialize_setsOwnerAndAdapter() public view {
        assertEq(middleware.owner(), owner);
        assertEq(address(middleware.appAdapter()), address(adapter));
    }

    function test_constructor_rejectsZeroAdapter() public {
        vm.expectRevert(InsuranceMiddleware.InvalidAppAdapter.selector);
        new InsuranceMiddleware(address(0));
    }

    function test_constructor_rejectsCodelessAdapter() public {
        assertEq(stranger.code.length, 0);
        vm.expectRevert(InsuranceMiddleware.InvalidAppAdapter.selector);
        new InsuranceMiddleware(stranger);
    }

    function test_constructor_setsAdapterBeforeInitialization() public {
        InsuranceMiddleware impl = new InsuranceMiddleware(address(adapter));
        assertEq(address(impl.appAdapter()), address(adapter));
        InsuranceMiddleware proxy = InsuranceMiddleware(address(new ERC1967Proxy(
            address(impl), abi.encodeCall(InsuranceMiddleware.initialize, (owner, acm, address(oracle)))
        )));
        assertEq(address(proxy.appAdapter()), address(adapter));
        assertEq(proxy.owner(), owner);
    }

    function test_initialize_cannotRunTwice() public {
        vm.expectRevert();
        middleware.initialize(stranger, stranger, address(oracle));
    }

    function _fundVault(uint256 amount) internal returns (InsuranceVault vault) {
        vault = InsuranceVault(address(new ERC1967Proxy(address(new InsuranceVault()),
            abi.encodeCall(InsuranceVault.initialize, (owner, acm, IStrataCDO(cdo), address(usde))))));
        MockStrataCDO(cdo).setInsuranceVault(address(vault));
        usde.mint(address(vault), amount);
        vm.prank(cdo);
        vault.recordFunding(address(usde), amount);
    }

    function test_fundedSurplusCoversNewClaimWithoutStakeOrOracle() public {
        InsuranceVault vault = _fundVault(100e18);
        adapter.setSlashable(0);
        vm.mockCallRevert(address(oracle), abi.encodeWithSelector(IOracleAdapter.getPrice.selector), "stale");
        assertEq(middleware.request(cdo, 80e18), 80e18);
        vm.prank(address(accounting));
        assertEq(middleware.coverAndSlash(cdo, 80e18), 80e18);
        accounting.setInsuranceAmount(80e18);
        assertEq(middleware.slashedClaimBase(cdo), 80e18);
        assertEq(vault.fundedCoverage(), 100e18);
        assertEq(vault.surplusCoverage(), 20e18);
        assertEq(adapter.lastSlashAmount(), 0);
    }

    function test_partialSurplusSlashesOnlyRemainderWithBuffer() public {
        _fundVault(60_000e18);
        vm.prank(owner);
        middleware.setMarket(cdo, accounting, address(usde), 1000, true);
        vm.prank(address(accounting));
        assertEq(middleware.coverAndSlash(cdo, 120_000e18), 120_000e18);
        assertEq(adapter.lastSlashAmount(), 1.1e8);
        assertEq(middleware.slashedClaimBase(cdo), 120_000e18);
        (,,,uint256 pending,,) = middleware.markets(cdo);
        assertEq(pending, 1.1e8, "only fresh slashing is pending funding");
    }

    function test_existingClaimIsReservedBeforeReuse() public {
        _fundVault(100e18);
        accounting.setInsuranceAmount(80e18);
        adapter.setSlashable(0);
        assertEq(middleware.request(cdo, 100e18), 20e18);
        vm.prank(address(accounting));
        assertEq(middleware.coverAndSlash(cdo, 100e18), 20e18);
    }

    function test_coverAndSlashAllocatesFundedBackingToNewClaim() public {
        _fundVault(60_000e18);
        _coverTo(cdo, accounting, 90_000e18);
        assertEq(adapter.lastSlashAmount(), 0.5e8);
        assertEq(middleware.slashedClaimBase(cdo), 90_000e18);
    }

    function test_coverAndSlashFullyFundedNeedsNoStake() public {
        _fundVault(100e18);
        adapter.setSlashable(0);
        _coverTo(cdo, accounting, 100e18);
        assertEq(middleware.slashedClaimBase(cdo), 100e18);
        assertEq(adapter.lastSlashAmount(), 0);
    }

    function test_coverAndSlashDoesNotCountBackingTwice() public {
        _fundVault(60_000e18);
        _coverTo(cdo, accounting, 60_000e18);
        _coverTo(cdo, accounting, 90_000e18);
        assertEq(adapter.lastSlashAmount(), 0.5e8);
    }

    function test_fundedForeignClaimDoesNotReserveSharedStake() public {
        _fundVault(60_000e18);
        accounting.setInsuranceAmount(60_000e18);
        MockStrataAccounting other = new MockStrataAccounting();
        address otherCdo = address(new MockStrataCDO(other));
        vm.prank(owner);
        middleware.setMarket(otherCdo, other, address(usde), 0, true);
        assertEq(middleware.request(otherCdo, type(uint128).max), expectedBaseAmount(SLASHABLE));
        adapter.setSlashable(0);
        accounting.setInsuranceAmount(0);
        assertEq(middleware.request(otherCdo, 60_000e18), 0, "surplus is market-specific");
    }

    function test_withdrawnSurplusIsNotAvailableForReuse() public {
        InsuranceVault vault = _fundVault(100e18);
        vm.prank(owner);
        vault.withdrawSurplus(100e18, owner);
        adapter.setSlashable(0);
        assertEq(middleware.request(cdo, 100e18), 0);
    }

    function test_reuseValuationAndMixedDecimals() public {
        MockERC20 base = new MockERC20("BASE6", 6);
        MockStrataCDO(cdo).setBaseAssetDecimals(6);
        vm.prank(owner);
        middleware.setMarket(cdo, accounting, address(base), 0, true);
        accounting.setValuationPrice(0.5e18);
        _fundVault(100e18);
        adapter.setSlashable(0);
        assertEq(middleware.request(cdo, 300e6), 200e6);
        vm.prank(address(accounting));
        assertEq(middleware.coverAndSlash(cdo, 200e6), 200e6);
    }

    function test_smallRemainderStillCovered() public {
        _fundVault(100e18 - 1);
        adapter.setSlashable(1);
        vm.prank(address(accounting));
        assertEq(middleware.coverAndSlash(cdo, 100e18), 100e18);
        assertEq(adapter.lastSlashAmount(), 1);
    }

    function test_pendingProceedsAreNotReusedAfterCancellation() public {
        _coverTo(cdo, accounting, 60_000e18);
        accounting.setInsuranceAmount(0);
        vm.prank(address(accounting));
        middleware.syncInsuranceClaim(cdo);
        adapter.setSlashable(0);
        assertEq(middleware.request(cdo, 60_000e18), 0);
    }

    function test_partialSurplusWithLimitedFreshStake() public {
        _fundVault(60_000e18);
        adapter.setSlashable(1e8);
        assertEq(middleware.request(cdo, 180_000e18), 120_000e18);
        vm.prank(address(accounting));
        assertEq(middleware.coverAndSlash(cdo, 180_000e18), 120_000e18);
        assertEq(middleware.slashedClaimBase(cdo), 120_000e18);
        assertEq(adapter.lastSlashAmount(), 1e8);
    }
}
