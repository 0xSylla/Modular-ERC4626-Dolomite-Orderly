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

/// @title E2EFullCycle
/// @notice Full E2E: Deploy → Deposit → Swap → Dolomite → Orderly → Short → Close → Repay → Swap back → Withdraw
/// @dev Run individual phases via --sig:
///      Phase 1: forge script script/mainnet-tests/E2EFullCycle.s.sol:E2EFullCycle --sig "phase1_deployAndSetup()" --rpc-url mainnet --broadcast --with-gas-price 200000
///      Phase 2: forge script ... --sig "phase2_depositAndTrade()" ...
///      Phase 3: forge script ... --sig "phase3_swapToIBGT()" ...
///      Phase 4: forge script ... --sig "phase4_launchStrategy()" ...
///      Phase 5: forge script ... --sig "phase5_depositOrderly()" ...
///      Phase 6: forge script ... --sig "phase6_closeStrategy()" ...
///      Phase 7: forge script ... --sig "phase7_swapToUSDC()" ...
///      Phase 8: forge script ... --sig "phase8_withdrawAndClose()" ...
contract E2EFullCycle is Script {
    // ============ Berachain Addresses ============
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    address public constant ORDERLY_VAULT = 0x816f722424B49Cf1275cc86DA9840Fbd5a6167e9;

    // Dolomite market IDs
    uint256 public constant DIBGT_MARKET_ID = 38;
    uint256 public constant USDC_MARKET_ID = 2;

    string public constant BROKER_ID = "honeypot";

    // ========================================
    // PHASE 1: Deploy Router + Create Vault + Curate + Init Modules + Delegate Signer
    // ========================================
    /// @dev Env: FACTORY_ADDR, PRIVATE_KEY
    function phase1_deployAndSetup() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);

        console.log("=== Phase 1: Deploy & Setup ===");
        console.log("Deployer:", deployer);
        console.log("Factory:", factoryAddr);
        console.log("USDC balance:", IERC20(USDC).balanceOf(deployer));

        vm.startBroadcast(pk);

        // --- 1a. Deploy Routers ---
        VaultCuratorRouter router = new VaultCuratorRouter(factoryAddr);
        UserRouter userRouter = new UserRouter(factoryAddr);
        console.log("CuratorRouter:", address(router));
        console.log("UserRouter:", address(userRouter));

        // --- 1b. Register Template + Create Vault ---
        factory.registerTemplate(keccak256("delta-neutral-v1"));

        address vaultAddr = factory.createVault(
            "Dirac iBGT Delta-Neutral E2E",
            "diBGT-E2E",
            USDC,
            1_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.CuratorFeeConfig({curatorFeeBps: 200, curatorFeeRecipient: deployer})
        );
        DiracVault vault = DiracVault(payable(vaultAddr));
        console.log("Vault:", vaultAddr);

        // --- 1c. Grant Router OPERATOR_ROLE (before using router) ---
        factory.grantVaultOperator(address(vault), address(router));
        factory.grantVaultCurator(address(vault), address(router));
        console.log("OPERATOR_ROLE + CURATOR_ROLE granted to router");

        // --- 1d. Whitelist Target Asset (via router) ---
        router.whitelistTargetAsset(vaultAddr, IBGT);
        console.log("iBGT whitelisted");

        // --- 1f. Define Position ---
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");
        bytes32 orderlyModule = keccak256("perps.orderly");

        uint256 positionId = router.definePosition(
            vaultAddr,
            IBGT,
            "BERA",                 // perpsAsset: short BERA
            12_000_000              // allocation: 12 USDC (6 decimals)
        );
        console.log("Position defined, ID:", positionId);

        // --- 1g. Init trading cycle (via router) ---
        // Bootstrap: 1 wei deposit direct to enter TRADING state
        router.openDeposits(vaultAddr);
        IERC20(USDC).approve(vaultAddr, 1);
        vault.deposit(1, deployer); // direct — 1 wei bootstrap only
        router.startTrading(vaultAddr);

        // --- 1h. Init Dolomite Module (via router) ---
        router.executeModule(
            vaultAddr,
            keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );
        console.log("Dolomite module initialized");

        // --- 1i. Init Orderly Module (via router) ---
        router.executeModule(
            vaultAddr,
            keccak256("perps.orderly"),
            abi.encodeCall(OrderlyModule.initializeModule, (ORDERLY_VAULT))
        );
        console.log("Orderly module initialized");

        // --- 1j. Delegate Signer (via router) ---
        bytes32 brokerHash = keccak256(abi.encodePacked(BROKER_ID));
        VaultTypes.VaultDelegate memory delegateData = VaultTypes.VaultDelegate({
            brokerHash: brokerHash,
            delegateSigner: deployer
        });
        router.executeModule(
            vaultAddr,
            keccak256("perps.orderly"),
            abi.encodeCall(OrderlyModule.delegateSigner, (delegateData))
        );
        console.log("Delegate signer set to:", deployer);

        // --- 1k. Reset cycle for Phase 2 (via router) ---
        router.openWithdrawals(vaultAddr);
        router.closeCycle(vaultAddr);
        console.log("Init cycle closed, ready for Phase 2");

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  PHASE 1 COMPLETE");
        console.log("=======================================");
        console.log("Vault:", vaultAddr);
        console.log("CuratorRouter:", address(router));
        console.log("UserRouter:", address(userRouter));
        console.log("\nSet in .env:");
        console.log("  ROUTER_ADDR=", address(router));
        console.log("  USER_ROUTER_ADDR=", address(userRouter));
        console.log("  VAULT_ADDR=", vaultAddr);
        console.log("\nNext: Run orderly-bot.js setup (with new VAULT_ADDRESS)");
        console.log("Then: Phase 2 (deposit and start trading)");
    }

    // ========================================
    // PHASE 2: Set new cycle + Open Deposits + User Deposits 12 USDC + Start Trading
    // ========================================
    /// @dev Env: VAULT_ADDR, ROUTER_ADDR, USER_ROUTER_ADDR, PRIVATE_KEY
    function phase2_depositAndTrade() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address routerAddr = vm.envAddress("ROUTER_ADDR");
        address userRouterAddr = vm.envAddress("USER_ROUTER_ADDR");

        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        UserRouter userRouter = UserRouter(userRouterAddr);

        console.log("=== Phase 2: Deposit & Start Trading ===");
        console.log("Vault:", vaultAddr);
        console.log("USDC balance:", IERC20(USDC).balanceOf(deployer));

        vm.startBroadcast(pk);

        router.openDeposits(vaultAddr);

        // Deposit 12 USDC via UserRouter
        uint256 depositAmount = 12_000_000; // 12 USDC (6 decimals)
        IERC20(USDC).approve(userRouterAddr, depositAmount);
        userRouter.depositIntoVault(vaultAddr, depositAmount, deployer);
        console.log("Deposited:", depositAmount);

        // Start trading (via router)
        router.startTrading(vaultAddr);
        console.log("Trading started");

        vm.stopBroadcast();

        console.log("\n--- Phase 2 Complete ---");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Next: Get Kodiak swap quote, then Phase 3");
    }

    // ========================================
    // PHASE 3: Swap USDC → iBGT via KodiakModule (uses FFI for Kodiak quote)
    // ========================================
    /// @dev Env: VAULT_ADDR, FACTORY_ADDR, ROUTER_ADDR, PRIVATE_KEY
    ///      Requires --ffi flag
    function phase3_swapToIBGT() external {
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

        // Fetch Kodiak quote via FFI
        (
            IKXRouter.SwapData memory swapData,
            IKXRouter.FeeData memory feeData,
            uint256 minAmountOut
        ) = _fetchKodiakQuote(USDC, IBGT, swapAmount, vaultAddr);

        console.log("Min iBGT out:", minAmountOut);

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

        uint256 ibgtBalance = IERC20(IBGT).balanceOf(vaultAddr);
        console.log("Swap complete. Vault iBGT:", ibgtBalance);
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("\nNext: Phase 4 (launchStrategy via router)");
    }

    // ========================================
    // PHASE 4: LAUNCH STRATEGY via Router
    // On-chain: Supply iBGT + Borrow USDC + Deposit to Orderly (single batch)
    // Off-chain: Open short PERP_BERA_USDC x2 (run orderly-bot.js after)
    // ========================================
    /// @dev Env: VAULT_ADDR, FACTORY_ADDR, ROUTER_ADDR, PRIVATE_KEY, COLLATERAL_AMOUNT, BORROW_AMOUNT
    function phase4_launchStrategy() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address routerAddr = vm.envAddress("ROUTER_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 orderlyModule = keccak256("perps.orderly");

        uint256 collateralAmount = vm.envUint("COLLATERAL_AMOUNT");
        uint256 borrowAmount = vm.envUint("BORROW_AMOUNT");

        console.log("=== Phase 4: Launch Strategy via Router ===");
        console.log("Collateral (iBGT):", collateralAmount);
        console.log("Borrow (USDC):", borrowAmount);

        // Build Orderly deposit data
        bytes32 brokerHash = keccak256(abi.encodePacked(BROKER_ID));
        bytes32 accountId = keccak256(abi.encode(vaultAddr, brokerHash));
        bytes32 tokenHash = keccak256(abi.encodePacked("USDC"));
        uint256 depositFee = 0.025 ether;

        VaultTypes.VaultDepositFE memory depositData = VaultTypes.VaultDepositFE({
            accountId: accountId,
            brokerHash: brokerHash,
            tokenHash: tokenHash,
            tokenAmount: uint128(borrowAmount) // deposit all borrowed USDC
        });

        // Build modules + datas arrays (in production, the API builds these from the strategy template)
        bytes32[] memory moduleTypes = new bytes32[](3);
        bytes[] memory datas = new bytes[](3);

        // Step 1: Supply collateral
        moduleTypes[0] = keccak256("lending.dolomite");
        datas[0] = abi.encodeCall(
            DolomiteLendingBase.supplyCollateral,
            (IBGT, collateralAmount, DIBGT_MARKET_ID)
        );

        // Step 2: Borrow USDC
        moduleTypes[1] = keccak256("lending.dolomite");
        datas[1] = abi.encodeCall(
            DolomiteLendingBase.borrow,
            (borrowAmount, DIBGT_MARKET_ID, USDC_MARKET_ID)
        );

        // Step 3: Deposit to Orderly
        moduleTypes[2] = keccak256("perps.orderly");
        datas[2] = abi.encodeCall(
            OrderlyModule.deposit,
            (USDC, depositData, depositFee)
        );

        vm.startBroadcast(pk);

        // Curator requests open, operator (API) fulfills with template-built modules + datas
        router.requestOpeningPosition(vaultAddr, 0);
        router.executeOpeningRequest{value: depositFee}(vaultAddr, 0, moduleTypes, datas);
        // In production, operator waits for Orderly deposit to settle + opens short off-chain
        // Then calls confirmOpen. Here we call it immediately for testing.
        router.confirmOpen(vaultAddr, 0);

        vm.stopBroadcast();

        console.log("Strategy launched via router! (Supply + Borrow + Deposit to Orderly)");
        console.log("Vault USDC remaining:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("AccountId:");
        console.logBytes32(accountId);
        console.log("\nNext: Open short via orderly-bot.js");
        console.log("  node orderly-bot.js setup (or just the short part if keys already registered)");
    }

    // ========================================
    // PHASE 5: CLOSE STRATEGY via Router
    // Off-chain (before calling this): Close short + Withdraw from Orderly (orderly-bot.js close + withdraw)
    // On-chain: Repay Debt (auto-withdraws iBGT collateral)
    // ========================================
    /// @dev Env: VAULT_ADDR, FACTORY_ADDR, ROUTER_ADDR, PRIVATE_KEY, REPAY_AMOUNT (optional)
    /// @dev Must have USDC in vault for repayment (from Orderly withdrawal)
    /// @dev Uses repayDebtWithCollateral to zap iBGT collateral → USDC inside Dolomite
    ///      This avoids needing USDC in the vault (useful when Orderly withdrawal is pending)
    ///      Requires --ffi flag for OogaBooga quote
    /// @dev Env: VAULT_ADDR, FACTORY_ADDR, ROUTER_ADDR, PRIVATE_KEY, OOGABOOGA_API_KEY
    function phase5_closeStrategy() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address routerAddr = vm.envAddress("ROUTER_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        bytes32 dolomiteModule = keccak256("lending.dolomite");

        console.log("=== Phase 5: Close Strategy via Router ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));

        // Get OogaBooga quote for iBGT → USDC (to zap collateral)
        // Set COLLATERAL_ESTIMATE env var to the collateral amount from Phase 4
        uint256 estimatedCollateral = vm.envUint("COLLATERAL_ESTIMATE");
        (
            uint256 expectedUSDCOut,
            uint256 minUSDCOut,
            bytes memory pathDefinition
        ) = _fetchOogaBoogaQuote(IBGT, USDC, estimatedCollateral);

        console.log("OogaBooga quote - expectedOut:", expectedUSDCOut);
        console.log("minOut:", minUSDCOut);

        // Build modules + datas (in production, API builds these from strategy template)
        bytes32[] memory moduleTypes = new bytes32[](1);
        bytes[] memory datas = new bytes[](1);

        // Step 1: Repay debt with collateral zap (handles repay + withdraw in one call)
        moduleTypes[0] = keccak256("lending.dolomite");
        datas[0] = abi.encodeCall(
            DolomiteBeraModule.repayDebtWithCollateral,
            (IBGT, USDC, minUSDCOut, expectedUSDCOut, pathDefinition, DIBGT_MARKET_ID, USDC_MARKET_ID)
        );

        vm.startBroadcast(pk);
        router.requestClosingPosition(vaultAddr, 0);
        router.executeClosingRequest(vaultAddr, 0, moduleTypes, datas);
        vm.stopBroadcast();

        console.log("Strategy closed! (Debt repaid with collateral zap)");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("\nNext: Phase 7 (open withdrawals, user withdraws, close)");
        console.log("Note: Phase 6 (swap iBGT to USDC) is skipped - collateral was zapped directly");
    }

    // ========================================
    // PHASE 6: Swap iBGT → USDC via KodiakModule (uses FFI for Kodiak quote)
    // ========================================
    /// @dev Env: VAULT_ADDR, FACTORY_ADDR, ROUTER_ADDR, PRIVATE_KEY. Requires --ffi flag
    function phase6_swapToUSDC() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address routerAddr = vm.envAddress("ROUTER_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        bytes32 kodiakModule = keccak256("swap.kodiak");

        uint256 swapAmount = IERC20(IBGT).balanceOf(vaultAddr);

        console.log("=== Phase 6: Swap iBGT -> USDC ===");
        console.log("iBGT to swap:", swapAmount);

        (
            IKXRouter.SwapData memory swapData,
            IKXRouter.FeeData memory feeData,
            uint256 minAmountOut
        ) = _fetchKodiakQuote(IBGT, USDC, swapAmount, vaultAddr);

        console.log("Min USDC out:", minAmountOut);

        vm.startBroadcast(pk);
        router.executeModule(
            vaultAddr,
            keccak256("swap.kodiak"),
            abi.encodeCall(
                KodiakModule.swap,
                (IBGT, false, swapAmount, USDC, false, minAmountOut, swapData, feeData)
            )
        );
        vm.stopBroadcast();

        console.log("Swap complete!");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("\nNext: Phase 7 (open withdrawals, user withdraws, close)");
    }

    // ========================================
    // PHASE 7: Open Withdrawals + User Withdraws + Close Cycle
    // ========================================
    /// @dev Env: VAULT_ADDR, ROUTER_ADDR, USER_ROUTER_ADDR, PRIVATE_KEY
    function phase7_withdrawAndClose() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address routerAddr = vm.envAddress("ROUTER_ADDR");
        address userRouterAddr = vm.envAddress("USER_ROUTER_ADDR");

        DiracVault vault = DiracVault(payable(vaultAddr));
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        UserRouter userRouter = UserRouter(userRouterAddr);

        console.log("=== Phase 7: Withdraw & Close Cycle ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Deployer shares:", vault.balanceOf(deployer));

        vm.startBroadcast(pk);

        // Open withdrawals (via router)
        router.openWithdrawals(vaultAddr);
        console.log("Withdrawals opened");

        // Redeem all shares via UserRouter
        uint256 shares = vault.balanceOf(deployer);
        if (shares > 0) {
            vault.approve(userRouterAddr, shares);
            uint256 assets = userRouter.redeemFromVault(vaultAddr, shares, deployer);
            console.log("Redeemed shares:", shares);
            console.log("USDC received:", assets);
        }

        // Close cycle (via router)
        router.closeCycle(vaultAddr);
        console.log("Cycle closed");

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  FULL E2E CYCLE COMPLETE!");
        console.log("=======================================");
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
    }

    // ========================================
    // DEBUG: Test supplyCollateral directly (bypass router)
    // ========================================
    function debugSupply() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address routerAddr = vm.envAddress("ROUTER_ADDR");
        uint256 collateralAmount = vm.envUint("COLLATERAL_AMOUNT");
        uint256 borrowAmount = vm.envUint("BORROW_AMOUNT");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        bytes32 dolomiteModule = keccak256("lending.dolomite");

        console.log("=== Debug: executeBatch (supply+borrow) via router ===");

        bytes32[] memory moduleTypes = new bytes32[](2);
        bytes[] memory datas = new bytes[](2);
        moduleTypes[0] = keccak256("lending.dolomite");
        datas[0] = abi.encodeCall(
            DolomiteLendingBase.supplyCollateral,
            (IBGT, collateralAmount, DIBGT_MARKET_ID)
        );
        moduleTypes[1] = keccak256("lending.dolomite");
        datas[1] = abi.encodeCall(
            DolomiteLendingBase.borrow,
            (borrowAmount, DIBGT_MARKET_ID, USDC_MARKET_ID)
        );

        vm.startBroadcast(pk);
        router.executeBatch(vaultAddr, moduleTypes, datas);
        vm.stopBroadcast();

        console.log("Batch succeeded!");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
    }

    // ========================================
    // HELPER: Fund vault with USDC (for repayment when Orderly withdrawal is pending)
    // ========================================
    /// @dev Env: VAULT_ADDR, PRIVATE_KEY, FUND_AMOUNT
    function fundVault() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        uint256 amount = vm.envUint("FUND_AMOUNT");

        console.log("Funding vault with", amount, "USDC");

        vm.startBroadcast(pk);
        IERC20(USDC).transfer(vaultAddr, amount);
        vm.stopBroadcast();

        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
    }

    // ========================================
    // HELPER: Redeploy router (payable) and grant OPERATOR_ROLE
    // ========================================
    /// @dev Env: VAULT_ADDR, FACTORY_ADDR, PRIVATE_KEY
    function redeployRouter() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVault vault = DiracVault(payable(vaultAddr));

        vm.startBroadcast(pk);
        VaultCuratorRouter newRouter = new VaultCuratorRouter(factoryAddr);
        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        factory.grantVaultOperator(address(vault), address(newRouter));
        factory.grantVaultCurator(address(vault), address(newRouter));
        vm.stopBroadcast();

        console.log("New Router:", address(newRouter));
        console.log("OPERATOR_ROLE + CURATOR_ROLE granted to new router");
    }

    // ========================================
    // HELPER: Check all balances
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
        console.log("Calldata length:", fullCalldata.length);

        bytes memory encoded = _stripSelector(fullCalldata);

        IKXRouter.InputAmount memory _input;
        IKXRouter.OutputAmount memory _output;

        (_input, _output, swapData, feeData) = abi.decode(
            encoded,
            (
                IKXRouter.InputAmount,
                IKXRouter.OutputAmount,
                IKXRouter.SwapData,
                IKXRouter.FeeData
            )
        );

        minAmountOut = _output.minAmountOut;

        console.log("  SwapData.router:", swapData.router);
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
