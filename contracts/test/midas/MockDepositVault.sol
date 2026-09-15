// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MockMToken} from "./MockMToken.sol";
import {MockOracle} from "./MockOracle.sol";

/**
 * @title MockDepositVault
 * @dev Mock Midas DepositVault that mints mToken on depositInstant
 */
contract MockDepositVault {
    MockMToken public mToken;

    MockOracle public oracle;

    constructor(MockMToken _mToken, MockOracle _oracle) {
        mToken = _mToken;
        oracle = _oracle;
    }

    function setRate(uint256 _rate) external {
        oracle.setRoundData(0, int256(_rate) * 10**8 / 10**18, 0);
    }
    function rate () public view returns (uint256) {
        int256 answer;
        (, answer, , ,) = oracle.latestRoundData();
        return uint256(answer) * 10**18 / (10**8);
    }

    function depositInstant(
        address tokenIn,
        uint256 amountTokenBase18,
        uint256 /* minReceiveAmount */,
        bytes32 /* referrerId */
    ) external {
        uint256 decimals = IERC20Metadata(tokenIn).decimals();

        uint256 amountToken = amountTokenBase18 / (10 ** (18 - decimals));
        // Transfer tokenIn from caller
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountToken);
        // Mint mToken to caller based on rate
        uint256 mTokenAmount = (amountTokenBase18 * 1e18) / rate();
        mToken.mint(msg.sender, mTokenAmount);
    }
}
