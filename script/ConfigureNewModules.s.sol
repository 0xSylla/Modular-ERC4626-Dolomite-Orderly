// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Data} from "../src/libraries/Data.sol";
import {DiracVaultFactory} from "../src/factory/DiracVaultFactory.sol";

/// @title ConfigureNewModules
/// @notice Whitelist assets and set lending configs for Aave + Morpho on existing Arbitrum factory
/// @dev Run: forge script script/ConfigureNewModules.s.sol:ConfigureNewModules --rpc-url arbitrum --broadcast
contract ConfigureNewModules is Script {
    // Arbitrum addresses
    address constant ARB_USDC   = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB_WBTC   = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant ARB_WETH   = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant ARB_WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    // Morpho wstETH/USDC market params
    address constant MORPHO_WSTETH_ORACLE = 0x8e02a9b9Cc29d783b2fCB71C3a72651B591cae31;
    address constant MORPHO_WSTETH_IRM    = 0x66F30587FB8D4206918deb78ecA7d5eBbafD06DA;
    uint256 constant MORPHO_WSTETH_LLTV   = 860000000000000000; // 86%

    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        require(deployerPrivateKey != 0, "Set PRIVATE_KEY env var");
        require(block.chainid == 42161, "Arbitrum only");

        address factoryAddr = vm.envAddress("ARB_FACTORY_ADDR");
        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);

        bytes32 aaveTypeHash    = keccak256("lending.aave");
        bytes32 morphoTypeHash  = keccak256("lending.morpho");
        bytes32 orderlyTypeHash = keccak256("perps.orderly");

        vm.startBroadcast(deployerPrivateKey);

        // ======== 1. Whitelist wstETH as strategy asset ========
        console.log("--- Whitelist wstETH ---");
        string[] memory wstethPerps = new string[](1);
        wstethPerps[0] = "ETH"; // wstETH hedges against ETH
        factory.whitelistStrategyAsset(Data.AssetInfo({
            token: ARB_WSTETH,
            allowedPerpsAssets: wstethPerps
        }));
        factory.setPerpsModuleSymbol(ARB_WSTETH, orderlyTypeHash, bytes("PERP_ETH_USDC"));
        console.log("wstETH whitelisted (hedge: ETH, Orderly: PERP_ETH_USDC)");

        // ======== 2. Set Aave lending configs ========
        // Aave uses asset addresses directly — config encodes the asset address
        // so the executor can pass it to the module's borrowAsset / supplyCollateral
        console.log("--- Configure Aave lending ---");
        factory.setModuleLendingConfig(aaveTypeHash, ARB_WBTC, abi.encode(ARB_WBTC));
        console.log("Aave config set for WBTC");

        factory.setModuleLendingConfig(aaveTypeHash, ARB_WETH, abi.encode(ARB_WETH));
        console.log("Aave config set for WETH");

        // ======== 3. Set Morpho lending config for wstETH ========
        // Morpho uses MarketParams — encode the full market identity
        // The executor decodes this to build the correct calldata
        console.log("--- Configure Morpho lending ---");
        factory.setModuleLendingConfig(morphoTypeHash, ARB_WSTETH, abi.encode(
            ARB_USDC,              // loanToken (what we borrow)
            ARB_WSTETH,            // collateralToken
            MORPHO_WSTETH_ORACLE,  // oracle
            MORPHO_WSTETH_IRM,     // irm
            MORPHO_WSTETH_LLTV     // lltv (86%)
        ));
        console.log("Morpho config set for wstETH (oracle/irm/lltv: 86%)");

        vm.stopBroadcast();

        console.log("=======================================");
        console.log("  ASSET CONFIGS COMPLETE");
        console.log("=======================================");
        console.log("wstETH:  whitelisted + Morpho config");
        console.log("WBTC:    Aave config set");
        console.log("WETH:    Aave config set");
        console.log("=======================================");
    }
}
