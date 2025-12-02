// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IChainlink} from "./interfaces/IChainlink.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";

// ============================================
error InvalidConstructor();
error InvalidAmount();
error WaitingToSettle();
error NoStake();
error EpochActive();
error SequencerDown();
error GracePeriodNotOver();
error StalePrice();
error InvalidPrice();
error InvalidPrediction();
// ============================================

contract SignalVault {
    constructor(
        address _upToken,
        address _downToken,
        address _oracleContract,
        address _sequencerUptimeFeed,
        uint256 _epochDuration,
        uint256 _firstSettlementTime
    ) {
        if (_upToken == address(0) || _downToken == address(0)) revert InvalidConstructor();
        UP_TOKEN = IERC20(_upToken);
        DOWN_TOKEN = IERC20(_downToken);

        if (_oracleContract == address(0)) revert InvalidConstructor();
        if (_sequencerUptimeFeed == address(0)) revert InvalidConstructor();

        ORACLE = IChainlink(_oracleContract);
        ORACLE_DECIMALS = ORACLE.decimals();
        SEQUENCER_UPTIME_FEED = IChainlink(_sequencerUptimeFeed);

        if (_epochDuration < 86400) revert InvalidConstructor();
        EPOCH_DURATION = _epochDuration;

        if (_firstSettlementTime < block.timestamp) revert InvalidConstructor();
        nextSettlement = _firstSettlementTime;
        epochReward = EPOCH_REWARD;
    }

    // ============================================
    // ==                STORAGE                 ==
    // ============================================
    using SafeERC20 for IERC20;

    IChainlink private immutable SEQUENCER_UPTIME_FEED; // = IChainlink(0xFdB631F5EE196F0ed6FAa767959853A9F217697D); // liveness feed for Chainlink on Arbitrum
    uint256 private constant ORACLE_THRESHOLD_TIME = 3600; // 1h threshold for price freshness & grace period after sequencer reboot
    uint256 private immutable ORACLE_DECIMALS; // Decimals of the oracle price feed

    IChainlink public immutable ORACLE;
    IERC20 public immutable UP_TOKEN; // Token the Vault buys when votes are up
    IERC20 public immutable DOWN_TOKEN; // Token the Vault buys when votes are down

    uint256 private constant PRECISION = 1e18;

    IERC20 private constant PSM = IERC20(0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5);
    address private constant POOL = 0xDa82C77Bce3E027A8d70405d790d6BAaafAc628F; // PSM-ETH LP on UniV2
    uint256 private constant DEPOSIT_FEE_PERCENT = 1; // 1% of staked PSM is redirected to the LP
    uint256 private constant MIN_STAKE_FOR_VOTEPOWER = 1e23; // minimum amount of staked PSM to get vote power
    uint256 private constant UNIFORM_VOTEPOWER = 1000; // The votepower of anyone with at least the minimum stake amount
    uint256 private constant VOTE_INCREASE_BASE = 2; // X^(winStreak)
    uint256 private constant VOTE_POWER_CAP = 100000; // Vote power that can be reached at most from correctly predicting

    uint256 public immutable EPOCH_DURATION; // The duration when no new trades are accepted before an epoch is settled
    uint256 private constant EPOCH_REWARD = 2e24; // The expected & maximum reward per epoch - less if insufficient PSM balance
    uint256 public epochReward; // The real epoch reward of the most recently settled epoch

    uint256 public nextSettlement; // Time when the active epoch can be settled
    uint256 public activeEpochID;

    struct StakeData {
        uint256 stakeBalance;
        uint256 winStreak;
    }

    mapping(address user => StakeData data) public stakes;
    mapping(address user => uint256 lastClaimed) public lastClaimTimes;

    uint256 public totalStaked; // Total amount of PSM staked

    struct PredictionData {
        uint256 votes;
        uint256 up1_down2;
        uint256 forSettlementTime;
    }

    mapping(uint256 epochID => mapping(address user => PredictionData data)) public predictions; // alternate storage for epochID 1 <-> 2, is overwritten

    mapping(uint256 epochID => uint256 upVotes) public upVotes;
    mapping(uint256 epochID => uint256 downVotes) public downVotes;
    mapping(uint256 epochID => uint256 stakedUp) public stakedUp;
    mapping(uint256 epochID => uint256 stakedDown) public stakedDown;

    uint256 public last_winnerStakeTotal; // total staked amount of the winning side - used for reward distribution
    uint256 public last_result; // 1 = up, 2 = down

    uint256 public last_settlementPrice; // Oracle price at last settlement
    uint256 public vaultDirection; // 1 = buy upToken & sell downToken, 2 = sell upToken & buy downToken

    // ============================================
    // ==                EVENTS                  ==
    // ============================================
    event PredictionPosted(
        address indexed user, uint256 indexed settlementTime, uint256 stakedBalance, uint256 votes, uint256 upOrDown1Or2
    );
    event EpochSettled(
        uint256 indexed lastDirectionResult,
        uint256 epochReward,
        uint256 winnerVotes,
        uint256 winnerStakeTotal,
        uint256 settlementPrice,
        uint256 settlementTime
    );
    event RewardCompounded(address indexed user, uint256 amount);

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event SyncFailed(address indexed pool);

    // ============================================
    // ==             USER FUNCTIONS             ==
    // ============================================
    ///@notice Let users stake their tokens to participate in predictions
    ///@dev User rewards are claimed and votes are reset on every stake/unstake/prediction
    ///@dev Allow zero amount to claim pending rewards manually
    function stake(uint256 _amount) external {
        // CHECKS - none

        // EFFECTS
        ///@dev claim and compound pending rewards & update prediction
        _claim(msg.sender);

        ///@dev Apply the deposit fee
        uint256 fee = (_amount * DEPOSIT_FEE_PERCENT) / 100;
        uint256 netAmount = _amount - fee;

        ///@dev Update user stake and vote power
        StakeData storage userStake = stakes[msg.sender];
        userStake.stakeBalance += netAmount;

        ///@dev Update the global stake tracker
        totalStaked += netAmount;

        ///@dev Update predictions and stake weight of the user for the upcoming settlement
        ///@dev Apply the stakeBalance and votePower adjustments to the current user prediction
        _updatePrediction(msg.sender, netAmount, true);

        // INTERACTIONS
        ///@dev Take tokens from the user
        PSM.safeTransferFrom(msg.sender, address(this), _amount);

        ///@dev Only move fee tokens if amount is positive
        if (fee > 0) {
            ///@dev Send deposit fee to LP and sync
            PSM.safeTransfer(POOL, fee);

            ///@dev If the sync call fails or runs out of gas, emit notification event and move on
            (bool success,) = POOL.call{gas: 300_000}(abi.encodeWithSelector(IUniswapV2Pair.sync.selector));
            if (!success) emit SyncFailed(POOL);
        }

        emit Staked(msg.sender, netAmount);
    }

    ///@notice Let users unstake their tokens at any time
    ///@dev User rewards are claimed and votes are reset on every stake/unstake/prediction
    function unstake(uint256 _amount) external {
        // CHECKS
        ///@dev Validate withdrawal amount
        if (_amount == 0) revert InvalidAmount();

        ///@dev claim and compound pending rewards & update prediction
        _claim(msg.sender);

        ///@dev Prevent withdrawal of more than the user staked via shoehorning the withdrawal amount
        uint256 amount = _amount;
        StakeData storage userStake = stakes[msg.sender];
        if (amount > userStake.stakeBalance) amount = userStake.stakeBalance;

        // EFFECTS
        ///@dev Update user stake and vote power
        userStake.stakeBalance -= amount;

        ///@dev Update the global stake tracker
        totalStaked -= amount;

        ///@dev Update predictions and stake weight of the user for the upcoming settlement
        ///@dev Apply the stakeBalance and votePower adjustments to the current user prediction
        _updatePrediction(msg.sender, amount, false);

        // INTERACTIONS
        PSM.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    ///@notice Let users cast their prediction for the next epoch
    ///@dev User rewards are claimed and votes are re-applied on every stake/unstake/prediction
    function castPrediction(uint256 _up1_down2) external {
        address user = msg.sender;

        // CHECKS
        ///@dev Input validation
        if (_up1_down2 != 1 && _up1_down2 != 2) revert InvalidPrediction();

        ///@dev Only allow predictions if the settlement of the active epoch is not overdue
        uint256 settlementTime = nextSettlement;
        if (block.timestamp >= settlementTime) revert WaitingToSettle();

        // EFFECTS
        ///@dev claim and compound pending rewards & update prediction
        _claim(user);

        ///@dev Only allow predictions from users with a stake balance after claiming
        StakeData storage userStake = stakes[user];
        if (userStake.stakeBalance == 0) revert NoStake();

        ///@dev Get the target Epoch ID to enter the prediction (not active)
        uint256 targetEpochID = (activeEpochID == 1) ? 2 : 1;

        ///@dev Calculate the settlement time of the target epoch
        settlementTime += EPOCH_DURATION;

        ///@dev Get user prediction data
        PredictionData storage prediction = predictions[targetEpochID][user];

        ///@dev Get user vote power
        uint256 votePower = _getVotePower(user);

        ///@dev Flag if the user already predicted for the epoch or enters the first time
        bool isFirstPrediction = settlementTime != prediction.forSettlementTime;

        ///@dev First prediction - add votes and stake weight to the correct side
        if (isFirstPrediction) {
            if (_up1_down2 == 1) {
                upVotes[targetEpochID] += votePower;
                stakedUp[targetEpochID] += userStake.stakeBalance;
            } else {
                // _up1_down2 == 2
                downVotes[targetEpochID] += votePower;
                stakedDown[targetEpochID] += userStake.stakeBalance;
            }
        } else {
            ///@dev Change of prediction
            if (_up1_down2 != prediction.up1_down2) {
                if (_up1_down2 == 1) {
                    upVotes[targetEpochID] += votePower;
                    downVotes[targetEpochID] -= votePower;

                    stakedUp[targetEpochID] += userStake.stakeBalance;
                    stakedDown[targetEpochID] -= userStake.stakeBalance;
                } else {
                    // _up1_down2 == 2
                    upVotes[targetEpochID] -= votePower;
                    downVotes[targetEpochID] += votePower;

                    stakedUp[targetEpochID] -= userStake.stakeBalance;
                    stakedDown[targetEpochID] += userStake.stakeBalance;
                }
            }
        }

        ///@dev Update user prediction data
        prediction.forSettlementTime = settlementTime;
        prediction.up1_down2 = _up1_down2;
        prediction.votes = votePower;

        // INTERACTIONS
        ///@dev Emit event that informs about this prediction
        emit PredictionPosted(user, settlementTime, userStake.stakeBalance, votePower, _up1_down2);
    }

    ///@notice Calculate the pending rewards of a user
    ///@dev Rewards are only claimable for one epoch. Expired rewards remain in the Vault.
    function getPendingRewards(address _user) public view returns (uint256 pendingRewards) {
        ///@dev Get the target epochID for claiming (not active but past)
        uint256 claimEpochID = (activeEpochID == 1) ? 2 : 1;

        ///@dev Get the user stake
        StakeData memory userStake = stakes[_user];

        ///@dev Get the related user prediction data
        PredictionData memory userPrediction = predictions[claimEpochID][_user];

        ///@dev Prevent multiple claims
        if (lastClaimTimes[_user] < nextSettlement - EPOCH_DURATION) {
            ///@dev Check that the user has participated and was among the winners in the last epoch
            bool hasWon = (
                userPrediction.forSettlementTime == nextSettlement - EPOCH_DURATION
                    && userPrediction.up1_down2 == last_result
            );

            ///@dev Calculate rewards if user participated in the last epoch & was among the winners
            if (hasWon) {
                ///@dev Prevent edge case of panic revert due to division by 0
                ///@dev This function should never revert
                if (last_winnerStakeTotal > 0) {
                    ///@dev Winners share the epoch reward proportionally to staked amount among winners
                    pendingRewards = (epochReward * userStake.stakeBalance) / last_winnerStakeTotal;
                }
            }
        }
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
        (uint80 roundId, int256 price, /*uint256 startedAt*/, uint256 updatedAt, uint80 answeredInRound) =
            ORACLE.latestRoundData();

        ///@dev Perform validation checks on the oracle feed
        _validatePriceData(roundId, price, updatedAt, answeredInRound);

        ///@dev Ensure that the settlement time is reached
        uint256 settlementTime = nextSettlement;
        if (block.timestamp < settlementTime) revert EpochActive();

        // EFFECTS
        ///@dev Typecast oracle price to uint256 and normalize to given precision
        uint256 settlementPrice = (uint256(price) * PRECISION) / (10 ** ORACLE_DECIMALS);

        ///@dev Evaluate the real direction of the previous epoch
        last_result = (last_settlementPrice < settlementPrice) ? 1 : 2; // 1 = up, 2 = down

        ///@dev Get the settled epoch ID
        uint256 activeEpoch = activeEpochID;

        ///@dev Update the vault direction for the beginning epoch
        ///@dev Use the inverse signal from voting, i.e. go short when majority votes are long
        vaultDirection = (upVotes[activeEpoch] < downVotes[activeEpoch]) ? 1 : 2; // 1 = buy upToken & sell downToken, 2 = sell upToken & buy downToken

        ///@dev Record the total amount of winning votes and stake weight of the settled epoch
        uint256 last_winnerVotes = (last_result == 1) ? upVotes[activeEpoch] : downVotes[activeEpoch]; // only for information via event
        last_winnerStakeTotal = (last_result == 1) ? stakedUp[activeEpoch] : stakedDown[activeEpoch];

        ///@dev Ensure that the epoch reward cannot exceed free PSM balance in the contract, avoid drawing from staked PSM
        uint256 freeBal = PSM.balanceOf(address(this)) - totalStaked;
        epochReward = (EPOCH_REWARD > freeBal) ? freeBal : EPOCH_REWARD;

        ///@dev Reset votes and stake weight for beginning epoch
        upVotes[activeEpoch] = 0;
        downVotes[activeEpoch] = 0;
        stakedUp[activeEpoch] = 0;
        stakedDown[activeEpoch] = 0;

        ///@dev Update the settlement price reference for the beginning epoch
        last_settlementPrice = settlementPrice;

        ///@dev Update the settlement time for the next round
        nextSettlement = settlementTime + EPOCH_DURATION;

        ///@dev Transition the active cohort 1 -> 2 or 2 -> 1
        activeEpochID = (activeEpoch == 1) ? 2 : 1;

        // INTERACTIONS
        ///@dev Emit event that the epoch was settled
        emit EpochSettled(
            last_result, epochReward, last_winnerVotes, last_winnerStakeTotal, settlementPrice, settlementTime
        );
    }

    // ============================================
    // ==          INTERNAL FUNCTIONS            ==
    // ============================================
    ///@notice Calculates the current vote power of a user
    ///@dev User must have a minimum stake amount to have any vote power
    ///@dev The winning streak of the user is considered to amplify the vote power
    function _getVotePower(address _user) private view returns (uint256 votePower) {
        StakeData memory userStake = stakes[_user];
        if (userStake.stakeBalance >= MIN_STAKE_FOR_VOTEPOWER) {
            ///@dev Prevent any chance of overflow
            if (userStake.winStreak > 50) {
                votePower = VOTE_POWER_CAP;
            } else {
                votePower = (UNIFORM_VOTEPOWER * (VOTE_INCREASE_BASE ** userStake.winStreak) > VOTE_POWER_CAP)
                    ? VOTE_POWER_CAP
                    : UNIFORM_VOTEPOWER * VOTE_INCREASE_BASE ** userStake.winStreak;
            }
        }
    }

    ///@notice Compound rewards in user stake positions
    ///@dev Pass through without effect if the user already claimed but never revert
    ///@dev Must be called in all function that touch user stakes or predictions to keep data in sync
    function _claim(address _user) private {
        ///@dev Get the target epochID for claiming (not active)
        uint256 claimEpochID = (activeEpochID == 1) ? 2 : 1;

        ///@dev Get the most recent user prediction data
        PredictionData memory userPrediction = predictions[claimEpochID][_user];

        ///@dev Get the user stake
        StakeData storage userStake = stakes[_user];

        ///@dev Get rewards of the user. Is 0 if already claimed
        uint256 pendingRewards = getPendingRewards(_user);

        ///@dev Only claim & increase voting power if the user has pending rewards
        if (pendingRewards > 0) {
            ///@dev Increase the stake balance by the claimed rewards & increase win streak
            totalStaked += pendingRewards;
            userStake.stakeBalance += pendingRewards;
            userStake.winStreak += 1;

            ///@dev Update the claiming time
            lastClaimTimes[_user] = block.timestamp;

            emit RewardCompounded(_user, pendingRewards);
        }

        ///@dev Check that the user has participated and was among the winners in the last epoch
        bool hasWon = (
            userPrediction.forSettlementTime == nextSettlement - EPOCH_DURATION
                && userPrediction.up1_down2 == last_result
        );

        ///@dev Reset the winstreak counter if not participated or lost in the last epoch
        if (!hasWon) {
            userStake.winStreak = 0;
        }

        ///@dev Update predictions and stake weight of the user for the upcoming settlement
        ///@dev Apply the stakeBalance and votePower adjustments to the current user prediction
        _updatePrediction(_user, pendingRewards, true);
    }

    ///@notice Update the prediction of a user for the current AND next settlement
    ///@dev If the user didn't make a prediction for a valid epoch yet, pass through
    function _updatePrediction(address _user, uint256 _amount, bool _addToStake) private {
        ///@dev Cache Epoch IDs for updating related predictions
        uint256 activeEpoch = activeEpochID;
        uint256 nextEpoch = (activeEpoch == 1) ? 2 : 1;

        ///@dev Calculate the settlement time of the target epoch
        uint256 settlementTimeActive = nextSettlement;
        uint256 settlementTimeNext = nextSettlement + EPOCH_DURATION;

        ///@dev Get prediction data for updating
        PredictionData storage prediction1 = predictions[1][_user]; // prediction for epochID 1
        PredictionData storage prediction2 = predictions[2][_user]; // prediction for epochID 2

        ///@dev Get user vote power
        uint256 votePower = _getVotePower(_user);

        ///@dev Relate updating the correct prediction storage to the respective epoch ID if a prediction was cast
        uint256 updatePrediction1EpochID;
        if (prediction1.forSettlementTime == settlementTimeActive) updatePrediction1EpochID = activeEpoch;
        else if (prediction1.forSettlementTime == settlementTimeNext) updatePrediction1EpochID = nextEpoch;

        uint256 updatePrediction2EpochID;
        if (prediction2.forSettlementTime == settlementTimeActive) updatePrediction2EpochID = activeEpoch;
        else if (prediction2.forSettlementTime == settlementTimeNext) updatePrediction2EpochID = nextEpoch;

        ///@dev calculate the potential difference in votePower
        uint256 updatedVotes1 = (prediction1.votes != votePower) ? votePower : prediction1.votes;
        uint256 updatedVotes2 = (prediction2.votes != votePower) ? votePower : prediction2.votes;

        ///@dev Initialize local variables
        uint256 voteDiff;
        bool isPositiveAdjustment;

        ///@dev Check if the user has made a prediction for one of the epochs and update the related storage slot
        ///@dev Update Prediction storage slot 1
        if (updatePrediction1EpochID > 0) {
            ///@dev Get the vote difference and direction for adjustments of total votes
            voteDiff = (updatedVotes1 > prediction1.votes)
                ? updatedVotes1 - prediction1.votes
                : prediction1.votes - updatedVotes1;
            isPositiveAdjustment = (updatedVotes1 > prediction1.votes) ? true : false;

            ///@dev Adjust value of the correct total vote tracker
            if (prediction1.up1_down2 == 1) {
                if (isPositiveAdjustment) upVotes[updatePrediction1EpochID] += voteDiff;
                if (!isPositiveAdjustment) upVotes[updatePrediction1EpochID] -= voteDiff;
            }

            if (prediction1.up1_down2 == 2) {
                if (isPositiveAdjustment) downVotes[updatePrediction1EpochID] += voteDiff;
                if (!isPositiveAdjustment) downVotes[updatePrediction1EpochID] -= voteDiff;
            }

            ///@dev Adjust stake weight of the respective side
            ///@dev Increase stake weight if amount is added to stake
            if (_addToStake) {
                if (prediction1.up1_down2 == 1) stakedUp[updatePrediction1EpochID] += _amount;
                if (prediction1.up1_down2 == 2) stakedDown[updatePrediction1EpochID] += _amount;
            }

            ///@dev Decrease stake weight if amount is subtracted from stake
            if (!_addToStake) {
                if (prediction1.up1_down2 == 1) stakedUp[updatePrediction1EpochID] -= _amount;
                if (prediction1.up1_down2 == 2) stakedDown[updatePrediction1EpochID] -= _amount;
            }

            ///@dev Update user votes, keep settlement time and directional info untouched
            prediction1.votes = updatedVotes1;
        }

        ///@dev Update Prediction storage slot 2
        if (updatePrediction2EpochID > 0) {
            ///@dev Get the vote difference and direction for adjustments of total votes
            voteDiff = (updatedVotes2 > prediction2.votes)
                ? updatedVotes2 - prediction2.votes
                : prediction2.votes - updatedVotes2;
            isPositiveAdjustment = (updatedVotes2 > prediction2.votes) ? true : false;

            ///@dev Adjust value of the correct total vote tracker
            if (prediction2.up1_down2 == 1) {
                if (isPositiveAdjustment) upVotes[updatePrediction2EpochID] += voteDiff;
                if (!isPositiveAdjustment) upVotes[updatePrediction2EpochID] -= voteDiff;
            }

            if (prediction2.up1_down2 == 2) {
                if (isPositiveAdjustment) downVotes[updatePrediction2EpochID] += voteDiff;
                if (!isPositiveAdjustment) downVotes[updatePrediction2EpochID] -= voteDiff;
            }

            ///@dev Adjust stake weight of the respective side
            ///@dev Increase stake weight if amount is added to stake
            if (_addToStake) {
                if (prediction2.up1_down2 == 1) stakedUp[updatePrediction2EpochID] += _amount;
                if (prediction2.up1_down2 == 2) stakedDown[updatePrediction2EpochID] += _amount;
            }

            ///@dev Decrease stake weight if amount is subtracted from stake
            if (!_addToStake) {
                if (prediction2.up1_down2 == 1) stakedUp[updatePrediction2EpochID] -= _amount;
                if (prediction2.up1_down2 == 2) stakedDown[updatePrediction2EpochID] -= _amount;
            }

            ///@dev Update user votes, keep settlement time and directional info untouched
            prediction2.votes = updatedVotes2;
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
    function _validatePriceData(uint80 roundId, int256 price, uint256 updatedAt, uint80 answeredInRound)
        internal
        view
    {
        // Check for stale data & round completion (round incomplete when updatedAt == 0)
        // Incomplete rounds will always revert because block.timestamp > (0 + ORACLE_THRESHOLD_TIME)
        uint256 timeDiff = (block.timestamp < updatedAt) ? 0 : block.timestamp - updatedAt;
        if (timeDiff > ORACLE_THRESHOLD_TIME) revert StalePrice();
        if (answeredInRound < roundId) revert StalePrice();

        // Check for valid price
        if (price <= 0) revert InvalidPrice();
    }
}
