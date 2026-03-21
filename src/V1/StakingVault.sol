// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRewardPool} from "./interfaces/IRewardPool.sol";

// ============================================
error InvalidAmount();
error InvalidConstructor();
error NoRewards();
// ============================================

contract StakingVault {
    constructor(address _rewardPool) {
        if (_rewardPool == address(0)) revert InvalidConstructor();
        REWARD_POOL = IRewardPool(_rewardPool);
    }

    // ============================================
    // ==                STORAGE                 ==
    // ============================================
    using SafeERC20 for IERC20;

    IRewardPool public immutable REWARD_POOL;

    IERC20 private constant PSM = IERC20(0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5);
    uint256 private constant WITHDRAWAL_FEE_PERCENT = 1; // 1% of staked PSM is retained in the contract

    uint256 public totalStaked;
    mapping(address user => uint256 amount) public stakes;

    // ============================================
    // ==                EVENTS                  ==
    // ============================================
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);

    event RewardCompounded(address indexed user, uint256 amount);

    // ============================================
    // ==             CORE FUNCTIONS             ==
    // ============================================
    ///@notice Let users stake their tokens to participate in predictions
    ///@dev User rewards are claimed on every stake/unstake
    function stake(uint256 _amount) external {
        // CHECKS
        ///@dev Validate stake amount
        if (_amount == 0) revert InvalidAmount();

        // EFFECTS
        ///@dev Get compoundable PSM rewards of the user
        uint256 userRewards = REWARD_POOL.getReward(msg.sender, address(PSM));

        ///@dev claim and compound pending PSM rewards from the reward pool
        if (userRewards > 0) {
            REWARD_POOL.claim(msg.sender, address(PSM));
            emit RewardCompounded(msg.sender, userRewards);
        }

        ///@dev Update user stake & global stake tracker
        stakes[msg.sender] += _amount + userRewards;
        totalStaked += _amount + userRewards;

        // INTERACTIONS
        ///@dev Take tokens from the user
        PSM.safeTransferFrom(msg.sender, address(this), _amount);

        emit Staked(msg.sender, _amount);
    }

    ///@notice Let users unstake their tokens at any time and deduct the withdrawal fee
    ///@dev User rewards are claimed on every stake/unstake
    function unstake(uint256 _amount) external {
        // CHECKS
        ///@dev Validate withdrawal amount
        if (_amount == 0) revert InvalidAmount();

        ///@dev Get compoundable PSM rewards of the user
        uint256 userRewards = REWARD_POOL.getReward(msg.sender, address(PSM));

        ///@dev claim and compound pending PSM rewards from the reward pool
        if (userRewards > 0) {
            REWARD_POOL.claim(msg.sender, address(PSM));
            emit RewardCompounded(msg.sender, userRewards);
        }

        ///@dev Prevent withdrawal of more than the user owns by shoehorning the withdrawal amount
        uint256 amount = _amount;
        uint256 userStake = stakes[msg.sender] + userRewards; // stake including claimed rewards
        if (amount > userStake) amount = userStake;

        // EFFECTS
        ///@dev Update user stake & global stake tracker
        stakes[msg.sender] = userStake - amount;
        totalStaked = totalStaked + userRewards - amount;

        ///@dev Apply the withdrawal fee for token transfer
        uint256 fee = (amount * WITHDRAWAL_FEE_PERCENT) / 100;
        uint256 netAmount = amount - fee;

        // INTERACTIONS
        ///@dev Transfer the net amount after fees to the user
        PSM.safeTransfer(msg.sender, netAmount);

        ///@dev Send all surplus PSM (e.g. fee) to the Reward Pool
        sweep(address(PSM));

        emit Unstaked(msg.sender, amount);
    }

    ///@notice Users can manually compound PSM rewards from the reward pool
    ///@dev This is in addition to the automatic compounding that happens on every stake/unstake
    function compound() external {
        // CHECKS
        ///@dev Check if the user can claim PSM
        uint256 userRewards = REWARD_POOL.getReward(msg.sender, address(PSM));
        if (userRewards == 0) revert NoRewards();

        // EFFECTS
        ///@dev Update the user's stake and total staked amount
        stakes[msg.sender] += userRewards;
        totalStaked += userRewards;

        // INTERACTIONS
        ///@dev Claim PSM from the reward pool (token transfer to this contract)
        REWARD_POOL.claim(msg.sender, address(PSM));

        emit RewardCompounded(msg.sender, userRewards);
    }

    // ============================================
    // ==           UTILITY FUNCTIONS            ==
    // ============================================
    ///@notice Send any Token balance or PSM surplus beyond staked tokens to the Reward Pool
    function sweep(address _token) public {
        uint256 amount = (_token == address(PSM))
            ? PSM.balanceOf(address(this)) - totalStaked
            : IERC20(_token).balanceOf(address(this));

        if (amount > 0) IERC20(_token).safeTransfer(address(REWARD_POOL), amount);
    }
}
