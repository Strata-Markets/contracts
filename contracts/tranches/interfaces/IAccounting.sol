// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ICDOComponent } from "./ICDOComponent.sol";
import { IAprPairFeedListener } from "./IAprPairFeed.sol";

interface IAccounting is ICDOComponent, IAprPairFeedListener {

    event ValuationPriceChanged(uint256 valuationPrice);
    event ValuationGracePeriodChanged(uint64 period);

    function updateAccounting () external;
    function updateBalanceFlow (
        uint256 jrtAssetsIn,
        uint256 jrtAssetsOut,
        uint256 srtAssetsIn,
        uint256 srtAssetsOut
    ) external;

    function totalAssetsT0() external view returns (uint256 jrtNavT0, uint256 srtNavT0, uint256 reserveNavT0);
    function totalAssets (uint256 navT1) external view returns (uint256 jrtNavT1, uint256 srtNavT1, uint256 reserveNavT1);
    function totalAssets () external view returns (uint256 jrtNavT1, uint256 srtNavT1, uint256 reserveNavT1);
    function totalAssetsUnprojected () external view returns (uint256 jrtNavUnprojected, uint256 srtNavUnprojected, uint256 reserveNavUnprojected);
    function totalReserve () external view returns (uint256);
    function valuationPrice () external view returns (uint128);
    function reduceReserve (uint256 amount, uint256 jrtAmountIn, uint256 srtAmountIn) external;
    function accrueFee(bool isJrt, uint256 amount) external;

    function maxWithdraw(bool isJrt) external view returns (uint256);
    function maxWithdraw(bool isJrt, bool ownerIsSharesCooldown) external view returns (uint256);
    function maxDeposit(bool isJrt) external view returns (uint256);

    function setValuationPrice(uint128 valuationPrice) external returns (bool valuationLossEntered);
}
