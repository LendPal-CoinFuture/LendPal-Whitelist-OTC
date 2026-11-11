// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OtcTrade} from "../contracts/OtcTrade.sol";

/// @notice 部署 OtcTrade UUPS 代理。默认对接已部署的 AccessRegistry。
contract DeployOtcTrade is Script {
    address internal constant DEFAULT_REGISTRY = 0x135Fb34eBAd72BB91932E22ff48Fa6963f0e5F9E;

    function run() external returns (address proxy, address implementation) {
        string memory network = vm.envOr("DEPLOY_NETWORK", string("sepolia"));
        uint256 key = _privateKey(network);
        address deployer = vm.addr(key);

        address initialOwner = deployer;
        if (vm.envExists("INITIAL_OWNER")) {
            string memory rawOwner = vm.envString("INITIAL_OWNER");
            if (bytes(rawOwner).length != 0) initialOwner = vm.parseAddress(rawOwner);
        }

        address registry = DEFAULT_REGISTRY;
        if (vm.envExists("ACCESS_REGISTRY_PROXY")) {
            string memory rawRegistry = vm.envString("ACCESS_REGISTRY_PROXY");
            if (bytes(rawRegistry).length != 0) registry = vm.parseAddress(rawRegistry);
        }

        address usdt = vm.envOr("USDT_TOKEN", address(0xaeb831366b23C6fd13aD39068017197478398e32));
        address fee = vm.envOr("FEE_WALLET", address(0x4F9064DAAE146e8F712e7C178EFeDEb6dE7BAA53));

        vm.startBroadcast(key);
        implementation = address(new OtcTrade());
        proxy = address(
            new ERC1967Proxy(
                implementation, abi.encodeCall(OtcTrade.initialize, (initialOwner, registry))
            )
        );
        OtcTrade(proxy).setUsdt(usdt);
        OtcTrade(proxy).setFeeRecipient(fee);
        vm.stopBroadcast();
    }

    function _privateKey(string memory network) internal view returns (uint256) {
        if (keccak256(bytes(network)) == keccak256("mainnet")) {
            return vm.envUint("MAINNET_PRIVATE_KEY");
        }
        return vm.envUint("SEPOLIA_PRIVATE_KEY");
    }
}
