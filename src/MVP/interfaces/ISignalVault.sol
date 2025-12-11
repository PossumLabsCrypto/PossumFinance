// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface ISignalVault {
    function UP_TOKEN() external view returns (address);
    function DOWN_TOKEN() external view returns (address);

    function vaultDirection() external view returns (uint256);
    function last_settlementPrice() external view returns (uint256);
}
