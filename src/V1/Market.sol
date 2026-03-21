// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IChainlink} from "./interfaces/IChainlink.sol";
import {IRewardPool} from "./interfaces/IRewardPool.sol";
import {IStakingVault} from "./interfaces/IStakingVault.sol";

// ============================================
error InvalidConstructor();
error InvalidAmount();
error WaitingToSettle();
error InsufficientStake();
error EpochActive();
error SequencerDown();
error GracePeriodNotOver();
error StalePrice();
error InvalidPrice();
error InvalidPrediction();
// ============================================

contract Market {
    constructor(
        address _stakingVault,
        address _rewardPool,
        address _oracleFeed,
        uint256 _marketMultiplicator,
        uint256 _firstSettlement
    ) {
        // Validate inputs
        if (_stakingVault == address(0)) revert InvalidConstructor();
        if (_rewardPool == address(0)) revert InvalidConstructor();
        if (_oracleFeed == address(0)) revert InvalidConstructor();
        if (_marketMultiplicator == 0) revert InvalidConstructor();
        if (_firstSettlement <= block.timestamp) revert InvalidConstructor();

        STAKING_VAULT = IStakingVault(_stakingVault);
        REWARD_POOL = IRewardPool(_rewardPool);
        MARKET_MUL = _marketMultiplicator;

        nextSettlement = _firstSettlement;

        ORACLE = IChainlink(_oracleFeed);
        ORACLE_DECIMALS = IChainlink(ORACLE).decimals();
    }

    // ============================================
    // ==                STORAGE                 ==
    // ============================================
    using SafeERC20 for IERC20;

    uint256 private constant ORACLE_THRESHOLD_TIME = 3600; // 1h threshold for price freshness & grace period after sequencer reboot
    uint8 private immutable ORACLE_DECIMALS;

    uint256 private constant PRECISION = 1e18; // Price feed precision normalisation
    uint256 private constant MIN_STAKE_TO_PARTICIPATE = 1e24; // Minimum stake required (1M PSM)

    uint256 private constant WIN_MUL = 3; // Points multiplier per win streak
    uint256 private constant WIN_MUL_MAX = 100; // Max points multiplier from win streak
    uint256 private constant ACTIVITY_MUL = 1; // Points multiplier for participation streak
    uint256 private constant ACTIVITY_MUL_MAX = 10; // Max points multiplier from participation streak
    uint256 private immutable MARKET_MUL; // General points multiplier of this market (significance for protocol)

    IChainlink public immutable ORACLE;
    IStakingVault public immutable STAKING_VAULT;
    IRewardPool public immutable REWARD_POOL;

    uint256 public constant EPOCH_DURATION = 60 * 60 * 24; // 24 hours

    uint256 public nextSettlement; // Time when the active epoch can be settled
    uint256 public activeEpochID;
    uint256 public last_settlementPrice; // Oracle price at last settlement

    struct PredictionData {
        uint256 up1_down2;
        uint256 forSettlementTime;
    }
    mapping(uint256 epochID => uint256 result) public results; // Mapping of epoch ID to winning direction

    mapping(address user => uint256 winStreak) public userWinStreaks;
    mapping(address user => uint256 activityStreak) public userActivityStreaks;

    mapping(address user => uint256 participatedEpochID) public userLastParticipated; // Epoch ID of the last participation of each user
    mapping(address user => uint256 claimedEpochID) public userLastClaimed; // Epoch ID of the last points claim of each user

    mapping(uint256 epochID => mapping(address user => PredictionData data)) public predictions; // Continuous storage of user predictions per epoch

    // ============================================
    // ==                EVENTS                  ==
    // ============================================
    event Prediction(
        address indexed user,
        uint256 indexed forSettlementTime,
        uint256 winStreak,
        uint256 activityStreak,
        uint256 up1_down2
    );

    event Settlement(uint256 indexed forSettlementTime, uint256 indexed winningDirection, uint256 settlementPrice);

    // ============================================
    // ==             USER FUNCTIONS             ==
    // ============================================
    ///@notice Let users cast or change their prediction for the next epoch
    ///@dev User points are claimed on every prediction
    function castPrediction(uint256 _up1_down2) external {
        // CHECKS
        ///@dev Input validation
        if (_up1_down2 != 1 && _up1_down2 != 2) revert InvalidPrediction();

        ///@dev Only allow predictions if the settlement of the active epoch is not overdue
        uint256 settlementTime = nextSettlement;
        if (block.timestamp >= settlementTime) revert WaitingToSettle();

        ///@dev Only allow predictions from users with a minimum stake balance
        address user = msg.sender;
        uint256 stake = STAKING_VAULT.stakes(user);
        if (stake < MIN_STAKE_TO_PARTICIPATE) revert InsufficientStake();

        // EFFECTS
        ///@dev Claim points from the previous participated epoch and update streaks
        _accruePoints(user);

        ///@dev Get the target Epoch ID to enter the prediction
        uint256 nextEpoch = activeEpochID + 1;

        ///@dev Update the user's last participated epoch ID
        userLastParticipated[user] = nextEpoch;

        ///@dev Calculate the settlement time of the target epoch
        settlementTime += EPOCH_DURATION;

        ///@dev Get user prediction data
        PredictionData storage prediction = predictions[nextEpoch][user];

        ///@dev Update user prediction data
        prediction.forSettlementTime = settlementTime;
        prediction.up1_down2 = _up1_down2;

        ///@dev Read win streak and participation streak for event info
        uint256 winStreak = userWinStreaks[user];
        uint256 activityStreak = userActivityStreaks[user];

        // INTERACTIONS
        ///@dev Emit event that informs about this prediction
        emit Prediction(user, settlementTime, winStreak, activityStreak, _up1_down2);
    }

    // ============================================
    // ==            KEEPER FUNCTIONS            ==
    // ============================================
    ///@notice Find winning direction + settlement price of the active epoch & set direction for next epoch
    function settleEpoch() external {
        // CHECKS
        ///@dev Get the settlement price and timestamps from the oracle
        (uint80 roundId, int256 price,/*uint256 startedAt*/, uint256 updatedAt, uint80 answeredInRound) =
            ORACLE.latestRoundData();

        ///@dev Perform validation checks on the oracle feed
        _validatePriceData(roundId, price, updatedAt, answeredInRound);

        ///@dev Ensure that the settlement time is reached
        uint256 settlementTime = nextSettlement;
        if (block.timestamp < settlementTime) revert EpochActive();

        // EFFECTS
        ///@dev Typecast oracle price to uint256 and normalize to given precision
        uint256 settlementPrice = (uint256(price) * PRECISION) / (10 ** ORACLE_DECIMALS);

        ///@dev Get the settled epoch ID
        uint256 activeEpoch = activeEpochID;

        ///@dev Find ID of the previous settled epoch
        uint256 previous_epoch = (activeEpoch > 1) ? activeEpoch - 1 : 0;

        ///@dev Record the real direction of the settled epoch
        uint256 result = (results[previous_epoch] < settlementPrice) ? 1 : 2; // 1 = up, 2 = down
        results[activeEpoch] = result;

        ///@dev Update the settlement price reference (start price) for the new epoch
        last_settlementPrice = settlementPrice;

        ///@dev Update the settlement time for the next epoch
        nextSettlement = settlementTime + EPOCH_DURATION;

        ///@dev Transition to the next epoch ID
        activeEpochID += 1;

        // INTERACTIONS
        ///@dev Emit event that the epoch was settled
        emit Settlement(result, settlementPrice, settlementTime);
    }

    // ============================================
    // ==          INTERNAL FUNCTIONS            ==
    // ============================================
    ///@notice Accrues points for a user based on their last participated epoch
    ///@dev Updates win and activity streaks accordingly
    function _accruePoints(address _user) private {
        // CHECKS
        uint256 participatedEpoch = userLastParticipated[_user];
        uint256 claimedEpoch = userLastClaimed[_user];

        ///@dev Only proceed if the user has participated in at least one epoch and there is a result for that epoch
        if (results[participatedEpoch] > 0) {
            ///@dev Only proceed if the user has not claimed points for the last participated epoch
            if (claimedEpoch < participatedEpoch) {
                // EFFECTS

                ///@dev Update participation streak
                if (participatedEpoch == activeEpochID - 1) {
                    userActivityStreaks[_user] += 1;
                } else {
                    userActivityStreaks[_user] = 1; // reset streak
                }

                ///@dev Update win streak
                PredictionData storage prediction = predictions[participatedEpoch][_user];
                if (prediction.up1_down2 == results[participatedEpoch]) {
                    // User won
                    userWinStreaks[_user] += 1;
                } else {
                    // User lost - reset win streak
                    userWinStreaks[_user] = 0;
                }

                ///@dev Update last claimed epoch to equal participated epoch
                userLastClaimed[_user] = participatedEpoch;

                ///@dev Update user points based on streaks
                uint256 userStake = STAKING_VAULT.stakes(_user);

                ///@dev Calculate multipliers
                uint256 participationMul = ((userActivityStreaks[_user] * ACTIVITY_MUL) > ACTIVITY_MUL_MAX)
                    ? ACTIVITY_MUL_MAX
                    : (userActivityStreaks[_user] * ACTIVITY_MUL);
                uint256 winMul =
                    ((userWinStreaks[_user] * WIN_MUL) > WIN_MUL_MAX) ? WIN_MUL_MAX : (userWinStreaks[_user] * WIN_MUL);

                uint256 totalMul = participationMul * winMul * MARKET_MUL; // Incentivizes constant activity & winning

                // INTERACTIONS
                ///@dev Update user points in the Reward Pool - will revert if market is not listed
                uint256 pointsAdded = totalMul * userStake;
                REWARD_POOL.addPoints(_user, pointsAdded);
            }
        }
    }

    ///@notice Validates the data provided by Chainlink
    function _validatePriceData(uint80 roundId, int256 price, uint256 updatedAt, uint80 answeredInRound) internal view {
        // Check for stale data & round completion (round incomplete when updatedAt == 0)
        // Incomplete rounds will always revert because block.timestamp > (0 + ORACLE_THRESHOLD_TIME)
        uint256 timeDiff = (block.timestamp < updatedAt) ? 0 : block.timestamp - updatedAt;
        if (timeDiff > ORACLE_THRESHOLD_TIME) revert StalePrice();
        if (answeredInRound < roundId) revert StalePrice();

        // Check for valid price
        if (price <= 0) revert InvalidPrice();
    }
}

