// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {AutoSettlementLP} from "src/MVP/AutoSettlementLP.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============================================
error DeadlineExpired();
error FailedToSendNativeToken();
error InsufficientReceived();
error InvalidAddress();
error InvalidAmount();
error InvalidToken();
error NotOwner();
error ZeroBalance();
// ============================================

contract AutoSettlementLPTest is Test {
    IERC20 PSM = IERC20(0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5); // PSM
    address SIGNAL_VAULT = 0xb800B8dbCF9A78b16F5C1135Cd1A39384ABf1fbc;
    address usdt = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    uint256 constant SWAP_FEE_PRECISION = 10000;
    uint256 constant SWAP_FEE = 5; // 0.05%

    AutoSettlementLP lp;

    uint256 ethAmounts = 10e18;
    uint256 psmAmounts = 10_000_000e18;
    address payable owner = payable(0xa0BFD02a7a47CBCA7230E03fbf04A196C3E771E3);
    address payable Alice = payable(address(0x117));
    address payable Bob = payable(address(0x118));

    // PSM Treasury
    address psmSender = 0xAb845D09933f52af5642FC87Dd8FBbf553fd7B33;

    //////////////////////////////////////
    /////// SETUP
    //////////////////////////////////////
    function setUp() public {
        // Create main net fork
        vm.createSelectFork({urlOrAlias: "alchemy_arbitrum_api", blockNumber: 432259450});

        // Deploy the LP contract
        lp = new AutoSettlementLP(owner);

        // Send PSM to users
        vm.startPrank(owner);
        PSM.transfer(Alice, psmAmounts);
        PSM.transfer(Bob, psmAmounts);
        vm.stopPrank();

        // Send ETH to users
        vm.deal(Alice, ethAmounts);
        vm.deal(Bob, ethAmounts);
        vm.deal(owner, ethAmounts);
    }

    //////////////////////////////////////
    /////// TESTS - Deployment
    //////////////////////////////////////
    function testSuccess_deployment() public {
        lp = new AutoSettlementLP(Alice);

        assertEq(lp.owner(), Alice);
    }

    // Revert cases
    function testRevert_deployment() public {
        vm.expectRevert(InvalidAddress.selector);
        lp = new AutoSettlementLP(address(0));
    }

    //////////////////////////////////////
    /////// TESTS - Owner Functions
    //////////////////////////////////////
    // Change owner
    function testSuccess_changeOwner() public {
        vm.prank(owner);
        lp.changeOwner(Bob);

        assertEq(lp.owner(), Bob);
    }

    // Revert cases
    function testRevert_changeOwner() public {
        // Scenario 1: Unauthorized caller
        vm.prank(Bob);
        vm.expectRevert(NotOwner.selector);
        lp.changeOwner(Bob);

        // Scenario 2: null address
        vm.prank(owner);
        vm.expectRevert(InvalidAddress.selector);
        lp.changeOwner(address(0));
    }

    // Set active markets
    function testSuccess_setActiveMarket() public {
        // add new market
        vm.prank(owner);
        lp.setActiveMarket(SIGNAL_VAULT, 0);

        assertEq(lp.markets(0), SIGNAL_VAULT);
        assertEq(lp.markets(1), address(0));
        assertEq(lp.lastMarketID(), 0);

        // override market
        vm.prank(owner);
        lp.setActiveMarket(Alice, 0);

        assertEq(lp.markets(0), Alice);
        assertEq(lp.markets(1), address(0));
        assertEq(lp.lastMarketID(), 0);

        // add second market
        vm.prank(owner);
        lp.setActiveMarket(SIGNAL_VAULT, 1);

        assertEq(lp.markets(0), Alice);
        assertEq(lp.markets(1), SIGNAL_VAULT);
        assertEq(lp.lastMarketID(), 1);
    }

    // Revert cases
    function testRevert_setActiveMarket() public {
        // Scenario 1: Unauthorized caller
        vm.prank(Bob);
        vm.expectRevert(NotOwner.selector);
        lp.setActiveMarket(SIGNAL_VAULT, 0);
    }

    // sweep LP balances and reset
    function testSuccess_sweepAndReset() public {
        uint256 amountSend = 1e18;

        // send tokens to contract
        vm.startPrank(owner);
        PSM.transfer(address(lp), amountSend);
        (bool success,) = address(lp).call{value: amountSend}("");
        if (!success) revert FailedToSendNativeToken();

        // Verify balance changes
        assertEq(address(lp).balance, amountSend);
        assertEq(PSM.balanceOf(address(lp)), amountSend);

        // sweep balances
        lp.sweepAndReset();

        // Verify balance changes
        assertEq(address(lp).balance, 0);
        assertEq(PSM.balanceOf(address(lp)), 0);
    }

    // Revert cases
    function testRevert_sweepAndReset() public {
        // Scenario 1: Unauthorized caller
        vm.prank(Bob);
        vm.expectRevert(NotOwner.selector);
        lp.sweepAndReset();

        // Scenario 2: no tokens (both)
        vm.prank(owner);
        vm.expectRevert(ZeroBalance.selector);
        lp.sweepAndReset();
    }

    // Withdraw random ERC20 token
    function testSuccess_withdraw() public {
        uint256 balanceUSDT = IERC20(usdt).balanceOf(owner);

        vm.startPrank(owner);
        IERC20(usdt).transfer(address(lp), balanceUSDT);

        // Verify balance changes
        assertTrue(IERC20(usdt).balanceOf(owner) == 0);
        assertTrue(IERC20(usdt).balanceOf(address(lp)) > 0);

        // withdraw tokens
        lp.withdraw(usdt);

        // Verify balance changes
        assertTrue(IERC20(usdt).balanceOf(owner) > 0);
        assertTrue(IERC20(usdt).balanceOf(address(lp)) == 0);
    }

    // Revert cases
    function testRevert_withdraw() public {
        // Scenario 1: Unauthorized caller
        vm.prank(Bob);
        vm.expectRevert(NotOwner.selector);
        lp.sweepAndReset();

        // Scenario 2: is PSM
        vm.startPrank(owner);
        vm.expectRevert(InvalidToken.selector);
        lp.withdraw(address(PSM));

        // Scenario 3: is ETH
        vm.expectRevert(InvalidToken.selector);
        lp.withdraw(address(0));

        // Scenario 4: no balance
        vm.expectRevert(ZeroBalance.selector);
        lp.withdraw(usdt);
    }

    //////////////////////////////////////
    /////// TESTS - Swaps
    //////////////////////////////////////
    // Quote Swap
    function testSuccess_quoteSwap() public {
        // Fund pool
        uint256 fundingPSM = 100_000_000e18;
        uint256 fundingETH = 1e18;

        vm.startPrank(owner);
        PSM.transfer(address(lp), fundingPSM);
        (bool success,) = address(lp).call{value: fundingETH}("");
        if (!success) revert FailedToSendNativeToken();

        // Set active market
        lp.setActiveMarket(SIGNAL_VAULT, 0);
        vm.stopPrank();

        // Params
        uint256 ethIn = 1e18;
        uint256 psmIn = 1e24;
        uint256 balanceETH = address(lp).balance;
        uint256 balancePSM = PSM.balanceOf(address(lp));

        // calculate expected return (input ETH)
        uint256 amountExpectedAfterFees =
            (ethIn * balancePSM * (SWAP_FEE_PRECISION - SWAP_FEE)) / ((ethIn + balanceETH) * SWAP_FEE_PRECISION) - 1;

        // call quote function (input ETH)
        uint256 result = lp.quoteSwap(address(0), ethIn, false);

        assertEq(result, amountExpectedAfterFees);

        // calculate expected return (input PSM)
        amountExpectedAfterFees =
            (psmIn * balanceETH * (SWAP_FEE_PRECISION - SWAP_FEE)) / ((psmIn + balancePSM) * SWAP_FEE_PRECISION) - 1;

        // call quote function (input ETH)
        result = lp.quoteSwap(address(PSM), psmIn, false);

        assertEq(result, amountExpectedAfterFees);
    }

    // Swaps ETH -> PSM and vice versa
    function testSuccess_swap() public {
        // Fund pool
        uint256 fundingPSM = 100_000_000e18;
        uint256 fundingETH = 1e18;

        vm.startPrank(owner);
        PSM.transfer(address(lp), fundingPSM);
        (bool success,) = address(lp).call{value: fundingETH}("");
        if (!success) revert FailedToSendNativeToken();

        // Set active market
        lp.setActiveMarket(SIGNAL_VAULT, 0);
        vm.stopPrank();

        // Scenario 1: Alice sells smallest possible PSM amount to get positive output - fee is considered
        uint256 preSwapBalanceEth = address(lp).balance;
        uint256 preSwapBalancePsm = PSM.balanceOf(address(lp));

        uint256 amountIn1 = 1000000000;

        uint256 amountOutNoFees = (amountIn1 * fundingETH) / (amountIn1 + fundingPSM);

        vm.startPrank(Alice);
        PSM.approve(address(lp), 1e55);
        lp.swap(address(PSM), amountIn1, 1, block.timestamp);

        uint256 gainedEthAlice1 = Alice.balance - ethAmounts;

        assertEq(amountOutNoFees, gainedEthAlice1 + 1); // min fee 1 WEI
        assertEq(PSM.balanceOf(Alice), psmAmounts - amountIn1);

        assertEq(address(lp).balance, preSwapBalanceEth - gainedEthAlice1);
        assertEq(PSM.balanceOf(address(lp)), fundingPSM + amountIn1);

        // Scenario 2: Alice sell PSM, verify correct fee calculation
        preSwapBalanceEth = address(lp).balance;
        preSwapBalancePsm = PSM.balanceOf(address(lp));

        uint256 amountIn2 = 1000000e18;

        uint256 amountExpectedAfterFees = (amountIn2 * preSwapBalanceEth * (SWAP_FEE_PRECISION - SWAP_FEE))
            / ((amountIn2 + preSwapBalancePsm) * SWAP_FEE_PRECISION) - 1;

        lp.swap(address(PSM), amountIn2, 1, block.timestamp);

        vm.stopPrank();

        uint256 gainedEthAlice2 = Alice.balance - ethAmounts - gainedEthAlice1;
        assertEq(amountExpectedAfterFees, gainedEthAlice2);
        assertEq(PSM.balanceOf(Alice), psmAmounts - amountIn1 - amountIn2);

        assertEq(address(lp).balance, preSwapBalanceEth - amountExpectedAfterFees);
        assertEq(PSM.balanceOf(address(lp)), preSwapBalancePsm + amountIn2);

        // Scenario 3: Bob swaps ETH for PSM, verify amounts and balance change
        preSwapBalanceEth = address(lp).balance;
        preSwapBalancePsm = PSM.balanceOf(address(lp));

        uint256 ethInBob = 1e18;

        uint256 amountExpectedPsmAfterFees = ((ethInBob * preSwapBalancePsm) * (SWAP_FEE_PRECISION - SWAP_FEE))
            / ((ethInBob + preSwapBalanceEth) * SWAP_FEE_PRECISION) - 1;

        vm.prank(Bob);
        lp.swap{value: ethInBob}(address(0), 1, 1, block.timestamp);

        uint256 psmGainedBob = PSM.balanceOf(Bob) - psmAmounts;
        assertEq(amountExpectedPsmAfterFees, psmGainedBob);
        assertEq(Bob.balance, ethAmounts - ethInBob);

        assertEq(address(lp).balance, preSwapBalanceEth + ethInBob);
        assertEq(PSM.balanceOf(address(lp)), preSwapBalancePsm - psmGainedBob);
    }

    // Revert Cases
    function testRevert_swap() public {
        // Fund pool only PSM
        uint256 fundingPSM = 100_000_000e18;

        vm.prank(owner);
        PSM.transfer(address(lp), fundingPSM);

        // Scenario 1: try swap if no market has been set (nextSettlement call fails)
        vm.prank(Alice);
        vm.expectRevert();
        lp.swap{value: 1e18}(address(0), 1e18, 1, block.timestamp);

        // Set active market
        vm.prank(owner);
        lp.setActiveMarket(SIGNAL_VAULT, 0);

        // Scenario 2: try swap if pool is not balanced
        vm.prank(Alice);
        vm.expectRevert(InsufficientReceived.selector);
        lp.swap{value: 1e18}(address(0), 1e18, 1, block.timestamp);

        // Fund pool, add ETH - pool is now balanced
        uint256 fundingETH = 1e18;

        vm.prank(owner);
        (bool success,) = address(lp).call{value: fundingETH}("");
        if (!success) revert FailedToSendNativeToken();

        // Scenario 3: Try circumvent fee via rounding
        vm.startPrank(Alice);
        PSM.approve(address(lp), 1e55);
        vm.expectRevert(InsufficientReceived.selector);
        lp.swap(address(PSM), 100_000_000, 1, block.timestamp);

        // Scenario 4: amount in 0 (ETH)
        vm.expectRevert(InvalidAmount.selector);
        lp.swap{value: 0}(address(0), 100_000_000, 1, block.timestamp);

        // Scenario 5: amount in 0 (PSM)
        vm.expectRevert(InvalidAmount.selector);
        lp.swap(address(PSM), 0, 1, block.timestamp);

        // Scenario 6: minimum received 0
        vm.expectRevert(InvalidAmount.selector);
        lp.swap(address(PSM), 1e18, 0, block.timestamp);

        // Scenario 7: expired deadline
        vm.expectRevert(DeadlineExpired.selector);
        lp.swap(address(PSM), 1e18, 1, block.timestamp - 1);
    }
}
