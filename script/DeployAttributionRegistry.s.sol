// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AttributionRegistry} from "../src/registry/AttributionRegistry.sol";
import {SoulboundReceiptPool} from "../src/token/SoulboundReceiptPool.sol";

/// @title DeployAttributionRegistry
/// @notice Phase 3 deploy (V4 + multisig path). Deploys the AttributionRegistry
///         bound to an already-deployed SoulboundReceiptPool and the LIVE V4
///         factory. No V5 vault / new factory required.
///
///         After deploy, the multisig must call
///         `pool.setAttributor(registry)` so the registry becomes the sole
///         minter of receipts. This script attempts that call automatically
///         only when the broadcasting key is the pool admin; otherwise it
///         prints the step for the multisig to execute.
///
/// @dev Required env:
///   PRIVATE_KEY     deployer signer (covers gas)
///   ADMIN           multisig — registry admin + attester + strategist attester
///   POOL_ADDR       address of the already-deployed SoulboundReceiptPool
///   FACTORY_ADDR    address of the LIVE V4 DiracVaultFactory
///
///   Optional:
///   ATTESTER            overrides ADMIN as the LP/curator attester
///   STRATEGIST_ATTESTER overrides ADMIN as the strategist attester
contract DeployAttributionRegistry is Script {
    function run() external {
        address admin = vm.envAddress("ADMIN");
        address poolAddr = vm.envAddress("POOL_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        require(admin != address(0), "ADMIN required");
        require(poolAddr != address(0), "POOL_ADDR required");
        require(factoryAddr != address(0), "FACTORY_ADDR required");

        address attester = vm.envOr("ATTESTER", admin);
        address strategistAttester = vm.envOr("STRATEGIST_ATTESTER", admin);

        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0));

        if (deployerPk != 0) vm.startBroadcast(deployerPk);
        else vm.startBroadcast();

        AttributionRegistry registry = new AttributionRegistry(
            poolAddr,
            factoryAddr,
            admin,
            attester,
            strategistAttester
        );
        console.log("AttributionRegistry deployed at:", address(registry));

        // Wire the pool's attributor role to the registry IF the broadcaster is
        // the current pool admin. Otherwise the multisig does it in a follow-up.
        SoulboundReceiptPool pool = SoulboundReceiptPool(poolAddr);
        address broadcaster = deployerPk != 0 ? vm.addr(deployerPk) : msg.sender;
        bool wired = false;
        if (pool.admin() == broadcaster) {
            pool.setAttributor(address(registry));
            wired = true;
        }

        vm.stopBroadcast();

        // Sanity
        require(address(registry.pool()) == poolAddr, "registry.pool mismatch");
        require(address(registry.factory()) == factoryAddr, "registry.factory mismatch");
        require(registry.admin() == admin, "registry.admin mismatch");
        require(registry.attester() == attester, "registry.attester mismatch");
        require(registry.strategistAttester() == strategistAttester, "registry.strategistAttester mismatch");

        console.log("");
        console.log("=== AttributionRegistry deployment summary ===");
        console.log("  Pool (existing):       ", poolAddr);
        console.log("  Factory (V4, existing):", factoryAddr);
        console.log("  Registry:              ", address(registry));
        console.log("  Admin:                 ", admin);
        console.log("  Attester (LP+curator): ", attester);
        console.log("  Strategist attester:   ", strategistAttester);
        console.log("");
        if (wired) {
            require(pool.attributor() == address(registry), "pool.attributor not set");
            console.log("  pool.attributor -> registry: SET (broadcaster was pool admin)");
        } else {
            console.log("Next manual step (multisig = pool admin):");
            console.log("  pool.setAttributor(registry)  // route minting through the registry");
        }
        console.log("");
        console.log("Then, to credit strategists, wire each template to its author:");
        console.log("  registry.setTemplateAuthor(templateId, strategistAddress)  // any time, re-pointable");
    }
}
