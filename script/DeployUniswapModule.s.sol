// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {UniswapModule} from "../src/modules/swap/UniswapModule.sol";
import {DiracVaultFactory} from "../src/factory/DiracVaultFactory.sol";

/// @title DeployUniswapModule
/// @notice Deploys UniswapModule and registers it on the existing Arbitrum factory under `swap.uniswap`.
/// @dev   Run:
///   PRIVATE_KEY=… ARB_FACTORY_ADDR=0x… \
///     forge script script/DeployUniswapModule.s.sol:DeployUniswapModule \
///     --rpc-url arbitrum --broadcast
contract DeployUniswapModule is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        require(deployerPrivateKey != 0, "Set PRIVATE_KEY env var");
        require(block.chainid == 42161, "Arbitrum only");

        address factoryAddr = vm.envAddress("ARB_FACTORY_ADDR");
        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);

        bytes32 uniswapTypeHash = keccak256("swap.uniswap");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy
        UniswapModule module = new UniswapModule();
        console.log("UniswapModule deployed at:", address(module));
        console.log("  moduleType hash:", vm.toString(uniswapTypeHash));

        // Register with the factory
        factory.registerModule(uniswapTypeHash, address(module));
        console.log("Registered with factory");

        vm.stopBroadcast();

        // Verify registration
        address registered = factory.getModule(uniswapTypeHash);
        require(registered == address(module), "Registration mismatch");
        console.log("Verification OK -- factory.getModule(swap.uniswap) =", registered);
    }
}
