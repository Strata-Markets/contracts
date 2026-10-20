// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DYSAccounting} from "../../../contracts/tranches/DYSAccounting.sol";
import {MTMAccounting} from "../../../contracts/tranches/MTMAccounting.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DiscreteAccounting} from "../../../contracts/tranches/DiscreteAccounting.sol";
import {IStrataCDO} from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IAprPairFeed} from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";
import {MockAprPairFeed} from "../../../contracts/test/MockAprPairFeed.sol";

/// @notice APR projection must preserve fee accounting and avoid underflow near Junior depletion.
abstract contract ProjectionUnderwriterFeeTests is Test {
    uint256 constant ONE_ASSET = 1e18;
    uint256 constant JRT = 1_000_000e18; // tiny Junior
    uint256 constant SRT = 1_000_000_000e18; // large Senior

    DiscreteAccounting accounting;
    MockAprPairFeed feed;
    uint256 mockNav;

    function totalStrategyAssets() external view returns (uint256) {
        return mockNav;
    }

    function totalStrategyAssets(uint256, uint256) external view returns (uint256) {
        return mockNav;
    }

    function _implementation() internal virtual returns (address);
    function _booksProjectionFee() internal pure virtual returns (bool);

    function totalStrategyAssetsSnapshot(uint256, uint256)
        external
        view
        returns (uint256, uint256, uint256, uint256)
    {
        return (mockNav, block.timestamp, mockNav, block.timestamp);
    }

    function setUp() public {
        vm.warp(1_790_000_000);
        AccessControlManager acm = new AccessControlManager(address(this));

        feed = new MockAprPairFeed();
        // 200% Senior floor, 1% base -> aprSrt = 200%
        feed.updateRoundData(2_000_000_000_000, 10_000_000_000, uint64(block.timestamp));

        accounting = DiscreteAccounting(
            address(
                new ERC1967Proxy(
                    _implementation(),
                    abi.encodeWithSelector(
                        DiscreteAccounting.initialize.selector,
                        address(this),
                        address(acm),
                        IStrataCDO(address(this)),
                        IAprPairFeed(address(feed))
                    )
                )
            )
        );

        // 20% underwriter fee; risk premium is the default ~40% at ratio 1, so ~8% of Senior gain
        accounting.setUnderwriterFeeBps(0.2e18);

        mockNav = JRT + SRT;
        accounting.updateBalanceFlow(JRT, 0, SRT, 0);

        assertEq(accounting.jrtBaseNav(), JRT);
        assertEq(accounting.jrtNavProjected(), JRT);
        assertEq(accounting.srtBaseNav(), SRT);
    }

    function _assertJuniorProjection() internal view virtual {
        assertGe(
            accounting.jrtNavProjected(),
            accounting.jrtBaseNav(),
            "Junior projection must cover real NAV"
        );
    }

    function test_repeatedProjectionUpdatesDoNotUnderflow() public {
        vm.warp(block.timestamp + 12 hours);
        for (uint256 i; i < 4; ++i) {
            accounting.updateAccounting();
            _assertJuniorProjection();
            assertEq(
                accounting.jrtBaseNav() + accounting.srtBaseNav() + accounting.underwriterFeeNav(),
                mockNav
            );
            if (_booksProjectionFee()) {
                assertGt(accounting.underwriterFeeNav(), 0, "Discrete books fees during projection");
            } else {
                assertEq(
                    accounting.underwriterFeeNav(), 0, "DYS/MTM defer fees until reconciliation"
                );
            }
            vm.warp(block.timestamp + 1 hours);
        }
        // Setters also checkpoint accounting and must remain callable.
        accounting.setUnderwriterFeeBps(0);
        accounting.updateAccounting();
    }

    function test_reconciliationBooksFeesWithoutBreakingNavConservation() public {
        vm.warp(block.timestamp + 1 hours);
        accounting.updateAccounting();
        uint256 beforeFee = accounting.underwriterFeeNav();
        if (!_booksProjectionFee()) assertEq(beforeFee, 0);
        vm.warp(block.timestamp + 1 hours);
        mockNav += 1_000_000e18;
        accounting.updateAccounting();
        assertGt(accounting.underwriterFeeNav(), beforeFee);
        assertEq(
            accounting.jrtBaseNav() + accounting.srtBaseNav() + accounting.reserveNav()
                + accounting.underwriterFeeNav(),
            mockNav
        );
        uint256 fee = accounting.underwriterFeeNav();
        accounting.updateAccounting();
        assertEq(
            accounting.underwriterFeeNav(), fee, "same-block refresh must not charge the fee again"
        );
    }
}

contract DiscreteProjectionUnderwriterFeeBalanceTest is ProjectionUnderwriterFeeTests {
    function _implementation() internal override returns (address) {
        return address(new DiscreteAccounting(18, false));
    }

    function _booksProjectionFee() internal pure override returns (bool) {
        return true;
    }
}

abstract contract DeferredProjectionUnderwriterFeeTests is ProjectionUnderwriterFeeTests {
    function _assertJuniorProjection() internal view override {
        assertGe(
            accounting.jrtNavProjected(), ONE_ASSET, "gross debit preserves projected Junior floor"
        );
        assertGe(accounting.jrtBaseNav(), ONE_ASSET, "net debit preserves real Junior floor");
    }

    function test_expectedFeeStaysExcludedFromProjectedJunior() public {
        uint256 start = block.timestamp;
        uint256 snapshot = vm.snapshotState();
        vm.warp(start + 1 hours);
        accounting.updateAccounting();
        uint256 juniorProjectedWithFee = accounting.jrtNavProjected();
        uint256 juniorRealWithFee = accounting.jrtBaseNav();
        uint256 seniorWithFee = accounting.srtBaseNav();
        assertEq(accounting.underwriterFeeNav(), 0, "fee remains deferred");

        assertTrue(vm.revertToState(snapshot));
        accounting.setUnderwriterFeeBps(0);
        vm.warp(start + 1 hours);
        accounting.updateAccounting();
        assertEq(
            accounting.jrtNavProjected(),
            juniorProjectedWithFee,
            "fee withholding must not increase Junior's projected price"
        );
        uint256 withheldFee = accounting.srtBaseNav() - seniorWithFee;
        assertGt(withheldFee, 0);
        assertEq(
            juniorRealWithFee - accounting.jrtBaseNav(),
            withheldFee,
            "unbooked fee remains only in real Junior NAV"
        );
    }

    function test_projectedJuniorLimitsGainBeforeRealJuniorIsDepleted() public {
        vm.warp(block.timestamp + 12 hours);
        accounting.updateAccounting();
        assertLt(accounting.jrtNavProjected(), accounting.jrtBaseNav());
        vm.warp(block.timestamp + 1 hours);
        accounting.updateAccounting();
        assertEq(accounting.jrtNavProjected(), ONE_ASSET);
        assertGt(accounting.jrtBaseNav(), ONE_ASSET);
        assertEq(accounting.underwriterFeeNav(), 0);
    }

    function _booksProjectionFee() internal pure override returns (bool) {
        return false;
    }
}

contract DYSProjectionUnderwriterFeeBalanceTest is DeferredProjectionUnderwriterFeeTests {
    function _implementation() internal override returns (address) {
        return address(new DYSAccounting(18, false, true, false, false, true));
    }
}

contract MTMProjectionUnderwriterFeeBalanceTest is DeferredProjectionUnderwriterFeeTests {
    function _implementation() internal override returns (address) {
        return address(new MTMAccounting(18, false, true, false, false, true, false));
    }
}
