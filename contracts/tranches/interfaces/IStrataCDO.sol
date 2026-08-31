// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IStrategy } from "./IStrategy.sol";
import {IAccounting} from "./IAccounting.sol";
import { ITranche } from "./ITranche.sol";
import { ISharesCooldown } from "./cooldown/ISharesCooldown.sol";

interface IStrataCDO {

    enum TExitMode {
        Dynamic,
        Fee,
        AssetsLock,
        SharesLock,
        ERC4626
    }

    function accounting() external view returns (IAccounting);
    function strategy() external view returns (IStrategy);
    function sharesCooldown() external view returns (ISharesCooldown);

    function totalAssets (address tranche) external view returns (uint256);
    function totalAssetsUnprojected (address tranche) external view returns (uint256);
    function totalStrategyAssets () external view returns (uint256);
    function totalStrategyAssets (uint256 latestNav, uint256 timestamp) external view returns (uint256);
    function updateAccounting () external;
    function updateBalanceFlow () external;

    function deposit (address tranche, address token, uint256 tokenAmount, uint256 baseAssets, bytes memory strategyOptions) external;
    function withdraw (address tranche, address token, uint256 tokenAmount, uint256 baseAssets, address owner, address receiver, bytes memory strategyOptions) external;
    function cooldownShares(
        address tranche,
        address token,
        uint256 shares,
        address sender,
        address receiver,
        uint256 fee,
        uint32 cooldownSeconds,
        bytes memory strategyOptions
    ) external;

    function maxWithdraw(address tranche) external view returns (uint256);
    function maxWithdraw(address tranche, address owner) external view returns (uint256);
    function maxDeposit(address tranche) external view returns (uint256);

    // reverts if neither Jrt nor Srt
    function isJrt (address tranche) external view returns (bool);

    function jrtVault() external view returns (ITranche);
    function srtVault() external view returns (ITranche);

    function accrueFee(address tranche, uint256 assetsFee) external;
    function exitFeeJrt () external view returns (uint256);
    function exitFeeSrt () external view returns (uint256);

    function calculateExitMode (address tranche, address owner) external view returns (TExitMode mode, uint256 feeBps, uint32 coverage);

    function setActionStates (address tranche, bool isDepositEnabled, bool isWithdrawEnabled) external;
    function setValuationPrice (uint128 valuationPrice) external;
}

interface IStrataCDOSetters {
    function setExitFees (uint256 feeJrt, uint256 feeSrt) external;
}
