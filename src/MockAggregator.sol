// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test-only Chainlink AggregatorV3. Never deploy to mainnet.
contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 answer_) external {
        answer = answer_;
        unchecked {
            roundId += 1;
        }
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 ts) external {
        updatedAt = ts;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
