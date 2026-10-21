// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ICDOComponent } from "./ICDOComponent.sol";
import { IAprPairFeedListener } from "./IAprPairFeed.sol";
import {IInsurancePool} from "../symbiotic/interfaces/IInsurancePool.sol";

interface IAccounting is ICDOComponent, IAprPairFeedListener {

    event InsuranceClaimWrittenDown(uint256 amount);

    event ValuationPriceChanged(uint256 valuationPrice);
    event ValuationGracePeriodChanged(uint64 period);
    event Reconciled(
        uint256 epochStart,
        uint256 epochEnd,
        uint256 navT0,
        uint256 navT1,
        uint256 jrtNav,
        uint256 srtNav,
        uint256 reserveNav
    );

    function updateAccounting () external;
    /// @dev CDO checkpoints first; accounting sizes the write-down against funding within the loss limit.
    function writeDownInsuranceClaim(uint256 fundedBase, uint256 maxPrincipalLoss) external returns (uint256 amount);
    function updateBalanceFlow (
        uint256 jrtAssetsIn,
        uint256 jrtAssetsOut,
        uint256 srtAssetsIn,
        uint256 srtAssetsOut
    ) external returns (uint256 insuranceBaseOut);

    function totalAssetsT0() external view returns (uint256 jrtNavT0, uint256 srtNavT0, uint256 reserveNavT0);
    function totalAssets () external view returns (uint256 jrtNavT1, uint256 srtNavT1, uint256 reserveNavT1);
    function totalAssetsSettled () external view returns (uint256 jrtNavSettled, uint256 srtNavSettled, uint256 reserveNavSettled);
    function totalAssetsLiveAndSettled() external view returns (
        uint256 jrtNavLive,
        uint256 srtNavLive,
        uint256 jrtNavSettled,
        uint256 srtNavSettled
    );
    function totalReserve () external view returns (uint256);
    function totalUnderwriterFeeNav () external view returns (uint256);
    function valuationPrice () external view returns (uint128);
    function reduceReserve (uint256 amount, uint256 jrtAmountIn, uint256 srtAmountIn) external;
    function reduceUnderwriterFee (uint256 amount) external;
    function accrueFee(bool isJrt, uint256 amount) external;

    function maxWithdraw(bool isJrt) external view returns (uint256);
    function maxWithdraw(bool isJrt, bool ownerIsSharesCooldown) external view returns (uint256);
    function maxDeposit(bool isJrt) external view returns (uint256);

    function setValuationPrice(uint128 valuationPrice) external returns (bool valuationLossEntered);
    function setInsurancePool(IInsurancePool pool) external;
    function setUnderwriterFeeBps(uint256 fee) external;
}
