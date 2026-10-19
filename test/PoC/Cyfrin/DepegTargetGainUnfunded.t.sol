// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UD60x18 } from "@prb/math/src/UD60x18.sol";

import { Accounting } from "../../../contracts/tranches/Accounting.sol";
import { IStrataCDO } from "../../../contracts/tranches/interfaces/IStrataCDO.sol";
import { IAprPairFeed } from "../../../contracts/tranches/interfaces/IAprPairFeed.sol";
import { AccessControlManager } from "../../../contracts/governance/AccessControlManager.sol";
import { MockInsurancePool } from "../../symbiotic/mocks/MockInsurancePool.sol";

/// @dev APR feed: Senior target defaults to 10%, base APR is 0.
contract TargetAprFeed10 {
    int64 public target = 100_000_000_000;

    function disableTarget() external { target = 0; }

    function decimals() external pure returns (uint8) { return 12; }

    function latestRoundData() external view returns (IAprPairFeed.TRound memory) {
        return IAprPairFeed.TRound({
            aprTarget: target, // SD7x12
            aprBase: 0,
            updatedAt: uint64(block.timestamp),
            answeredInRound: 1
        });
    }
}

/// @notice Regression adapted from the auditor target-gain PoC.
/// @dev Senior APR must be capped to what Junior can protect without new insurance claims.
///      Uses real Accounting with a mock CDO, strategy and insurance pool; no real vault transfers.
contract DepegTargetGainUnfundedTest is Test {
    Accounting accounting;
    MockInsurancePool pool;
    uint256 mockStrategyTvl;

    uint256 constant CAPACITY = 1_000_000e18;
    uint128 constant PRICE = 0.4e18;

    function totalStrategyAssets() external view returns (uint256) {
        return mockStrategyTvl;
    }

    function _deploy(uint256 jrtDeposit, uint128 price) internal {
        mockStrategyTvl = 0; // fresh market: nothing in the strategy before the first deposit
        AccessControlManager acm = new AccessControlManager(address(this));
        accounting = Accounting(address(new ERC1967Proxy(
            address(new Accounting(18)),
            abi.encodeWithSelector(
                Accounting.initialize.selector,
                address(this), address(acm), IStrataCDO(address(this)), IAprPairFeed(address(0))
            )
        )));
        acm.grantRole(accounting.UPDATER_STRAT_CONFIG_ROLE(), address(this));
        pool = new MockInsurancePool();
        pool.setCapacity(CAPACITY);
        accounting.setInsurancePool(pool);
        accounting.setReserveBps(0.1e18);
        accounting.setUnderwriterFeeBps(0.1e18);

        mockStrategyTvl = jrtDeposit + 1000e18;
        accounting.updateBalanceFlow(jrtDeposit, 0, 1000e18, 0);
        accounting.setRiskParameters(UD60x18.wrap(0.5e18), UD60x18.wrap(0), UD60x18.wrap(1e18));
        accounting.setAprPairFeed(IAprPairFeed(address(new TargetAprFeed10())));

        if (price < 1e18) accounting.setValuationPrice(price);
    }

    function _accrueOneYear() internal {
        vm.warp(vm.getBlockTimestamp() + 365 days);
        accounting.updateAccounting();
    }

    function _slashed() internal view returns (uint256) {
        return CAPACITY - pool.capacity();
    }

    function _effective() internal view returns (uint256 jrt, uint256 srt) {
        (jrt, srt,) = accounting.totalAssets();
    }

    /// @dev Next valuation push: a 1 wei price change, which `AccountablePushOracle` accepts.
    function _nextPush() internal returns (uint256 claimAdded) {
        uint256 claimBefore = accounting.insuranceAmount();
        accounting.setValuationPrice(PRICE - 1);
        claimAdded = accounting.insuranceAmount() - claimBefore;
    }

    function _checkZeroAprBeforeDepeg(uint256 juniorDeposit, uint256 expectedClaim) internal {
        _deploy(juniorDeposit, 1e18);
        TargetAprFeed10 zeroFeed = new TargetAprFeed10();
        zeroFeed.disableTarget();
        // The setter checkpoints the old APR at par, then activates the zero target APR.
        accounting.setAprPairFeed(IAprPairFeed(address(zeroFeed)));
        accounting.setValuationPrice(PRICE);
        assertEq(accounting.insuranceAmount(), expectedClaim);
        assertEq(_slashed(), expectedClaim);
        uint256 seniorBefore = accounting.srtBaseNav();
        uint256 juniorBefore = accounting.jrtBaseNav();
        uint256 feesBefore = accounting.underwriterFeeNav();

        _accrueOneYear();
        assertEq(accounting.srtBaseNav(), seniorBefore, "no additional Senior gain or insurance credit");
        assertEq(accounting.jrtBaseNav(), juniorBefore, "no APR charged to Junior");
        assertEq(accounting.underwriterFeeNav(), feesBefore, "no APR-related fee");
        assertEq(accounting.insuranceAmount(), expectedClaim, "no APR-related claim");
        assertEq(_slashed(), expectedClaim, "no additional slash during accrual");

        // Repeating the same valuation must not create any additional coverage demand either.
        accounting.setValuationPrice(PRICE);
        assertEq(accounting.insuranceAmount(), expectedClaim);
        assertEq(_slashed(), expectedClaim);
    }

    function test_zeroTargetAprBeforeDepeg_partialJuniorHeadroom() public {
        _checkZeroAprBeforeDepeg(1611e18, 0);
    }

    function test_zeroTargetAprBeforeDepeg_noJuniorHeadroom() public {
        _checkZeroAprBeforeDepeg(1000e18, 501e18);
    }

    /// Intended rule, at par: with Junior at its floor, Senior earns no target gain.
    function test_control_atPar_noJuniorNoGain() public {
        _deploy(1e18, 1e18); // Junior holds only its 1-token floor
        _accrueOneYear();
        (, uint256 srt) = _effective();
        assertEq(srt, 1000e18, "no Junior headroom: no Senior gain");
        assertEq(_slashed(), 0);
    }

    /// Junior has 110 free tokens, enough to protect 44 gross gain (41.8 after fees).
    function test_partialHeadroomCapsGainWithoutSlashing() public {
        _deploy(1611e18, PRICE);
        (uint256 jrtBefore, uint256 srtBefore) = _effective();
        assertEq(jrtBefore, 111e18, "Junior effective: 1 floor + 110 of free headroom");
        assertEq(srtBefore, 2500e18);
        assertEq(_slashed(), 0, "Junior alone covers the de-peg");

        uint256 srtBaseBefore = accounting.srtBaseNav();
        _accrueOneYear();
        (uint256 jrtAfter, uint256 srtAfter) = _effective();
        assertEq(accounting.srtBaseNav() - accounting.srtInsuranceFundNav() - srtBaseBefore, 41.8e18, "gain capped before the fee");
        assertEq(jrtAfter, 4.3e18, "conservative gross cap leaves fee-related headroom");
        uint256 protectedNeed = uint256(1041.8e18) * 1e18 / PRICE;
        assertEq(protectedNeed, 2604.5e18, "funded principal protected at $1");
        assertEq(protectedNeed, srtAfter, "shortfall covered during the accrual update");

        uint256 claimAdded = accounting.insuranceAmount();
        assertEq(claimAdded, 0, "no APR-related claim");
        assertEq(_slashed(), 0);

        emit log_named_decimal_uint("gain credited to Senior (base)", 41.8e18, 18);
        emit log_named_decimal_uint("gain Junior could protect (base)", 44e18, 18);
        emit log_named_decimal_uint("claim booked during accrual (base)", claimAdded, 18);
    }

    /// Junior has no effective headroom, so APR accrual must stop.
    function test_noHeadroomAccruesNoGainOrClaim() public {
        _deploy(1000e18, PRICE);
        (uint256 jrtBefore, uint256 srtBefore) = _effective();
        assertEq(jrtBefore, 1e18, "Junior effective at its floor: no free headroom");
        assertEq(accounting.jrtBaseNav(), 1000e18, "but its stored NAV still reads 1000");

        _accrueOneYear();
        (, uint256 srtAfter) = _effective();
        assertEq(accounting.jrtBaseNav(), 1000e18, "no gain charged to pledged Junior NAV");
        assertEq(srtAfter, srtBefore, "no unfunded Senior gain");

        uint256 claimAdded = accounting.insuranceAmount() - 501e18;
        assertEq(claimAdded, 0, "no APR-related claim");

        emit log_named_decimal_uint("claim booked during accrual (base)", claimAdded, 18);
    }

    /// Re-peg after capped accrual has no APR-related slash to unwind.
    function test_repegAfterCappedAccrualCreatesNoClaim() public {
        _deploy(1611e18, PRICE);
        _accrueOneYear();
        _nextPush();
        uint256 slashed = _slashed();
        assertLe(slashed, 10, "only rounding from the one-wei price drop");

        accounting.setValuationPrice(1e18);
        assertEq(accounting.insuranceAmount(), 0, "claim cancelled at re-peg");
        assertEq(_slashed(), slashed, "collateral stays slashed");
    }
}
