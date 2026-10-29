// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessControlManager} from "../../../contracts/governance/AccessControlManager.sol";
import {IInsurancePool} from "../../../contracts/tranches/symbiotic/interfaces/IInsurancePool.sol";
import {MockInsurancePool} from "../../symbiotic/mocks/MockInsurancePool.sol";
import {
    IProRataAccounting,
    AccountingRedemptionHarness,
    DiscreteAccountingRedemptionHarness,
    DYSAccountingRedemptionHarness,
    MTMRedemptionHarness
} from "../../symbiotic/ProRataRedemption.t.sol";

interface ISelfFundAccounting is IProRataAccounting {
    function setPaidProjection(uint256 amount) external;
    function updateAccounting() external;
    function accrueFee(bool isJrt, uint256 amount) external;
    function setFeeRetentionBps(uint256 junior, uint256 senior) external;
}

/// @notice Exercise actual fees, reconciliations and valuation updates against all four variants.
contract SelfFundDysHarness is DYSAccountingRedemptionHarness {
    constructor() DYSAccountingRedemptionHarness(false) {}

    function setPaidProjection(uint256 amount) external {
        srtPaidProjected = amount;
    }
}

contract SelfFundMtmHarness is MTMRedemptionHarness {
    constructor() MTMRedemptionHarness(false) {}

    function setPaidProjection(uint256 amount) external {
        srtPaidProjected = amount;
    }
}

contract SelfFundWriteDownTest is Test {
    ISelfFundAccounting a;
    MockInsurancePool pool;
    uint256 strategyNav;

    function totalStrategyAssets() external view returns (uint256) {
        return strategyNav;
    }

    function totalStrategyAssets(uint256, uint256) external view returns (uint256) {
        return strategyNav;
    }

    function totalStrategyAssetsSnapshot(uint256, uint256)
        external
        view
        returns (uint256, uint256, uint256, uint256)
    {
        return (strategyNav, block.timestamp, strategyNav, block.timestamp);
    }

    function _deploy(uint256 variant) internal {
        strategyNav = 0;
        address implementation;
        if (variant == 0) implementation = address(new AccountingRedemptionHarness());
        else if (variant == 1) implementation = address(new DiscreteAccountingRedemptionHarness());
        else if (variant == 2) implementation = address(new SelfFundDysHarness());
        else implementation = address(new SelfFundMtmHarness());
        AccessControlManager acm = new AccessControlManager(address(this));
        a = ISelfFundAccounting(
            address(
                new ERC1967Proxy(
                    implementation,
                    abi.encodeWithSignature(
                        "initialize(address,address,address,address)",
                        address(this),
                        address(acm),
                        address(this),
                        address(0)
                    )
                )
            )
        );
        pool = new MockInsurancePool();
        a.setInsurancePool(IInsurancePool(address(pool)));
        a.setFeeRetentionBps(0, 0);
    }

    function _seed(
        uint256 junior,
        uint256 senior,
        uint256 claim,
        uint256 credit,
        uint256 fund,
        uint256 projection
    ) internal {
        a.seed(junior, senior, claim, credit, fund, fund, projection, 0.5e18);
        strategyNav = junior + senior - claim;
    }

    function _assertFunds(uint256 expected) internal view {
        assertEq(a.srtFundedGrossNav(), expected, "self-funded principal");
        assertEq(a.srtFundNav(), expected, "self-fund deduction");
    }

    function test_realizedLossThenDeeperDepeg() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            _seed(0, 0, 0, 0, 0, 0);
            strategyNav = 100e18;
            a.updateBalanceFlow(0, 0, 100e18, 0);
            _assertFunds(100e18);
            strategyNav = 80e18;
            a.updateAccounting();
            assertEq(a.srtBaseNav(), 80e18);
            _assertFunds(80e18);
            a.updateAccounting();
            _assertFunds(80e18);
            pool.setCapacity(1000e18);
            a.setValuationPrice(0.4e18);
            assertEq(a.insuranceAmount(), 40e18);
            assertEq(a.srtBaseNav(), 120e18);
            _assertFunds(80e18);
        }
    }

    function test_reservedFeeScalesButRetainedFeeDoesNot() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            _seed(0, 100e18, 0, 0, 100e18, 0);
            a.setFeeRetentionBps(0, 0.5e18);
            a.accrueFee(false, 20e18);
            assertEq(a.reserveNav(), 10e18);
            assertEq(a.srtBaseNav(), 90e18);
            _assertFunds(90e18);
            a.setFeeRetentionBps(0, 1e18);
            a.accrueFee(false, 20e18);
            _assertFunds(90e18);
        }
    }

    function test_juniorFeeDoesNotScaleSeniorFunds() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            _seed(100e18, 100e18, 0, 0, 100e18, 0);
            a.accrueFee(true, 10e18);
            _assertFunds(100e18);
        }
    }

    function test_juniorAndInsuranceAbsorbedLossesDoNotScale() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            _seed(100e18, 100e18, 0, 0, 100e18, 0);
            strategyNav -= 20e18;
            a.updateAccounting();
            _assertFunds(100e18);
            _seed(0, 100e18, 0, 0, 100e18, 0);
            pool.setCapacity(1000e18);
            strategyNav = 80e18;
            a.updateAccounting();
            assertEq(a.insuranceAmount(), 20e18);
            assertEq(a.srtBaseNav(), 100e18);
            _assertFunds(100e18);
        }
    }

    function test_existingValuationCreditIsExcludedFromLossRatio() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            _seed(0, 400e18, 100e18, 100e18, 200e18, 0);
            strategyNav -= 100e18;
            a.updateAccounting();
            // DYS/MTM also resize excess valuation credit after the loss. Check principal separately.
            assertEq(a.srtBaseNav() - a.srtInsuranceFundNav(), 200e18);
            _assertFunds(uint256(200e18) * 200 / 300);
        }
    }

    function test_claimCancellationDoesNotWriteDownSelfFundedPrincipal() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            _seed(0, 400e18, 100e18, 100e18, 200e18, 0);
            a.setValuationPrice(0.7e18);
            assertLt(a.srtInsuranceFundNav(), 100e18);
            assertEq(a.srtFundedGrossNav(), 200e18);
            assertEq(a.srtFundNav(), 200e18, "entry self-funding survives claim cancellation");
            a.setValuationPrice(1e18);
            _assertFunds(0);
        }
    }

    function test_reconciliationUsesLiveNavWhenProjectionReverses() public {
        for (uint256 i = 2; i < 4; i++) {
            _deploy(i);
            _seed(100e18, 120e18, 0, 0, 100e18, 20e18);
            strategyNav += 1e18;
            a.updateAccounting();
            assertLt(a.srtBaseNav(), 120e18);
            assertGe(a.srtBaseNav(), 100e18);
            _assertFunds(uint256(100e18) * a.srtBaseNav() / 120e18);
        }
    }

    function test_realizedLossUsesLiveNavRatio() public {
        for (uint256 i = 2; i < 4; i++) {
            _deploy(i);
            _seed(0, 120e18, 0, 0, 100e18, 20e18);
            strategyNav = 80e18;
            a.updateAccounting();
            assertEq(a.srtBaseNav(), 79e18);
            _assertFunds(uint256(100e18) * 79 / 120);
        }
    }

    function test_feeUsesEffectiveNavIncludingRemainingProjection() public {
        for (uint256 i = 2; i < 4; i++) {
            _deploy(i);
            _seed(100e18, 120e18, 0, 0, 100e18, 20e18);
            a.accrueFee(false, 10e18);
            // Effective Senior NAV is 120 / 0.5 - 100 = 140; the fee consumes 10 / 140.
            _assertFunds(100e18 - uint256(100e18) * 10 / 140);
            assertEq(a.reserveNav(), 10e18);
        }
    }

    function test_sequentialLossesAndRecoveryDoNotRestoreWrittenDownFunds() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            _seed(0, 100e18, 0, 0, 100e18, 0);
            strategyNav = 80e18;
            a.updateAccounting();
            strategyNav = 60e18;
            a.updateAccounting();
            _assertFunds(60e18);
            strategyNav = 100e18;
            a.updateAccounting();
            _assertFunds(60e18);
        }
    }

    function testFuzz_lossScalesBothTrackers(uint8 variant, uint96 capital, uint96 lossInput)
        public
    {
        _deploy(variant % 4);
        uint256 principal = bound(uint256(capital), 2e18, 1e24);
        uint256 loss = bound(uint256(lossInput), 1, principal - 1e18);
        uint256 funded = principal / 3;
        _seed(0, principal, 0, 0, funded, 0);
        strategyNav = principal - loss;
        a.updateAccounting();
        _assertFunds(funded * (principal - loss) / principal);
    }

    function test_fullPrincipalLossClearsBothTrackers() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            _seed(0, 100e18, 0, 0, 100e18, 0);
            strategyNav = 0;
            a.updateAccounting();
            assertEq(a.srtBaseNav(), 0);
            _assertFunds(0);
        }
    }

    function test_lossScalesRetainedFundAfterPartialRecovery() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            _seed(0, 100e18, 0, 0, 100e18, 0);
            a.setValuationPrice(0.7e18);
            uint256 fundBefore = a.srtFundNav();
            assertEq(fundBefore, 100e18, "partial recovery retains entry self-funding");
            strategyNav = 80e18;
            a.updateAccounting();
            assertEq(a.srtFundedGrossNav(), 80e18);
            assertEq(a.srtFundNav(), fundBefore * 80 / 100);
        }
    }

    function test_reconciliationUsesStoredNavWithPaidProjection() public {
        for (uint256 i = 2; i < 4; i++) {
            _deploy(i);
            _seed(100e18, 120e18, 0, 0, 100e18, 30e18);
            a.setPaidProjection(10e18); // only 20 of projection remains embedded in Senior NAV
            strategyNav += 1e18;
            a.updateAccounting();
            // These fixtures charge paid projection to Senior at reconciliation.
            assertLt(a.srtBaseNav(), 100e18);
            assertGt(a.srtBaseNav(), 90e18);
            _assertFunds(uint256(100e18) * a.srtBaseNav() / 120e18);
        }
    }

    function test_partialInsuranceScalesOnlyUncoveredSeniorLoss() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            _seed(0, 100e18, 0, 0, 100e18, 0);
            pool.setCapacity(10e18);
            strategyNav = 80e18;
            a.updateAccounting();
            assertEq(a.insuranceAmount(), 10e18);
            assertEq(a.srtBaseNav(), 90e18);
            _assertFunds(90e18);
        }
    }

    function test_reserveAbsorbedLossDoesNotScaleSeniorFunds() public {
        for (uint256 i; i < 4; i++) {
            _deploy(i);
            _seed(20e18, 100e18, 0, 0, 100e18, 0);
            a.accrueFee(true, 10e18);
            strategyNav -= 15e18;
            a.updateAccounting();
            assertLt(a.reserveNav(), 10e18);
            assertEq(a.srtBaseNav(), 100e18);
            _assertFunds(100e18);
        }
    }
}
