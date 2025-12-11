// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISignalVault} from "./interfaces/ISignalVault.sol";

// ============================================
error InvalidConstructor();
error NotOwner();
error InvalidAmount();
error InvalidToken();
error DeadlineExpired();
error InvalidSwapDirection();
error InsufficientReceived();
// ============================================

contract AssetVault {
    constructor(address _signalVault, uint256 _upTokenDecimals, uint256 _downTokenDecimals) {
        if (_signalVault == address(0)) revert InvalidConstructor();
        SIGNAL_VAULT = ISignalVault(_signalVault);

        UP_TOKEN = IERC20(SIGNAL_VAULT.UP_TOKEN());
        DOWN_TOKEN = IERC20(SIGNAL_VAULT.DOWN_TOKEN());

        if (_upTokenDecimals > 18 || _downTokenDecimals > 18) revert InvalidConstructor();
        TOKEN_DECIMAL_RATIO_ADJUSTMENT = 10 ** (_upTokenDecimals + 18 - _downTokenDecimals);
    }

    // ============================================
    // ==                STORAGE                 ==
    // ============================================
    using SafeERC20 for IERC20;

    ////////// Remove in later version /////////////
    address public owner = 0xa0BFD02a7a47CBCA7230E03fbf04A196C3E771E3;
    ////////// Remove in later version /////////////

    ISignalVault public immutable SIGNAL_VAULT; // The Vault that gives the buy or sell signal
    IERC20 public immutable UP_TOKEN;
    IERC20 public immutable DOWN_TOKEN;

    uint256 private immutable TOKEN_DECIMAL_RATIO_ADJUSTMENT;

    uint256 private constant PSM_REDEEM_LIMIT = 5e26; // Maximum 500M PSM per redeem transaction to protect the Vault from draining
    uint256 private constant REDEEM_BASE = 1e27; // 1Bn PSM = 100% of a specific token balance
    IERC20 private constant PSM = IERC20(0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5);

    // ============================================
    // ==                EVENTS                  ==
    // ============================================
    event RedeemedPSM(address indexed user, address indexed tokenOut, uint256 amountPSM, uint256 amountTokenOut);
    event Swap(address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    // ============================================
    // ==            OWNER FUNCTIONS             ==
    // ============================================
    ///@notice Allow the admin to withdraw any tokens
    function withdrawTokens(address _token) external {
        if (msg.sender != owner) revert NotOwner();

        uint256 amount = IERC20(_token).balanceOf(address(this));

        ///@dev Send the tokens to the owner
        IERC20(_token).safeTransfer(owner, amount);
    }

    // ============================================
    // ==               SWAP TOKENS              ==
    // ============================================
    ///@notice Simulate selling tokenUp or tokenDown for the opposite at the exchange rate of last settlementPrice
    ///@dev Any other token exchange or routes that go against vaultDirection return 0
    ///@dev Return the received amount of output tokens and reclaimed input if excessive to buy the full contract balance of output token
    function quoteSwapTokens(address _tokenIn, uint256 _amountIn)
        public
        view
        returns (uint256 amountOut, uint256 inputRefund)
    {
        ///@dev Flag if a swap happens
        bool executeSwap;

        ///@dev Vault buys tokenUp for tokenDown (e.g. input WETH for output USDC) -> direction up == 1
        if (_tokenIn == address(UP_TOKEN) && SIGNAL_VAULT.vaultDirection() == 1) {
            ///@dev calculate the maximum input amount to receive the full balance of output token
            uint256 balOutput = DOWN_TOKEN.balanceOf(address(this)); // USDC
            uint256 inputMax = (balOutput * TOKEN_DECIMAL_RATIO_ADJUSTMENT) / SIGNAL_VAULT.last_settlementPrice(); // WETH

            inputRefund = (_amountIn > inputMax) ? _amountIn - inputMax : 0;

            ///@dev take the real input amount and calculate the output amount
            uint256 realInput = (_amountIn > inputMax) ? inputMax : _amountIn;
            amountOut = (realInput * SIGNAL_VAULT.last_settlementPrice()) / TOKEN_DECIMAL_RATIO_ADJUSTMENT;

            executeSwap = true;
        }

        ///@dev Vault buys tokenDown for tokenUp (e.g. input USDC for output WETH) -> direction down == 2
        if (_tokenIn == address(DOWN_TOKEN) && SIGNAL_VAULT.vaultDirection() == 2) {
            ///@dev calculate the maximum input amount to receive the full balance of output token
            uint256 balOutput = UP_TOKEN.balanceOf(address(this)); // WETH
            uint256 inputMax = (balOutput * SIGNAL_VAULT.last_settlementPrice()) / TOKEN_DECIMAL_RATIO_ADJUSTMENT; // USDC

            inputRefund = (_amountIn > inputMax) ? _amountIn - inputMax : 0;

            ///@dev take the real input amount and calculate the output amount
            uint256 realInput = (_amountIn > inputMax) ? inputMax : _amountIn;
            amountOut = (realInput * TOKEN_DECIMAL_RATIO_ADJUSTMENT) / SIGNAL_VAULT.last_settlementPrice();

            executeSwap = true;
        }

        ///@dev Declare a refund of all input tokens if the route is invalid, i.e. no swap happens
        if (!executeSwap) inputRefund = _amountIn;
    }

    ///@notice Anyone can buy Up token for Down token when the current majority vote is UP and vice versa
    ///@dev The exchange rate is last settlementPrice quoted as tokenUp/tokenDown, e.g. ETH/USD
    ///@dev The exchange can only happen in the direction of the majority prediction (vaultDirection)
    function swapTokens(address _tokenIn, uint256 _amountIn, uint256 _minReceived, uint256 _deadline) external {
        // CHECKS
        ///@dev Input validation
        if (_tokenIn != address(UP_TOKEN) && _tokenIn != address(DOWN_TOKEN)) revert InvalidToken();
        if (_amountIn == 0) revert InvalidAmount();

        ///@dev Enforce the deadline
        if (block.timestamp > _deadline) revert DeadlineExpired();

        ///@dev Only allow swaps in the vaultDirection
        if (_tokenIn == address(UP_TOKEN) && SIGNAL_VAULT.vaultDirection() != 1) revert InvalidSwapDirection();
        if (_tokenIn == address(DOWN_TOKEN) && SIGNAL_VAULT.vaultDirection() != 2) revert InvalidSwapDirection();

        ///@dev Ensure the minimum expected value is received
        (uint256 amountOut, uint256 inputRefund) = quoteSwapTokens(_tokenIn, _amountIn);
        uint256 netInput = _amountIn - inputRefund;
        if (amountOut < _minReceived) revert InsufficientReceived();

        // EFFECTS - none

        // INTERACTIONS
        ///@dev Take input amount from caller
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), netInput);

        ///@dev Send output tokens
        if (_tokenIn == address(UP_TOKEN)) DOWN_TOKEN.safeTransfer(msg.sender, amountOut);
        if (_tokenIn == address(DOWN_TOKEN)) UP_TOKEN.safeTransfer(msg.sender, amountOut);

        ///@dev Emit event that tokens were swapped
        emit Swap(_tokenIn, netInput, amountOut);
    }

    // ============================================
    // ==           VAULT WITHDRAWAL             ==
    // ============================================
    ///@notice Allow anyone to sweep PSM tokens from this contract to the connected Signal Vault
    ///@dev PSM is not supposed to be in this contract
    ///@dev Sending PSM to the Signal Vault enables recycling as staking rewards
    function sweepPsmToSignalVault() external {
        uint256 balPSM = PSM.balanceOf(address(this));
        if (balPSM == 0) revert InvalidAmount();
        PSM.safeTransfer(address(SIGNAL_VAULT), balPSM);
    }

    ///@notice Returns the amount of tokens received by redeeming a given number of PSM
    ///@dev PSM is exchanged for a specified token of the Vault
    function quoteRedeemPSM(address _token, uint256 _amountPSM) public view returns (uint256 amountOut) {
        ///@dev Prevent Zero address
        if (_token == address(0)) revert InvalidToken();

        uint256 balance = IERC20(_token).balanceOf(address(this));
        uint256 amount = _amountPSM;

        ///@dev Ensure that the PSM amount is within the redeem limit
        if (amount > PSM_REDEEM_LIMIT) amount = PSM_REDEEM_LIMIT;

        ///@dev Calculate the amount received in exchange of PSM (redeem base for 100% of balance of one token)
        amountOut = (balance * amount) / REDEEM_BASE;
    }

    ///@notice Allow PSM holders to redeem their PSM for tokens from the Vault
    ///@dev Exchange PSM for tokens from the Vault where REDEEM_BASE = 100% of the token balance of a specified token
    ///@dev PSM is sent to the Signal Vault to refill the epoch rewards
    ///@dev PSM can be redeemed for PSM in the Vault in case of donations / accidental direct transfer
    function redeemPSM(address _token, uint256 _amountPSM, uint256 _minReceived, uint256 _deadline) external {
        uint256 amount = _amountPSM;
        // CHECKS
        ///@dev Ensure that the PSM amount is within the maximum for a single transaction
        if (amount > PSM_REDEEM_LIMIT) amount = PSM_REDEEM_LIMIT;

        ///@dev Ensure that some tokens are transferred (fool proofing)
        uint256 received = quoteRedeemPSM(_token, amount);
        if (received == 0) revert InsufficientReceived();

        ///@dev Ensure that the received amount matches the expected minimum (frontrun protection)
        if (received < _minReceived) revert InsufficientReceived();

        ///@dev Enforce the deadline
        if (_deadline < block.timestamp) revert DeadlineExpired();

        // INTERACTONS
        ///@dev Take PSM from the user and send to Signal Vault
        PSM.safeTransferFrom(msg.sender, address(SIGNAL_VAULT), amount);

        ///@dev Send specified token to the user
        IERC20(_token).safeTransfer(msg.sender, received);

        emit RedeemedPSM(msg.sender, _token, amount, received);
    }
}
