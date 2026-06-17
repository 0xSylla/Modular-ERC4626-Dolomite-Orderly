// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DiracVaultFactoryV3} from "../src/factory/DiracVaultFactoryV3.sol";
import {Data} from "../src/libraries/Data.sol";

/// @title BootstrapV3
/// @notice Mirrors V2's whitelists / module registrations onto the freshly-
///         deployed V3 factory so vaults can actually be created. Module
///         addresses are reused from V1/V2 — modules are stateless delegatecall
///         targets that don't care which factory deployed the calling vault.
///
/// @dev Required env: ADMIN (signer, must hold DIRAC_ADMIN_ROLE on V3 factory)
///                    V3_FACTORY (address of the just-deployed factory)
///                    PRIVATE_KEY (admin's signing key)
contract BootstrapV3 is Script {
    // V1/V2 module addresses (re-registered on V3 — same delegatecall targets).
    address constant MORPHO_MODULE      = 0xb8668b18B3626ad25a541c34288038a7CF3FAeea;
    address constant DOLOMITE_MODULE    = 0xBb6c80327B03DF564E460Bc40E7d9A9805b8BB75;
    address constant AAVE_MODULE        = 0x833F1F34482f32c6c6611cdda6db1afd96E42f67;
    address constant ODOS_MODULE        = 0xbaFFF3c60eD1C6D1dDa0dbC36bdcEbFd37B1B78B;
    address constant UNISWAP_MODULE     = 0x31c1a79fe37A00B4f664fc32ca8fcAc2cb670121;
    address constant ORDERLY_MODULE     = 0x0828f24D02b8F563b1F48604B706b18879B994e0;
    address constant HYPERLIQUID_MODULE = 0xA427397b68DEBFB8400d2133e5920c81a37a96E8;

    // Tokens
    address constant USDC   = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant WBTC   = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant WETH   = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    // Morpho lending config for wstETH (loanToken USDC + market params).
    // Same as V1/V2: copied verbatim from V1 factory's moduleLendingConfig.
    bytes constant MORPHO_CONFIG_WSTETH = hex"000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e58310000000000000000000000005979d7b546e38e414f7e9822514be443a48005290000000000000000000000008e02a9b9cc29d783b2fcb71c3a72651b591cae3100000000000000000000000066f30587fb8d4206918deb78eca7d5ebbafd06da0000000000000000000000000000000000000000000000000bef55718ad60000";

    function run() external {
        address factoryAddr = vm.envAddress("V3_FACTORY");
        DiracVaultFactoryV3 factory = DiracVaultFactoryV3(factoryAddr);

        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPk != 0) {
            vm.startBroadcast(deployerPk);
        } else {
            vm.startBroadcast();
        }

        // ----- 1. Deposit token: USDC -----
        factory.whitelistDepositToken(USDC);
        console.log("whitelistDepositToken(USDC)");

        // ----- 2. Module registrations (7 modules) -----
        bytes32 LENDING_MORPHO     = keccak256("lending.morpho");
        bytes32 LENDING_DOLOMITE   = keccak256("lending.dolomite");
        bytes32 LENDING_AAVE       = keccak256("lending.aave");
        bytes32 SWAP_ODOS          = keccak256("swap.odos");
        bytes32 SWAP_UNISWAP       = keccak256("swap.uniswap");
        bytes32 PERPS_ORDERLY      = keccak256("perps.orderly");
        bytes32 PERPS_HYPERLIQUID  = keccak256("perps.hyperliquid");

        factory.registerModule(LENDING_MORPHO,     MORPHO_MODULE);
        factory.registerModule(LENDING_DOLOMITE,   DOLOMITE_MODULE);
        factory.registerModule(LENDING_AAVE,       AAVE_MODULE);
        factory.registerModule(SWAP_ODOS,          ODOS_MODULE);
        factory.registerModule(SWAP_UNISWAP,       UNISWAP_MODULE);
        factory.registerModule(PERPS_ORDERLY,      ORDERLY_MODULE);
        factory.registerModule(PERPS_HYPERLIQUID,  HYPERLIQUID_MODULE);
        console.log("registerModule x7 done");

        // ----- 3. Strategy assets -----
        string[] memory wstethPerps = new string[](1);
        wstethPerps[0] = "ETH";
        factory.whitelistStrategyAsset(Data.AssetInfo({ token: WSTETH, allowedPerpsAssets: wstethPerps }));

        string[] memory wbtcPerps = new string[](1);
        wbtcPerps[0] = "BTC";
        factory.whitelistStrategyAsset(Data.AssetInfo({ token: WBTC, allowedPerpsAssets: wbtcPerps }));

        string[] memory wethPerps = new string[](1);
        wethPerps[0] = "ETH";
        factory.whitelistStrategyAsset(Data.AssetInfo({ token: WETH, allowedPerpsAssets: wethPerps }));
        console.log("whitelistStrategyAsset(wstETH, WBTC, WETH)");

        // ----- 4. Perps module symbols -----
        factory.setPerpsModuleSymbol(WSTETH, PERPS_ORDERLY, bytes("PERP_ETH_USDC"));
        factory.setPerpsModuleSymbol(WBTC,   PERPS_ORDERLY, bytes("PERP_BTC_USDC"));
        factory.setPerpsModuleSymbol(WETH,   PERPS_ORDERLY, bytes("PERP_ETH_USDC"));
        console.log("setPerpsModuleSymbol x3 done");

        // ----- 5. Morpho lending config for wstETH -----
        factory.setModuleLendingConfig(LENDING_MORPHO, WSTETH, MORPHO_CONFIG_WSTETH);
        console.log("setModuleLendingConfig(Morpho, wstETH)");

        // ----- 6. Template -----
        factory.registerTemplate(keccak256("delta-neutral-v1"));
        console.log("registerTemplate(delta-neutral-v1)");

        vm.stopBroadcast();

        console.log("");
        console.log("=== V3 Bootstrap complete ===");
        console.log("  V3 Factory: ", factoryAddr);
        console.log("  Ready to deploy V3 vaults.");
    }
}
