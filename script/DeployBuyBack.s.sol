// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {BuyBackEngine} from "../src/buyback/BuyBackEngine.sol";

/// @title DeployBuyBack
/// @notice Phase 4 deploy — BuyBackEngine (spend USDC revenue to market-buy
///         TDIRAC on a V2-style DEX, forward to a configured recipient).
///
/// @dev Required env:
///   PRIVATE_KEY     deployer signer (covers gas)
///   ADMIN           multisig — admin (handed to DiracTimelock later)
///   TDIRAC_ADDR     token bought back
///   REVENUE_TOKEN   token spent (USDC)
///   DEX_ROUTER      V2-style router (Kodiak on Bera, Camelot/Sushi on Arbitrum)
///   BUYBACK_RECIPIENT  where bought TDIRAC go (SoulboundReceiptPool by default)
///   KEEPER          address allowed to trigger buybacks
///
///   Optional:
///   PATH_MID        a single intermediate hop token (USDC -> MID -> TDIRAC).
///                   If unset, a direct USDC -> TDIRAC path is used.
contract DeployBuyBack is Script {
    function run() external {
        address admin = vm.envAddress("ADMIN");
        address tdirac = vm.envAddress("TDIRAC_ADDR");
        address revenueToken = vm.envAddress("REVENUE_TOKEN");
        address router = vm.envAddress("DEX_ROUTER");
        address recipient = vm.envAddress("BUYBACK_RECIPIENT");
        address keeper = vm.envAddress("KEEPER");
        require(admin != address(0), "ADMIN required");
        require(tdirac != address(0), "TDIRAC_ADDR required");
        require(revenueToken != address(0), "REVENUE_TOKEN required");
        require(router != address(0), "DEX_ROUTER required");
        require(recipient != address(0), "BUYBACK_RECIPIENT required");
        require(keeper != address(0), "KEEPER required");

        address mid = vm.envOr("PATH_MID", address(0));
        address[] memory path;
        if (mid == address(0)) {
            path = new address[](2);
            path[0] = revenueToken;
            path[1] = tdirac;
        } else {
            path = new address[](3);
            path[0] = revenueToken;
            path[1] = mid;
            path[2] = tdirac;
        }

        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPk != 0) vm.startBroadcast(deployerPk);
        else vm.startBroadcast();

        BuyBackEngine engine = new BuyBackEngine(
            revenueToken, tdirac, router, recipient, admin, keeper, path
        );
        console.log("BuyBackEngine deployed at:", address(engine));

        vm.stopBroadcast();

        require(address(engine.usdc()) == revenueToken, "usdc mismatch");
        require(address(engine.tdirac()) == tdirac, "tdirac mismatch");
        require(engine.router() == router, "router mismatch");
        require(engine.recipient() == recipient, "recipient mismatch");
        require(engine.admin() == admin, "admin mismatch");
        require(engine.keeper() == keeper, "keeper mismatch");

        console.log("");
        console.log("=== BuyBackEngine deployment summary ===");
        console.log("  Spend token (USDC):  ", revenueToken);
        console.log("  Buy token (TDIRAC):  ", tdirac);
        console.log("  Router:              ", router);
        console.log("  Recipient:           ", recipient);
        console.log("  Admin:               ", admin);
        console.log("  Keeper:              ", keeper);
        console.log("  Path hops:           ", path.length);
        console.log("");
        console.log("Fund it by transferring USDC to the engine, then keeper calls:");
        console.log("  engine.buyback(amountIn, minOut, deadline)");
        console.log("Hand admin to governance later: engine.setAdmin(timelock)");
    }
}
