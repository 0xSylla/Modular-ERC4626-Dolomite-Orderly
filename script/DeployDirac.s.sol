// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Data} from "../src/libraries/Data.sol";
import {DiracVaultFactory} from "../src/factory/DiracVaultFactory.sol";
import {DolomiteBeraModule} from "../src/modules/lending/dolomite/DolomiteBeraModule.sol";
import {DolomiteArbModule} from "../src/modules/lending/dolomite/DolomiteArbModule.sol";
import {KodiakModule} from "../src/modules/swap/KodiakModule.sol";
import {OdosModule} from "../src/modules/swap/OdosModule.sol";
import {OrderlyModule} from "../src/modules/perps/OrderlyModule.sol";
import {AaveModule} from "../src/modules/lending/aave/AaveModule.sol";
import {MorphoModule} from "../src/modules/lending/morpho/MorphoModule.sol";
import {UserRouter} from "../src/routers/UserRouter.sol";
import {VaultCuratorRouter} from "../src/routers/VaultCuratorRouter.sol";

/// @title DeployDirac
/// @notice Deploys the full Dirac protocol: Factory → Modules → Routers → Whitelist assets
/// @dev Run: forge script script/DeployDirac.s.sol:DeployDirac --rpc-url mainnet --broadcast
contract DeployDirac is Script {
    // ============ Chain IDs ============
    uint256 constant CHAIN_BERACHAIN = 80094;
    uint256 constant CHAIN_ARBITRUM  = 42161;
    uint256 constant CHAIN_ETHEREUM  = 1;

    // ============ Berachain Mainnet ============
    address constant BERA_USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address constant BERA_IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    address constant BERA_WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c; // TODO: verify on-chain
    address constant BERA_WETH = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590; // TODO: verify on-chain
    uint256 constant BERA_DOLOMITE_IBGT_ID  = 34;
    uint256 constant BERA_DOLOMITE_WBTC_ID  = 4; // TODO: set correct Dolomite market ID
    uint256 constant BERA_DOLOMITE_WETH_ID  = 0; // TODO: set correct Dolomite market ID

    // ============ Arbitrum Mainnet ============
    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB_WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    uint256 constant ARB_DOLOMITE_USDC_ID = 17; // Native USDC (0xaf88d0...) on Arbitrum Dolomite
    uint256 constant ARB_DOLOMITE_WBTC_ID = 4;  // WBTC market ID on Arbitrum Dolomite
    uint256 constant ARB_DOLOMITE_WETH_ID = 0;  // WETH market ID on Arbitrum Dolomite
    address constant ARB_WSTETH = 0x5979d7B546E38E9Ab8B0d483b5C0c2C99b27C399;

    // ============ Ethereum Mainnet ============
    address constant ETH_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant ETH_WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant ETH_DOLOMITE_WBTC_ID = 4; // TODO: set correct Dolomite market ID
    uint256 constant ETH_DOLOMITE_WETH_ID = 0; // TODO: set correct Dolomite market ID

    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPrivateKey == 0) {
            console.log("WARNING: PRIVATE_KEY not set, using default anvil key");
            deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }

        address admin = vm.addr(deployerPrivateKey);
        // Operator = API wallet that executes on-chain position actions. Defaults to admin if not set.
        address operator = vm.envOr("OPERATOR_ADDRESS", admin);
        address protocolFeeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", admin);
        address daoFeeRecipient = vm.envOr("DAO_FEE_RECIPIENT", admin);

        uint256 chainId = block.chainid;
        bool isBerachain = chainId == CHAIN_BERACHAIN;
        bool isArbitrum  = chainId == CHAIN_ARBITRUM;
        bool isEthereum  = chainId == CHAIN_ETHEREUM;

        require(isBerachain || isArbitrum || isEthereum, "Unsupported chain");

        address usdc = isBerachain ? BERA_USDC : isArbitrum ? ARB_USDC : ETH_USDC;

        vm.startBroadcast(deployerPrivateKey);

        // ======== 1. Deploy Factory ========
        console.log("--- Step 1: Deploy Factory ---");

        Data.ProtocolFees memory fees = Data.ProtocolFees({
            protocolFeeBps: 1000, // 10%
            daoFeeBps: 300, // 3%
            protocolFeeRecipient: protocolFeeRecipient,
            daoFeeRecipient: daoFeeRecipient
        });

        DiracVaultFactory factory = new DiracVaultFactory(admin, operator, fees);
        console.log("Factory deployed at:", address(factory));

        // ======== 2. Deploy Modules ========
        console.log("--- Step 2: Deploy Modules ---");

        OrderlyModule orderlyModule = new OrderlyModule();
        console.log("OrderlyModule deployed at:", address(orderlyModule));

        address dolomiteModuleAddr;
        address swapModuleAddr;
        bytes32 swapModuleType;

        address aaveModuleAddr;
        address morphoModuleAddr;

        if (isArbitrum) {
            DolomiteArbModule arbDolomite = new DolomiteArbModule();
            dolomiteModuleAddr = address(arbDolomite);
            console.log("DolomiteArbModule deployed at:", dolomiteModuleAddr);

            OdosModule odosModule = new OdosModule();
            swapModuleAddr = address(odosModule);
            swapModuleType = keccak256("swap.odos");
            console.log("OdosModule deployed at:", swapModuleAddr);

            AaveModule aaveModule = new AaveModule();
            aaveModuleAddr = address(aaveModule);
            console.log("AaveModule deployed at:", aaveModuleAddr);

            MorphoModule morphoModule = new MorphoModule();
            morphoModuleAddr = address(morphoModule);
            console.log("MorphoModule deployed at:", morphoModuleAddr);
        } else {
            DolomiteBeraModule dolomiteModule = new DolomiteBeraModule();
            dolomiteModuleAddr = address(dolomiteModule);
            console.log("DolomiteBeraModule deployed at:", dolomiteModuleAddr);

            KodiakModule kodiakModule = new KodiakModule();
            swapModuleAddr = address(kodiakModule);
            swapModuleType = keccak256("swap.kodiak");
            console.log("KodiakModule deployed at:", swapModuleAddr);
        }

        // ======== 3. Register Modules on Factory ========
        console.log("--- Step 3: Register Modules ---");

        factory.registerModule(keccak256("lending.dolomite"), dolomiteModuleAddr);
        factory.registerModule(swapModuleType,                swapModuleAddr);
        factory.registerModule(keccak256("perps.orderly"),    address(orderlyModule));
        if (isArbitrum) {
            factory.registerModule(keccak256("lending.aave"),  aaveModuleAddr);
            factory.registerModule(keccak256("lending.morpho"), morphoModuleAddr);
            console.log("Aave + Morpho modules registered.");
        }
        console.log("All modules registered.");

        // ======== 4. Register Template ========
        console.log("--- Step 4: Register Template ---");

        factory.registerTemplate(keccak256("delta-neutral-v1"));
        console.log("Template 'delta-neutral-v1' registered.");

        // ======== 5. Whitelist Deposit Token ========
        console.log("--- Step 5: Whitelist Deposit Token ---");

        factory.whitelistDepositToken(usdc);
        console.log("USDC whitelisted as deposit token.");

        // ======== 6. Whitelist Strategy Assets + Configure Modules ========
        console.log("--- Step 6: Whitelist Strategy Assets ---");

        bytes32 dolomiteTypeHash = keccak256("lending.dolomite");
        bytes32 aaveTypeHash     = keccak256("lending.aave");
        bytes32 morphoTypeHash   = keccak256("lending.morpho");
        bytes32 orderlyTypeHash  = keccak256("perps.orderly");

        if (isBerachain) {
            // iBGT — hedge: BERA, Orderly symbol: PERP_BERA_USDC
            string[] memory ibgtPerps = new string[](1);
            ibgtPerps[0] = "BERA";
            factory.whitelistStrategyAsset(Data.AssetInfo({ token: BERA_IBGT, allowedPerpsAssets: ibgtPerps }));
            factory.setModuleLendingConfig(dolomiteTypeHash, BERA_IBGT, abi.encode(BERA_DOLOMITE_IBGT_ID));
            factory.setPerpsModuleSymbol(BERA_IBGT, orderlyTypeHash, bytes("PERP_BERA_USDC"));
            console.log("iBGT whitelisted (hedge: BERA, Orderly: PERP_BERA_USDC).");

            // WBTC — hedge: BTC, Orderly symbol: PERP_BTC_USDC
            string[] memory wbtcPerps = new string[](1);
            wbtcPerps[0] = "BTC";
            factory.whitelistStrategyAsset(Data.AssetInfo({ token: BERA_WBTC, allowedPerpsAssets: wbtcPerps }));
            factory.setModuleLendingConfig(dolomiteTypeHash, BERA_WBTC, abi.encode(BERA_DOLOMITE_WBTC_ID));
            factory.setPerpsModuleSymbol(BERA_WBTC, orderlyTypeHash, bytes("PERP_BTC_USDC"));
            console.log("WBTC whitelisted (hedge: BTC, Orderly: PERP_BTC_USDC).");

            // WETH — hedge: ETH, Orderly symbol: PERP_ETH_USDC
            string[] memory wethPerps = new string[](1);
            wethPerps[0] = "ETH";
            factory.whitelistStrategyAsset(Data.AssetInfo({ token: BERA_WETH, allowedPerpsAssets: wethPerps }));
            factory.setModuleLendingConfig(dolomiteTypeHash, BERA_WETH, abi.encode(BERA_DOLOMITE_WETH_ID));
            factory.setPerpsModuleSymbol(BERA_WETH, orderlyTypeHash, bytes("PERP_ETH_USDC"));
            console.log("WETH whitelisted (hedge: ETH, Orderly: PERP_ETH_USDC).");

        } else if (isArbitrum) {
            // --- WBTC: Dolomite + Aave ---
            string[] memory wbtcPerps = new string[](1);
            wbtcPerps[0] = "BTC";
            factory.whitelistStrategyAsset(Data.AssetInfo({ token: ARB_WBTC, allowedPerpsAssets: wbtcPerps }));
            factory.setModuleLendingConfig(dolomiteTypeHash, ARB_WBTC, abi.encode(ARB_DOLOMITE_WBTC_ID));
            factory.setModuleLendingConfig(aaveTypeHash,     ARB_WBTC, abi.encode(ARB_WBTC));
            factory.setPerpsModuleSymbol(ARB_WBTC, orderlyTypeHash, bytes("PERP_BTC_USDC"));
            console.log("WBTC whitelisted (Dolomite + Aave, hedge: BTC).");

            // --- WETH: Dolomite + Aave ---
            string[] memory wethPerps = new string[](1);
            wethPerps[0] = "ETH";
            factory.whitelistStrategyAsset(Data.AssetInfo({ token: ARB_WETH, allowedPerpsAssets: wethPerps }));
            factory.setModuleLendingConfig(dolomiteTypeHash, ARB_WETH, abi.encode(ARB_DOLOMITE_WETH_ID));
            factory.setModuleLendingConfig(aaveTypeHash,     ARB_WETH, abi.encode(ARB_WETH));
            factory.setPerpsModuleSymbol(ARB_WETH, orderlyTypeHash, bytes("PERP_ETH_USDC"));
            console.log("WETH whitelisted (Dolomite + Aave, hedge: ETH).");

            // --- wstETH: Morpho only ---
            string[] memory wstethPerps = new string[](1);
            wstethPerps[0] = "ETH"; // wstETH hedges against ETH
            factory.whitelistStrategyAsset(Data.AssetInfo({ token: ARB_WSTETH, allowedPerpsAssets: wstethPerps }));
            factory.setModuleLendingConfig(morphoTypeHash, ARB_WSTETH, abi.encode(
                ARB_USDC,    // loanToken
                ARB_WSTETH,  // collateralToken
                address(0),  // oracle  - TODO: set actual Morpho oracle
                address(0),  // irm     - TODO: set actual Morpho IRM
                uint256(0)   // lltv    - TODO: set actual LLTV
            ));
            factory.setPerpsModuleSymbol(ARB_WSTETH, orderlyTypeHash, bytes("PERP_ETH_USDC"));
            console.log("wstETH whitelisted (Morpho, hedge: ETH).");

        } else {
            // Ethereum mainnet
            string[] memory wbtcPerps = new string[](1);
            wbtcPerps[0] = "BTC";
            factory.whitelistStrategyAsset(Data.AssetInfo({ token: ETH_WBTC, allowedPerpsAssets: wbtcPerps }));
            factory.setModuleLendingConfig(dolomiteTypeHash, ETH_WBTC, abi.encode(ETH_DOLOMITE_WBTC_ID));
            factory.setPerpsModuleSymbol(ETH_WBTC, orderlyTypeHash, bytes("PERP_BTC_USDC"));
            console.log("WBTC whitelisted (hedge: BTC, Orderly: PERP_BTC_USDC).");

            string[] memory wethPerps = new string[](1);
            wethPerps[0] = "ETH";
            factory.whitelistStrategyAsset(Data.AssetInfo({ token: ETH_WETH, allowedPerpsAssets: wethPerps }));
            factory.setModuleLendingConfig(dolomiteTypeHash, ETH_WETH, abi.encode(ETH_DOLOMITE_WETH_ID));
            factory.setPerpsModuleSymbol(ETH_WETH, orderlyTypeHash, bytes("PERP_ETH_USDC"));
            console.log("WETH whitelisted (hedge: ETH, Orderly: PERP_ETH_USDC).");
        }

        // ======== 7. Deploy Routers ========
        console.log("--- Step 7: Deploy Routers ---");

        UserRouter userRouter = new UserRouter(address(factory));
        console.log("UserRouter deployed at:", address(userRouter));

        VaultCuratorRouter curatorRouter = new VaultCuratorRouter(address(factory));
        console.log("VaultCuratorRouter deployed at:", address(curatorRouter));

        factory.setCuratorRouter(address(curatorRouter));
        console.log("CuratorRouter registered on factory.");

        vm.stopBroadcast();

        // ======== Summary ========
        console.log("=======================================");
        console.log("  DIRAC PROTOCOL DEPLOYMENT COMPLETE");
        console.log("=======================================");
        console.log("Chain ID:           ", chainId);
        console.log("Admin:              ", admin);
        console.log("Operator:           ", operator);
        console.log("Factory:            ", address(factory));
        console.log("DolomiteBeraModule:     ", dolomiteModuleAddr);
        console.log("SwapModule:         ", swapModuleAddr);
        console.log("OrderlyModule:      ", address(orderlyModule));
        console.log("UserRouter:         ", address(userRouter));
        console.log("VaultCuratorRouter: ", address(curatorRouter));
        console.log("=======================================");
    }
}
