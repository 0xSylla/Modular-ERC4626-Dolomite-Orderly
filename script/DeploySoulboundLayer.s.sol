// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SoulboundReceiptToken} from "../src/token/SoulboundReceiptToken.sol";
import {SoulboundReceiptPool} from "../src/token/SoulboundReceiptPool.sol";

/// @title DeploySoulboundLayer
/// @notice Phase 2 deploy — drops `SoulboundReceiptPool` + `SoulboundReceiptToken`
///         alongside an already-deployed TDIRAC.
///
///         Deploys in order:
///         1. Compute the future Pool address (we need it inside the SBT
///            constructor, but the Pool needs the SBT address inside its
///            constructor — chicken/egg).
///         2. Resolve via the standard "deploy SBT pointing at a precomputed
///            Pool address" trick: forge's `vm.computeCreateAddress` gives us
///            the deterministic next address for the deployer's current nonce.
///
/// @dev Required env:
///   PRIVATE_KEY     deployer signer (covers gas)
///   ADMIN           multisig — initial admin + attributor (rotated to
///                   AttributionRegistry in Phase 3)
///   DIRAC_ADDR      address of the already-deployed TDIRAC
///   REVENUE_TOKEN   USDC address on the target chain
///
///   Optional: SBT_RESERVE_AMOUNT — TDIRAC the deployer wants to seed the pool
///                                 with. Defaults to 0; treasury transfers
///                                 separately as needed.
contract DeploySoulboundLayer is Script {
    function run() external {
        address admin = vm.envAddress("ADMIN");
        address diracAddr = vm.envAddress("DIRAC_ADDR");
        address revenueToken = vm.envAddress("REVENUE_TOKEN");
        require(admin != address(0), "ADMIN required");
        require(diracAddr != address(0), "DIRAC_ADDR required");
        require(revenueToken != address(0), "REVENUE_TOKEN required");

        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = deployerPk != 0 ? vm.addr(deployerPk) : msg.sender;

        // Precompute the Pool address — it'll be deployed at deployer's
        // current_nonce + 1 (SBT goes first at current_nonce).
        uint256 nonce = vm.getNonce(deployer);
        address futurePool = vm.computeCreateAddress(deployer, nonce + 1);

        if (deployerPk != 0) vm.startBroadcast(deployerPk);
        else vm.startBroadcast();

        // 1. SBT — references the future Pool address.
        SoulboundReceiptToken sbt = new SoulboundReceiptToken(futurePool);
        console.log("SoulboundReceiptToken deployed at:", address(sbt));

        // 2. Pool — references SBT + TDIRAC + revenueToken.
        SoulboundReceiptPool pool = new SoulboundReceiptPool(
            diracAddr,
            address(sbt),
            revenueToken,
            admin, // attributor (multisig until Phase 3)
            admin  // admin
        );
        console.log("SoulboundReceiptPool deployed at:", address(pool));

        vm.stopBroadcast();

        // Sanity: futurePool prediction must match reality.
        require(address(pool) == futurePool, "Pool address mismatch (nonce drift?)");
        require(address(sbt.pool()) == address(pool), "SBT.pool mismatch");
        require(address(pool.sbt()) == address(sbt), "Pool.sbt mismatch");
        require(address(pool.dirac()) == diracAddr, "Pool.dirac mismatch");
        require(address(pool.revenueToken()) == revenueToken, "Pool.revenueToken mismatch");
        require(pool.admin() == admin, "Pool.admin mismatch");
        require(pool.attributor() == admin, "Pool.attributor mismatch");
        require(pool.burnRatio() == 1e18, "Pool.burnRatio default mismatch");

        console.log("");
        console.log("=== Soulbound layer deployment summary ===");
        console.log("  TDIRAC (existing):          ", diracAddr);
        console.log("  RevenueToken (USDC):        ", revenueToken);
        console.log("  SoulboundReceiptToken (SBT):", address(sbt));
        console.log("  SoulboundReceiptPool:       ", address(pool));
        console.log("  Admin / Attributor:         ", admin);
        console.log("  Burn ratio (TDIRAC : SBT):  1e18 (1:1)");
        console.log("");
        console.log("Next manual steps (multisig):");
        console.log("  1. Transfer TDIRAC reserve to Pool:");
        console.log("       TDIRAC.transfer(Pool, <reserve_amount>)");
        console.log("  2. (Phase 3) Deploy AttributionRegistry, then call");
        console.log("       Pool.setAttributor(<registry_address>)");
        console.log("  3. Revenue: any contract calling distributeRevenue must first");
        console.log("       USDC.approve(Pool, amount)");
    }
}
