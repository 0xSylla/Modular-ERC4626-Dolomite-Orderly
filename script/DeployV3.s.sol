// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DiracVaultFactoryV3} from "../src/factory/DiracVaultFactoryV3.sol";
import {VaultCuratorRouterV6} from "../src/routers/VaultCuratorRouterV6.sol";

/// @title DeployV3 — full V3 stack deploy
/// @notice Deploys DiracVaultFactoryV3 + VaultCuratorRouterV6 side-by-side with
///         the existing V2 stack. Existing V2 vaults stay on V2 factory + V5
///         router. New vaults deployed through V3 factory get V3 vault behavior
///         (inner-revert bubble + 3-state cycle, no WITHDRAW_OPEN) + V6 router.
///
/// @dev Workflow:
///   1. Deploy V3 factory with the admin address.
///   2. Deploy V6 router pointing at V3 factory.
///   3. Wire the router into the factory via setCuratorRouter.
///   4. (Manual) Run BootstrapV3 / post-deploy txs to whitelist deposit tokens,
///      strategy assets, modules, templates — same shape as V2 bootstrap. This
///      script intentionally only stands up the empty V3 framework; module
///      addresses are reused from V2 (already-deployed module contracts work
///      with any factory since they're just delegatecall targets).
///
/// @dev Required env vars:
///   PRIVATE_KEY  admin signer
///   ADMIN        address granted DIRAC_ADMIN_ROLE on V3 factory
///   OPERATOR     master operator EOA (granted OPERATOR_ROLE on each new V3 vault)
contract DeployV3 is Script {
    function run() external {
        address admin = vm.envAddress("ADMIN");
        address operator = vm.envAddress("OPERATOR");
        require(operator != address(0), "OPERATOR required");

        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPk != 0) {
            vm.startBroadcast(deployerPk);
        } else {
            vm.startBroadcast();
        }

        // 1. Deploy V3 factory
        DiracVaultFactoryV3 factory = new DiracVaultFactoryV3(admin, operator);
        console.log("DiracVaultFactoryV3 deployed at:", address(factory));

        // 2. Deploy V6 router pointing at V3 factory
        VaultCuratorRouterV6 router = new VaultCuratorRouterV6(address(factory));
        console.log("VaultCuratorRouterV6 deployed at:", address(router));

        // 3. Wire router into factory (grants V6 router OPERATOR + CURATOR roles
        //    on every future vault deployed via this factory).
        factory.setCuratorRouter(address(router));
        console.log("factory.setCuratorRouter(V6) done");

        vm.stopBroadcast();

        // Sanity checks
        require(address(router.factory()) == address(factory), "router.factory mismatch");
        require(factory.operator() == operator, "factory.operator mismatch");
        require(factory.curatorRouter() == address(router), "factory.curatorRouter mismatch");

        console.log("\n=== V3 Deployment summary ===");
        console.log("  V3 Factory:     ", address(factory));
        console.log("  V6 Router:      ", address(router));
        console.log("  Admin:          ", admin);
        console.log("  Operator:       ", operator);
        console.log("\n=== Post-deploy checklist (admin txs) ===");
        console.log("  1. factory.whitelistDepositToken(USDC)");
        console.log("  2. factory.whitelistStrategyAsset(wstETH config + allowed perps assets)");
        console.log("  3. factory.registerModule(MORPHO_MODULE_TYPE, morphoModuleAddr)        [reuse V2 module addrs]");
        console.log("  4. factory.registerModule(UNISWAP_MODULE_TYPE, uniswapModuleAddr)      [reuse V2 module addrs]");
        console.log("  5. factory.registerModule(ORDERLY_MODULE_TYPE, orderlyModuleAddr)      [reuse V2 module addrs]");
        console.log("  6. factory.registerModule(HYPERLIQUID_MODULE_TYPE, hyperliquidModuleAddr) [reuse V2 module addrs]");
        console.log("  7. factory.setPerpsModuleSymbol(wstETH, ORDERLY_HASH, 'PERP_ETH_USDC')");
        console.log("  8. factory.registerTemplate(TEMPLATE_ID)");
        console.log("  9. Update Vercel env: NEXT_PUBLIC_FACTORY_ADDR_ARB_V2, NEXT_PUBLIC_ROUTER_ADDR_ARB_V2");
        console.log(" 10. Update Heroku V2 API env: FACTORY_ADDR_ARB, ROUTER_ADDR_ARB (point at V3 addresses)");
    }
}
