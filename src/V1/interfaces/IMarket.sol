// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface IMarket {
    // ============================================
    // ==                STORAGE                 ==
    // ============================================
    struct PredictionData {
        uint256 up1_down2;
        uint256 forSettlementTime;
    }

    function ORACLE() external view returns (address);
    function STAKING_VAULT() external view returns (address);
    function REWARD_POOL() external view returns (address);
    function EPOCH_DURATION() external view returns (uint256);

    function nextSettlement() external view returns (uint256);
    function activeEpochID() external view returns (uint256);
    function last_settlementPrice() external view returns (uint256);

    function results(uint256 _epochID) external view returns (uint256);

    function userWinStreaks(address _user) external view returns (uint256);
    function userActivityStreaks(address _user) external view returns (uint256);

    function userLastParticipated(address _user) external view returns (uint256);
    function userLastClaimed(address _user) external view returns (uint256);

    function predictions(uint256 _epochID, address _user) external view returns (PredictionData memory);

    // ============================================
    // ==               FUNCTIONS                ==
    // ============================================
    function castPrediction(uint256 _up1_down2) external;
    function settleEpoch() external;
}
