// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {SignalVault} from "src/SignalVault.sol";
import {AssetVault} from "src/AssetVault.sol";

contract DeployVaults is Script {
    function setUp() public {}

    // ================= MAINNET =================== //
    uint256 epochDuration_mainnet = 604800; // 7 days
    uint256 firstSettlement_mainnet = 1764615600; // Dec 01, 7pm UTC

    address weth_mainnet = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address usdc_mainnet = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address psm_mainnet = 0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5;
    address arb_mainnet = 0x912CE59144191C1204E64559FE8253a0e49E6548;
    address link_mainnet = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;

    // Chainlink oracle feeds on Arbitrum - Mainnet
    address uptimeFeed_mainnet = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    address eth_usd_mainnet = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address arb_usd_mainnet = 0xb2A824043730FE05F3DA2efaFa1CBbe83fa548D6;
    address link_eth_mainnet = 0xb7c8Fb1dB45007F98A68Da0588e1AA524C317f27;

    // ================= TESTNET =================== //
    uint256 epochDuration_testnet = 86400; // 1 day
    uint256 firstSettlement_testnet = 1763751600; // Nov 21, 7pm UTC

    address weth_testnet = 0x45385d06799c411BF4A80A7Dd18eb00979D8024C;
    address arb_testnet = 0xa9075341367B5e66Aadf7Fc4c73E2787003d43F7;
    address link_testnet = 0x519374734C0729224dEA0badb36aC43f4145d498;
    address usdc_testnet = 0xaC150A34a3E20Ae0055dd3b3A132E4C79832676A;
    address psm_testnet = 0x790bC7D766733CB593EFAC44e3D21544eBb12B18;

    address eth_usd_testnet = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
    address arb_usd_testnet = 0xD1092a65338d049DB68D7Be6bD89d17a0929945e;
    address link_eth_testnet = 0x3ec8593F930EA45ea58c968260e6e9FF53FC934f;

    address uptimeFeed_testnet = 0x7216A2B55735BF56f1160b51263623E7fDE18D6A;

    function run() public returns (address signalVaultETHUSD, address assetVaultETHUSD) {
        vm.startBroadcast();

        // Create contract instances - MAINNET
        // WETH/USDC vault pair
        SignalVault vault1 = new SignalVault(
            weth_mainnet,
            usdc_mainnet,
            eth_usd_mainnet,
            uptimeFeed_mainnet,
            epochDuration_mainnet,
            firstSettlement_mainnet
        );
        signalVaultETHUSD = address(vault1);

        AssetVault vault2 = new AssetVault(signalVaultETHUSD, 18, 6);
        assetVaultETHUSD = address(vault2);

        // // Create contract instances - TESTNET
        // // WETH/USDC vault pair
        // SignalVault vault1 = new SignalVault(
        //     weth_testnet, usdc_testnet, eth_usd_testnet, uptimeFeed_testnet, epochDuration_testnet, firstSettlement_testnet
        // );
        // signalVaultETHUSD = address(vault1);

        // AssetVault vault2 = new AssetVault(signalVaultETHUSD, 18, 6);
        // assetVaultETHUSD = address(vault2);

        // // ARB/USDC vault pair
        // vault1 = new SignalVault(
        //     arb_testnet, usdc_testnet, arb_usd_testnet, uptimeFeed_testnet, epochDuration_testnet, firstSettlement_testnet
        // );
        // signalVaultARBUSD = address(vault1);

        // vault2 = new AssetVault(signalVaultARBUSD, 18, 6);
        // assetVaultARBUSD = address(vault2);

        // // LINK/WETH vault pair
        // vault1 = new SignalVault(
        //     link_testnet, weth_testnet, link_eth_testnet, uptimeFeed_testnet, epochDuration_testnet, firstSettlement_testnet
        // );
        // signalVaultLINKETH = address(vault1);

        // vault2 = new AssetVault(signalVaultLINKETH, 18, 18);
        // assetVaultLINKETH = address(vault2);

        vm.stopBroadcast();
    }
}

// TESTNET
// forge script script/DeployVaults.s.sol --rpc-url $ARB_SEPOLIA_URL --private-key $PRIVATE_KEY --broadcast --optimize --optimizer-runs 9999 --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY

// MAINNET
// forge script script/DeployVaults.s.sol --rpc-url $ARB_MAINNET_URL --private-key $PRIVATE_KEY --broadcast --optimize --optimizer-runs 9999 --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
