// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IChainlink} from "src/interfaces/IChainlink.sol";
import {SignalVault} from "src/SignalVault.sol";
import {AssetVault} from "src/AssetVault.sol";
import {SequencerOutage} from "test/mocks/SequencerOutage.sol";
import {BrokenOracle} from "test/mocks/BrokenOracle.sol";
import {FakeOracle} from "test/mocks/FakeOracle.sol";
import {DelayedOracle} from "test/mocks/DelayedOracle.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";

// ============================================
error InvalidConstructor();
error InvalidAmount();
error ExceedUserBalance();
error WaitingToSettle();
error NoStake();
error EpochActive();
error SequencerDown();
error GracePeriodNotOver();
error StalePrice();
error InvalidPrice();
error InvalidPrediction();

error NotOwner();
error InvalidToken();
error DeadlineExpired();
error InvalidSwapDirection();
error InsufficientReceived();
// ============================================

contract PossumFinanceTest is Test {
    // addresses
    address payable Alice = payable(address(0x117));
    address payable Bob = payable(address(0x118));
    address payable Charlie = payable(address(0x119));
    address payable treasury = payable(0xa0BFD02a7a47CBCA7230E03fbf04A196C3E771E3);
    IERC20 psm = IERC20(0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5);
    IERC20 usdc = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20 weth = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);

    address usdcWhale = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;
    address wethWhale = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;

    // Token amounts
    uint256 aliceETH = 100e18;
    uint256 bobETH = 100e18;
    uint256 treasuryETH = 1000000000e18;
    uint256 psm_10million = 1e25;

    // Contract instances
    SignalVault signalVault;
    AssetVault assetVault;

    SignalVault brokenOracleVault;
    SignalVault fakeOracleVault;
    AssetVault fakeOracleAssetVault;
    SignalVault fakeSequencerVault;
    SignalVault delayedOracleVault;
    SequencerOutage sequencerOutageFeed;

    // time
    uint256 oneYear = 60 * 60 * 24 * 365;
    uint256 oneWeek = 60 * 60 * 24 * 7;

    // Sequencer historical data
    uint256 lastReboot = 1713187535;
    uint256 lastRound = 18446744073709551653;

    // Constants
    // Signal Vault
    uint256 constant UNIFORM_VOTEPOWER = 1000;
    uint256 VOTE_POWER_CAP = 100000;

    uint256 usdc100k = 1e11;
    uint256 weth10 = 1e19;

    uint256 up_token_decimals = 18;
    uint256 down_token_decimals = 6;

    address constant uptimeFeedReal = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D; // Chainlink sequencer feed

    uint256 DEPOSIT_FEE_PERCENT = 1;
    address POOL = 0xDa82C77Bce3E027A8d70405d790d6BAaafAc628F;
    uint256 poolBalance;

    uint256 constant FIRST_SETTLEMENT = 1761166816;
    uint256 constant EPOCH_DURATION = 86400;
    uint256 public constant EPOCH_REWARD = 2e24; // 2M PSM

    address constant ETH_USD_CHAINLINK_ORACLE = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    IChainlink constant oracle = IChainlink(ETH_USD_CHAINLINK_ORACLE);
    uint256 constant ORACLE_RESPONSE_AT_FORK_HEIGHT = 11060800999999; // 110608.001 BTC/USD

    uint256 constant PRECISION = 18;

    // Asset Vault
    uint256 private constant PSM_REDEEM_LIMIT = 5e26; // Maximum 500M PSM per redeem transaction to protect the Vault from draining
    uint256 private constant REDEEM_BASE = 1e27; // 1Bn PSM = 100% of a specific token balance

    //////////////////////////////////////
    /////// SETUP
    //////////////////////////////////////
    function setUp() public {
        // Create main net fork
        vm.createSelectFork({urlOrAlias: "alchemy_arbitrum_api", blockNumber: 389869015});

        // get LP balance PSM
        poolBalance = psm.balanceOf(POOL);

        // Create contract instances
        signalVault = new SignalVault(
            address(weth), address(usdc), ETH_USD_CHAINLINK_ORACLE, uptimeFeedReal, EPOCH_DURATION, FIRST_SETTLEMENT
        );

        assetVault = new AssetVault(address(signalVault), up_token_decimals, down_token_decimals);

        BrokenOracle brokenOracle = new BrokenOracle();
        brokenOracleVault = new SignalVault(
            address(weth), address(usdc), address(brokenOracle), uptimeFeedReal, EPOCH_DURATION, FIRST_SETTLEMENT
        );

        FakeOracle fakeOracle = new FakeOracle();
        fakeOracleVault = new SignalVault(
            address(weth), address(usdc), address(fakeOracle), uptimeFeedReal, EPOCH_DURATION, FIRST_SETTLEMENT
        );

        fakeOracleAssetVault = new AssetVault(address(fakeOracleVault), up_token_decimals, down_token_decimals);

        sequencerOutageFeed = new SequencerOutage();
        fakeSequencerVault = new SignalVault(
            address(weth),
            address(usdc),
            address(sequencerOutageFeed),
            address(sequencerOutageFeed),
            EPOCH_DURATION,
            FIRST_SETTLEMENT
        );

        DelayedOracle delayedOracle = new DelayedOracle();
        delayedOracleVault = new SignalVault(
            address(weth), address(usdc), address(delayedOracle), uptimeFeedReal, EPOCH_DURATION, FIRST_SETTLEMENT
        );

        // Give PSM to entities & fake signal Vault
        vm.startPrank(address(treasury));
        psm.transfer(Alice, psm_10million);
        psm.transfer(Bob, psm_10million);
        psm.transfer(Charlie, psm_10million);
        psm.transfer(address(fakeOracleVault), psm_10million);
        vm.stopPrank();

        // send 10k USDC and 10 WETH to asset vaults, Alice, Bob, Charlie
        vm.startPrank(usdcWhale);
        usdc.transfer(address(assetVault), usdc100k);
        usdc.transfer(address(fakeOracleAssetVault), usdc100k);
        usdc.transfer(Alice, usdc100k);
        usdc.transfer(Bob, usdc100k);
        usdc.transfer(Charlie, usdc100k);
        vm.stopPrank();

        vm.startPrank(wethWhale);
        weth.transfer(address(assetVault), weth10);
        weth.transfer(address(fakeOracleAssetVault), weth10);
        weth.transfer(Alice, weth10);
        weth.transfer(Bob, weth10);
        weth.transfer(Charlie, weth10);
        vm.stopPrank();
    }

    //////////////////////////////////////
    /////// HELPER FUNCTIONS
    //////////////////////////////////////
    function helper_stake100k() public {
        psm.approve(address(signalVault), 1e55);

        signalVault.stake(1e23);
    }

    //////////////////////////////////////
    /////// TESTS - Deployment
    //////////////////////////////////////
    // Check that all starting parameters are correct
    function testSuccess_verifyDeployments() public view {
        assertEq(address(signalVault.ORACLE()), ETH_USD_CHAINLINK_ORACLE);
        assertEq(address(signalVault.UP_TOKEN()), address(weth));
        assertEq(address(signalVault.DOWN_TOKEN()), address(usdc));

        assertEq(signalVault.EPOCH_DURATION(), EPOCH_DURATION);
        assertEq(signalVault.nextSettlement(), FIRST_SETTLEMENT);
        assertEq(signalVault.activeEpochID(), 0);

        assertEq(signalVault.totalStaked(), 0);
        assertEq(signalVault.last_settlementPrice(), 0);
        assertEq(signalVault.vaultDirection(), 0);

        assertEq(address(assetVault.SIGNAL_VAULT()), address(signalVault));
        assertEq(assetVault.owner(), treasury);
        assertEq(address(assetVault.UP_TOKEN()), address(signalVault.UP_TOKEN()));
        assertEq(address(assetVault.DOWN_TOKEN()), address(signalVault.DOWN_TOKEN()));
    }

    // Revert of vault deployments
    function testRevert_vaultConstructor() public {
        // Signal Vault
        SignalVault sVault;

        // Zero address upToken
        vm.expectRevert(InvalidConstructor.selector);
        sVault = new SignalVault(
            address(0), address(usdc), ETH_USD_CHAINLINK_ORACLE, uptimeFeedReal, EPOCH_DURATION, FIRST_SETTLEMENT
        );

        // Zero address downToken
        vm.expectRevert(InvalidConstructor.selector);
        sVault = new SignalVault(
            address(weth), address(0), ETH_USD_CHAINLINK_ORACLE, uptimeFeedReal, EPOCH_DURATION, FIRST_SETTLEMENT
        );

        // Zero address oracle contract
        vm.expectRevert(InvalidConstructor.selector);
        sVault =
            new SignalVault(address(weth), address(usdc), address(0), uptimeFeedReal, EPOCH_DURATION, FIRST_SETTLEMENT);

        // Zero address oracle uptime feed
        vm.expectRevert(InvalidConstructor.selector);
        sVault = new SignalVault(
            address(weth), address(usdc), ETH_USD_CHAINLINK_ORACLE, address(0), EPOCH_DURATION, FIRST_SETTLEMENT
        );

        // Too short epoch duration
        vm.expectRevert(InvalidConstructor.selector);
        sVault = new SignalVault(
            address(weth), address(usdc), ETH_USD_CHAINLINK_ORACLE, uptimeFeedReal, 12345, FIRST_SETTLEMENT
        );

        // first settlement before the current timestamp
        vm.expectRevert(InvalidConstructor.selector);
        sVault = new SignalVault(
            address(weth), address(usdc), ETH_USD_CHAINLINK_ORACLE, uptimeFeedReal, EPOCH_DURATION, block.timestamp - 1
        );

        // Asset Vault
        AssetVault aVault;

        // Zero address Signal Vault
        vm.expectRevert(InvalidConstructor.selector);
        aVault = new AssetVault(address(0), up_token_decimals, down_token_decimals);

        // Too many decimals upToken
        vm.expectRevert(InvalidConstructor.selector);
        aVault = new AssetVault(address(signalVault), 19, down_token_decimals);

        // Too many decimals downToken
        vm.expectRevert(InvalidConstructor.selector);
        aVault = new AssetVault(address(signalVault), up_token_decimals, 23);
    }

    //////////////////////////////////////
    /////// TESTS - SIGNAL VAULT
    //////////////////////////////////////
    // test staking
    function testSuccess_stake() public {
        uint256 amount = 1e23;
        uint256 fee = (amount * DEPOSIT_FEE_PERCENT) / 100;

        vm.startPrank(Alice);

        psm.approve(address(signalVault), amount);

        // To test the missing branch, replace POOL address in contract & test with a non-LP address and uncomment below
        vm.mockCallRevert(POOL, abi.encodeWithSelector(IUniswapV2Pair.sync.selector), "POOL is not a valid LP");
        vm.expectEmit(true, false, false, true);
        emit SignalVault.SyncFailed(POOL);

        signalVault.stake(1e23);

        vm.stopPrank();

        // Verify effects
        assertEq(psm.balanceOf(Alice), psm_10million - amount);
        assertEq(psm.balanceOf(address(signalVault)), amount - fee);
        assertEq(psm.balanceOf(POOL), poolBalance + fee);

        (uint256 stakeBalance, uint256 winStreak) = signalVault.stakes(Alice);

        assertEq(stakeBalance, amount - fee);
        assertEq(winStreak, 0);
    }

    function testSuccess_stakePredictAndClaim_multiSettlement() public {
        uint256 stakeAmount = 1e23; // 100k
        uint256 netStakeAmount = stakeAmount - (stakeAmount / 100);

        /////////////////////////////////////////////////////////////////////////// EPOCH 0
        // Alice stakes & makes prediction for epoch 1 (down 2)
        vm.startPrank(Alice);

        psm.approve(address(fakeOracleVault), 1e55);
        fakeOracleVault.stake(stakeAmount);
        fakeOracleVault.castPrediction(2);

        vm.stopPrank();

        // Bob stakes & makes prediction for epoch 1 (down 2)
        vm.startPrank(Bob);

        psm.approve(address(fakeOracleVault), 1e55);
        fakeOracleVault.stake(stakeAmount);
        fakeOracleVault.castPrediction(2);

        vm.stopPrank();

        ///////////////////////////////////////////////////////////////////////////

        // Verify settlement price and ID before first settlement (0)
        assertEq(fakeOracleVault.last_settlementPrice(), 0);
        assertEq(fakeOracleVault.activeEpochID(), 0);
        assertEq(fakeOracleVault.totalStaked(), 2 * netStakeAmount);

        /////////////////////////////////////////////////////////////////////////// EPOCH 0 -> 1

        // settlement epoch 0 - no votes, no winners
        vm.warp(fakeOracleVault.nextSettlement());

        fakeOracleVault.settleEpoch();

        ///////////////////////////////////////////////////////////////////////////

        // Verify settlement of epoch 0, price, ID, lastResult, direction
        assertEq(fakeOracleVault.last_settlementPrice(), 4200e18);
        assertEq(fakeOracleVault.activeEpochID(), 1); // 0 -> 1
        assertEq(fakeOracleVault.last_result(), 1); // up (from 0 to 4200)
        assertEq(fakeOracleVault.vaultDirection(), 2); // 0 votes (= equilibrium), hence default to 2

        // Verify that the settled epoch 0 has no winners, no votes, and no stakes on any side
        assertEq(fakeOracleVault.last_winnerStakeTotal(), 0);
        assertEq(fakeOracleVault.upVotes(0), 0);
        assertEq(fakeOracleVault.downVotes(0), 0);
        assertEq(fakeOracleVault.stakedUp(0), 0);
        assertEq(fakeOracleVault.stakedDown(0), 0);

        // Verify user predictions - Alice
        (uint256 votesAlice, uint256 upDownAlice, uint256 forSettlementAlice) = fakeOracleVault.predictions(1, Alice);
        assertEq(votesAlice, 0); // below staking threshold of 1e23 due to deposit fee
        assertEq(upDownAlice, 2); // voted down
        assertEq(forSettlementAlice, fakeOracleVault.nextSettlement()); // prediction is now in the active epoch, settled next

        (votesAlice, upDownAlice, forSettlementAlice) = fakeOracleVault.predictions(2, Alice);
        assertEq(votesAlice, 0); // untouched storage
        assertEq(upDownAlice, 0); // untouched storage
        assertEq(forSettlementAlice, 0); // untouched storage

        // Verify user predictions - Bob
        (uint256 votesBob, uint256 upDownBob, uint256 forSettlementBob) = fakeOracleVault.predictions(1, Bob);
        assertEq(votesBob, 0); // below staking threshold of 1e23 due to deposit fee
        assertEq(upDownBob, 2); // voted down
        assertEq(forSettlementBob, fakeOracleVault.nextSettlement()); // prediction is now in the active epoch, settled next

        (votesBob, upDownBob, forSettlementBob) = fakeOracleVault.predictions(2, Bob);
        assertEq(votesBob, 0); // untouched storage
        assertEq(upDownBob, 0); // untouched storage
        assertEq(forSettlementBob, 0); // untouched storage

        ///////////////////////////////////////////////////////////////////////////

        // Alice makes prediction for epoch 2 (down 2)
        vm.prank(Alice);
        fakeOracleVault.castPrediction(2);

        // Bob makes prediction for epoch 2 (up 1)
        vm.prank(Bob);
        fakeOracleVault.castPrediction(1);

        ///////////////////////////////////////////////////////////////////////////

        // Verify Alice and Bobs predictions for epoch 2
        (votesAlice, upDownAlice, forSettlementAlice) = fakeOracleVault.predictions(2, Alice);
        assertEq(votesAlice, 0); // below staking threshold of 1e23 due to deposit fee
        assertEq(upDownAlice, 2); // down
        assertEq(forSettlementAlice, fakeOracleVault.nextSettlement() + EPOCH_DURATION); // prediction is in the following epoch

        (votesBob, upDownBob, forSettlementBob) = fakeOracleVault.predictions(2, Bob);
        assertEq(votesBob, 0); // below staking threshold of 1e23 due to deposit fee
        assertEq(upDownBob, 1); // up
        assertEq(forSettlementBob, fakeOracleVault.nextSettlement() + EPOCH_DURATION); // prediction is in the following epoch

        // Verify that Alice and Bob don't have anything to claim yet
        assertEq(fakeOracleVault.getPendingRewards(Alice), 0);
        assertEq(fakeOracleVault.getPendingRewards(Bob), 0);

        // Verify that Alice and Bob didn't perform a claim action yet
        assertEq(fakeOracleVault.lastClaimTimes(Alice), 0);
        assertEq(fakeOracleVault.lastClaimTimes(Bob), 0);

        // Verify correct storage of prediction information of epoch 1
        assertEq(fakeOracleVault.upVotes(1), 0); // no votes
        assertEq(fakeOracleVault.downVotes(1), 0); // zero because of threshold
        assertEq(fakeOracleVault.stakedUp(1), 0); // no stakes
        assertEq(fakeOracleVault.stakedDown(1), 2 * netStakeAmount); // full stakes

        // Verify correct storage of prediction information of epoch 2
        assertEq(fakeOracleVault.upVotes(2), 0); // zero because of threshold
        assertEq(fakeOracleVault.downVotes(2), 0); // zero because of threshold
        assertEq(fakeOracleVault.stakedUp(2), netStakeAmount); // 1 stake
        assertEq(fakeOracleVault.stakedDown(2), netStakeAmount); // 1 stake

        //////////////////////////////////////////////////////////// EPOCH 1 -> 2
        // settlement epoch 1 - Alice & Bob both win (down) because price is equal to prev.
        vm.warp(fakeOracleVault.nextSettlement());
        fakeOracleVault.settleEpoch();

        ////////////////////////////////////////////////////////////

        uint256 expectedGain = EPOCH_REWARD / 2;
        uint256 expGain = (fakeOracleVault.epochReward() * netStakeAmount) / fakeOracleVault.last_winnerStakeTotal();
        assertEq(expectedGain, expGain);

        // Verify settlement of epoch 1, price, ID, lastResult, direction
        assertEq(fakeOracleVault.last_settlementPrice(), 4200e18);
        assertEq(fakeOracleVault.activeEpochID(), 2); // 1 -> 2
        assertEq(fakeOracleVault.last_result(), 2); // equal price = down (from 4200 to 4200)
        assertEq(fakeOracleVault.vaultDirection(), 2); // 0 votes due to threshold -> default = 2

        // Verify that the settled epoch 1 has full stake as winners, zero votes, and staked values were reset
        assertEq(fakeOracleVault.totalStaked(), 2 * netStakeAmount);
        assertEq(fakeOracleVault.last_winnerStakeTotal(), 2 * netStakeAmount);
        assertEq(fakeOracleVault.upVotes(1), 0); // reset during settlement
        assertEq(fakeOracleVault.downVotes(1), 0); // reset during settlement
        assertEq(fakeOracleVault.stakedUp(1), 0); // reset during settlement
        assertEq(fakeOracleVault.stakedDown(1), 0); // reset during settlement

        // Verify gains of Alice & Bob from epoch 1
        assertEq(fakeOracleVault.getPendingRewards(Alice), expectedGain);
        assertEq(fakeOracleVault.getPendingRewards(Bob), expectedGain);

        // Verify reset of prediction information of epoch 1
        assertEq(fakeOracleVault.upVotes(1), 0); // reset to 0
        assertEq(fakeOracleVault.downVotes(1), 0); // reset to 0
        assertEq(fakeOracleVault.stakedUp(1), 0); // reset to 0
        assertEq(fakeOracleVault.stakedDown(1), 0); // reset to 0

        ////////////////////////////////////////////////////////////

        // Alice stakes again, includes claiming
        vm.prank(Alice);
        fakeOracleVault.stake(1e23);

        // Verify balance changes
        assertEq(psm.balanceOf(Alice), psm_10million - 2e23);
        assertEq(psm.balanceOf(address(fakeOracleVault)), psm_10million + (3 * netStakeAmount));

        // Verify claiming of previous rewards & win streak update
        (uint256 aliceBalance, uint256 aliceWinStreak) = fakeOracleVault.stakes(Alice);
        (uint256 bobBalance, uint256 bobWinStreak) = fakeOracleVault.stakes(Bob);

        assertEq(aliceBalance, (2 * netStakeAmount) + expectedGain);
        assertEq(aliceWinStreak, 1);
        assertEq(bobBalance, netStakeAmount); // profit not yet claimed
        assertEq(bobWinStreak, 0);

        ////////////////////////////////////////////////////////////

        // Bob makes new prediction incl. claiming
        vm.prank(Bob);
        fakeOracleVault.castPrediction(1);

        // Verify claiming by Bob
        (bobBalance, bobWinStreak) = fakeOracleVault.stakes(Bob);
        assertEq(bobBalance, netStakeAmount + expectedGain); // profit not yet claimed
        assertEq(bobWinStreak, 1);
    }

    // No Revert Cases for stake

    // test unstaking
    function testSuccess_unstake() public {
        uint256 amount = 1e23; // 100k
        uint256 fee = (amount * DEPOSIT_FEE_PERCENT) / 100;

        // Alice unstakes the exact amount
        vm.startPrank(Alice);

        helper_stake100k();
        signalVault.unstake(amount - fee);

        vm.stopPrank();

        // Bob tries to unstake too much - amount gets shoehorned
        vm.startPrank(Bob);

        helper_stake100k();
        signalVault.unstake(amount * 5);

        vm.stopPrank();

        // Verify effects
        assertEq(psm.balanceOf(Alice), psm_10million - fee);
        assertEq(psm.balanceOf(Bob), psm_10million - fee);
        assertEq(psm.balanceOf(address(signalVault)), 0);
        assertEq(psm.balanceOf(POOL), poolBalance + fee * 2);

        (uint256 stakeBalanceAlice, uint256 winStreakAlice) = signalVault.stakes(Alice);
        (uint256 stakeBalanceBob, uint256 winStreakBob) = signalVault.stakes(Bob);

        assertEq(stakeBalanceAlice, 0);
        assertEq(winStreakAlice, 0);
        assertEq(stakeBalanceBob, 0);
        assertEq(winStreakBob, 0);
    }

    function testSuccess_unstakeAndClaim_afterPrediction() public {
        uint256 stakeAmount = 1e24; // 1M
        uint256 netStakeAmount = stakeAmount - (stakeAmount / 100);
        uint256 fee = stakeAmount - netStakeAmount;

        /////////////////////////////////////////////////////////////////////////// EPOCH 0
        // Alice stakes & makes prediction for epoch 1 (down 2)
        vm.startPrank(Alice);

        psm.approve(address(fakeOracleVault), 1e55);
        fakeOracleVault.stake(stakeAmount);
        fakeOracleVault.castPrediction(2);

        vm.stopPrank();

        /////////////////////////////////////////////////////////////////////////// EPOCH 0 -> 1

        // settlement epoch 0 - no votes, no winners
        vm.warp(fakeOracleVault.nextSettlement());

        fakeOracleVault.settleEpoch();

        ///////////////////////////////////////////////////////////////////////////

        // Verify user predictions - Alice
        (uint256 votesAlice, uint256 upDownAlice, uint256 forSettlementAlice) = fakeOracleVault.predictions(1, Alice);
        assertEq(votesAlice, UNIFORM_VOTEPOWER); // above staking threshold of 1e23 -> 1000
        assertEq(upDownAlice, 2); // voted down
        assertEq(forSettlementAlice, fakeOracleVault.nextSettlement()); // prediction is now in the active epoch, settled next

        (votesAlice, upDownAlice, forSettlementAlice) = fakeOracleVault.predictions(2, Alice);
        assertEq(votesAlice, 0); // untouched storage
        assertEq(upDownAlice, 0); // untouched storage
        assertEq(forSettlementAlice, 0); // untouched storage

        // Verify that Alice doesn't have anything to claim yet
        assertEq(fakeOracleVault.getPendingRewards(Alice), 0);

        // Verify total votes and stakes on sides
        assertEq(fakeOracleVault.upVotes(1), 0); // reset during settlement
        assertEq(fakeOracleVault.downVotes(1), UNIFORM_VOTEPOWER); // reset during settlement
        assertEq(fakeOracleVault.stakedUp(1), 0); // reset during settlement
        assertEq(fakeOracleVault.stakedDown(1), netStakeAmount); // reset during settlement

        ///////////////////////////////////////////////////////////////////////////

        // Alice makes prediction for epoch 2 (up 1)
        vm.prank(Alice);
        fakeOracleVault.castPrediction(1);

        ///////////////////////////////////////////////////////////////////////////

        // Verify predictions for epoch 2
        (votesAlice, upDownAlice, forSettlementAlice) = fakeOracleVault.predictions(2, Alice);
        assertEq(votesAlice, UNIFORM_VOTEPOWER); // above threshold
        assertEq(upDownAlice, 1); // predicted up
        assertEq(forSettlementAlice, fakeOracleVault.nextSettlement() + EPOCH_DURATION); // next epoch

        //////////////////////////////////////////////////////////// EPOCH 1 -> 2

        // settlement epoch 1 - Alice wins (down) because price is equal to prev.
        vm.warp(fakeOracleVault.nextSettlement());
        fakeOracleVault.settleEpoch();

        ////////////////////////////////////////////////////////////

        uint256 expectedGain = EPOCH_REWARD;
        uint256 expGain = (fakeOracleVault.epochReward() * netStakeAmount) / fakeOracleVault.last_winnerStakeTotal();
        assertEq(expectedGain, expGain);

        // Verify settlement of epoch 1, price, ID, lastResult, direction
        assertEq(fakeOracleVault.last_settlementPrice(), 4200e18);
        assertEq(fakeOracleVault.activeEpochID(), 2); // 1 -> 2
        assertEq(fakeOracleVault.last_result(), 2); // equal price = down (from 4200 to 4200)
        assertEq(fakeOracleVault.vaultDirection(), 1); // 1 vote down -> direction is inverse = up (1)

        // Verify that the settled epoch 1 has full stake as winners, 1 vote, and staked values were reset
        assertEq(fakeOracleVault.totalStaked(), netStakeAmount);
        assertEq(fakeOracleVault.last_winnerStakeTotal(), netStakeAmount);
        assertEq(fakeOracleVault.upVotes(1), 0); // reset during settlement
        assertEq(fakeOracleVault.downVotes(1), 0); // reset during settlement
        assertEq(fakeOracleVault.stakedUp(1), 0); // reset during settlement
        assertEq(fakeOracleVault.stakedDown(1), 0); // reset during settlement

        // Verify gains of Alice from epoch 1
        assertEq(fakeOracleVault.getPendingRewards(Alice), expectedGain);

        // Verify reset of prediction information of epoch 1
        assertEq(fakeOracleVault.upVotes(1), 0); // reset to 0
        assertEq(fakeOracleVault.downVotes(1), 0); // reset to 0
        assertEq(fakeOracleVault.stakedUp(1), 0); // reset to 0
        assertEq(fakeOracleVault.stakedDown(1), 0); // reset to 0

        ////////////////////////////////////////////////////////////

        // Alice unstakes all
        vm.prank(Alice);
        fakeOracleVault.unstake(1e55);

        // Verify that Alice got her stake and claimed rewards
        assertEq(psm.balanceOf(Alice), psm_10million + expectedGain - fee);

        ////////////////////////////////////////////////////////////

        // Alice stakes again & makes predictions for Epoch 3 (ID 1), down (2), including claiming of profits
        vm.startPrank(Alice);
        fakeOracleVault.stake(stakeAmount);
        fakeOracleVault.castPrediction(2);

        // Alice unstakes again
        fakeOracleVault.unstake(1e55);

        ////////////////////////////////////////////////////////////

        // Verify alice balance after second fee payment
        assertEq(psm.balanceOf(Alice), psm_10million + expectedGain - fee * 2);

        // Verify persistence of predictions for epoch 2 (active epoch)
        (votesAlice, upDownAlice, forSettlementAlice) = fakeOracleVault.predictions(2, Alice);
        assertEq(votesAlice, 0); // stake amount below threshold now (0)
        assertEq(upDownAlice, 1); // predicted up
        assertEq(forSettlementAlice, fakeOracleVault.nextSettlement()); // active epoch

        // Verify reset of predictions for epoch 1 (next epoch)
        (votesAlice, upDownAlice, forSettlementAlice) = fakeOracleVault.predictions(1, Alice);
        assertEq(votesAlice, 0); // reset
        assertEq(upDownAlice, 2); // direction persists
        assertEq(forSettlementAlice, fakeOracleVault.nextSettlement() + EPOCH_DURATION); // next epoch
    }

    // Revert cases
    function testRevert_unstake() public {
        vm.startPrank(Alice);
        helper_stake100k();

        // Scenario 1: 0 unstake
        vm.expectRevert(InvalidAmount.selector);
        signalVault.unstake(0);

        vm.stopPrank();
    }

    // test new branches of getVotePower()
    function testSuccess_predictionSequence() public {
        // Alice stakes 1M
        uint256 stakeAmount = 1e24;
        uint256 netStakeAmount = 1e24 - 1e22;

        vm.startPrank(Alice);
        psm.approve(address(fakeOracleVault), 1e55);
        fakeOracleVault.stake(stakeAmount);

        uint256 staked;
        uint256 winStreak;

        // 51 consequtive wins
        for (uint256 i = 0; i < 53; i++) {
            fakeOracleVault.castPrediction(2);

            uint256 settlement = fakeOracleVault.nextSettlement();
            vm.warp(settlement);

            fakeOracleVault.settleEpoch();

            // unstake and send rewards back to Vault so that we don't run out of funds
            (staked, winStreak) = fakeOracleVault.stakes(Alice);
            console.log(winStreak);

            if (staked > EPOCH_REWARD) {
                fakeOracleVault.unstake(EPOCH_REWARD);
                psm.transfer(address(fakeOracleVault), EPOCH_REWARD);
            }
        }

        // make one more prediction but don't settle so that both epochs have full vote power instead of reset
        fakeOracleVault.castPrediction(2);

        vm.stopPrank();

        // Verify results
        assertEq(staked, netStakeAmount + EPOCH_REWARD);
        assertEq(winStreak, 51);

        // Verify that vote power was capped
        uint256 votes1 = fakeOracleVault.downVotes(1);
        uint256 votes2 = fakeOracleVault.downVotes(2);

        assertEq(votes1, votes2);
        assertEq(votes1, VOTE_POWER_CAP);
    }

    // test the execution of predictions
    function testSuccess_castPrediction() public {
        // Alice stakes 1M
        uint256 stakeAmount = 1e24;
        uint256 netStakeAmount = 1e24 - 1e22;

        vm.startPrank(Alice);
        psm.approve(address(fakeOracleVault), 1e55);
        fakeOracleVault.stake(stakeAmount);

        // Alice makes the first prediction (up)
        fakeOracleVault.castPrediction(1);

        // Verify the prediction data storage
        uint256 activeEpoch = fakeOracleVault.activeEpochID();
        uint256 targetEpoch = (activeEpoch == 1) ? 2 : 1;

        assertEq(fakeOracleVault.upVotes(targetEpoch), UNIFORM_VOTEPOWER);
        assertEq(fakeOracleVault.downVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), 0);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), netStakeAmount);
        assertEq(fakeOracleVault.stakedDown(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), 0);

        // Verify Alice predictions
        (uint256 votes, uint256 upDown, uint256 forSettlement) = fakeOracleVault.predictions(1, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER);
        assertEq(upDown, 1);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        // Alice changes the prediction
        fakeOracleVault.castPrediction(2);

        // Verify the prediction data storage
        assertEq(fakeOracleVault.upVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.downVotes(targetEpoch), UNIFORM_VOTEPOWER);
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), 0);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(targetEpoch), netStakeAmount);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), 0);

        // Verify Alice predictions
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(1, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER);
        assertEq(upDown, 2);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        // Alice repeats the same prediction
        fakeOracleVault.castPrediction(2);

        // Verify the prediction data storage
        assertEq(fakeOracleVault.upVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.downVotes(targetEpoch), UNIFORM_VOTEPOWER);
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), 0);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(targetEpoch), netStakeAmount);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), 0);

        // Verify Alice predictions
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(1, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER);
        assertEq(upDown, 2);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        // Alice changes the prediction back again
        fakeOracleVault.castPrediction(1);

        // Verify the prediction data storage
        assertEq(fakeOracleVault.upVotes(targetEpoch), UNIFORM_VOTEPOWER);
        assertEq(fakeOracleVault.downVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), 0);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), netStakeAmount);
        assertEq(fakeOracleVault.stakedDown(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), 0);

        // Verify Alice predictions
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(1, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER);
        assertEq(upDown, 1);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        // Reduce Alice stake (update prediction)
        fakeOracleVault.unstake((netStakeAmount * 99) / 100);

        // Verify the prediction data storage
        assertEq(fakeOracleVault.upVotes(targetEpoch), 0); // changed to 0 because stake reduced below threshold
        assertEq(fakeOracleVault.downVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), 0);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), netStakeAmount / 100); // reduced stakedUp amount
        assertEq(fakeOracleVault.stakedDown(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), 0);

        // Verify Alice predictions
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(1, Alice);
        assertEq(votes, 0); // stake is below threshold
        assertEq(upDown, 1);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        // Increase Alice stake again (update prediction)
        fakeOracleVault.stake(stakeAmount);

        // Verify the prediction data storage
        assertEq(fakeOracleVault.upVotes(targetEpoch), UNIFORM_VOTEPOWER); // changed to 1 because stake above threshold
        assertEq(fakeOracleVault.downVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), 0);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), netStakeAmount + netStakeAmount / 100); // increased stakedUp amount
        assertEq(fakeOracleVault.stakedDown(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), 0);

        // Verify Alice predictions
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(1, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER); // stake is above threshold
        assertEq(upDown, 1);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        // Change and reduce Alice stake (update prediction)
        fakeOracleVault.castPrediction(2);
        fakeOracleVault.unstake(netStakeAmount);

        // Verify the prediction data storage
        assertEq(fakeOracleVault.upVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.downVotes(targetEpoch), 0); // 0 because stake below threshold
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), 0);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(targetEpoch), netStakeAmount / 100); // stake amount decreased and switched sides
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), 0);

        // Verify Alice predictions
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(1, Alice);
        assertEq(votes, 0); // stake is below threshold
        assertEq(upDown, 2);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        // Increase Alice stake (update prediction)
        fakeOracleVault.stake(stakeAmount);

        // Verify the prediction data storage
        assertEq(fakeOracleVault.upVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.downVotes(targetEpoch), UNIFORM_VOTEPOWER); // changed to 1 because stake above threshold
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), 0);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(targetEpoch), netStakeAmount + netStakeAmount / 100); // stake amount increased
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), 0);

        // Verify Alice predictions
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(1, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER); // stake is above threshold
        assertEq(upDown, 2);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        vm.stopPrank();
    }

    function testSuccess_castPrediction_changeVotePower() public {
        // Alice stakes 1M
        uint256 stakeAmount = 1e24;
        uint256 netStakeAmount = 1e24 - 1e22;

        vm.startPrank(Alice);
        psm.approve(address(fakeOracleVault), 1e55);
        fakeOracleVault.stake(stakeAmount);

        // Alice makes the prediction for epoch 1 (down)
        fakeOracleVault.castPrediction(2);

        // Verify the prediction data storage
        uint256 activeEpoch = fakeOracleVault.activeEpochID();
        uint256 targetEpoch = (activeEpoch == 1) ? 2 : 1;

        assertEq(fakeOracleVault.upVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.downVotes(targetEpoch), UNIFORM_VOTEPOWER);
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), 0);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(targetEpoch), netStakeAmount);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), 0);

        // Verify Alice predictions
        (uint256 votes, uint256 upDown, uint256 forSettlement) = fakeOracleVault.predictions(1, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER);
        assertEq(upDown, 2);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        // Settle epoch 0
        uint256 settlement = fakeOracleVault.nextSettlement();
        vm.warp(settlement);

        fakeOracleVault.settleEpoch();

        // Alice makes the prediction for epoch 2 (down)
        fakeOracleVault.castPrediction(2);

        // Verify the prediction data storage
        activeEpoch = fakeOracleVault.activeEpochID();
        targetEpoch = (activeEpoch == 1) ? 2 : 1;

        assertEq(fakeOracleVault.upVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.downVotes(targetEpoch), UNIFORM_VOTEPOWER);
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), UNIFORM_VOTEPOWER);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(targetEpoch), netStakeAmount);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), netStakeAmount);

        // Verify Alice predictions
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(2, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER);
        assertEq(upDown, 2);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        // Settle epoch 1 - Alice won
        settlement = fakeOracleVault.nextSettlement();
        vm.warp(settlement);

        fakeOracleVault.settleEpoch();

        // Alice makes the prediction for epoch 3 (down) & claims rewards from epoch 1
        fakeOracleVault.castPrediction(2);

        // Verify the prediction data storage - both predictions got updated stake & power
        activeEpoch = fakeOracleVault.activeEpochID();
        targetEpoch = (activeEpoch == 1) ? 2 : 1;
        assertEq(fakeOracleVault.upVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.downVotes(targetEpoch), UNIFORM_VOTEPOWER * 2);
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), UNIFORM_VOTEPOWER * 2);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(targetEpoch), netStakeAmount + EPOCH_REWARD);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), netStakeAmount + EPOCH_REWARD);

        // Verify Alice predictions & stake
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(1, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER * 2);
        assertEq(upDown, 2);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        (uint256 aliceStake, uint256 winStreak) = fakeOracleVault.stakes(Alice);
        assertEq(aliceStake, netStakeAmount + EPOCH_REWARD);
        assertEq(winStreak, 1);

        // Settle epoch 2 - Alice won again
        settlement = fakeOracleVault.nextSettlement();
        vm.warp(settlement);

        fakeOracleVault.settleEpoch();

        // Alice makes the prediction for epoch 4 (up) & claims rewards from epoch 2
        fakeOracleVault.castPrediction(1);

        // Verify the prediction data storage
        activeEpoch = fakeOracleVault.activeEpochID();
        targetEpoch = (activeEpoch == 1) ? 2 : 1;
        assertEq(fakeOracleVault.upVotes(targetEpoch), UNIFORM_VOTEPOWER * 4);
        assertEq(fakeOracleVault.downVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), UNIFORM_VOTEPOWER * 4);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), netStakeAmount + (2 * EPOCH_REWARD));
        assertEq(fakeOracleVault.stakedDown(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), netStakeAmount + (2 * EPOCH_REWARD));

        // Verify Alice predictions & stake
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(2, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER * 4);
        assertEq(upDown, 1);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        (aliceStake, winStreak) = fakeOracleVault.stakes(Alice);
        assertEq(aliceStake, netStakeAmount + (2 * EPOCH_REWARD));
        assertEq(winStreak, 2);

        // Settle epoch 3 - Alice won a third time
        settlement = fakeOracleVault.nextSettlement();
        vm.warp(settlement);

        fakeOracleVault.settleEpoch();

        // Alice makes the prediction for epoch 5 (up) & claims rewards from epoch 3
        fakeOracleVault.castPrediction(1);

        // Verify the prediction data storage
        activeEpoch = fakeOracleVault.activeEpochID();
        targetEpoch = (activeEpoch == 1) ? 2 : 1;
        assertEq(fakeOracleVault.upVotes(targetEpoch), UNIFORM_VOTEPOWER * 8);
        assertEq(fakeOracleVault.downVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.upVotes(activeEpoch), UNIFORM_VOTEPOWER * 8);
        assertEq(fakeOracleVault.downVotes(activeEpoch), 0);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), netStakeAmount + (3 * EPOCH_REWARD));
        assertEq(fakeOracleVault.stakedDown(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), netStakeAmount + (3 * EPOCH_REWARD));
        assertEq(fakeOracleVault.stakedDown(activeEpoch), 0);

        // Verify Alice predictions & stake
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(1, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER * 8);
        assertEq(upDown, 1);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        (aliceStake, winStreak) = fakeOracleVault.stakes(Alice);
        assertEq(aliceStake, netStakeAmount + (3 * EPOCH_REWARD));
        assertEq(winStreak, 3);

        // Settle epoch 4 - Alice lost -> reset of votepower
        settlement = fakeOracleVault.nextSettlement();
        vm.warp(settlement);

        fakeOracleVault.settleEpoch();

        // Alice makes the prediction for epoch 6 (down), no rewards from epoch 4
        fakeOracleVault.castPrediction(2);

        // Verify the prediction data storage
        activeEpoch = fakeOracleVault.activeEpochID();
        targetEpoch = (activeEpoch == 1) ? 2 : 1;
        assertEq(fakeOracleVault.upVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.downVotes(targetEpoch), UNIFORM_VOTEPOWER);
        assertEq(fakeOracleVault.upVotes(activeEpoch), UNIFORM_VOTEPOWER);
        assertEq(fakeOracleVault.downVotes(activeEpoch), 0);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(targetEpoch), netStakeAmount + (3 * EPOCH_REWARD));
        assertEq(fakeOracleVault.stakedUp(activeEpoch), netStakeAmount + (3 * EPOCH_REWARD));
        assertEq(fakeOracleVault.stakedDown(activeEpoch), 0);

        // Verify Alice predictions & stake
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(2, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER);
        assertEq(upDown, 2);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        (aliceStake, winStreak) = fakeOracleVault.stakes(Alice);
        assertEq(aliceStake, netStakeAmount + (3 * EPOCH_REWARD));
        assertEq(winStreak, 0);
    }

    // Revert cases
    function testRevert_castPrediction() public {
        // Scenario 1: invalid prediction
        vm.prank(Alice);
        vm.expectRevert(InvalidPrediction.selector);
        signalVault.castPrediction(4);

        // Scenario 2: Market isn't settled
        vm.warp(signalVault.nextSettlement());
        vm.prank(Alice);
        vm.expectRevert(WaitingToSettle.selector);
        signalVault.castPrediction(1);

        // Scenario 3: User has no stake
        vm.warp(signalVault.nextSettlement() - 1);
        vm.prank(Alice);
        vm.expectRevert(NoStake.selector);
        signalVault.castPrediction(1);
    }

    function testRevert_castPrediction_II() public {
        // Scenario 7: Market must be settled first
        vm.warp(signalVault.nextSettlement() + 1);

        vm.prank(Alice);
        vm.expectRevert(WaitingToSettle.selector);
        signalVault.castPrediction(1);
    }

    // test missing updatePrediction paths
    function testSuccess_updatePrediction() public {
        // Alice stakes 1M
        uint256 stakeAmount = 1e24;
        uint256 netStakeAmount = 1e24 - 1e22;
        uint256 unstakeAmount = (netStakeAmount * 9) / 10;

        vm.startPrank(Alice);
        psm.approve(address(fakeOracleVault), 1e55);
        fakeOracleVault.stake(stakeAmount);

        // Alice makes the prediction for epoch 1 (down)
        fakeOracleVault.castPrediction(2);

        // Verify the prediction data storage
        uint256 activeEpoch = fakeOracleVault.activeEpochID();
        uint256 targetEpoch = (activeEpoch == 1) ? 2 : 1;

        assertEq(fakeOracleVault.upVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.downVotes(targetEpoch), UNIFORM_VOTEPOWER);
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), 0);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(targetEpoch), netStakeAmount);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), 0);

        // Verify Alice predictions
        (uint256 votes, uint256 upDown, uint256 forSettlement) = fakeOracleVault.predictions(1, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER);
        assertEq(upDown, 2);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        // Settle epoch 0
        uint256 settlement = fakeOracleVault.nextSettlement();
        vm.warp(settlement);

        fakeOracleVault.settleEpoch();

        // Alice makes the prediction for epoch 2 (down)
        fakeOracleVault.castPrediction(2);

        // Verify the prediction data storage
        activeEpoch = fakeOracleVault.activeEpochID();
        targetEpoch = (activeEpoch == 1) ? 2 : 1;

        assertEq(fakeOracleVault.upVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.downVotes(targetEpoch), UNIFORM_VOTEPOWER);
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), UNIFORM_VOTEPOWER);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(targetEpoch), netStakeAmount);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), netStakeAmount);

        // Verify Alice predictions
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(2, Alice);
        assertEq(votes, UNIFORM_VOTEPOWER);
        assertEq(upDown, 2);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        // Alice unstakes 90% and updates the votes
        fakeOracleVault.unstake(unstakeAmount);

        // Verify the prediction data storage
        activeEpoch = fakeOracleVault.activeEpochID();
        targetEpoch = (activeEpoch == 1) ? 2 : 1;

        assertEq(fakeOracleVault.upVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.downVotes(targetEpoch), 0);
        assertEq(fakeOracleVault.upVotes(activeEpoch), 0);
        assertEq(fakeOracleVault.downVotes(activeEpoch), 0);

        assertEq(fakeOracleVault.stakedUp(targetEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(targetEpoch), netStakeAmount / 10);
        assertEq(fakeOracleVault.stakedUp(activeEpoch), 0);
        assertEq(fakeOracleVault.stakedDown(activeEpoch), netStakeAmount / 10);

        // Verify Alice predictions
        (votes, upDown, forSettlement) = fakeOracleVault.predictions(2, Alice);
        assertEq(votes, 0);
        assertEq(upDown, 2);
        assertEq(forSettlement, fakeOracleVault.nextSettlement() + EPOCH_DURATION);

        (votes, upDown, forSettlement) = fakeOracleVault.predictions(1, Alice);
        assertEq(votes, 0);
        assertEq(upDown, 2);
        assertEq(forSettlement, fakeOracleVault.nextSettlement());
    }

    // test the settlement
    function testSuccess_settleEpoch() public {
        uint256 settlement = fakeOracleVault.nextSettlement();
        vm.warp(settlement);

        vm.prank(Alice);
        fakeOracleVault.settleEpoch();

        assertEq(fakeOracleVault.nextSettlement(), settlement + fakeOracleVault.EPOCH_DURATION());
        assertEq(fakeOracleVault.last_settlementPrice(), 4200e18);
        assertEq(fakeOracleVault.vaultDirection(), 2); // no votes for this epoch -> sell
    }

    // Revert cases
    function testRevert_settleEpoch_noSequencer() public {
        // Scenario 1: Sequencer is down
        vm.expectRevert(SequencerDown.selector);
        fakeSequencerVault.settleEpoch();

        // Scenario 2: Sequencer got rebooted recently within the grace period
        uint256 timeStart = block.timestamp;
        vm.warp(lastReboot + 10);
        vm.expectRevert(GracePeriodNotOver.selector);
        signalVault.settleEpoch();
        vm.warp(timeStart);

        // Scenario 3: Cohort is still active
        vm.expectRevert(EpochActive.selector);
        signalVault.settleEpoch();

        // Scenario 4: Get a stale oracle price (freshness threshold)
        vm.warp(signalVault.nextSettlement());
        vm.expectRevert(StalePrice.selector);
        signalVault.settleEpoch(); // The ETHUSD oracle price at moment of fork snapshot is too long in the past when warping to settlement time

        // Scenario 5: Get a stale oracle price (roundID > answeredInRound)
        vm.expectRevert(StalePrice.selector);
        delayedOracleVault.settleEpoch();

        // Scenario 8: Get a false oracle price (0)
        vm.expectRevert(InvalidPrice.selector);
        brokenOracleVault.settleEpoch();
    }

    //////////////////////////////////////
    /////// TESTS - ASSET VAULT
    //////////////////////////////////////
    // test the owner ability to withdraw assets
    function testSuccess_withdrawTokens() public {
        uint256 amount = 1e23;
        uint256 treasuryStart = psm.balanceOf(treasury);

        vm.prank(Alice);
        psm.transfer(address(assetVault), amount);

        assertEq(psm.balanceOf(address(assetVault)), amount);
        assertEq(psm.balanceOf(Alice), psm_10million - amount);

        vm.prank(treasury);
        assetVault.withdrawTokens(address(psm));

        assertEq(psm.balanceOf(address(assetVault)), 0);
        assertEq(psm.balanceOf(treasury), treasuryStart + amount);
    }

    // Revert cases
    function testRevert_withdrawTokens() public {
        vm.prank(Alice);
        vm.expectRevert(NotOwner.selector);
        assetVault.withdrawTokens(address(usdc));
    }

    // test sweeping PSM to the Signal Vault
    function testSuccess_sweepPsmToSignalVault() public {
        uint256 amount = 1e24;

        vm.prank(treasury);
        psm.transfer(address(assetVault), amount);

        assertEq(psm.balanceOf(address(assetVault)), amount);

        assetVault.sweepPsmToSignalVault();

        assertEq(psm.balanceOf(address(assetVault)), 0);
    }

    // Revert cases
    function testrevert_sweepPsmToSignalVault() public {
        vm.expectRevert(InvalidAmount.selector);
        assetVault.sweepPsmToSignalVault();
    }

    // test the additional branch of the quoteSwapTokens() function
    function testSuccess_quoteSwapTokens() public {
        // Settle first epoch to get settlement price (4200)
        vm.warp(fakeOracleVault.nextSettlement());
        fakeOracleVault.settleEpoch();

        // call quote function with valid inputs & verify results
        uint256 usdcAmountSell = 4200e6; // 4200 USDC
        (uint256 wethAmountOut, uint256 usdcReturned) =
            fakeOracleAssetVault.quoteSwapTokens(address(usdc), usdcAmountSell); // 4200 USDC -> 1 WETH

        assertEq(wethAmountOut, 1e18);
        assertEq(usdcReturned, 0);

        // call quote function with opposite route than what is given by the Signal Vault
        uint256 wethAmountSell = 1e18; // 1 WETH
        (uint256 usdcAmountOut, uint256 usdcwethReturned) =
            fakeOracleAssetVault.quoteSwapTokens(address(weth), wethAmountSell); // 1 WETH -> full return because invalid route

        assertEq(usdcAmountOut, 0);
        assertEq(usdcwethReturned, wethAmountSell);
    }

    // test the swapping of upTokens and downTokens
    function testSuccess_swapTokens() public {
        // Settle first epoch to get settlement price (4200)
        vm.warp(fakeOracleVault.nextSettlement());
        fakeOracleVault.settleEpoch();
        uint256 price = fakeOracleVault.last_settlementPrice();

        uint256 usdcAmountSell = 4200e6; // 4200 USDC
        (uint256 wethAmountOut, uint256 usdcReturned) =
            fakeOracleAssetVault.quoteSwapTokens(address(usdc), usdcAmountSell); // 4200 USDC -> 1 ETH

        assertEq(wethAmountOut, 1e18);
        assertEq(usdcReturned, 0);

        // Alice sells USDC to Vault for WETH
        vm.startPrank(Alice);

        usdc.approve(address(fakeOracleAssetVault), 1e55);
        fakeOracleAssetVault.swapTokens(address(usdc), usdcAmountSell, 1, block.timestamp);

        vm.stopPrank();

        // Verify the correctness of swapped amounts and state changes
        assertEq(weth.balanceOf(Alice), weth10 + wethAmountOut);
        assertEq(usdc.balanceOf(Alice), usdc100k - usdcAmountSell);

        assertEq(weth.balanceOf(address(fakeOracleAssetVault)), weth10 - wethAmountOut);
        assertEq(usdc.balanceOf(address(fakeOracleAssetVault)), usdc100k + usdcAmountSell);

        // interim balances
        uint256 balAliceUsdc = usdc.balanceOf(Alice);
        uint256 balAliceWeth = weth.balanceOf(Alice);

        uint256 balVaultUsdc = usdc.balanceOf(address(fakeOracleAssetVault));
        uint256 balVaultWeth = weth.balanceOf(address(fakeOracleAssetVault));

        // Swap more than the Vault can handle (+ 42k USDC)
        uint256 usdcInput = usdcAmountSell * 10;
        (wethAmountOut, usdcReturned) = fakeOracleAssetVault.quoteSwapTokens(address(usdc), usdcInput); // return 9 WETH + 4200 USDC

        // Calculate the maximum input amount to receive the full balance of output token
        uint256 inputMax = (weth.balanceOf(address(fakeOracleAssetVault)) * price) / (10 ** 30); // USDC
        uint256 amountOut = (inputMax * (10 ** 30)) / price; // WETH

        assertEq(wethAmountOut, amountOut);
        assertEq(usdcReturned, usdcInput - inputMax);

        vm.prank(Alice);
        fakeOracleAssetVault.swapTokens(address(usdc), usdcInput, 1, block.timestamp);

        assertEq(weth.balanceOf(Alice), balAliceWeth + wethAmountOut);
        assertEq(usdc.balanceOf(Alice), balAliceUsdc - inputMax);
        assertEq(weth.balanceOf(address(fakeOracleAssetVault)), balVaultWeth - wethAmountOut);
        assertEq(usdc.balanceOf(address(fakeOracleAssetVault)), balVaultUsdc + inputMax);

        assertEq(usdc.balanceOf(Alice) + usdc.balanceOf(address(fakeOracleAssetVault)), 2 * usdc100k); // invariant testing
        assertEq(weth.balanceOf(Alice) + weth.balanceOf(address(fakeOracleAssetVault)), 2 * weth10); // invariant testing

        // vault gets predictions and is settled so that direction = 1
        vm.startPrank(Bob);
        psm.approve(address(fakeOracleVault), 1e55);
        fakeOracleVault.stake(1e24);
        fakeOracleVault.castPrediction(2);
        vm.stopPrank();

        vm.warp(fakeOracleVault.nextSettlement());
        fakeOracleVault.settleEpoch();

        vm.warp(fakeOracleVault.nextSettlement());
        fakeOracleVault.settleEpoch();

        // interim balances
        balAliceUsdc = usdc.balanceOf(Alice);
        balAliceWeth = weth.balanceOf(Alice);

        balVaultUsdc = usdc.balanceOf(address(fakeOracleAssetVault));
        balVaultWeth = weth.balanceOf(address(fakeOracleAssetVault));

        // Alice sells WETH to the Vault
        uint256 wethAmountSell = 1e18; // 1 WETH
        (uint256 usdcAmountOut, uint256 wethReturned) =
            fakeOracleAssetVault.quoteSwapTokens(address(weth), wethAmountSell);

        vm.startPrank(Alice);
        weth.approve(address(fakeOracleAssetVault), 1e55);
        fakeOracleAssetVault.swapTokens(address(weth), wethAmountSell, 1, block.timestamp);

        // Verify balance changes
        assertEq(weth.balanceOf(Alice), balAliceWeth - wethAmountSell);
        assertEq(usdc.balanceOf(Alice), balAliceUsdc + usdcAmountOut);
        assertEq(weth.balanceOf(address(fakeOracleAssetVault)), balVaultWeth + wethAmountSell);
        assertEq(usdc.balanceOf(address(fakeOracleAssetVault)), balVaultUsdc - usdcAmountOut);
        assertEq(wethReturned, 0);
    }

    // Revert cases
    function testRevert_swapTokens() public {
        uint256 wethAmountSell = 1e18;
        uint256 usdcAmountSell = 1e9;

        // Scenario 1: try swap before first settlement (price == 0, vaultDirection == 0)
        vm.startPrank(Alice);
        weth.approve(address(fakeOracleAssetVault), 1e55);
        usdc.approve(address(fakeOracleAssetVault), 1e55);

        vm.expectRevert(InvalidSwapDirection.selector);
        fakeOracleAssetVault.swapTokens(address(weth), wethAmountSell, 1, block.timestamp);

        vm.expectRevert(InvalidSwapDirection.selector);
        fakeOracleAssetVault.swapTokens(address(usdc), usdcAmountSell, 1, block.timestamp);

        // Settle first epoch to get settlement price (4200)
        uint256 settlement = fakeOracleVault.nextSettlement();
        vm.warp(settlement);
        fakeOracleVault.settleEpoch();
        uint256 price = fakeOracleVault.last_settlementPrice();

        assertEq(price, 4200e18);

        // Scenario 2: wrong token
        vm.expectRevert(InvalidToken.selector);
        fakeOracleAssetVault.swapTokens(address(psm), wethAmountSell, 1, block.timestamp);

        // Scenario 3: zero amount
        vm.expectRevert(InvalidAmount.selector);
        fakeOracleAssetVault.swapTokens(address(weth), 0, 1, block.timestamp);

        // Scenario 4: deadline expired
        vm.expectRevert(DeadlineExpired.selector);
        fakeOracleAssetVault.swapTokens(address(weth), wethAmountSell, 1, block.timestamp - 1);

        // Scenario 5: not received enough
        (uint256 expectedOut, uint256 returned) = fakeOracleAssetVault.quoteSwapTokens(address(usdc), usdcAmountSell);

        assertEq(returned, 0);
        assertTrue(expectedOut > 0);

        vm.expectRevert(InsufficientReceived.selector);
        fakeOracleAssetVault.swapTokens(address(usdc), usdcAmountSell, expectedOut + 1, block.timestamp);
    }

    // test the redeeming of PSM for vault assets
    function testSuccess_redeemPSM() public {
        uint256 balance = 1e23;
        uint256 redeemAmount = 1e23;
        uint256 balTreasury = psm.balanceOf(treasury);

        // load contract balance
        vm.prank(treasury);
        psm.transfer(address(assetVault), balance);

        uint256 expectedOut = (redeemAmount * balance) / REDEEM_BASE;
        uint256 outControl = assetVault.quoteRedeemPSM(address(psm), redeemAmount);

        assertEq(expectedOut, outControl);
        assertEq(psm.balanceOf(address(assetVault)), balance);

        // Scenario 1: redeem normally
        vm.startPrank(Alice);

        psm.approve(address(assetVault), 1e55);
        assetVault.redeemPSM(address(psm), redeemAmount, 1, block.timestamp);

        vm.stopPrank();

        assertEq(psm.balanceOf(address(assetVault)), balance - expectedOut);
        assertEq(psm.balanceOf(address(signalVault)), redeemAmount);
        assertEq(psm.balanceOf(Alice), psm_10million + expectedOut - redeemAmount);

        // Scenario 2: try redeem more than redeem limit (shoehorn amount)
        balTreasury = psm.balanceOf(treasury);
        balance = psm.balanceOf(address(assetVault));

        expectedOut = (balance * PSM_REDEEM_LIMIT) / REDEEM_BASE;
        outControl = assetVault.quoteRedeemPSM(address(psm), 1e55);
        assertEq(expectedOut, outControl);

        vm.startPrank(treasury);

        psm.approve(address(assetVault), 1e55);
        assetVault.redeemPSM(address(psm), PSM_REDEEM_LIMIT + redeemAmount, 1, block.timestamp);

        vm.stopPrank();

        assertEq(psm.balanceOf(address(assetVault)), balance - expectedOut);
        assertEq(psm.balanceOf(address(signalVault)), PSM_REDEEM_LIMIT + redeemAmount);
        assertEq(psm.balanceOf(treasury), balTreasury - PSM_REDEEM_LIMIT + expectedOut);
    }

    // Revert cases
    function testRevert_redeemPSM() public {
        uint256 redeemAmount = 1e23;
        uint256 balance = 1e23;

        // Scenario 1: address 0
        vm.startPrank(Alice);
        vm.expectRevert(InvalidToken.selector);
        assetVault.redeemPSM(address(0), redeemAmount, 1, block.timestamp);

        // Scenario 2: receive 0
        vm.expectRevert(InsufficientReceived.selector);
        assetVault.redeemPSM(address(psm), redeemAmount, 0, block.timestamp);

        // Scenario 3: receive less than minReceived
        psm.transfer(address(assetVault), balance);
        assertEq(psm.balanceOf(Alice), psm_10million - balance);
        assertEq(psm.balanceOf(address(assetVault)), balance);

        vm.expectRevert(InsufficientReceived.selector);
        assetVault.redeemPSM(address(psm), redeemAmount, 1e23, block.timestamp);

        // Scenario 4: deadline passed
        vm.expectRevert(DeadlineExpired.selector);
        assetVault.redeemPSM(address(psm), redeemAmount, 1, block.timestamp - 1);

        vm.stopPrank();
    }
}
