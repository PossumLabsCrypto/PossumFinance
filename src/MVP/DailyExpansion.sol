// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IChainlink} from "./interfaces/IChainlink.sol";
import {ISignalVault} from "./interfaces/ISignalVault.sol";

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

contract DailyExpansion {
    constructor(uint256 _firstSettlement) {
        // Ensure all inputs are valid
        if (_firstSettlement <= block.timestamp) revert InvalidConstructor();

        ORACLE = IChainlink(SIGNAL_VAULT.ORACLE());
        ORACLE_DECIMALS = IChainlink(ORACLE).decimals();

        nextSettlement = _firstSettlement;
    }

    // ============================================
    // ==                STORAGE                 ==
    // ============================================
    using SafeERC20 for IERC20;

    ISignalVault private constant SIGNAL_VAULT = ISignalVault(0xb800B8dbCF9A78b16F5C1135Cd1A39384ABf1fbc);
    IChainlink private constant SEQUENCER_UPTIME_FEED = IChainlink(0xFdB631F5EE196F0ed6FAa767959853A9F217697D); // liveness feed for Chainlink on Arbitrum
    uint256 private constant ORACLE_THRESHOLD_TIME = 3600; // 1h threshold for price freshness & grace period after sequencer reboot
    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_STAKE_TO_PARTICIPATE = 1e23; // Minimum stake required (100k PSM)

    uint256 private constant WIN_MUL = 5; // Points multiplier per win streak
    uint256 private constant WIN_MUL_MAX = 100; // Max points multiplier from win streak
    uint256 private constant PARTIZIPATION_MUL = 1; // Points multiplier for participation streak
    uint256 private constant PARTIZIPATION_MUL_MAX = 7; // Max points multiplier from participation streak

    IChainlink private immutable ORACLE;
    uint8 private immutable ORACLE_DECIMALS;

    uint256 public constant EPOCH_DURATION = 60 * 60 * 24; // 24 hours

    uint256 public nextSettlement; // Time when the active epoch can be settled
    uint256 public activeEpochID;

    struct PredictionData {
        uint256 up1_down2;
        uint256 forSettlementTime;
    }
    mapping(uint256 epochID => uint256 result) public results; // Mapping of epoch ID to winning direction

    mapping(address user => uint256 winStreak) public userWinStreaks;
    mapping(address user => uint256 participationStreak) public userParticipationStreaks;
    mapping(uint256 epochID => mapping(address user => PredictionData data)) public predictions; // Continuous storage of user predictions per epoch

    mapping(address user => uint256 participatedEpochID) public userLastParticipated; // Epoch ID of the last participation of each user
    mapping(address user => uint256 claimedEpochID) public userLastClaimed; // Epoch ID of the last points claim of each user
    mapping(address user => uint256 points) public userPoints; // Total points accumulated by each user

    uint256 public totalPoints; // Total points accumulated by all users

    uint256 public last_settlementPrice; // Oracle price at last settlement

    // ============================================
    // ==                EVENTS                  ==
    // ============================================

    event Prediction(
        address indexed user,
        uint256 indexed forSettlementTime,
        uint256 winStreak,
        uint256 participationStreak,
        uint256 up1_down2
    );

    event PointsAccrued(address indexed user, uint256 pointsAdded, uint256 userPoints);
    event TotalPoints(uint256 indexed forSettlementTime, uint256 totalPoints);

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
        uint256 stake = SIGNAL_VAULT.stakes(user).stakeBalance;
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

        ///@dev Read win streak and participation streak for event emission
        uint256 winStreak = userWinStreaks[user];
        uint256 participationStreak = userParticipationStreaks[user];

        // INTERACTIONS
        ///@dev Emit event that informs about this prediction
        emit Prediction(user, settlementTime, winStreak, participationStreak, _up1_down2);
    }

    // ============================================
    // ==            KEEPER FUNCTIONS            ==
    // ============================================
    ///@notice Find winning direction + settlement price of the active epoch & set direction for next epoch
    function settleEpoch() external {
        // CHECKS
        ///@dev Ensure that the L2 sequencer is live and was not restarted just recently
        _checkSequencerStatus();

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

        ///@dev Record the real direction of the active epoch
        uint256 result = (results[previous_epoch] < settlementPrice) ? 1 : 2; // 1 = up, 2 = down
        results[activeEpoch] = result;

        ///@dev Update the settlement price reference for the new epoch
        last_settlementPrice = settlementPrice;

        ///@dev Update the settlement time for the next round
        nextSettlement = settlementTime + EPOCH_DURATION;

        ///@dev Transition the next cohort ID (continuous)
        activeEpochID += 1;

        // INTERACTIONS
        ///@dev Emit event that the epoch was settled
        emit Settlement(result, settlementPrice, settlementTime);
        emit TotalPoints(settlementTime, totalPoints);
    }

    // ============================================
    // ==          INTERNAL FUNCTIONS            ==
    // ============================================
    ///@notice Accrues points for a user based on their last participated epoch
    ///@dev Updates win and participation streaks accordingly
    function _accruePoints(address _user) private {
        uint256 participatedEpoch = userLastParticipated[_user];
        uint256 claimedEpoch = userLastClaimed[_user];

        ///@dev Only proceed if the user has participated in at least one epoch and there is a result for that epoch
        if (results[participatedEpoch] > 0) {
            ///@dev Only proceed if the user has not claimed points for the last participated epoch
            if (claimedEpoch < participatedEpoch) {
                ///@dev Check if the user has participated in the previous epoch & update participation streak
                if (participatedEpoch == activeEpochID - 1) {
                    userParticipationStreaks[_user] += 1;
                } else {
                    userParticipationStreaks[_user] = 1; // reset streak
                }

                ///@dev Check if the user won or lost in the last participated epoch & update win streak
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
                uint256 userStake = SIGNAL_VAULT.stakes(_user).stakeBalance;

                ///@dev Calculate multipliers
                uint256 participationMul = ((userParticipationStreaks[_user] * PARTIZIPATION_MUL)
                        > PARTIZIPATION_MUL_MAX)
                    ? PARTIZIPATION_MUL_MAX
                    : (userParticipationStreaks[_user] * PARTIZIPATION_MUL);
                uint256 winMul =
                    ((userWinStreaks[_user] * WIN_MUL) > WIN_MUL_MAX) ? WIN_MUL_MAX : (userWinStreaks[_user] * WIN_MUL);

                uint256 totalMul = participationMul * winMul; // Highly incentivizes winning consistently

                ///@dev Update user and total points
                uint256 pointsAdded = totalMul * userStake;
                userPoints[_user] += pointsAdded;
                totalPoints += pointsAdded;

                emit PointsAccrued(_user, pointsAdded, userPoints[_user]);
            }
        }
    }

    ///@notice Ensures that the L2 sequencer is live and that a grace period has passed since restart
    function _checkSequencerStatus() internal view {
        (
            /*uint80 roundID*/
            ,
            int256 answer,
            uint256 startedAt,
            /*uint256 updatedAt*/
            ,
            /*uint80 answeredInRound*/
        ) = SEQUENCER_UPTIME_FEED.latestRoundData();

        // Answer == 0: Sequencer is up
        // Answer == 1: Sequencer is down
        bool isSequencerUp = answer == 0;
        if (!isSequencerUp) {
            revert SequencerDown();
        }

        // Make sure grace period has passed after sequencer comes back up
        uint256 timeSinceUp = (block.timestamp < startedAt) ? 0 : block.timestamp - startedAt;
        if (timeSinceUp <= ORACLE_THRESHOLD_TIME) {
            revert GracePeriodNotOver();
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

