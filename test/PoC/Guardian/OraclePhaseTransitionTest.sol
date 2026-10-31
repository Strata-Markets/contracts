// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";
import { ChainlinkAprProviderLib } from "../../../contracts/tranches/oracles/providers/ChainlinkAprProviderLib.sol";
import { IRoundDataOracle } from "../../../contracts/tranches/oracles/interfaces/IRoundDataOracle.sol";

contract MockPhaseTransitionOracle is IRoundDataOracle {
    uint80 public latestRound;
    int256 public latestAnswer;
    uint256 public latestUpdatedAt;

    bool public shouldRevertLatest;
    bool public shouldRevertGetRound;

    function setLatestRoundData(uint80 _roundId, int256 _answer, uint256 _updatedAt) external {
        latestRound = _roundId;
        latestAnswer = _answer;
        latestUpdatedAt = _updatedAt;
    }

    function setRevertConditions(bool _revertLatest, bool _revertGetRound) external {
        shouldRevertLatest = _revertLatest;
        shouldRevertGetRound = _revertGetRound;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        require(!shouldRevertLatest, "OracleLatestReverted");
        return (latestRound, latestAnswer, latestUpdatedAt, latestUpdatedAt, latestRound);
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        require(!shouldRevertGetRound, "No data present");
        return (_roundId, latestAnswer, latestUpdatedAt, latestUpdatedAt, _roundId);
    }
}

contract OraclePhaseTransitionTest is Test {
    MockPhaseTransitionOracle internal oracle;

    function setUp() public {
        oracle = new MockPhaseTransitionOracle();
    }

    function testPhaseTransitionFirstRoundDoesNotRevert() public {
        // Phase 2, Round 1: roundId = (2 << 64) | 1
        uint80 phase2Round1 = (uint80(2) << 64) | 1;
        oracle.setLatestRoundData(phase2Round1, 100e8, block.timestamp);
        // If oracle.getRoundData((2<<64) | 0) were queried, it would revert with "No data present"
        oracle.setRevertConditions(false, true);

        // ChainlinkAprProviderLib should detect originalRoundId <= 1 and safely return 0 without querying getRoundData
        int64 apr = ChainlinkAprProviderLib.getApr(oracle);
        assertEq(apr, 0);
    }

    function testOracleRevertHandledGracefully() public {
        // If latestRoundData reverts, library must catch and return 0
        oracle.setRevertConditions(true, true);
        int64 apr = ChainlinkAprProviderLib.getApr(oracle);
        assertEq(apr, 0);
    }
}
