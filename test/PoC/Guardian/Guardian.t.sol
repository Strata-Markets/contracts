// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { stdError } from "forge-std/StdError.sol";
import "./AccessControlManagerGrantCall.sol";
import "./AccountingOnAprChangedSandwich.sol";
import "./AccountingRetroactiveAPR.sol";
import "./AccountingRiskLag.sol";
import "./AccountingRiskDoS.sol";
import "./JrtSupplyRunaway.sol";
import "./ReserveWithdrawalUnitMismatch.sol";
import "./TrancheMaxMint.sol";
import "./WithdrawGriefingDoS.sol";

import "@openzeppelin/contracts/access/IAccessControl.sol";

contract GuardianPoCsTest is Test {

    function testReserveWithdrawalUnitMismatchTest_testReserveWithdrawalShareMismatch() public {
        ReserveWithdrawalUnitMismatchTest reserveWithdrawalUnitMismatchTest = new ReserveWithdrawalUnitMismatchTest();
        reserveWithdrawalUnitMismatchTest.setUp();
        // Fixed: reduceReserve now converts the USDe amount to shares (sUSDe.convertToShares, floor), so the
        // payout is no longer above the deducted USDe and the PoC's overpayment log (usdePayout - reserveUSDe) underflows
        vm.expectRevert(stdError.arithmeticError);
        reserveWithdrawalUnitMismatchTest.pocReserveWithdrawalShareMismatch();
    }

    function testJrtSupplyRunawayTest_test_poc() public {
        JrtSupplyRunawayTest jrtSupplyRunawayTest = new JrtSupplyRunawayTest();
        jrtSupplyRunawayTest.setUp();
        vm.expectRevert(bytes("(PoC) JRT deposit is still enabled"));
        jrtSupplyRunawayTest.pocJrtSupplyRunawayDueToTinyPrice();
    }

    function testWithdrawGriefingDoS_test_poc() public {
        WithdrawGriefingDoS withdrawGriefingDoS = new WithdrawGriefingDoS();
        withdrawGriefingDoS.setUp();
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            0xa959355654849CbEAbBf65235f8235833b9e031D,
            0x97d8f58e0f008a842799f9fb6a4e6212ac93db0249409467f149ba102924e880
        ));
        withdrawGriefingDoS.poc();
    }

    function testAccountingOnAprChangedSandwichTest_testOnAprChangedCanBeSandwiched() public {
        AccountingOnAprChangedSandwichTest accountingOnAprChangedSandwichTest = new AccountingOnAprChangedSandwichTest();
        accountingOnAprChangedSandwichTest.setUp();
        vm.expectRevert(bytes("APR must stay sticky"));
        accountingOnAprChangedSandwichTest.pocOnAprChangedCanBeSandwiched();
    }

    function testAccessControlManagerGrantCallTest_testGrantCallFallbackSelectorGivesDefaultAdmin() public {
        AccessControlManagerGrantCallTest accessControlManagerGrantCallTest = new AccessControlManagerGrantCallTest();
        accessControlManagerGrantCallTest.setUp();
        vm.expectRevert(bytes("StrictPermissionOnly"));
        accessControlManagerGrantCallTest.pocGrantCallFallbackSelectorGivesDefaultAdmin();
    }

    function testAccountingRiskLag_testRiskUsesPreSplitBalances() public {
        AccountingRiskLagTest accountingRiskLagTest = new AccountingRiskLagTest();
        accountingRiskLagTest.setUp();
        // Fixed: risk now uses post-deposit balances, so the PoC's own lag assertion fails
        vm.expectRevert(bytes("risk used should match pre-deposit ratio"));
        accountingRiskLagTest.pocRiskUsesPreSplitBalances();
    }

    function testTrancheMaxMintTest_testJrtMaxMintRevertsWhenSharePriceBelowOne() public {
        TrancheMaxMintTest trancheMaxMintTest = new TrancheMaxMintTest();
        trancheMaxMintTest.setUp();
        //vm.expectRevert();
        trancheMaxMintTest.testJrtMaxMintRevertsWhenSharePriceBelowOne();
    }

    function testAccountingRiskDoSTest_testRiskOverOneHundredPercentRevertsUpdate() public {
        AccountingRiskDoSTest accountingRiskDoSTest = new AccountingRiskDoSTest();
        accountingRiskDoSTest.setUp();
        // Fixed: setRiskParameters rejects max risk above 100% at config time
        vm.expectRevert(">100%");
        accountingRiskDoSTest.pocRiskOverOneHundredPercentRevertsUpdate();
    }

    function testAccountingRetroactiveAPR_testRiskOverOneHundredPercentRevertsUpdate() public {
        AccountingRetroactiveAPR accountingRetroactiveAPR = new AccountingRetroactiveAPR();
        accountingRetroactiveAPR.setUp();
        vm.expectRevert("index accrues at new apr");
        accountingRetroactiveAPR.pocRetroactiveAPRJump();
    }

}
