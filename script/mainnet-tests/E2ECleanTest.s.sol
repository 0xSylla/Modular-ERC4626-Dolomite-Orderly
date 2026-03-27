// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Data} from "../../src/libraries/Data.sol";
import {DiracVaultFactory} from "../../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../../src/vault/DiracVault.sol";
import {VaultCuratorRouter} from "../../src/routers/VaultCuratorRouter.sol";
import {UserRouter} from "../../src/routers/UserRouter.sol";
import {OrderlyModule} from "../../src/modules/perps/OrderlyModule.sol";
import {DolomiteBeraModule} from "../../src/modules/lending/dolomite/DolomiteBeraModule.sol";
import {DolomiteLendingBase} from "../../src/modules/lending/dolomite/DolomiteLendingBase.sol";
import {KodiakModule} from "../../src/modules/swap/KodiakModule.sol";
import {IKXRouter} from "../../src/interfaces/IKXRouter.sol";
import {IVault, VaultTypes} from "../../src/interfaces/IOrderly.sol";

/// @title E2ECleanTest
/// @notice Clean E2E test: Deploy everything fresh, run full cycle with repayDebtWithCollateral
/// @dev Phases:
///   1. Deploy protocol (factory + modules + router + whitelist + vault + init + delegate signer)
///   2. Deposit USDC + start trading
///   3. Swap USDC → iBGT via Kodiak (FFI)
///   4. Launch strategy via router (supply + borrow + deposit to Orderly)
///   5. Close strategy via router (repayDebtWithCollateral — OogaBooga FFI)
///   6. Withdraw and close cycle
///
/// Run each phase separately:
///   forge script script/mainnet-tests/E2ECleanTest.s.sol:E2ECleanTest \
///     --sig "phase1_deploy()" --rpc-url mainnet --broadcast --with-gas-price 200000 --ffi
contract E2ECleanTest is Script {
    // ============ Berachain Addresses ============
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    address public constant ORDERLY_VAULT = 0x816f722424B49Cf1275cc86DA9840Fbd5a6167e9;

    uint256 public constant DIBGT_MARKET_ID = 38;
    uint256 public constant IBGT_MARKET_ID = 34;
    uint256 public constant USDC_MARKET_ID = 2;

    string public constant BROKER_ID = "honeypot";

    // ========================================
    // PHASE 1: Deploy Everything Fresh
    // ========================================
    /// @dev Env: PRIVATE_KEY
    /// @dev Deploys: Factory, Modules, Router, Vault. Inits Dolomite + Orderly. Sets delegate signer.
    function phase1_deploy() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== Phase 1: Deploy Full Protocol ===");
        console.log("Deployer:", deployer);
        console.log("USDC balance:", IERC20(USDC).balanceOf(deployer));

        vm.startBroadcast(pk);

        // --- 1. Deploy Factory ---
        Data.ProtocolFees memory fees = Data.ProtocolFees({
            protocolFeeBps: 1000,
            daoFeeBps: 300,
            protocolFeeRecipient: deployer,
            daoFeeRecipient: deployer
        });
        DiracVaultFactory factory = new DiracVaultFactory(deployer, deployer);
        console.log("Factory:", address(factory));

        // --- 2. Deploy Modules ---
        DolomiteBeraModule dolomiteModule = new DolomiteBeraModule();
        KodiakModule kodiakModule = new KodiakModule();
        OrderlyModule orderlyModule = new OrderlyModule();
        console.log("DolomiteBeraModule:", address(dolomiteModule));
        console.log("KodiakModule:", address(kodiakModule));
        console.log("OrderlyModule:", address(orderlyModule));

        // --- 3. Register Modules ---
        factory.registerModule(keccak256("lending.dolomite"), address(dolomiteModule));
        factory.registerModule(keccak256("swap.kodiak"), address(kodiakModule));
        factory.registerModule(keccak256("perps.orderly"), address(orderlyModule));

        // --- 4. Register Template ---
        factory.registerTemplate(keccak256("delta-neutral-v1"));

        // --- 5. Whitelist Assets ---
        factory.whitelistDepositToken(USDC);

        string[] memory ibgtPerps = new string[](1);
        ibgtPerps[0] = "BERA";
        factory.whitelistStrategyAsset(
            Data.AssetInfo({
                token: IBGT,
                allowedPerpsAssets: ibgtPerps
            })
        );
        factory.setModuleLendingConfig(keccak256("lending.dolomite"), IBGT, abi.encode(uint256(IBGT_MARKET_ID)));

        // --- 6. Deploy Routers ---
        VaultCuratorRouter router = new VaultCuratorRouter(address(factory));
        UserRouter userRouter = new UserRouter(address(factory));
        console.log("CuratorRouter:", address(router));
        console.log("UserRouter:", address(userRouter));

        // --- 7. Create Vault ---
        address vaultAddr = factory.createVault(
            "Dirac iBGT Delta-Neutral Clean",
            "diBGT-CLEAN",
            USDC,
            1_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.VaultFees({ performanceFeeBps: 1000, managementFeeBps: 50, feeRecipient: deployer }),
            0, // rebalanceThresholdBps
            0  // fundingRateThresholdBps
        );
        DiracVault vault = DiracVault(payable(vaultAddr));
        console.log("Vault:", vaultAddr);

        // --- 8. Grant Router OPERATOR_ROLE + CURATOR_ROLE ---
        factory.grantVaultOperator(vaultAddr, address(router));
        factory.grantVaultCurator(vaultAddr, address(router));

        // --- 9. Init trading cycle (needed to executeModule) ---
        // Bootstrap: direct vault calls for 1 wei deposit to enter TRADING state
        router.openDeposits(vaultAddr);
        IERC20(USDC).approve(vaultAddr, 1);
        vault.deposit(1, deployer); // direct — UserRouter not deployed, 1 wei bootstrap only
        router.startTrading(vaultAddr);

        // --- 10. Initialize Dolomite Module ---
        router.executeModule(
            vaultAddr,
            keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );
        console.log("Dolomite initialized");

        // --- 11. Initialize Orderly Module ---
        router.executeModule(
            vaultAddr,
            keccak256("perps.orderly"),
            abi.encodeCall(OrderlyModule.initializeModule, (ORDERLY_VAULT))
        );
        console.log("Orderly module initialized");

        // --- 12. Delegate Signer ---
        bytes32 brokerHash = keccak256(abi.encodePacked(BROKER_ID));
        router.executeModule(
            vaultAddr,
            keccak256("perps.orderly"),
            abi.encodeCall(OrderlyModule.delegateSigner, (
                VaultTypes.VaultDelegate({brokerHash: brokerHash, delegateSigner: deployer})
            ))
        );
        console.log("Delegate signer set to:", deployer);

        // --- 13. Whitelist iBGT as target asset on vault ---
        router.whitelistTargetAsset(vaultAddr, IBGT);
        console.log("iBGT whitelisted as target asset");

        // --- 14. Reset cycle for Phase 2 ---
        router.openWithdrawals(vaultAddr);
        router.closeCycle(vaultAddr);

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  PHASE 1 COMPLETE - PROTOCOL DEPLOYED");
        console.log("=======================================");
        console.log("Factory:", address(factory));
        console.log("CuratorRouter:", address(router));
        console.log("UserRouter:", address(userRouter));
        console.log("Vault:", vaultAddr);
        console.log("\nSet in .env:");
        console.log("  FACTORY_ADDR=", address(factory));
        console.log("  ROUTER_ADDR=", address(router));
        console.log("  USER_ROUTER_ADDR=", address(userRouter));
        console.log("  VAULT_ADDR=", vaultAddr);
        console.log("\nNext:");
        console.log("  1. Run orderly-bot.js setup (confirm delegate + register key)");
        console.log("  2. Phase 2: deposit + start trading");
    }

    // ========================================
    // PHASE 2: Deposit USDC + Start Trading
    // ========================================
    /// @dev Env: VAULT_ADDR, ROUTER_ADDR, USER_ROUTER_ADDR, PRIVATE_KEY
    function phase2_deposit() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address routerAddr = vm.envAddress("ROUTER_ADDR");
        address userRouterAddr = vm.envAddress("USER_ROUTER_ADDR");

        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        UserRouter userRouter = UserRouter(userRouterAddr);

        console.log("=== Phase 2: Deposit & Start Trading ===");

        vm.startBroadcast(pk);

        router.openDeposits(vaultAddr);

        uint256 depositAmount = 12_000_000; // 12 USDC
        IERC20(USDC).approve(userRouterAddr, depositAmount);
        userRouter.depositIntoVault(vaultAddr, depositAmount, deployer);

        router.startTrading(vaultAddr);

        vm.stopBroadcast();

        console.log("Deposited:", depositAmount);
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("\nNext: Phase 3 (swap USDC to iBGT)");
    }

    // ========================================
    // PHASE 3: Swap USDC → iBGT via Kodiak (FFI)
    // ========================================
    /// @dev Env: VAULT_ADDR, FACTORY_ADDR, ROUTER_ADDR, PRIVATE_KEY. Requires --ffi
    function phase3_swap() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address routerAddr = vm.envAddress("ROUTER_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        bytes32 kodiakModule = keccak256("swap.kodiak");

        uint256 swapAmount = IERC20(USDC).balanceOf(vaultAddr);
        console.log("=== Phase 3: Swap USDC -> iBGT ===");
        console.log("Swap amount:", swapAmount);

        (
            IKXRouter.SwapData memory swapData,
            IKXRouter.FeeData memory feeData,
            uint256 minAmountOut
        ) = _fetchKodiakQuote(USDC, IBGT, swapAmount, vaultAddr);

        vm.startBroadcast(pk);
        router.executeModule(
            vaultAddr,
            keccak256("swap.kodiak"),
            abi.encodeCall(
                KodiakModule.swap,
                (USDC, false, swapAmount, IBGT, false, minAmountOut, swapData, feeData)
            )
        );
        vm.stopBroadcast();

        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("\nNext: Phase 4 (launch strategy via router)");
    }

    // ========================================
    // PHASE 4: Launch Strategy via Router
    // Supply iBGT + Borrow USDC + Deposit to Orderly
    // ========================================
    /// @dev Env: VAULT_ADDR, FACTORY_ADDR, ROUTER_ADDR, PRIVATE_KEY, COLLATERAL_AMOUNT, BORROW_AMOUNT
    /// @dev Uses router.definePosition + executeOpeningRequest + confirmOpen
    function phase4_launch() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address routerAddr = vm.envAddress("ROUTER_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");
        bytes32 orderlyModule = keccak256("perps.orderly");

        uint256 collateralAmount = vm.envUint("COLLATERAL_AMOUNT");
        uint256 borrowAmount = vm.envUint("BORROW_AMOUNT");

        console.log("=== Phase 4: Launch Strategy ===");
        console.log("Collateral (iBGT):", collateralAmount);
        console.log("Borrow (USDC):", borrowAmount);

        bytes32 brokerHash = keccak256(abi.encodePacked(BROKER_ID));
        bytes32 accountId = keccak256(abi.encode(vaultAddr, brokerHash));
        bytes32 tokenHash = keccak256(abi.encodePacked("USDC"));
        uint256 depositFee = 0.025 ether;

        VaultTypes.VaultDepositFE memory depositData = VaultTypes.VaultDepositFE({
            accountId: accountId,
            brokerHash: brokerHash,
            tokenHash: tokenHash,
            tokenAmount: uint128(borrowAmount)
        });

        // Build modules + datas arrays for executeBatch
        bytes32[] memory moduleTypes = new bytes32[](3);
        bytes[] memory datas = new bytes[](3);

        moduleTypes[0] = keccak256("lending.dolomite");
        datas[0] = abi.encodeCall(
            DolomiteLendingBase.supplyCollateral, (IBGT, collateralAmount, DIBGT_MARKET_ID)
        );

        moduleTypes[1] = keccak256("lending.dolomite");
        datas[1] = abi.encodeCall(
            DolomiteLendingBase.borrow, (borrowAmount, DIBGT_MARKET_ID, USDC_MARKET_ID)
        );

        moduleTypes[2] = keccak256("perps.orderly");
        datas[2] = abi.encodeCall(
            OrderlyModule.deposit, (USDC, depositData, depositFee)
        );

        vm.startBroadcast(pk);

        // 1. Define position on router (curator action)
        router.definePosition(
            vaultAddr,
            IBGT,
            "BERA",
            collateralAmount
        );
        console.log("Position 0 defined");

        // 2. Request opening (curator: IDLE → OPEN_REQUESTED)
        router.requestOpeningPosition(vaultAddr, 0);

        // 3. Execute opening (operator: OPEN_REQUESTED → OPENING)
        router.executeOpeningRequest{value: depositFee}(vaultAddr, 0, moduleTypes, datas);

        // 4. Confirm open (operator: OPENING → ACTIVE)
        // In production, API waits for Orderly deposit to settle + opens short first.
        // For testing we call it immediately.
        router.confirmOpen(vaultAddr, 0);

        vm.stopBroadcast();

        console.log("Strategy launched!");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("AccountId:");
        console.logBytes32(accountId);
        console.log("\nNext: Open short via orderly-bot.js, then Phase 5 to close");
    }

    // ========================================
    // PHASE 5: Close Strategy — repayDebtWithCollateral
    // ========================================
    /// @dev Env: VAULT_ADDR, FACTORY_ADDR, ROUTER_ADDR, PRIVATE_KEY, OOGABOOGA_API_KEY, COLLATERAL_ESTIMATE
    /// @dev Requires --ffi for OogaBooga quote
    /// @dev Before this: close short + settle PnL + withdraw from Orderly via bot/API
    function phase5_close() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address routerAddr = vm.envAddress("ROUTER_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        bytes32 dolomiteModule = keccak256("lending.dolomite");

        console.log("=== Phase 5: Close Strategy (repayDebtWithCollateral) ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));

        // Estimate collateral amount for OogaBooga quote
        uint256 estimatedCollateral = vm.envUint("COLLATERAL_ESTIMATE");
        console.log("Estimated collateral:", estimatedCollateral);

        (
            uint256 expectedUSDCOut,
            uint256 minUSDCOut,
            bytes memory pathDefinition
        ) = _fetchOogaBoogaQuote(IBGT, USDC, estimatedCollateral);

        console.log("OogaBooga expectedOut:", expectedUSDCOut);
        console.log("OogaBooga minOut:", minUSDCOut);

        bytes32[] memory moduleTypes = new bytes32[](1);
        bytes[] memory datas = new bytes[](1);

        moduleTypes[0] = keccak256("lending.dolomite");
        datas[0] = abi.encodeCall(
            DolomiteBeraModule.repayDebtWithCollateral,
            (IBGT, USDC, minUSDCOut, expectedUSDCOut, pathDefinition, DIBGT_MARKET_ID, USDC_MARKET_ID)
        );

        vm.startBroadcast(pk);
        // 1. Request close (curator: ACTIVE → CLOSE_REQUESTED)
        router.requestClosingPosition(vaultAddr, 0);
        // 2. Execute close (operator: CLOSE_REQUESTED → IDLE)
        router.executeClosingRequest(vaultAddr, 0, moduleTypes, datas);
        vm.stopBroadcast();

        console.log("Strategy closed!");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("\nNext: Phase 6 (withdraw and close cycle)");
    }

    // ========================================
    // PHASE 6: Withdraw and Close Cycle
    // ========================================
    /// @dev Env: VAULT_ADDR, ROUTER_ADDR, USER_ROUTER_ADDR, PRIVATE_KEY
    function phase6_withdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address routerAddr = vm.envAddress("ROUTER_ADDR");
        address userRouterAddr = vm.envAddress("USER_ROUTER_ADDR");

        DiracVault vault = DiracVault(payable(vaultAddr));
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        UserRouter userRouter = UserRouter(userRouterAddr);

        console.log("=== Phase 6: Withdraw & Close ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Deployer shares:", vault.balanceOf(deployer));

        vm.startBroadcast(pk);

        router.openWithdrawals(vaultAddr);

        uint256 shares = vault.balanceOf(deployer);
        if (shares > 0) {
            // Approve UserRouter to spend vault shares, then redeem via router
            vault.approve(userRouterAddr, shares);
            uint256 assets = userRouter.redeemFromVault(vaultAddr, shares, deployer);
            console.log("Redeemed shares:", shares);
            console.log("USDC received:", assets);
        }

        router.closeCycle(vaultAddr);

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  FULL E2E CYCLE COMPLETE!");
        console.log("=======================================");
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));
    }

    // ========================================
    // HELPER: Check balances
    // ========================================
    function checkBalances() external view {
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        console.log("=== Balance Check ===");
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("Deployer shares:", DiracVault(payable(vaultAddr)).balanceOf(deployer));
    }

    // ============ Kodiak Quote Helper (FFI) ============

    function _fetchKodiakQuote(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        address recipient
    )
        internal
        returns (
            IKXRouter.SwapData memory swapData,
            IKXRouter.FeeData memory feeData,
            uint256 minAmountOut
        )
    {
        string memory curlCmd = string.concat(
            "curl -s 'https://backend.kodiak.finance/quote"
            "?tokenInAddress=", vm.toString(tokenIn),
            "&tokenInChainId=80094"
            "&tokenOutAddress=", vm.toString(tokenOut),
            "&tokenOutChainId=80094"
            "&amount=", vm.toString(amount),
            "&type=exactIn"
            "&recipient=", vm.toString(recipient),
            "&slippageTolerance=5'"
        );

        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = curlCmd;

        console.log("Fetching Kodiak quote...");
        bytes memory result = vm.ffi(cmd);
        string memory json = string(result);

        bytes memory fullCalldata = vm.parseJsonBytes(json, ".methodParameters.calldata");
        bytes memory encoded = _stripSelector(fullCalldata);

        IKXRouter.InputAmount memory _input;
        IKXRouter.OutputAmount memory _output;

        (_input, _output, swapData, feeData) = abi.decode(
            encoded,
            (IKXRouter.InputAmount, IKXRouter.OutputAmount, IKXRouter.SwapData, IKXRouter.FeeData)
        );

        minAmountOut = _output.minAmountOut;
        console.log("  minAmountOut:", minAmountOut);
    }

    // ============ OogaBooga Quote Helper (FFI) ============

    function _fetchOogaBoogaQuote(
        address tokenIn,
        address tokenOut,
        uint256 amount
    )
        internal
        returns (
            uint256 expectedOut,
            uint256 minOut,
            bytes memory pathDefinition
        )
    {
        string memory apiKey = vm.envString("OOGABOOGA_API_KEY");
        string memory curlCmd = string.concat(
            "curl -s -H 'Authorization: Bearer ", apiKey, "' "
            "'https://mainnet.api.oogabooga.io/v1/swap"
            "?tokenIn=", vm.toString(tokenIn),
            "&tokenOut=", vm.toString(tokenOut),
            "&amount=", vm.toString(amount),
            "&to=", vm.toString(address(0x0CE205f7bCBa70E4c03f826918c8c21073386ED3)),
            "&slippage=0.05'"
        );

        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = curlCmd;

        console.log("Fetching OogaBooga quote...");
        bytes memory result = vm.ffi(cmd);
        string memory json = string(result);

        expectedOut = vm.parseJsonUint(json, ".assumedAmountOut");
        minOut = (expectedOut * 95) / 100;
        pathDefinition = vm.parseJsonBytes(json, ".routerParams.pathDefinition");
    }

    function _stripSelector(bytes memory data) internal pure returns (bytes memory) {
        require(data.length >= 4, "calldata too short");
        bytes memory result = new bytes(data.length - 4);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[i + 4];
        }
        return result;
    }
}
