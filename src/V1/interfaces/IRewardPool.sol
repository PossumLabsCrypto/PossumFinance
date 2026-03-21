// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface IRewardPool {
    // ============================================
    // ==                STORAGE                 ==
    // ============================================
    function owner() external view returns (address);
    function stakingVault() external view returns (address);

    function totalPoints() external view returns (uint256);

    function userAvailablePoints(address _user) external view returns (uint256);
    function userRedeemedPoints(address _user) external view returns (uint256);

    function activeMarkets(address _market) external view returns (bool);

    // ============================================
    // ==            OWNER FUNCTIONS             ==
    // ============================================
    function setStakingVault(address _stakingVault) external;
    function changeOwner(address _newOwner) external;
    function changeAdmin(address _newAdmin) external;
    function changeTreasurer(address _newTreasurer) external;
    function updateMarket(address _market, bool _isAccepted) external;
    function withdrawTokens(address _token) external;

    // ============================================
    // ==          CALLABLE BY MARKETS           ==
    // ============================================
    function addPoints(address _user, uint256 _points) external;

    // ============================================
    // ==        CALLABLE BY USER & VAULT        ==
    // ============================================
    function claim(address _user, address _tokenReceived) external;

    // ============================================
    // ==             READ FUNCTIONS             ==
    // ============================================
    function getReward(address _user, address _tokenReceived) external view returns (uint256 userReward);
}
