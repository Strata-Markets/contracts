// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { SeniorDepegLiveBackingBase } from "./SeniorDepegLiveBacking.t.sol";

/// @notice f-20 regression using the auditor's held-settled/live-NAV strategy scenario.
contract EmptyMTMMarketDonationTest is SeniorDepegLiveBackingBase {
    function _useMTMProjection() internal pure virtual returns (bool) {
        return true;
    }

    function _setupMarket() internal {
        _deployMTMStack(AccFlags({ benchmark: false, mtmProjection: _useMTMProjection() }));
        vm.warp(block.timestamp + 1 hours);
    }

    function _donate(uint256 amount) internal {
        token.mint(address(mtmStrategy), amount);
        mtmStrategy.setTotalAssets(mtmStrategy.totalAssets() + amount);
    }

    function _checkpoint() internal {
        accounting.onAprChanged();
        _assertIdentity();
    }

    function _assertIdentity() internal view {
        assertEq(
            accounting.jrtBaseNav() + accounting.srtBaseNav() + accounting.reserveNav()
                + accounting.underwriterFeeNav(),
            accounting.nav() + accounting.insuranceAmount(),
            "stored components must equal settled NAV plus insurance"
        );
    }

    function test_oneWeiDonationDoesNotBlockFlowsOrReconciliation() public {
        _setupMarket();
        _donate(1);
        _deposit(jrt, alice, 1000e18);
        assertEq(accounting.nav(), 1000e18);
        assertEq(accounting.reserveNav(), 0);
        _assertIdentity();

        _deposit(srt, bob, 1000e18);
        _checkpoint();
        uint256 shares = jrt.balanceOf(alice) / 2;
        vm.prank(alice);
        assertGt(jrt.redeem(shares, alice, alice), 0);
        _assertIdentity();

        vm.warp(block.timestamp + 2 days);
        _checkpoint();
        assertEq(accounting.nav(), mtmStrategy.totalAssets(), "donation included in settled NAV");
        accounting.setReserveBps(0.1e18);
        _assertIdentity();

        shares = jrt.balanceOf(alice) / 2;
        vm.prank(alice);
        assertGt(jrt.redeem(shares, alice, alice), 0);
        _assertIdentity();
    }

    function test_donationSettlesToReserveWhileMarketRemainsEmpty() public {
        _setupMarket();
        _donate(100e18);
        _checkpoint();
        assertEq(accounting.nav(), 0);
        assertEq(accounting.reserveNav(), 0);
        vm.warp(block.timestamp + 2 days);
        _checkpoint();
        assertEq(accounting.nav(), 100e18);
        assertEq(accounting.reserveNav(), 100e18);
        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
        _checkpoint();
    }

    function test_noDonationControl() public {
        _setupMarket();
        _deposit(jrt, alice, 1000e18);
        _deposit(srt, bob, 1000e18);
        _checkpoint();
        assertEq(accounting.nav(), 2000e18);
        assertEq(accounting.reserveNav(), 0);
    }
}

contract EmptyMTMMarketDonationAPRTest is EmptyMTMMarketDonationTest {
    function _useMTMProjection() internal pure override returns (bool) {
        return false;
    }
}
