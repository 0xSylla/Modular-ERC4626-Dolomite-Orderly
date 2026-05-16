// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VaultCuratorRouterV3} from "../src/routers/VaultCuratorRouterV3.sol";
import {DiracVaultFactory} from "../src/factory/DiracVaultFactory.sol";

/// @title DeployVaultCuratorRouterV3
/// @notice Deploys VaultCuratorRouterV3 and wires it into the existing factory via
///         setCuratorRouter(newRouter). V3 = V2 + `setPositionStatus(...)` operator
///         escape hatch for stuck REBALANCING positions (used when reopen is infeasible
///         due to vault USDC below the perps floor).
///
///         The factory grants the new router CURATOR_ROLE + OPERATOR_ROLE on every NEW
///         vault created from this point on. Existing vaults under V2 keep using V2 (their
///         roles weren't transferred). To migrate a live position from V2 to V3, the curator
///         can wait until the next natural close and reopen on V3 — see the lazy migration
///         notes in the V2 → V3 conversation thread.
///
/// @dev Mainnet workflow:
///   PRIVATE_KEY=<admin> ARB_FACTORY_ADDR=0xb161... \
///     forge script script/DeployVaultCuratorRouterV3.s.sol:DeployV3Router \
///     --rpc-url arbitrum --broadcast
contract DeployV3Router is Script {
    function run() external {
        address factoryAddr = vm.envAddress("ARB_FACTORY_ADDR");
        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);

        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPk != 0) {
            vm.startBroadcast(deployerPk);
        } else {
            vm.startBroadcast();
        }

        // 1. Deploy the new router pointing at the existing factory
        VaultCuratorRouterV3 router = new VaultCuratorRouterV3(factoryAddr);
        console.log("VaultCuratorRouterV3 deployed at:", address(router));

        // 2. Wire it into the factory — future createVault() calls will grant
        //    OPERATOR_ROLE + CURATOR_ROLE to this router on every new vault.
        //    NOTE: this is admin-only on the factory. The broadcaster must hold
        //    DIRAC_ADMIN_ROLE (i.e. the multisig EOA or its delegate).
        factory.setCuratorRouter(address(router));
        console.log("factory.setCuratorRouter(V3) done");

        vm.stopBroadcast();

        // Sanity checks
        require(address(router.factory()) == factoryAddr, "router.factory mismatch");
        console.log("\n=== Deployment summary ===");
        console.log("  Factory:        ", factoryAddr);
        console.log("  Router V3:      ", address(router));
        console.log("  V2 still owns positions on existing vaults; they keep working.");
        console.log("  New vaults deployed from now on will route through Router V3.");
        console.log("  V3 adds setPositionStatus(vault, positionId, status) for stuck-state recovery.");
    }
}
