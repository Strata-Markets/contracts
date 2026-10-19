// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UD60x18} from "@prb/math/src/ud60x18/ValueType.sol";
import {Accounting} from "../../../contracts/tranches/Accounting.sol";
import {DiscreteAccounting} from "../../../contracts/tranches/DiscreteAccounting.sol";
import {DYSAccounting} from "../../../contracts/tranches/DYSAccounting.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IAprPairFeed} from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import {IInsurancePool} from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";

import {DepegNavLossFixture} from "./NavLossDuringDepeg.t.sol";

/// @notice A valuation push must checkpoint pending strategy PnL before sizing coverage.
abstract contract ValuationCheckpointTests is DepegNavLossFixture {
    function test_pricePushCheckpointsPendingLoss() public {
        mockStrategyTvl = 1500e18;
        accounting.setValuationPrice(0.5e18);
        assertEq(accounting.nav(), 1500e18);
        assertEq(accounting.insuranceAmount(), 501e18);
        assertEq(_totalSlashed(), 250.5e18);
        (, uint256 senior,) = accounting.totalAssets();
        assertEq(senior, 2000e18);
        accounting.setValuationPrice(0.5e18);
        assertEq(_totalSlashed(), 250.5e18, "same-block repeat must not slash again");
    }

    function test_pendingGainMatchesExplicitCheckpoint() public {
        vm.warp(block.timestamp + 1 days);
        mockStrategyTvl = 2200e18;
        uint256 snapshot = vm.snapshotState();
        accounting.updateAccounting();
        accounting.setValuationPrice(0.4e18);
        uint256 expectedClaim = accounting.insuranceAmount();
        uint256 expectedJunior = accounting.jrtBaseNav();
        uint256 expectedSenior = accounting.srtBaseNav();
        uint256 expectedReserve = accounting.reserveNav();
        assertTrue(vm.revertToState(snapshot));
        accounting.setValuationPrice(0.4e18);
        assertEq(accounting.nav(), 2200e18);
        assertEq(accounting.insuranceAmount(), expectedClaim);
        assertEq(accounting.jrtBaseNav(), expectedJunior);
        assertEq(accounting.srtBaseNav(), expectedSenior);
        assertEq(accounting.reserveNav(), expectedReserve);
        assertEq(_totalSlashed(), expectedClaim * 0.4e18 / 1e18);
    }

    function test_repegDoesNotSlashPendingValuationShortfall() public {
        accounting.setValuationPrice(0.4e18);
        mockStrategyTvl = 1750e18;
        accounting.setValuationPrice(1e18);
        assertEq(accounting.nav(), 1750e18);
        assertEq(accounting.jrtBaseNav(), 750e18);
        assertEq(accounting.srtBaseNav(), 1000e18);
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(_totalSlashed(), 200.4e18, "must not top up coverage at the old price");
    }

    function test_recoveryUsesNewPriceWithPendingLoss() public {
        accounting.setValuationPrice(0.4e18);
        mockStrategyTvl = 1750e18;
        accounting.setValuationPrice(0.5e18);
        assertEq(accounting.insuranceAmount(), 251e18);
        assertEq(accounting.srtInsuranceFundNav(), 251e18);
        assertEq(_totalSlashed(), 200.4e18);
        assertEq(middleware.slashedClaimBase(address(this)), 251e18);
    }

    function test_deeperDepegUsesUpdatedNav() public {
        accounting.setValuationPrice(0.5e18);
        mockStrategyTvl = 1750e18;
        accounting.setValuationPrice(0.4e18);
        assertEq(accounting.insuranceAmount(), 751e18);
        // The first 1-token claim is priced at $0.50; the new 750 at $0.40.
        assertEq(_totalSlashed(), 0.5e18 + 300e18);
    }

    function _navLossFloor() internal pure virtual returns (uint256) {
        return ONE_ASSET;
    }

    function test_repegStillCoversPendingNavLoss() public {
        accounting.setValuationPrice(0.4e18);
        mockStrategyTvl = 750e18;
        accounting.setValuationPrice(1e18);
        assertEq(accounting.insuranceAmount(), 250e18 + _navLossFloor());
        assertEq(accounting.srtInsuranceFundNav(), 0);
        assertEq(accounting.jrtBaseNav(), _navLossFloor());
        assertEq(accounting.srtBaseNav(), 1000e18);
        // Pending NAV loss is checkpointed at the old $0.40 valuation before repeg.
        assertEq(_totalSlashed(), (501e18 + 250e18 + _navLossFloor()) * 0.4e18 / 1e18);
    }

    function test_pricePushWithPartialCapacity() public {
        adapter.setSlashable(50e18); // $50 covers 100 base tokens at $0.50
        mockStrategyTvl = 1500e18;
        accounting.setValuationPrice(0.5e18);
        assertEq(accounting.nav(), 1500e18);
        assertEq(accounting.insuranceAmount(), 100e18);
        assertEq(_totalSlashed(), 50e18);
        accounting.setValuationPrice(0.5e18);
        assertEq(_totalSlashed(), 50e18);
    }

    function test_pricePushWithoutInsurance() public {
        accounting.setInsurancePool(IInsurancePool(address(0)));
        mockStrategyTvl = 1500e18;
        accounting.setValuationPrice(0.5e18);
        assertEq(accounting.nav(), 1500e18);
        assertEq(accounting.jrtBaseNav(), 500e18);
        assertEq(accounting.insuranceAmount(), 0);
    }
}

contract ValuationCheckpointAccountingTest is ValuationCheckpointTests {
    function _deployAccounting() internal override returns (address) {
        return address(
            new ERC1967Proxy(
                address(new Accounting(18)),
                abi.encodeWithSelector(
                    Accounting.initialize.selector,
                    address(this),
                    address(acm),
                    IStrataCDO(address(this)),
                    IAprPairFeed(address(0))
                )
            )
        );
    }
}

contract ValuationCheckpointDiscreteTest is ValuationCheckpointTests {
    // Discrete reconciliation consumes the entire Junior NAV in its existing loss waterfall.
    function _navLossFloor() internal pure override returns (uint256) {
        return 0;
    }

    function _deployAccounting() internal override returns (address a) {
        a = address(
            new ERC1967Proxy(
                address(new DiscreteAccounting(18, false)),
                abi.encodeWithSelector(
                    DiscreteAccounting.initialize.selector,
                    address(this),
                    address(acm),
                    IStrataCDO(address(this)),
                    IAprPairFeed(address(this))
                )
            )
        );
        acm.grantRole(DiscreteAccounting(a).UPDATER_STRAT_CONFIG_ROLE(), address(this));
        DiscreteAccounting(a).setRiskParameters(
            UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18)
        );
    }
}

contract ValuationCheckpointDYSTest is ValuationCheckpointTests {
    function _deployAccounting() internal override returns (address) {
        return address(
            new ERC1967Proxy(
                address(new DYSAccounting(18, false, false, false, true, false)),
                abi.encodeWithSelector(
                    DYSAccounting.initialize.selector,
                    address(this),
                    address(acm),
                    IStrataCDO(address(this)),
                    IAprPairFeed(address(this))
                )
            )
        );
    }
}

contract ValuationCheckpointMTMTest is ValuationCheckpointTests {
    bool twoSnapshots;

    function totalStrategyAssetsSnapshot(uint256, uint256)
        external
        view
        override
        returns (uint256, uint256, uint256, uint256)
    {
        if (twoSnapshots) {
            return (mockStrategyTvl, block.timestamp - 1, mockStrategyTvl - 100e18, block.timestamp);
        }
        return (mockStrategyTvl, block.timestamp, mockStrategyTvl, block.timestamp);
    }

    function test_pricePushWithSettledAndLiveSnapshots() public {
        accounting.setValuationPrice(0.4e18);
        vm.warp(block.timestamp + 1 days);
        mockStrategyTvl = 1750e18;
        twoSnapshots = true;
        accounting.setValuationPrice(1e18);
        assertEq(accounting.nav(), 1750e18, "live loss must remain unsettled");
        assertEq(MTMAccounting(address(accounting)).srtNavTime(), 1000e18 * 1 seconds);
        assertEq(MTMAccounting(address(accounting)).lastAccrual(), block.timestamp);
        assertEq(accounting.insuranceAmount(), 0);
        assertEq(_totalSlashed(), 200.4e18, "recursive checkpoint must defer old-price coverage");
        (uint256 liveJunior,,) = accounting.totalAssets();
        assertEq(liveJunior, 650e18);
        twoSnapshots = false;
        (uint256 recoveredJunior,,) = accounting.totalAssets();
        assertEq(recoveredJunior, 750e18, "live projection remains reversible");
    }

    function _deployAccounting() internal override returns (address) {
        return address(
            new ERC1967Proxy(
                address(new MTMAccounting(18, false, true, false, true, true, true)),
                abi.encodeWithSelector(
                    MTMAccounting.initialize.selector,
                    address(this),
                    address(acm),
                    IStrataCDO(address(this)),
                    IAprPairFeed(address(this))
                )
            )
        );
    }
}
