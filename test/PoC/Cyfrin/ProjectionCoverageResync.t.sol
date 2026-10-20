// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DYSAccounting} from "../../../contracts/tranches/DYSAccounting.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IAprPairFeed} from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import {DepegNavLossFixture} from "./NavLossDuringDepeg.t.sol";

/// @notice Credited projection is insured, but its disappearance must release excess valuation credit.
abstract contract ProjectionCoverageResyncTests is DepegNavLossFixture {
    function setUp() public override {
        mockAprTarget = 80_000_000_000;
        super.setUp();
        accounting.setReserveBps(0);
        accounting.setUnderwriterFeeBps(0);
        accounting.updateBalanceFlow(0, 900e18, 0, 0);
        mockStrategyTvl = 1100e18;
    }

    function _openProjection() internal virtual;

    function _openCoveredProjection() internal {
        _openProjection();
        assertGt(DYSAccounting(address(accounting)).srtPnLProjected(), 0);
        accounting.setValuationPrice(0.5e18);
        assertGt(accounting.insuranceAmount(), 901e18, "projection is insured before realization");
    }

    function _assertSynced() internal view {
        uint256 claim = accounting.insuranceAmount();
        assertEq(accounting.srtInsuranceFundNav(), claim);
        assertEq(middleware.slashedClaimBase(address(this)), claim);
        assertEq(accounting.jrtBaseNav() + accounting.srtBaseNav(), accounting.nav() + claim);
        uint256 principal = accounting.srtBaseNav() - claim;
        assertApproxEqAbs(claim, principal - (accounting.jrtBaseNav() - ONE_ASSET), 2);
    }

    function test_reconciliationReleasesUnrealizedProjectionCoverage() public {
        _openCoveredProjection();
        uint256 slashed = _totalSlashed();
        uint256 pending = _pendingFunding();
        // A one-wei strategy gain triggers reconciliation without materially realizing the projection.
        mockStrategyTvl = 1100e18 + 1;
        accounting.updateAccounting();
        assertEq(DYSAccounting(address(accounting)).srtPnLProjected(), 0);
        assertApproxEqAbs(accounting.insuranceAmount(), 901e18, 2);
        _assertSynced();
        assertEq(_totalSlashed(), slashed, "resync must not slash again");
        assertEq(
            _pendingFunding(), pending, "slashed proceeds remain pending until funded or returned"
        );
        uint256 claim = accounting.insuranceAmount();
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), claim, "same-block update is idempotent");
    }

    function test_realizedGainResizesCoverageUsingFinalNavs() public {
        _openCoveredProjection();
        uint256 slashed = _totalSlashed();
        mockStrategyTvl = 1130e18;
        accounting.updateAccounting();
        assertEq(DYSAccounting(address(accounting)).srtPnLProjected(), 0);
        assertGt(accounting.srtBaseNav() - accounting.srtInsuranceFundNav(), 1000e18);
        _assertSynced();
        assertEq(_totalSlashed(), slashed);
    }

    function test_furtherLossStillTopsUpCoverage() public {
        _openCoveredProjection();
        uint256 slashed = _totalSlashed();
        mockStrategyTvl = 1050e18;
        accounting.updateAccounting();
        assertApproxEqAbs(accounting.insuranceAmount(), 951e18, 2);
        _assertSynced();
        assertGt(_totalSlashed(), slashed);
    }

    function test_atParNavLossClaimStillRepaidByGains() public {
        mockStrategyTvl = 900e18;
        accounting.updateAccounting();
        uint256 claim = accounting.insuranceAmount();
        assertGt(claim, 0);
        assertEq(accounting.srtInsuranceFundNav(), 0);
        mockStrategyTvl += 10e18;
        accounting.updateAccounting();
        assertEq(accounting.insuranceAmount(), claim - 10e18);
        assertEq(accounting.srtInsuranceFundNav(), 0);
    }
}

contract DYSProjectionCoverageResyncTest is ProjectionCoverageResyncTests {
    function _deployAccounting() internal override returns (address) {
        return address(
            new ERC1967Proxy(
                address(new DYSAccounting(18, false, true, false, false, true)),
                abi.encodeCall(
                    DYSAccounting.initialize,
                    (
                        address(this),
                        address(acm),
                        IStrataCDO(address(this)),
                        IAprPairFeed(address(this))
                    )
                )
            )
        );
    }

    function _openProjection() internal override {
        vm.warp(block.timestamp + 90 days);
        accounting.updateAccounting();
    }
}

contract MTMProjectionCoverageResyncTest is ProjectionCoverageResyncTests {
    uint256 liveNav;

    function _deployAccounting() internal override returns (address) {
        return address(
            new ERC1967Proxy(
                address(new MTMAccounting(18, false, true, false, false, true, true)),
                abi.encodeCall(
                    MTMAccounting.initialize,
                    (
                        address(this),
                        address(acm),
                        IStrataCDO(address(this)),
                        IAprPairFeed(address(this))
                    )
                )
            )
        );
    }

    function totalStrategyAssetsSnapshot(uint256, uint256)
        external
        view
        override
        returns (uint256, uint256, uint256, uint256)
    {
        if (liveNav > 0 && mockStrategyTvl == 1100e18) {
            return (mockStrategyTvl, block.timestamp - 1, liveNav, block.timestamp);
        }
        return (mockStrategyTvl, block.timestamp, mockStrategyTvl, block.timestamp);
    }

    function _openProjection() internal override {
        vm.warp(block.timestamp + 1 hours);
        liveNav = 1130e18;
        accounting.updateAccounting();
    }

    function test_livePullbackReleasesCoverageBeforeReconciliation() public {
        _openCoveredProjection();
        uint256 slashed = _totalSlashed();
        liveNav = 0;
        vm.warp(block.timestamp + 1 hours);
        accounting.updateAccounting();
        assertEq(accounting.nav(), 1100e18, "settled strategy NAV has not changed");
        assertEq(MTMAccounting(address(accounting)).srtPnLProjected(), 0);
        assertApproxEqAbs(accounting.insuranceAmount(), 901e18, 2);
        _assertSynced();
        assertEq(_totalSlashed(), slashed);
    }
}
