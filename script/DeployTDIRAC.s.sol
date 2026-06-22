// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TDIRAC} from "../src/token/TDIRAC.sol";

/// @title DeployTDIRAC
/// @notice Deploys the TDIRAC token and mints the entire 10B supply to `ADMIN`.
///         Single tx, no role grants, no post-deploy steps required for the
///         token itself. Subsequent treasury operations (seed DEX pairs, fund
///         SoulboundReceiptPool, distribute via Sablier) are off-chain
///         multisig actions using standard ERC20 transfers.
///
/// @dev Required env:
///   PRIVATE_KEY  deployer signer (covers gas; doesn't receive supply)
///   ADMIN        recipient of the entire 10B initial supply (the multisig)
///
/// @dev Chain selection: the same script runs on Arbitrum (42161) and
///      Berachain (80094). Pick the RPC at invoke time. The Berachain
///      deployment is a mirror — token addresses will differ across chains
///      (no CREATE2 used in this draft), so cross-chain users will need a
///      bridge or per-chain claim.
contract DeployTDIRAC is Script {
    function run() external {
        address admin = vm.envAddress("ADMIN");
        require(admin != address(0), "ADMIN required");

        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPk != 0) {
            vm.startBroadcast(deployerPk);
        } else {
            vm.startBroadcast();
        }

        TDIRAC token = new TDIRAC(admin);

        vm.stopBroadcast();

        // Sanity checks (still in script context, just as assertions)
        require(token.totalSupply() == 10_000_000_000 * 1e18, "supply mismatch");
        require(token.balanceOf(admin) == 10_000_000_000 * 1e18, "admin balance mismatch");
        require(
            keccak256(abi.encodePacked(token.symbol())) == keccak256(abi.encodePacked("TDIRAC")),
            "symbol mismatch"
        );

        console.log("");
        console.log("=== TDIRAC deployment summary ===");
        console.log("  Token address:  ", address(token));
        console.log("  Treasury (admin):", admin);
        console.log("  Total supply:   ", token.totalSupply());
        console.log("  Admin balance:  ", token.balanceOf(admin));
        console.log("");
        console.log("Next steps (multisig orchestrated, off-chain):");
        console.log("  1. Seed DEX pair: send TDIRAC + USDC to a Uniswap V3 / Camelot pool");
        console.log("  2. Fund SoulboundReceiptPool when Phase 2 deploys");
        console.log("  3. Set up Sablier streams for NFT diamond hands / SAFT / team / advisors");
        console.log("  4. Delegate votes (treasury holders call token.delegate(address))");
    }
}
