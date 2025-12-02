// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

contract SequencerOutage {
    constructor() {}

    // ============================================
    // ==                STORAGE                 ==
    // ============================================
    uint8 _decimals = 8;

    // ============================================
    // ==               FUNCTIONS                ==
    // ============================================
    function latestRoundData()
        external
        pure
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = 100;
        answer = 1;
        startedAt = 0;
        updatedAt = 0;
        answeredInRound = 100;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}
