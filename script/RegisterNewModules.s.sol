// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DiracVaultFactory} from "../src/factory/DiracVaultFactory.sol";
import {AaveModule} from "../src/modules/lending/aave/AaveModule.sol";
import {MorphoModule} from "../src/modules/lending/morpho/MorphoModule.sol";

/// @title RegisterNewModules
/// @notice Deploy and register AaveModule + MorphoModule on the existing Arbitrum factory
/// @dev Run: forge script script/RegisterNewModules.s.sol:RegisterNewModules --rpc-url arbitrum --broadcast
contract RegisterNewModules is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        require(deployerPrivateKey != 0, "Set PRIVATE_KEY env var");
        require(block.chainid == 42161, "This script is for Arbitrum only");

        address factoryAddr = vm.envAddress("ARB_FACTORY_ADDR");
        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);

        vm.startBroadcast(deployerPrivateKey);

        // ======== 1. Deploy Modules ========
        console.log("--- Deploy AaveModule ---");
        AaveModule aaveModule = new AaveModule();
        console.log("AaveModule deployed at:", address(aaveModule));

        console.log("--- Deploy MorphoModule ---");
        MorphoModule morphoModule = new MorphoModule();
        console.log("MorphoModule deployed at:", address(morphoModule));

        // ======== 2. Register on Factory ========
        console.log("--- Register modules on factory ---");
        factory.registerModule(keccak256("lending.aave"),  address(aaveModule));
        factory.registerModule(keccak256("lending.morpho"), address(morphoModule));
        console.log("Both modules registered.");

        vm.stopBroadcast();

        console.log("=======================================");
        console.log("  NEW MODULES REGISTERED ON ARBITRUM");
        console.log("=======================================");
        console.log("Factory:       ", factoryAddr);
        console.log("AaveModule:    ", address(aaveModule));
        console.log("MorphoModule:  ", address(morphoModule));
        console.log("=======================================");
    }
}
