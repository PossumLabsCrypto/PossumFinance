// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {AutoSettlementLP} from "src/V1/AutoSettlementLP.sol";

contract DeployAutoSettlementLP is Script {
    function setUp() public {}

    address owner = 0xbFF0b8CcD7ebA169107bbE72426dB370407C8f2D;
    address newOwner = 0xa0BFD02a7a47CBCA7230E03fbf04A196C3E771E3;

    function run() public returns (address lp_address) {
        vm.startBroadcast();

        // Deploy contract
        AutoSettlementLP lp1 = new AutoSettlementLP(owner);
        lp_address = address(lp1);

        // set first market at slot 0
        lp1.setActiveMarket(0xb800B8dbCF9A78b16F5C1135Cd1A39384ABf1fbc, 0);

        // change owner to secure address - ready to be funded
        lp1.changeOwner(newOwner);

        vm.stopBroadcast();
    }
}

// MAINNET
// forge script script/DeployAutoSettlementLP.s.sol --rpc-url $ARB_MAINNET_URL --private-key $PRIVATE_KEY --broadcast --optimize --optimizer-runs 99999 --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
