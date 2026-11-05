// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { console, Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { DiscreteAccounting } from "../../../contracts/tranches/DiscreteAccounting.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";

/// @notice Live Senior pricing and exit splitting exclude Junior unrealized gains from valuation backing.
/// @dev Real `DiscreteAccounting`, no insurance pool; the test contract is the CDO, the strategy and the APR feed
///      Junior 1000, Senior 4000, price 0.5, 10% base APR. Isolated harness: the exit is booked through
///      `updateBalanceFlow` as `StrataCDO::withdraw` books it, without the Tranche share maths
contract DiscreteDepegExitProjectedJuniorSplitTest is Test {
    DiscreteAccounting accounting;
    uint256 mockStrategyTvl;

    uint128 constant PRICE = 0.5e18;

    function totalStrategyAssets() external view returns (uint256) {
        return mockStrategyTvl;
    }

    function totalStrategyAssets(uint256, uint256) external view returns (uint256) {
        return mockStrategyTvl;
    }

    function getRate() external pure returns (uint256) {
        return 1e18;
    }

    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound({
            aprTarget: 0,
            aprBase: 100_000_000_000, // 10% APR, SD7x12
            updatedAt: uint64(block.timestamp),
            answeredInRound: 1
        });
    }

    function setUp() public {
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = DiscreteAccounting(address(new ERC1967Proxy(
            address(new DiscreteAccounting(18, false)),
            abi.encodeWithSelector(
                DiscreteAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
            )
        )));

        // Junior 1000 and Senior 4000, as StrataCDO::deposit books them
        mockStrategyTvl = 5000e18;
        accounting.updateBalanceFlow(1000e18, 0, 4000e18, 0);
        accounting.setValuationPrice(PRICE);
    }

    /// @dev Senior effective NAV measured the way `_splitValuationWithdrawal` measures it: settled Junior NAV,
    ///      no credit and no self-fund in this market
    function _splitBasis() internal view returns (uint256) {
        uint256 srt = accounting.srtBaseNav();
        uint256 headroom = accounting.jrtBaseNav() - 1e18;
        uint256 needed = srt * 1e18 / PRICE - srt;
        return srt + (headroom < needed ? headroom : needed);
    }

    /// @dev Half of Senior exits at its live price, then the price returns to par
    function _halfExitAndRepeg() internal returns (uint256 exitAssets, uint256 srtAfterExit, uint256 srtAtPar, uint256 jrtAtPar) {
        accounting.updateAccounting(); // the update a Senior exit runs first
        (, uint256 srtLive,) = accounting.totalAssets();
        exitAssets = srtLive / 2;
        uint256 fromVault = accounting.updateBalanceFlow(0, 0, 0, exitAssets);
        mockStrategyTvl -= exitAssets - fromVault;
        srtAfterExit = accounting.srtBaseNav();

        accounting.setValuationPrice(1e18);
        uint256 jrtLiveAtPar;
        (jrtLiveAtPar, srtAtPar,) = accounting.totalAssets();
        jrtAtPar = jrtLiveAtPar;
    }

    function test_pendingReconciliationUsesFreshJuniorBacking() public {
        vm.warp(vm.getBlockTimestamp() + 73 days);
        accounting.updateAccounting();
        mockStrategyTvl += 200e18;
        (uint256 juniorPreview, uint256 seniorPreview,) = accounting.totalAssets();
        accounting.updateAccounting();
        (uint256 juniorAfter, uint256 seniorAfter,) = accounting.totalAssets();
        assertEq(juniorPreview, juniorAfter);
        assertEq(seniorPreview, seniorAfter);
        assertEq(accounting.jrtNavProjected(), accounting.jrtBaseNav(), "gain settled");
    }

    /// Control: with no open Junior projection, price and split use the same Junior NAV and a half exit keeps
    /// exactly half of Senior principal
    function test_PoC_DiscreteDepegHalfExitWithoutProjectionIsProRata() public {
        (uint256 exitAssets, uint256 srtAfterExit, uint256 srtAtPar, uint256 jrtAtPar) = _halfExitAndRepeg();
        assertEq(exitAssets, 2499.5e18, "half of Senior's live NAV");
        assertApproxEqAbs(srtAfterExit, 2000e18, 1e6, "remaining Senior keeps half of its principal");
        assertApproxEqAbs(srtAtPar, 2000e18, 1e6, "remaining Senior whole at re-peg");
        assertApproxEqAbs(jrtAtPar, 500.5e18, 1e6, "Junior keeps its pro-rata share");
    }

    /// Open Junior projection stays with Junior rather than inflating Senior exit protection.
    function test_DiscreteOpenJuniorProjectionDoesNotBackSenior() public {
        vm.warp(vm.getBlockTimestamp() + 73 days);
        accounting.updateAccounting();

        assertEq(accounting.jrtNavProjected(), 1100e18, "Junior's open projection");
        assertEq(accounting.jrtBaseNav(), 1000e18, "settled Junior NAV");
        assertEq(accounting.srtBaseNav(), 4000e18, "Senior principal");
        (, uint256 srtLive,) = accounting.totalAssets();
        assertEq(srtLive, 4999e18, "price basis excludes unrealized Junior gain");
        (uint256 juniorLive,,) = accounting.totalAssets();
        assertEq(juniorLive, 101e18, "Junior retains its unrealized gain and dust");
        assertEq(_splitBasis(), 4999e18, "split basis: Senior topped up from settled Junior NAV");

        (uint256 exitAssets, uint256 srtAfterExit, uint256 srtAtPar, uint256 jrtAtPar) = _halfExitAndRepeg();
        assertEq(exitAssets, 2499.5e18, "half the backed Senior NAV");
        assertApproxEqAbs(srtAfterExit, 2000e18, 1e6, "remaining half of principal preserved");
        assertApproxEqAbs(srtAtPar, 2000e18, 1e6);
        assertApproxEqAbs(jrtAtPar, 600.5e18, 1e6, "Junior keeps all 100 of its open projection");
    }
}
