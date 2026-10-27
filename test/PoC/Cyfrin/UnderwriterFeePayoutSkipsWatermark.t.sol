// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { DiscreteAccounting } from "../../../contracts/tranches/DiscreteAccounting.sol";
import { DYSAccounting } from "../../../contracts/tranches/DYSAccounting.sol";
import { MTMAccounting } from "../../../contracts/tranches/MTMAccounting.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";

/// @dev The subset of the accounting ABI shared by Accounting, DiscreteAccounting, DYSAccounting and MTMAccounting
interface IFeeAccounting {
    function updateBalanceFlow(uint256, uint256, uint256, uint256) external returns (uint256);
    function updateAccounting() external;
    function setUnderwriterFeeBps(uint256) external;
    function setReserveBps(uint256) external;
    function reduceUnderwriterFee(uint256) external;
    function reserveNav() external view returns (uint256);
    function underwriterFeeNav() external view returns (uint256);
}

/// @notice f-44 auditor PoC adapted as a regression: payouts must lower the watermark.
/// @dev The test contract plays the CDO and the APR feed (100% Senior target, so a Senior gain accrues an
///      underwriter fee). Junior 1000 + Senior 1000, one year of 2000 strategy gain, then a 10% reserve fee
abstract contract UnderwriterFeePayoutSkipsWatermarkTests is Test {
    IFeeAccounting accounting;
    AccessControlManager acm;
    uint256 mockStrategyTvl;

    function totalStrategyAssets() external view returns (uint256) { return mockStrategyTvl; }
    function totalStrategyAssets(uint256, uint256) external view returns (uint256) { return mockStrategyTvl; }
    function totalStrategyAssetsSnapshot(uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        return (mockStrategyTvl, block.timestamp, mockStrategyTvl, block.timestamp);
    }
    function getRate() external pure returns (uint256) { return 1e18; }
    function decimals() external pure returns (uint8) { return 12; }
    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound({ aprTarget: 1e12, aprBase: 0, updatedAt: uint64(block.timestamp), answeredInRound: 1 });
    }

    function _deployAccounting() internal virtual returns (address);

    function setUp() public {
        vm.warp(1_790_000_000);
        acm = new AccessControlManager(address(this));
        accounting = IFeeAccounting(_deployAccounting());
        mockStrategyTvl = 2000e18;
        accounting.updateBalanceFlow(1000e18, 0, 1000e18, 0);
        accounting.setUnderwriterFeeBps(0.2e18);
        vm.warp(block.timestamp + 365 days);
        mockStrategyTvl += 2000e18;
        accounting.updateAccounting();
        accounting.setReserveBps(0.1e18);
    }

    /// @dev Optionally pays out the whole underwriter fee, then reports a gain of the same size
    function _reserveFeeOnNextGain(bool payout) internal returns (uint256 fee, uint256 reserveFee) {
        fee = accounting.underwriterFeeNav();
        if (payout) {
            accounting.reduceUnderwriterFee(fee);
            mockStrategyTvl -= fee; // the CDO pays the fee out of the strategy
        }
        uint256 reserveBefore = accounting.reserveNav();
        vm.warp(block.timestamp + 1);
        mockStrategyTvl += fee;
        accounting.updateAccounting();
        reserveFee = accounting.reserveNav() - reserveBefore;
    }

    function test_PoC_UnderwriterFeePayoutSkipsReserveFee() public {
        uint256 snap = vm.snapshotState();
        (uint256 fee, uint256 reserveFeeControl) = _reserveFeeOnNextGain(false);
        vm.revertToState(snap);

        (, uint256 reserveFeeAfterPayout) = _reserveFeeOnNextGain(true);
        assertEq(reserveFeeControl, fee * 0.1e18 / 1e18, "control: the gain pays the 10% reserve fee");
        assertEq(reserveFeeAfterPayout, reserveFeeControl, "payout preserves reserve fee on new gain");

        console.log("underwriter fee paid out", fee);
        console.log("reserve fee on the next gain, no payout", reserveFeeControl);
        console.log("reserve fee on the next gain, after payout", reserveFeeAfterPayout);
    }
}

contract UnderwriterFeePayoutSkipsWatermarkAccountingTest is UnderwriterFeePayoutSkipsWatermarkTests {
    function _deployAccounting() internal override returns (address a) {
        a = address(new ERC1967Proxy(address(new Accounting(18)), abi.encodeWithSelector(
            Accounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
        )));
    }
}

contract UnderwriterFeePayoutSkipsWatermarkDiscreteTest is UnderwriterFeePayoutSkipsWatermarkTests {
    function _deployAccounting() internal override returns (address a) {
        a = address(new ERC1967Proxy(address(new DiscreteAccounting(18, false)), abi.encodeWithSelector(
            DiscreteAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
        )));
    }
}

contract UnderwriterFeePayoutSkipsWatermarkDYSTest is UnderwriterFeePayoutSkipsWatermarkTests {
    function _deployAccounting() internal override returns (address a) {
        a = address(new ERC1967Proxy(address(new DYSAccounting(18, false, false, false, false, false)), abi.encodeWithSelector(
            DYSAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
        )));
    }
}

contract UnderwriterFeePayoutSkipsWatermarkMTMTest is UnderwriterFeePayoutSkipsWatermarkTests {
    function _deployAccounting() internal override returns (address a) {
        a = address(new ERC1967Proxy(address(new MTMAccounting(18, false, false, false, false, false, false)), abi.encodeWithSelector(
            MTMAccounting.initialize.selector, address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(this))
        )));
    }
}
