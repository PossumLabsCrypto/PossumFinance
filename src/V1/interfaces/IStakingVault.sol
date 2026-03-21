// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface IStakingVault {
    // ============================================
    // ==                STORAGE                 ==
    // ============================================
    function REWARD_POOL() external view returns (address);
    function totalStaked() external view returns (uint256);
    function stakes(address _user) external view returns (uint256);

    // ============================================
    // ==             CORE FUNCTIONS             ==
    // ============================================
    function stake(uint256 _amount) external;
    function unstake(uint256 _amount) external;
    function compound() external;

    // ============================================
    // ==           UTILITY FUNCTIONS            ==
    // ============================================
    function sweep(address _token) external;
}
