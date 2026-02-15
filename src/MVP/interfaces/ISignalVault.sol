// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface ISignalVault {
    struct StakeData {
        uint256 stakeBalance;
        uint256 winStreak;
    }

    function UP_TOKEN() external view returns (address);
    function DOWN_TOKEN() external view returns (address);

    function vaultDirection() external view returns (uint256);
    function last_settlementPrice() external view returns (uint256);

    function stakes(address user) external view returns (StakeData memory);
    function ORACLE() external view returns (address);

    function nextSettlement() external view returns (uint256);
    function settleEpoch() external;
}
