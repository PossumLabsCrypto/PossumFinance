// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IChainlink} from "./interfaces/IChainlink.sol";
import {ISignalVault} from "./interfaces/ISignalVault.sol";

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

contract AutoSettlementLP {
    constructor(address _owner) {
        if (_owner == address(0)) revert InvalidAddress();
        owner = _owner;
    }

    // ============================================
    // ==                STORAGE                 ==
    // ============================================
    using SafeERC20 for IERC20;

    IERC20 private constant PSM = IERC20(0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5);
    uint256 private constant SWAP_FEE_PRECISION = 10000;
    uint256 private constant SWAP_FEE = 5; // 0.05%

    address public owner;
    uint256 public totalEthVolume;

    mapping(uint256 marketID => address market) public markets;
    uint256 public lastMarketID;

    // ============================================
    // ==                 EVENTS                 ==
    // ============================================
    event OwnerChanged(address oldOwner, address newOwner);
    event Sweeped(address indexed token, uint256 amount);

    event Swap(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    // ============================================
    // ==            OWNER FUNCTIONS             ==
    // ============================================
    function changeOwner(address _newOwner) external {
        checkOwner(msg.sender);
        if (_newOwner == address(0)) revert InvalidAddress();

        owner = _newOwner;

        emit OwnerChanged(msg.sender, owner);
    }

    function setActiveMarket(address _market, uint256 _marketID) external {
        checkOwner(msg.sender);

        ///@dev Set (override) a market address at specified ID in the mapping
        markets[_marketID] = _market;

        ///@dev Increase last market tracker if the ID is greater than any previous ID
        if (_marketID > lastMarketID) lastMarketID = _marketID;
    }

    function sweepAndReset() external {
        checkOwner(msg.sender);

        uint256 balancePSM = PSM.balanceOf(address(this));
        uint256 balanceETH = address(this).balance;
        if (balancePSM == 0 && balanceETH == 0) revert ZeroBalance();

        // Reset market counter
        lastMarketID = 0;

        // Send tokens to owner
        PSM.safeTransfer(owner, balancePSM);

        address payable ownerPayable = payable(owner);
        (bool success,) = ownerPayable.call{value: balanceETH}("");
        if (!success) revert FailedToSendNativeToken();

        emit Sweeped(address(PSM), balancePSM);
        emit Sweeped(address(0), balanceETH);
    }

    function withdraw(address _token) external {
        checkOwner(msg.sender);
        if (_token == address(0)) revert InvalidToken();
        if (_token == address(PSM)) revert InvalidToken();

        IERC20 token = IERC20(_token);
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert ZeroBalance();

        token.safeTransfer(owner, balance);

        emit Sweeped(_token, balance);
    }

    function checkOwner(address _caller) internal view {
        if (_caller != owner) revert NotOwner();
    }

    // ============================================
    // ==          EXTERNAL FUNCTIONS            ==
    // ============================================
    ///@notice Get results for a swap of PSM to ETH or ETH to PSM
    ///@dev Calculate swaps based on current token balances using the constant product fomula k = x * y
    ///@param _tokenIn Input token, either address(0) or PSM address
    ///@param _amountIn Number of input tokens sold to the contract
    ///@return amountOut Number of output tokens received. Output token is the opposite of input token (ETH or PSM)
    function quoteSwap(address _tokenIn, uint256 _amountIn, bool internalCall) public view returns (uint256 amountOut) {
        /// @dev Get the PSM token reserve
        uint256 reserve0 = PSM.balanceOf(address(this));

        /// @dev Get the reserve of ETH
        uint256 reserve1 = address(this).balance;

        ///@dev Calculate pre-call ETH balance when input is ETH and called from this contract
        ///@dev Avoid double counting ETH from msg.value when this function is called from an active swap
        if (internalCall && _tokenIn == address(0)) {
            uint256 preCallEthBalance = reserve1 - _amountIn;
            reserve1 = preCallEthBalance;
        }

        ///@dev return 0 if either balance is 0 (prevent swaps until pool is balanced)
        if (reserve0 == 0 || reserve1 == 0) return 0;

        ///@dev Calculate input after fee
        uint256 inputAfterFee = (_amountIn * (SWAP_FEE_PRECISION - SWAP_FEE)) / SWAP_FEE_PRECISION;

        ///@dev Add a minimum fee of 1 WEI, prevent free swaps
        uint256 result = (inputAfterFee * reserve1) / (_amountIn + reserve0);
        if (_tokenIn == address(PSM)) amountOut = (result > 0) ? result - 1 : 0;

        result = (inputAfterFee * reserve0) / (_amountIn + reserve1);
        if (_tokenIn == address(0)) amountOut = (result > 0) ? result - 1 : 0;
    }

    ///@notice Sell PSM for ETH or vice versa in a full range pool
    ///@dev Output amount is calculated using the constant product fomula k = x * y with swap fees
    function swap(address _tokenIn, uint256 _amountIn, uint256 _minReceived, uint256 _deadline) external payable {
        // CHECKS
        ///@dev Cache the correct input amount
        uint256 amountIn = (_tokenIn == address(0)) ? msg.value : _amountIn;

        /// @dev Verify input amount & minimum received is greater than zero
        if (amountIn == 0 || _minReceived == 0) revert InvalidAmount();

        /// @dev Verify deadline
        if (_deadline < block.timestamp) {
            revert DeadlineExpired();
        }

        uint256 amountOut = quoteSwap(_tokenIn, amountIn, true);

        /// @dev Verify minimum received & abort any wrong inputs that result in 0 received, e.g. wrong token
        if (amountOut < _minReceived) revert InsufficientReceived();

        // EFFECTS
        totalEthVolume = (_tokenIn == address(0)) ? totalEthVolume + amountIn : totalEthVolume + amountOut;

        // INTERACTIONS
        ///@dev Check and trigger settlement of all registered markets
        ISignalVault vault;
        for (uint256 i; i <= lastMarketID; i++) {
            vault = ISignalVault(markets[i]);

            ///@dev Only trigger if market expects settlement
            if (vault.nextSettlement() <= block.timestamp) {
                vault.settleEpoch();
            }
        }

        ///@dev Take and send tokens
        // ETH in via function call, PSM out
        if (_tokenIn == address(0)) PSM.safeTransfer(msg.sender, amountOut);

        // PSM in, ETH out
        if (_tokenIn == address(PSM)) {
            PSM.safeTransferFrom(msg.sender, address(this), amountIn);

            address payable user = payable(msg.sender);
            (bool success,) = user.call{value: amountOut}("");
            if (!success) revert FailedToSendNativeToken();
        }

        /// @dev Emit swap event
        emit Swap(msg.sender, _tokenIn, amountIn, amountOut);
    }

    // ============================================
    // ==               ACCEPT ETH               ==
    // ============================================
    receive() external payable {}

    fallback() external payable {}
}
