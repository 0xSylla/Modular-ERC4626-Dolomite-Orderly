// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VaultCuratorRouterV4} from "../src/routers/VaultCuratorRouterV4.sol";
import {DiracVaultFactory} from "../src/factory/DiracVaultFactory.sol";

/// @title DeployVaultCuratorRouterV4
/// @notice Deploys VaultCuratorRouterV4 and wires it into the existing factory via
///         setCuratorRouter(newRouter).
///
///         V4 vs V3:
///           - definePosition refuses a duplicate (collateralAsset, perpsAsset) pair if any
///             existing record for the same vault is currently non-IDLE.
///           - requestOpeningPosition refuses if another same-pair record is non-IDLE.
///           - All other lifecycle paths are identical to V3.
///
///         Migration model:
///           - factory.setCuratorRouter(V4) makes V4 the role-recipient for NEW vaults.
///           - Existing V3 vaults keep their V3 roles. They do NOT automatically get V4 roles.
///             V4 cannot operate on them unless DIRAC_ADMIN grants V4 OPERATOR_ROLE + CURATOR_ROLE
///             on each existing vault (cheap, ~50k gas/vault).
///           - V4's position storage is empty; existing positions live in V3 storage forever.
///             To migrate a live position to V4: close it cleanly on V3, then re-define on V4.
///
/// @dev Mainnet workflow:
///   PRIVATE_KEY=<admin> ARB_FACTORY_ADDR=0xb161... \
///     forge script script/DeployVaultCuratorRouterV4.s.sol:DeployV4Router \
///     --rpc-url arbitrum --broadcast
contract DeployV4Router is Script {
    function run() external {
        address factoryAddr = vm.envAddress("ARB_FACTORY_ADDR");
        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);

        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPk != 0) {
            vm.startBroadcast(deployerPk);
        } else {
            vm.startBroadcast();
        }

        VaultCuratorRouterV4 router = new VaultCuratorRouterV4(factoryAddr);
        console.log("VaultCuratorRouterV4 deployed at:", address(router));

        factory.setCuratorRouter(address(router));
        console.log("factory.setCuratorRouter(V4) done");

        vm.stopBroadcast();

        require(address(router.factory()) == factoryAddr, "router.factory mismatch");
        console.log("\n=== Deployment summary ===");
        console.log("  Factory:        ", factoryAddr);
        console.log("  Router V4:      ", address(router));
        console.log("  V3 still owns positions on existing vaults; they keep working.");
        console.log("  New vaults deployed from now on will route through Router V4.");
        console.log("  V4 adds duplicate-pair refusal in definePosition + requestOpeningPosition.");
    }
}
