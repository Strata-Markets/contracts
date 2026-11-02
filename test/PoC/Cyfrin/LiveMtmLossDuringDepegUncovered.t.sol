// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { MockInsurancePool } from "../../symbiotic/mocks/MockInsurancePool.sol";

/// @notice In an MTM market a strategy loss is first seen as a live mark below the settled NAV. During a covered
///         de-peg the projected loss waterfall charges it to Junior's real NAV, which `calcEffectiveNav` has
///         already pledged to Senior, and asks the pool for nothing. Senior's live NAV, which prices Senior exits,
///         falls by the full loss while the pool has capacity. At par the same live loss beyond Junior is held by
///         would-be coverage and Senior's live NAV does not move
/// @dev Real `MTMAccounting` (conservative pricing, MTM projection) with `MockInsurancePool`; the test contract is
///      the CDO and the strategy. Junior 1000, Senior 1000
contract LiveMtmLossDuringDepegUncoveredTest is Test {
    MTMAccounting accounting;
    MockInsurancePool pool;

    uint256 constant CAPACITY = 1_000_000e18;
    uint128 constant PRICE = 0.4e18;
    uint256 constant SRT_WHOLE = 2500e18; // 1000 of principal at 0.40

    uint256 mockStrategyTvl;
    uint256 mtmLoss; // live mark below the settled strategy NAV

    function totalStrategyAssets() external view returns (uint256) {
        return mockStrategyTvl;
    }

    function totalStrategyAssets(uint256, uint256) external view returns (uint256) {
        return mockStrategyTvl;
    }

    function totalStrategyAssetsSnapshot(uint256, uint256)
        external
        view
        returns (uint256, uint256, uint256, uint256)
    {
        if (mtmLoss > 0) {
            return (mockStrategyTvl, block.timestamp - 1, mockStrategyTvl - mtmLoss, block.timestamp);
        }
        return (mockStrategyTvl, block.timestamp, mockStrategyTvl, block.timestamp);
    }

    function getRate() external pure returns (uint256) {
        return 1e18;
    }

    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound({
            aprTarget: 0,
            aprBase: 100_000_000_000,
            updatedAt: uint64(block.timestamp),
            answeredInRound: 1
        });
    }

    function setUp() public {
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = MTMAccounting(address(new ERC1967Proxy(
            address(new MTMAccounting(18, false, true, false, true, true, true)),
            abi.encodeWithSelector(
                MTMAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        )));
        pool = new MockInsurancePool();
        pool.setCapacity(CAPACITY);
        accounting.setInsurancePool(pool);

        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
    }

    /// @dev Senior redemption price used by a conservative-price Tranche: min(live, settled)
    function _seniorRedeemable() internal view returns (uint256) {
        (, uint256 srtLive,, uint256 srtSettled) = accounting.totalAssetsLiveAndSettled();
        return Math.min(srtLive, srtSettled);
    }

    function _slashed() internal view returns (uint256) {
        return CAPACITY - pool.capacity();
    }

    /// Control at par: a live loss of 1100 exceeds Junior's 999 of headroom, and Senior's live NAV stays whole
    function test_PoC_ParLiveMtmLossBeyondJuniorLeavesSeniorWhole() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        mtmLoss = 1100e18;
        accounting.updateAccounting();

        (, uint256 srtLive,) = accounting.totalAssets();
        assertEq(srtLive, 1000e18, "at par Senior's live NAV is held by would-be coverage");
    }

    /// During a covered de-peg a live loss of only 100 is charged to pledged Junior headroom: Senior's live NAV,
    /// and its redemption price, fall by 100 tokens with no claim booked and the pool's capacity unused
    function test_PoC_LiveMtmLossDuringDepegReachesSenior() public {
        accounting.setValuationPrice(PRICE);
        assertEq(accounting.insuranceAmount(), 501e18, "de-peg claim");
        (, uint256 srtBefore,) = accounting.totalAssets();
        assertEq(srtBefore, SRT_WHOLE, "Senior whole after the de-peg push");

        vm.warp(vm.getBlockTimestamp() + 1 days);
        mtmLoss = 100e18;
        accounting.updateAccounting();
        accounting.updateAccounting(); // the update a Senior exit runs first

        (, uint256 srtLive,) = accounting.totalAssets();
        assertEq(srtLive, SRT_WHOLE - 100e18, "Senior's live NAV falls by the whole live loss");
        assertLt(_seniorRedeemable(), SRT_WHOLE, "Senior exits are priced below the protected value");
        assertEq(accounting.insuranceAmount(), 501e18, "no coverage requested");
        assertEq(_slashed(), 501e18, "pool capacity left unused");
        assertGt(pool.capacity(), 100e18);
    }

    /// A Senior holding 10% exits at the live price before reconciliation, then reconciliation covers the same
    /// loss for the Seniors who stayed: the exiter alone bears it
    function test_PoC_SeniorExitBeforeReconciliationBearsLiveLoss() public {
        accounting.setValuationPrice(PRICE);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        mtmLoss = 100e18;
        accounting.updateAccounting();

        uint256 exitAssets = _seniorRedeemable() / 10;
        assertApproxEqAbs(exitAssets, 240e18, 1e6, "10% of Senior is paid 240 tokens");
        uint256 fromVault = accounting.updateBalanceFlow(0, 0, 0, exitAssets);
        mockStrategyTvl -= exitAssets - fromVault;

        // The live loss is realized and reconciled
        vm.warp(vm.getBlockTimestamp() + 1);
        mockStrategyTvl -= mtmLoss;
        mtmLoss = 0;
        uint256 claimBefore = accounting.insuranceAmount();
        accounting.updateAccounting();

        (, uint256 srtAfter,) = accounting.totalAssets();
        assertApproxEqAbs(srtAfter, 2250e18, 1e9, "remaining 90% of Senior is made whole at reconciliation");
        assertGt(accounting.insuranceAmount(), claimBefore, "coverage was available and is booked only now");
        emit log_named_decimal_uint("exiter received (tokens)", exitAssets, 18);
        emit log_named_decimal_uint("exiter was owed (tokens)", SRT_WHOLE / 10, 18);
    }
}
