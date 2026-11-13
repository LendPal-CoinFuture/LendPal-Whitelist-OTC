// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {PledgeLoan} from "../contracts/PledgeLoan.sol";

/// @notice 部署质押转账合约。法币在线下，合约只负责整笔 USDT 的打出和归还。
contract DeployPledgeLoan is Script {
    address internal constant DEFAULT_REGISTRY = 0x135Fb34eBAd72BB91932E22ff48Fa6963f0e5F9E;

    function run() external returns (address loan) {
        uint256 key = vm.envUint("SEPOLIA_PRIVATE_KEY");
        address registry = DEFAULT_REGISTRY;
        if (vm.envExists("ACCESS_REGISTRY_PROXY")) {
            string memory rawRegistry = vm.envString("ACCESS_REGISTRY_PROXY");
            if (bytes(rawRegistry).length != 0) registry = vm.parseAddress(rawRegistry);
        }
        address usdt = vm.envOr("USDT_TOKEN", address(0xaeb831366b23C6fd13aD39068017197478398e32));

        vm.startBroadcast(key);
        loan = address(new PledgeLoan(registry, usdt));
        vm.stopBroadcast();
    }
}
