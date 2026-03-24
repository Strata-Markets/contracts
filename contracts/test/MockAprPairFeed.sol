// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAprPairFeed } from "../tranches/interfaces/IAprPairFeed.sol";

contract MockAprPairFeed is IAprPairFeed {
    uint8 public constant decimals = 12;
    string public constant description = "Mock Apr Feed";

    TRound internal round;

    function updateRoundData(int64 newAprTarget, int64 newAprBase, uint64 timestamp) external {
        round = TRound({
            aprTarget: newAprTarget,
            aprBase: newAprBase,
            updatedAt: timestamp,
            answeredInRound: round.answeredInRound + 1
        });
    }

    function getRoundData(uint64) external view returns (TRound memory) {
        return round;
    }

    function latestRoundData() external view returns (TRound memory) {
        return round;
    }
}
