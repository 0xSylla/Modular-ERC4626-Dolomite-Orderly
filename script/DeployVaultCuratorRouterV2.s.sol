// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VaultCuratorRouterV2} from "../src/routers/VaultCuratorRouterV2.sol";
import {DiracVaultFactory} from "../src/factory/DiracVaultFactory.sol";

/// @title DeployVaultCuratorRouterV2
/// @notice Deploys VaultCuratorRouterV2 and wires it into the existing factory via
///         setCuratorRouter(newRouter). The factory grants the new router CURATOR_ROLE +
///         OPERATOR_ROLE on every NEW vault created from this point on. Existing vaults
///         keep using the old router (their roles weren't transferred).
///
/// @dev Local fork workflow (Anvil forked from Arbitrum mainnet):
///   1. anvil --fork-url https://arb1.arbitrum.io/rpc --chain-id 42161 (keep running)
///   2. cast rpc anvil_impersonateAccount <DIRAC_ADMIN_ADDR> --rpc-url http://localhost:8545
///   3. cast rpc anvil_setBalance <DIRAC_ADMIN_ADDR> 0x21e19e0c9bab2400000 --rpc-url http://localhost:8545
///   4. PRIVATE_KEY=<anvil-default-key-0> ARB_FACTORY_ADDR=0xb161... ADMIN_ADDR=<addr> \
///      forge script script/DeployVaultCuratorRouterV2.s.sol:DeployV2Router \
///      --rpc-url http://localhost:8545 --broadcast --unlocked --sender <DIRAC_ADMIN_ADDR>
///
/// @dev Mainnet workflow:
///   PRIVATE_KEY=<admin> ARB_FACTORY_ADDR=0xb161... \
///     forge script script/DeployVaultCuratorRouterV2.s.sol:DeployV2Router \
///     --rpc-url arbitrum --broadcast
contract DeployV2Router is Script {
    function run() external {
        address factoryAddr = vm.envAddress("ARB_FACTORY_ADDR");
        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);

        // Two execution modes:
        //   - If PRIVATE_KEY set, broadcast with it (mainnet / testnet)
        //   - Otherwise, expect --unlocked + --sender for anvil impersonation
        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPk != 0) {
            vm.startBroadcast(deployerPk);
        } else {
            vm.startBroadcast();
        }

        // 1. Deploy the new router pointing at the existing factory
        VaultCuratorRouterV2 router = new VaultCuratorRouterV2(factoryAddr);
        console.log("VaultCuratorRouterV2 deployed at:", address(router));

        // 2. Wire it into the factory — future createVault() calls will grant
        //    OPERATOR_ROLE + CURATOR_ROLE to this router on every new vault.
        //    NOTE: this is admin-only on the factory. The broadcaster must hold
        //    DIRAC_ADMIN_ROLE (i.e. the multisig EOA or its delegate).
        factory.setCuratorRouter(address(router));
        console.log("factory.setCuratorRouter(newRouter) done");

        vm.stopBroadcast();

        // Sanity checks
        require(address(router.factory()) == factoryAddr, "router.factory mismatch");
        console.log("\n=== Deployment summary ===");
        console.log("  Factory:        ", factoryAddr);
        console.log("  Router V2:      ", address(router));
        console.log("  Router V1 still owns positions on existing vaults; they keep working.");
        console.log("  New vaults deployed from now on will route through Router V2.");
    }
}
