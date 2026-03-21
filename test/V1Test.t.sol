// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IChainlink} from "src/V1/interfaces/IChainlink.sol";
import {StakingVault} from "src/V1/StakingVault.sol";
import {RewardPool} from "src/V1/RewardPool.sol";
import {Market} from "src/V1/Market.sol";
import {SequencerOutage} from "test/mocks/SequencerOutage.sol";
import {BrokenOracle} from "test/mocks/BrokenOracle.sol";
import {FakeOracle} from "test/mocks/FakeOracle.sol";
import {DelayedOracle} from "test/mocks/DelayedOracle.sol";

// ============================================
error InvalidAmount();
error InvalidConstructor();
error NoRewards();

error FailedToSendNativeToken();
error InsufficientReceived();
error InvalidAddress();
error InvalidDeadline();
error NotAuthorized();
error NoBalance();
error StakingVaultSet();

// ============================================

contract V1Test is Test {
    // ============================================
    // ==                STORAGE                 ==
    // ============================================
    // addresses
    address payable Alice = payable(address(0x117));
    address payable Bob = payable(address(0x118));
    address payable Charlie = payable(address(0x119));
    address payable treasury = payable(0xa0BFD02a7a47CBCA7230E03fbf04A196C3E771E3);
    IERC20 psm = IERC20(0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5);
    IERC20 usdc = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20 weth = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IERC20 usdt = IERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);

    address usdcWhale = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;
    address wethWhale = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;

    // Token amounts
    uint256 usdc100k = 1e11;
    uint256 weth10 = 10e18;
    uint256 eth100 = 100e18;
    uint256 psm_10million = 1e25;

    // Contract instances
    RewardPool rewardPool;
    StakingVault stakingVault;
    Market market;

    Market brokenOracleMarket;
    Market fakeOracleMarket;
    Market fakeSequencerMarket;
    Market delayedOracleMarket;
    SequencerOutage sequencerOutageFeed;

    // time
    uint256 oneYear = 60 * 60 * 24 * 365;
    uint256 oneWeek = 60 * 60 * 24 * 7;
    uint256 oneDay = 60 * 60 * 24;

    // Sequencer historical data
    uint256 lastReboot = 1713187535;
    uint256 lastRound = 18446744073709551653;

    // Constants
    uint256 startPoints = 1e28;

    address constant uptimeFeedReal = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D; // Chainlink sequencer feed

    uint256 WITHDRAWAL_FEE_PERCENT = 1;

    address constant ETH_USD_CHAINLINK_ORACLE = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    IChainlink constant oracle = IChainlink(ETH_USD_CHAINLINK_ORACLE);
    uint256 constant ORACLE_RESPONSE_AT_FORK_HEIGHT = 11060800999999; // 110608.001 BTC/USD

    uint256 constant PRECISION = 18;

    uint256 constant WIN_MUL = 3;
    uint256 constant WIN_MUL_MAX = 100;
    uint256 constant ACTIVITY_MUL = 1;
    uint256 constant ACTIVITY_MUL_MAX = 10;

    // ============================================
    // ==                 SETUP                  ==
    // ============================================
    function setUp() public {
        // Create main net fork
        vm.createSelectFork({urlOrAlias: "alchemy_arbitrum_api", blockNumber: 389869015});

        // Create contract instances
        rewardPool = new RewardPool(treasury);
        stakingVault = new StakingVault(address(rewardPool));

        // Give PSM to entities & fake signal Vault
        vm.startPrank(address(treasury));
        psm.transfer(Alice, psm_10million);
        psm.transfer(Bob, psm_10million);
        psm.transfer(Charlie, psm_10million);
        psm.transfer(address(rewardPool), psm_10million);
        psm.transfer(address(stakingVault), psm_10million);
        vm.stopPrank();

        // send 10k USDC and 10 WETH to entities
        vm.startPrank(usdcWhale);
        usdc.transfer(address(stakingVault), usdc100k);
        usdc.transfer(address(rewardPool), usdc100k);
        usdc.transfer(Alice, usdc100k);
        usdc.transfer(Bob, usdc100k);
        usdc.transfer(Charlie, usdc100k);
        vm.stopPrank();

        vm.startPrank(wethWhale);
        weth.transfer(address(stakingVault), weth10);
        weth.transfer(address(rewardPool), weth10);
        weth.transfer(Alice, weth10);
        weth.transfer(Bob, weth10);
        weth.transfer(Charlie, weth10);
        vm.stopPrank();

        // Give 100 ETH to entities
        vm.deal(Alice, eth100); // 100 ETH
        vm.deal(Bob, eth100); // 100 ETH
        vm.deal(address(rewardPool), eth100); // 100 ETH
    }

    // ============================================
    // ==                HELPER                  ==
    // ============================================
    function helper_stake1M() public {
        psm.approve(address(stakingVault), 1e55);

        stakingVault.stake(1e24);
    }

    // ============================================
    // ==          TESTS - DEPLOYMENT            ==
    // ============================================
    // Check that all starting parameters are correct
    function testSuccess_verifyDeployments() public view {
        // stakingVault
        assertEq(address(stakingVault.REWARD_POOL()), address(rewardPool));
        assertEq(stakingVault.totalStaked(), 0);

        // rewardPool
        assertEq(rewardPool.owner(), treasury);
        assertEq(rewardPool.admin(), treasury);
        assertEq(rewardPool.treasurer(), treasury);
        assertEq(rewardPool.stakingVault(), address(0));
        assertEq(rewardPool.totalPoints(), startPoints);

        // market
    }

    // Revert of deployments
    function testRevert_constructor() public {
        // Reward pool
        vm.expectRevert(InvalidConstructor.selector);
        new RewardPool(address(0));

        // Staking vault
        vm.expectRevert(InvalidConstructor.selector);
        new StakingVault(address(0));
    }

    // ============================================
    // ==          TESTS - REWARD POOL           ==
    // ============================================
    // OWNER FUNCTIONS
    // Set the staking vault address
    function testSuccess_setStakingVault() public {
        assertEq(rewardPool.stakingVault(), address(0));

        vm.prank(treasury);
        rewardPool.setStakingVault(address(stakingVault));

        assertEq(rewardPool.stakingVault(), address(stakingVault));
    }

    function testRevert_setStakingVault() public {
        // Scenario 1: caller not owner
        vm.expectRevert(NotAuthorized.selector);
        rewardPool.setStakingVault(address(123));

        // Scenario 2: Zero address
        vm.startPrank(treasury);
        vm.expectRevert(InvalidAddress.selector);
        rewardPool.setStakingVault(address(0));

        // Scenario 3: Address already set
        rewardPool.setStakingVault(address(stakingVault));
        vm.expectRevert(StakingVaultSet.selector);
        rewardPool.setStakingVault(address(123));
    }

    // Transfer ownership
    function testSuccess_changeOwner() public {
        assertEq(rewardPool.owner(), treasury);

        vm.prank(treasury);
        rewardPool.changeOwner(Alice);

        assertEq(rewardPool.owner(), Alice);
    }

    function testRevert_changeOwner() public {
        vm.expectRevert(NotAuthorized.selector);
        rewardPool.changeOwner(Alice);
    }

    // Change the admin
    function testSuccess_changeAdmin() public {
        assertEq(rewardPool.admin(), treasury);

        // owner changes admin
        vm.prank(treasury);
        rewardPool.changeAdmin(Alice);

        assertEq(rewardPool.admin(), Alice);

        // admin changes admin
        vm.prank(Alice);
        rewardPool.changeAdmin(treasury);

        assertEq(rewardPool.admin(), treasury);
    }

    function testRevert_changeAdmin() public {
        // Scenario 1: Caller not authorized
        vm.expectRevert(NotAuthorized.selector);
        rewardPool.changeAdmin(Alice);

        // Scenario 2:
        vm.prank(treasury);
        vm.expectRevert(InvalidAddress.selector);
        rewardPool.changeAdmin(address(0));
    }

    // Change the treasurer
    function testSuccess_changeTreasurer() public {
        assertEq(rewardPool.treasurer(), treasury);

        // owner changes treasurer
        vm.prank(treasury);
        rewardPool.changeTreasurer(Alice);

        assertEq(rewardPool.treasurer(), Alice);

        // treasurer changes treasurer
        vm.prank(Alice);
        rewardPool.changeTreasurer(treasury);

        assertEq(rewardPool.treasurer(), treasury);
    }

    function testRevert_changeTreasurer() public {
        // Scenario 1: Caller not authorized
        vm.expectRevert(NotAuthorized.selector);
        rewardPool.changeTreasurer(Alice);

        // Scenario 2:
        vm.prank(treasury);
        vm.expectRevert(InvalidAddress.selector);
        rewardPool.changeTreasurer(address(0));
    }

    // Add, remove, update listed markets
    function testSuccess_updateMarket() public {
        // Owner updates list
        assertEq(rewardPool.activeMarkets(Charlie), false);

        vm.startPrank(treasury);
        rewardPool.updateMarket(Charlie, true);

        assertEq(rewardPool.activeMarkets(Charlie), true);

        // Admin updates list
        rewardPool.changeAdmin(Alice);
        vm.stopPrank();

        vm.prank(Alice);
        rewardPool.updateMarket(Bob, true);

        assertEq(rewardPool.activeMarkets(Bob), true);
    }

    function testRevert_updateMarket() public {
        // Not authorized
        vm.prank(Bob);
        vm.expectRevert(NotAuthorized.selector);
        rewardPool.updateMarket(Charlie, true);
    }

    // Withdraw any token
    function testSuccess_withdrawTokens() public {
        assertEq(usdc.balanceOf(address(rewardPool)), usdc100k);
        assertEq(address(rewardPool).balance, eth100);

        vm.startPrank(treasury);
        rewardPool.changeTreasurer(Alice);

        // withdraw ERC20
        rewardPool.withdrawTokens(address(usdc));
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(rewardPool)), 0);

        // withdraw ETH
        vm.prank(Alice);
        rewardPool.withdrawTokens(address(0));

        assertEq(address(rewardPool).balance, 0);
    }

    function testRevert_withdrawTokens() public {
        // Scenario 1: Not authorized
        vm.expectRevert(NotAuthorized.selector);
        rewardPool.withdrawTokens(address(usdc));

        // Scenario 2: No balance
        vm.startPrank(treasury);
        rewardPool.withdrawTokens(address(usdc));

        vm.expectRevert(NoBalance.selector);
        rewardPool.withdrawTokens(address(usdc));

        // Scenario 3: Cannot receive ETH
        rewardPool.changeTreasurer(address(stakingVault));
        vm.stopPrank();

        vm.prank(address(stakingVault));
        vm.expectRevert(FailedToSendNativeToken.selector);
        rewardPool.withdrawTokens(address(0));
    }

    // CORE FUNCTIONS
    // Add points via whitelisted address
    function testSuccess_addPoints() public {
        assertEq(rewardPool.activeMarkets(Alice), false);

        vm.prank(treasury);
        rewardPool.updateMarket(Alice, true);

        assertEq(rewardPool.activeMarkets(Alice), true);
        assertEq(rewardPool.userAvailablePoints(Bob), 0);

        // Give points to Bob
        vm.prank(Alice);
        rewardPool.addPoints(Bob, startPoints);

        assertEq(rewardPool.userAvailablePoints(Bob), startPoints);
        assertEq(rewardPool.totalPoints(), startPoints * 2);
        assertEq(rewardPool.getReward(Bob, address(usdc)), usdc100k / 2);

        // Give points to Alice, check reward impact from point supply increase
        vm.prank(Alice);
        rewardPool.addPoints(Alice, startPoints);

        assertEq(rewardPool.userAvailablePoints(Alice), startPoints);
        assertEq(rewardPool.totalPoints(), startPoints * 3);
        assertEq(rewardPool.getReward(Bob, address(usdc)), usdc100k / 3);
    }

    function testRevert_addPoints() public {
        vm.expectRevert(NotAuthorized.selector);
        rewardPool.addPoints(Bob, startPoints);
    }

    // Claim rewards by redeeming points
    function testSuccess_claim() public {
        vm.prank(treasury);
        rewardPool.updateMarket(Alice, true);

        // Give points to Bob
        vm.prank(Alice);
        rewardPool.addPoints(Bob, startPoints);

        // Bob claims rewards in ETH (+50)
        vm.prank(Bob);
        rewardPool.claim(Bob, address(0));

        uint256 outputBob = (eth100 * startPoints) / (2 * startPoints);

        assertEq(Bob.balance, eth100 + outputBob);
        assertEq(address(rewardPool).balance, eth100 - outputBob);
        assertEq(rewardPool.userAvailablePoints(Bob), 0);
        assertEq(rewardPool.userRedeemedPoints(Bob), startPoints);
        assertEq(rewardPool.totalPoints(), startPoints * 2);

        // Give points to Alice
        vm.prank(Alice);
        rewardPool.addPoints(Alice, startPoints);

        // Alice claims rewards in ETH (+16.666)
        vm.prank(Alice);
        rewardPool.claim(Alice, address(0));

        uint256 outputAlice = (eth100 - outputBob) * startPoints / (3 * startPoints); // 16.666

        assertEq(Alice.balance, eth100 + outputAlice);
        assertEq(address(rewardPool).balance, eth100 - outputBob - outputAlice);
        assertEq(rewardPool.userAvailablePoints(Alice), 0);
        assertEq(rewardPool.userRedeemedPoints(Alice), startPoints);
        assertEq(rewardPool.totalPoints(), startPoints * 3);

        // Give points to Bob
        vm.prank(Alice);
        rewardPool.addPoints(Bob, startPoints);

        // Set the staking vault address
        vm.prank(treasury);
        rewardPool.setStakingVault(address(stakingVault));

        // Bob claims rewards in PSM via the staking vault (simulated) + 2.5M PSM
        vm.prank(address(stakingVault));
        rewardPool.claim(Bob, address(psm));

        outputBob = (psm_10million * startPoints) / (4 * startPoints);

        assertEq(psm.balanceOf(address(stakingVault)), outputBob + psm_10million); // staking vault gets the PSM to compound for Bob
        assertEq(psm.balanceOf(address(rewardPool)), psm_10million - outputBob);
        assertEq(rewardPool.userAvailablePoints(Bob), 0);
        assertEq(rewardPool.userRedeemedPoints(Bob), 2 * startPoints);
        assertEq(rewardPool.totalPoints(), startPoints * 4);
    }

    function testRevert_claim() public {
        vm.prank(treasury);
        rewardPool.updateMarket(Alice, true);

        vm.prank(Alice);
        rewardPool.addPoints(Bob, startPoints);

        // Scenario 1: No balance to claim
        vm.prank(Bob);
        vm.expectRevert(NoRewards.selector);
        rewardPool.claim(Bob, address(usdt));

        // Scenario 2: cannot receive ETH
        vm.prank(Alice);
        rewardPool.addPoints(address(stakingVault), startPoints);

        vm.prank(address(stakingVault));
        vm.expectRevert(FailedToSendNativeToken.selector);
        rewardPool.claim(payable(address(stakingVault)), address(0));
    }

    // Sell PSM for assets in the pool
    function testSuccess_sellPsmForAsset() public {
        // Alice sells PSM for USDC
        uint256 inputAlice = 1e24; // 1M
        uint256 balUSDC = usdc.balanceOf(address(rewardPool));
        uint256 outputAlice = (inputAlice * balUSDC) / (inputAlice + psm_10million);
        uint256 outputCalc = rewardPool.quoteSellPsmForAsset(address(usdc), inputAlice);

        assertEq(outputAlice, outputCalc);

        vm.startPrank(Alice);
        psm.approve(address(rewardPool), 1e55);
        rewardPool.sellPsmForAsset(address(usdc), inputAlice, 1, block.timestamp);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(rewardPool)), usdc100k - outputAlice);
        assertEq(usdc.balanceOf(Alice), usdc100k + outputAlice);
        assertEq(psm.balanceOf(address(rewardPool)), 11e24);
        assertEq(psm.balanceOf(Alice), 9e24);

        // Contract loses all PSM
        vm.prank(address(rewardPool));
        psm.transfer(treasury, 11e24);

        // Bob sells PSM for ETH
        uint256 inputBob = 1e24;
        uint256 balETH = address(rewardPool).balance;
        uint256 outputBob = (balETH * inputBob) / (inputBob + 1e24); // 1e24 is the minimum enforced PSM balance

        vm.startPrank(Bob);
        psm.approve(address(rewardPool), 1e55);
        rewardPool.sellPsmForAsset(address(0), inputBob, 1, block.timestamp);
        vm.stopPrank();

        assertEq(address(rewardPool).balance, eth100 - outputBob); // 50 eth
        assertEq(Bob.balance, eth100 + outputBob); // 150 eth
        assertEq(psm.balanceOf(address(rewardPool)), inputBob); // 1M PSM
        assertEq(psm.balanceOf(Bob), 9e24); // 9M PSM
    }

    function testRevert_sellPsmForAsset() public {
        // Scenario 1: Zero input
        vm.startPrank(Alice);
        vm.expectRevert(InvalidAmount.selector);
        rewardPool.sellPsmForAsset(address(usdc), 0, 0, block.timestamp);

        // Scenario 2: No balance
        vm.expectRevert(InsufficientReceived.selector);
        rewardPool.sellPsmForAsset(address(usdt), 1e18, 0, block.timestamp);

        // Scenario 3: Try get PSM
        vm.expectRevert(InsufficientReceived.selector);
        rewardPool.sellPsmForAsset(address(psm), 1e18, 0, block.timestamp);

        // Scenario 4: Insufficient reveived
        vm.expectRevert(InsufficientReceived.selector);
        rewardPool.sellPsmForAsset(address(usdc), 1e18, 1e22, block.timestamp);

        // Scenario 5: Deadline expired
        vm.expectRevert(InvalidDeadline.selector);
        rewardPool.sellPsmForAsset(address(usdc), 1e18, 0, block.timestamp - 1);
        vm.stopPrank();

        // Scenario 6: cannot receive ETH
        vm.startPrank(address(stakingVault));
        psm.approve(address(rewardPool), 1e55);
        vm.expectRevert(FailedToSendNativeToken.selector);
        rewardPool.sellPsmForAsset(address(0), 1e18, 0, block.timestamp);
    }

    // ============================================
    // ==         TESTS - STAKING VAULT          ==
    // ============================================
    // Test staking
    function testSuccess_stake() public {}

    function testRevert_stake() public {}

    // Test unstaking
    function testSuccess_unstake() public {}

    function testRevert_unstake() public {}

    // Test compounding
    function testSuccess_compound() public {}

    function testRevert_compound() public {}

    // test sweep
    function testSuccess_sweep() public {}

    // ============================================
    // ==            TESTS - MARKET              ==
    // ============================================
}
