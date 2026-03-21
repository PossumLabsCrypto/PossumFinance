// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRewardPool} from "./interfaces/IRewardPool.sol";

// ============================================
error FailedToSendNativeToken();
error InsufficientReceived();
error InvalidAddress();
error InvalidAmount();
error InvalidConstructor();
error InvalidDeadline();
error NotAuthorized();
error NoBalance();
error NoRewards();
error StakingVaultSet();
// ============================================

contract RewardPool {
    constructor(address _owner) {
        if (_owner == address(0)) revert InvalidConstructor();
        owner = _owner;
        admin = _owner;
        treasurer = _owner;
        totalPoints = 1e28; // 10bn Points starting value
    }

    // ============================================
    // ==                STORAGE                 ==
    // ============================================
    using SafeERC20 for IERC20;

    IERC20 private constant PSM = IERC20(0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5);

    address public owner;
    address public admin;
    address public treasurer;
    address public stakingVault;

    uint256 public totalPoints;

    mapping(address staker => uint256 points) public userAvailablePoints;
    mapping(address staker => uint256 points) public userRedeemedPoints;

    mapping(address market => bool accepted) public activeMarkets;

    // ============================================
    // ==                EVENTS                  ==
    // ============================================
    event OwnerChanged(address newOwner);
    event AdminChanged(address newAdmin);
    event TreasurerChanged(address newTreasurer);
    event MarketStatusUpdated(address indexed market, bool indexed accepted);

    event PointsUpdated(address indexed user, uint256 availablePoints, uint256 redeemedPoints);
    event Claimed(address indexed user, address indexed tokenOut, uint256 amount);

    // ============================================
    // ==            OWNER FUNCTIONS             ==
    // ============================================
    ///@notice The owner can set the staking vault that is allowed to compound rewards for users
    ///@dev This function can only be called once for security reasons
    function setStakingVault(address _stakingVault) external {
        if (_stakingVault == address(0)) revert InvalidAddress();
        if (stakingVault != address(0)) revert StakingVaultSet();
        checkAuth(msg.sender, 1);
        stakingVault = _stakingVault;
    }

    ///@notice The owner can transfer ownership
    ///@dev Setting the owner to address(0) is allowed to revoke ownership
    function changeOwner(address _newOwner) external {
        checkAuth(msg.sender, 1);
        owner = _newOwner;
        emit OwnerChanged(owner);
    }

    ///@notice The owner and Admin can change the Admin who controls market listing
    function changeAdmin(address _newAdmin) external {
        checkAuth(msg.sender, 2);
        if (_newAdmin == address(0)) revert InvalidAddress();
        admin = _newAdmin;
        emit AdminChanged(_newAdmin);
    }

    ///@notice The owner and treasurer can change the Treasurer who can withdraw & manage funds
    function changeTreasurer(address _newTreasurer) external {
        checkAuth(msg.sender, 3);
        if (_newTreasurer == address(0)) revert InvalidAddress();
        treasurer = _newTreasurer;
        emit TreasurerChanged(_newTreasurer);
    }

    ///@notice owner or admin can add and remove market permissions to update user points
    function updateMarket(address _market, bool _isAccepted) external {
        checkAuth(msg.sender, 2);
        activeMarkets[_market] = _isAccepted;
        emit MarketStatusUpdated(_market, _isAccepted);
    }

    ///@dev owner or treasurer can withdraw any token balance
    function withdrawTokens(address _token) external {
        checkAuth(msg.sender, 3);

        uint256 balance = (_token == address(0)) ? address(this).balance : IERC20(_token).balanceOf(address(this));
        if (balance == 0) revert NoBalance();

        if (_token == address(0)) {
            (bool sent,) = payable(msg.sender).call{value: balance}("");
            if (!sent) revert FailedToSendNativeToken();
        } else {
            IERC20(_token).safeTransfer(msg.sender, balance);
        }
    }

    function checkAuth(address _caller, uint256 _mode) internal view {
        // Only owner
        if (_mode == 1) {
            if (_caller != owner) revert NotAuthorized();
        }

        // Owner or Admin
        if (_mode == 2) {
            if (_caller != owner && _caller != admin) revert NotAuthorized();
        }

        // Owner or Treasurer
        if (_mode == 3) {
            if (_caller != owner && _caller != treasurer) revert NotAuthorized();
        }
    }

    // ============================================
    // ==          CALLABLE BY MARKETS           ==
    // ============================================
    ///@notice Add points to a user
    ///@dev Only callable by accepted market contracts
    function addPoints(address _user, uint256 _points) external {
        // CHECKS
        if (!activeMarkets[msg.sender]) revert NotAuthorized();

        // EFFECTS
        uint256 availablePoints = userAvailablePoints[_user] + _points;
        uint256 redeemedPoints = userRedeemedPoints[_user];

        ///@dev Add the points to the user and to the total points
        userAvailablePoints[_user] = availablePoints;
        totalPoints += _points;

        emit PointsUpdated(_user, availablePoints, redeemedPoints);
    }

    // ============================================
    // ==        CALLABLE BY USER & VAULT        ==
    // ============================================
    ///@notice Claim rewards for users either directly or via compounding through the Staking Vault
    ///@dev Pull PSM from this contract to the Staking Vault or send any token directly to users
    function claim(address payable _user, address _tokenReceived) external {
        // CHECKS
        ///@dev Get the correct user for redeeming points
        address payable user = (msg.sender == stakingVault) ? _user : payable(msg.sender);

        // EFFECTS
        ///@dev Get the pending rewards
        uint256 userReward = getReward(user, _tokenReceived);
        if (userReward == 0) revert NoRewards();

        ///@dev Reduce user points (redeem all)
        uint256 redeemedPoints = userAvailablePoints[user];
        uint256 totalRedeemed = userRedeemedPoints[user] + redeemedPoints;
        userAvailablePoints[user] = 0;
        userRedeemedPoints[user] = totalRedeemed;
        emit PointsUpdated(user, 0, totalRedeemed);

        // INTERACTIONS
        ///@dev Send claimed tokens to the caller (is Staking Vault or user directly)
        ///@dev When called through the Staking Vault, the PSM rewards are compunded into user stake
        if (_tokenReceived == address(0)) {
            ///@dev Send ETH to the user
            (bool sent,) = payable(msg.sender).call{value: userReward}("");
            if (!sent) revert FailedToSendNativeToken();
        } else {
            ///@dev Send Tokens to the user or Staking Vault (Staking Vault pulls only PSM)
            IERC20(_tokenReceived).safeTransfer(msg.sender, userReward);
        }

        emit Claimed(msg.sender, _tokenReceived, userReward);
    }

    ///@notice Swap PSM for any asset in the pool using the full range AMM curve
    ///@dev No swap fee, one-way swap (only sell PSM)
    ///@dev This function provides asset-backing to PSM and replenishes the PSM balance via arbitrage
    function sellPsmForAsset(address _assetOut, uint256 _psmIn, uint256 _minReceived, uint256 _deadline) public {
        // CHECKS
        ///@dev Input validation
        if (_psmIn == 0) revert InvalidAmount();
        if (_deadline < block.timestamp) revert InvalidDeadline();

        ///@dev Ensure minimum amount received
        uint256 received = quoteSellPsmForAsset(_assetOut, _psmIn);
        if (received < _minReceived || received == 0) revert InsufficientReceived();

        // EFFECTS - none

        // INTERACTIONS
        ///@dev Take PSM from user to contract
        PSM.safeTransferFrom(msg.sender, address(this), _psmIn);

        ///@dev Send output token to user
        if (_assetOut == address(0)) {
            ///@dev Send ETH to the user
            (bool sent,) = payable(msg.sender).call{value: received}("");
            if (!sent) revert FailedToSendNativeToken();
        } else {
            ///@dev Send ERC20 token to the user
            IERC20(_assetOut).safeTransfer(msg.sender, received);
        }
    }

    // ============================================
    // ==             READ FUNCTIONS             ==
    // ============================================
    ///@notice Calculate the reward of a user claimable in any token including ETH
    ///@dev Redeeming points for tokens suffers no slippage because that occurs when adding points
    function getReward(address _user, address _tokenReceived) public view returns (uint256 userReward) {
        uint256 balance =
            (_tokenReceived == address(0)) ? address(this).balance : IERC20(_tokenReceived).balanceOf(address(this));

        uint256 pointsToRedeem = userAvailablePoints[_user];

        userReward = (pointsToRedeem * balance) / totalPoints;
    }

    function quoteSellPsmForAsset(address _assetOut, uint256 _psmIn) public view returns (uint256 amountOut) {
        if (_assetOut != address(PSM)) {
            uint256 balanceAsset =
                (_assetOut == address(0)) ? address(this).balance : IERC20(_assetOut).balanceOf(address(this));
            uint256 balancePSM = PSM.balanceOf(address(this));

            if (balancePSM < 1e24) balancePSM = 1e24; // ensure minimum 1 million PSM balance to avoid draining

            amountOut = (_psmIn * balanceAsset) / (_psmIn + balancePSM);
        }
    }

    // ============================================
    // ==             ENABLE ETH                 ==
    // ============================================
    receive() external payable {}

    fallback() external payable {}
}
