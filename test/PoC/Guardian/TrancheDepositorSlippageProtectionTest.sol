// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { StrataProtocolDeploymentBase } from "./StrataProtocolDeploymentBase.sol";
import { TrancheDepositor } from "../../../contracts/tranches/TrancheDepositor.sol";
import { IMetaVault } from "../../../contracts/tranches/interfaces/IMetaVault.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TrancheDepositorSlippageProtectionTest is StrataProtocolDeploymentBase {

    TrancheDepositor internal trancheDepositor;

    function testSwapDepositRevertsOnZeroSlippageProtectionAndExpiredDeadline() public {
        _deployStrataStack();

        vm.startPrank(owner);
        trancheDepositor = TrancheDepositor(
            address(
                new ERC1967Proxy(
                    address(new TrancheDepositor()),
                    abi.encodeWithSelector(TrancheDepositor.initialize.selector, owner, address(acm))
                )
            )
        );
        acm.grantRole(trancheDepositor.DEPOSITOR_CONFIG_ROLE(), owner);
        trancheDepositor.addCdo(cdo);

        address fakeRouter = makeAddr("uniswapRouter");
        address usdt = address(0xdAC17F958D2ee523a2206206994597C13D831ec7);
        trancheDepositor.addSwapInfo(usdt, TrancheDepositor.TAutoSwap(fakeRouter, 100, 900));
        vm.stopPrank();

        address depositorUser = makeAddr("depositorUser");
        deal(usdt, depositorUser, 1_000e6);

        vm.startPrank(depositorUser);
        SafeERC20.forceApprove(IERC20(usdt), address(trancheDepositor), type(uint256).max);

        // 1. Must revert with ZeroSlippageProtection when swapAmountOutMinimum is 0
        TrancheDepositor.TDepositParams memory zeroSlippageParams = TrancheDepositor.TDepositParams({
            swapDeadline: block.timestamp + 1 hours,
            swapAmountOutMinimum: 0,
            swapTokenOut: USDE,
            minShares: 0
        });

        vm.expectRevert(TrancheDepositor.ZeroSlippageProtection.selector);
        trancheDepositor.deposit(IMetaVault(address(jrtVault)), IERC20(usdt), 10e6, depositorUser, zeroSlippageParams);

        // 2. Must revert with InvalidDeadline when swapDeadline is expired or 0
        TrancheDepositor.TDepositParams memory zeroDeadlineParams = TrancheDepositor.TDepositParams({
            swapDeadline: 0,
            swapAmountOutMinimum: 9e18,
            swapTokenOut: USDE,
            minShares: 0
        });

        vm.expectRevert(TrancheDepositor.InvalidDeadline.selector);
        trancheDepositor.deposit(IMetaVault(address(jrtVault)), IERC20(usdt), 10e6, depositorUser, zeroDeadlineParams);

        vm.stopPrank();
    }
}
