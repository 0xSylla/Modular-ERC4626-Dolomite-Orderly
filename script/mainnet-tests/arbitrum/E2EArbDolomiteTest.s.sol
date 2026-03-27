// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Data} from "../../../src/libraries/Data.sol";
import {DiracVaultFactory} from "../../../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../../../src/vault/DiracVault.sol";
import {VaultCuratorRouter} from "../../../src/routers/VaultCuratorRouter.sol";
import {UserRouter} from "../../../src/routers/UserRouter.sol";
import {DolomiteArbModule} from "../../../src/modules/lending/dolomite/DolomiteArbModule.sol";
import {DolomiteLendingBase} from "../../../src/modules/lending/dolomite/DolomiteLendingBase.sol";
import {OdosModule} from "../../../src/modules/swap/OdosModule.sol";
import {OrderlyModule} from "../../../src/modules/perps/OrderlyModule.sol";

/// @title E2EArbDolomiteTest
/// @notice Arbitrum E2E: Deploy → Deposit $1 USDC → Swap to WETH → Supply to Dolomite → Borrow half back → Repay
///
/// @dev Run phases individually:
///   forge script script/mainnet-tests/arbitrum/E2EArbDolomiteTest.s.sol:E2EArbDolomiteTest \
///     --sig "phase1_deploy()" --rpc-url arbitrum --broadcast --ffi
///
///   forge script script/mainnet-tests/arbitrum/E2EArbDolomiteTest.s.sol:E2EArbDolomiteTest \
///     --sig "phase2_deposit()" --rpc-url arbitrum --broadcast
///
///   forge script script/mainnet-tests/arbitrum/E2EArbDolomiteTest.s.sol:E2EArbDolomiteTest \
///     --sig "phase3_swapSupplyBorrow()" --rpc-url arbitrum --broadcast --ffi
///
///   forge script script/mainnet-tests/arbitrum/E2EArbDolomiteTest.s.sol:E2EArbDolomiteTest \
///     --sig "phase4_repayAndWithdraw()" --rpc-url arbitrum --broadcast --ffi
///
/// @dev Env vars required:
///   PRIVATE_KEY             — deployer / curator / operator wallet
///   Phase 2+: FACTORY_ADDR, ROUTER_ADDR, USER_ROUTER_ADDR, VAULT_ADDR
///   Phase 3:  BORROW_AMOUNT  (optional, default 500_000 = 0.5 USDC)
///   Phase 4:  REPAY_AMOUNT   (optional, default 0 = auto 107%)
///             WETH_ESTIMATE  (optional, WETH wei in Dolomite — needed if vault holds no WETH yet)
contract E2EArbDolomiteTest is Script {
    // ============ Arbitrum Mainnet Addresses ============
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // native USDC
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    // Dolomite market IDs on Arbitrum
    uint256 public constant WETH_MARKET_ID = 0;
    uint256 public constant USDC_MARKET_ID = 17; // native USDC

    // Deposit amount: $0.09 = 90_000 (USDC has 6 decimals)
    uint256 public constant DEPOSIT_AMOUNT = 90_000;

    // ============================================================
    // PHASE 1: Deploy Full Protocol
    // ============================================================
    /// @notice Deploy factory, modules, routers. Create vault. Initialize Dolomite.
    /// @dev After this phase, copy the logged addresses to your .env file.
    function phase1_deploy() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== Phase 1: Deploy Arbitrum Protocol ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        require(block.chainid == 42161, "Must run on Arbitrum (--rpc-url arbitrum)");

        vm.startBroadcast(pk);

        // --- 1. Factory ---
        Data.ProtocolFees memory fees = Data.ProtocolFees({
            protocolFeeBps: 1000,
            daoFeeBps: 300,
            protocolFeeRecipient: deployer,
            daoFeeRecipient: deployer
        });
        DiracVaultFactory factory = new DiracVaultFactory(deployer, deployer);
        console.log("Factory:", address(factory));

        // --- 2. Modules ---
        DolomiteArbModule dolomiteModule = new DolomiteArbModule();
        OdosModule odosModule = new OdosModule();
        OrderlyModule orderlyModule = new OrderlyModule(); // registered for completeness
        console.log("DolomiteArbModule:", address(dolomiteModule));
        console.log("OdosModule:", address(odosModule));
        console.log("OrderlyModule:", address(orderlyModule));

        // --- 3. Register modules ---
        factory.registerModule(keccak256("lending.dolomite"), address(dolomiteModule));
        factory.registerModule(keccak256("swap.odos"),        address(odosModule));
        factory.registerModule(keccak256("perps.orderly"),    address(orderlyModule));
        console.log("Modules registered.");

        // --- 4. Register template ---
        factory.registerTemplate(keccak256("delta-neutral-v1"));

        // --- 5. Whitelist USDC as deposit token ---
        factory.whitelistDepositToken(USDC);

        // --- 6. Whitelist WETH as strategy asset (hedge: ETH) ---
        string[] memory wethPerps = new string[](1);
        wethPerps[0] = "ETH";
        factory.whitelistStrategyAsset(Data.AssetInfo({ token: WETH, allowedPerpsAssets: wethPerps }));
        factory.setModuleLendingConfig(
            keccak256("lending.dolomite"),
            WETH,
            abi.encode(WETH_MARKET_ID)
        );
        console.log("WETH whitelisted as strategy asset (Dolomite market ID: 0).");

        // --- 7. Routers ---
        VaultCuratorRouter router = new VaultCuratorRouter(address(factory));
        UserRouter userRouter = new UserRouter(address(factory));
        factory.setCuratorRouter(address(router));
        console.log("VaultCuratorRouter:", address(router));
        console.log("UserRouter:", address(userRouter));

        // --- 8. Create vault ---
        address vaultAddr = factory.createVault(
            "Dirac WETH Delta-Neutral Arbitrum",
            "dWETH-ARB",
            USDC,
            10_000_000_000e6, // 10B USDC cap
            keccak256("delta-neutral-v1"),
            Data.VaultFees({ performanceFeeBps: 1000, managementFeeBps: 50, feeRecipient: deployer }),
            0, // rebalanceThresholdBps
            0  // fundingRateThresholdBps
        );
        DiracVault vault = DiracVault(payable(vaultAddr));
        console.log("Vault:", vaultAddr);

        // --- 9. Grant router roles ---
        factory.grantVaultOperator(vaultAddr, address(router));
        factory.grantVaultCurator(vaultAddr, address(router));

        // --- 10. Bootstrap: open deposits → 1 wei deposit → start trading → init Dolomite → reset ---
        router.openDeposits(vaultAddr);
        IERC20(USDC).approve(vaultAddr, 1);
        vault.deposit(1, deployer);
        router.startTrading(vaultAddr);

        router.executeModule(
            vaultAddr,
            keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );
        console.log("Dolomite module initialized (Deposit/Withdrawal router authorized as operator).");

        // Whitelist WETH as a target asset the vault can hold
        router.whitelistTargetAsset(vaultAddr, WETH);
        console.log("WETH whitelisted as target asset on vault.");

        // Reset cycle so Phase 2 can open a fresh deposit window
        router.openWithdrawals(vaultAddr);
        router.closeCycle(vaultAddr);

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  PHASE 1 COMPLETE");
        console.log("=======================================");
        console.log("Set in .env:");
        console.log("  FACTORY_ADDR=", address(factory));
        console.log("  ROUTER_ADDR=", address(router));
        console.log("  USER_ROUTER_ADDR=", address(userRouter));
        console.log("  VAULT_ADDR=", vaultAddr);
        console.log("\nNext: phase2_deposit()");
    }

    // ============================================================
    // PHASE 2: Deposit $1 USDC
    // ============================================================
    /// @notice Open deposits, user deposits 1 USDC ($1), start trading cycle.
    function phase2_deposit() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address depositor = vm.addr(pk);
        address vaultAddr = vm.envAddress("ARB_VAULT_ADDR");
        address routerAddr = vm.envAddress("ARB_ROUTER_ADDR");
        address userRouterAddr = vm.envAddress("ARB_USER_ROUTER_ADDR");

        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        UserRouter userRouter = UserRouter(userRouterAddr);

        console.log("=== Phase 2: Deposit $1 USDC ===");
        console.log("Depositor:", depositor);
        console.log("Depositor USDC:", IERC20(USDC).balanceOf(depositor));

        vm.startBroadcast(pk);

        router.openDeposits(vaultAddr);

        IERC20(USDC).approve(userRouterAddr, DEPOSIT_AMOUNT);
        userRouter.depositIntoVault(vaultAddr, DEPOSIT_AMOUNT, depositor);

        router.startTrading(vaultAddr);

        vm.stopBroadcast();

        console.log("Deposited:", DEPOSIT_AMOUNT, "(1 USDC)");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Depositor vault shares:", DiracVault(payable(vaultAddr)).balanceOf(depositor));
        console.log("\nNext: phase3_swapSupplyBorrow()");
    }

    // ============================================================
    // PHASE 3: Swap USDC → WETH (Odos FFI) → Supply → Borrow half
    // ============================================================
    /// @notice Swap vault's USDC to WETH via Odos, supply all WETH to Dolomite, borrow half back in USDC.
    /// @dev Requires --ffi. Set BORROW_AMOUNT env var (default: 500_000 = 0.5 USDC).
    function phase3_swapSupplyBorrow() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("ARB_VAULT_ADDR");
        address factoryAddr = vm.envAddress("ARB_FACTORY_ADDR");
        address routerAddr = vm.envAddress("ARB_ROUTER_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 odosModule = keccak256("swap.odos");

        uint256 swapAmount = IERC20(USDC).balanceOf(vaultAddr);
        // Borrow ~50% of deposited value back. Default 500_000 (0.5 USDC).
        // Adjust based on the actual WETH collateral value you receive.
        uint256 borrowAmount = vm.envOr("ARB_BORROW_AMOUNT", uint256(40_000));

        console.log("=== Phase 3: Swap USDC -> WETH -> Supply -> Borrow ===");
        console.log("Vault USDC (swap in):", swapAmount);
        console.log("Borrow amount (USDC):", borrowAmount);

        // Fetch Odos swap quote via FFI
        (uint256 minAmountOut, bytes memory odosCalldata) = _fetchOdosQuote(
            USDC, WETH, swapAmount, vaultAddr
        );
        console.log("Odos minAmountOut (WETH wei):", minAmountOut);

        vm.startBroadcast(pk);

        // --- Step 1: Swap USDC → WETH ---
        router.executeModule(
            vaultAddr,
            keccak256("swap.odos"),
            abi.encodeCall(OdosModule.swap, (USDC, swapAmount, WETH, minAmountOut, odosCalldata))
        );
        console.log("Vault WETH after swap:", IERC20(WETH).balanceOf(vaultAddr));

        // --- Step 2: Supply all WETH to Dolomite ---
        router.executeModule(
            vaultAddr,
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.supplyCollateral,
                (WETH, type(uint256).max, WETH_MARKET_ID)
            )
        );
        console.log("WETH supplied to Dolomite (market ID 0). Vault WETH:", IERC20(WETH).balanceOf(vaultAddr));

        // --- Step 3: Borrow half the deposited value back in USDC ---
        router.executeModule(
            vaultAddr,
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.borrow,
                (borrowAmount, WETH_MARKET_ID, USDC_MARKET_ID)
            )
        );

        vm.stopBroadcast();

        console.log("Borrowed:", borrowAmount, "USDC from Dolomite.");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault WETH:", IERC20(WETH).balanceOf(vaultAddr));
        console.log("\nNext: phase4_repayAndWithdraw() --ffi");
    }

    // ============================================================
    // PHASE 4: Repay debt → swap WETH back to USDC → withdraw to user
    // ============================================================
    /// @notice Repay borrowed USDC, get WETH collateral back, swap WETH → USDC via Odos,
    ///         open withdrawals, user redeems all shares, close cycle.
    /// @dev Requires --ffi for the Odos WETH → USDC quote.
    ///      Pass REPAY_AMOUNT = 0 (default) to auto-calculate with 7% interest buffer.
    function phase4_repayAndWithdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        address vaultAddr = vm.envAddress("ARB_VAULT_ADDR");
        address factoryAddr = vm.envAddress("ARB_FACTORY_ADDR");
        address routerAddr = vm.envAddress("ARB_ROUTER_ADDR");
        address userRouterAddr = vm.envAddress("ARB_USER_ROUTER_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        UserRouter userRouter = UserRouter(userRouterAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 odosModule = keccak256("swap.odos");

        // 0 = auto-calculate (107% of borrowed to cover accrued interest)
        uint256 repayAmount = vm.envOr("ARB_REPAY_AMOUNT", uint256(0));

        console.log("=== Phase 4: Repay + Swap WETH -> USDC + Withdraw to User ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault WETH:", IERC20(WETH).balanceOf(vaultAddr));
        console.log("User shares:", vault.balanceOf(user));

        // --- 4a. Fetch Odos quote for WETH → USDC before broadcasting ---
        // Use the vault's WETH balance as the estimated collateral amount for the quote.
        // The actual amount returned by Dolomite will be approximately equal
        // (collateral deposited minus negligible protocol fee if any).
        // We fetch the quote pre-broadcast so it doesn't count as a state-modifying call.
        uint256 wethEstimate = vm.envOr("ARB_WETH_ESTIMATE", IERC20(WETH).balanceOf(vaultAddr));
        // If vault holds no WETH now (it's all in Dolomite), pass COLLATERAL_ESTIMATE env var.
        require(wethEstimate > 0, "Set WETH_ESTIMATE env var (WETH amount that will be returned from Dolomite)");

        (uint256 minUSDCOut, bytes memory odosCalldata) = _fetchOdosQuote(
            WETH, USDC, wethEstimate, vaultAddr
        );
        console.log("Odos WETH->USDC minAmountOut:", minUSDCOut);

        vm.startBroadcast(pk);

        // --- 4b. Repay debt → WETH collateral returned to vault ---
        // repayDebt deposits the vault's USDC to Dolomite, repays all debt,
        // closes the borrow position, and calls _withdrawCollateralInternal
        // which sends WETH back to the vault.
        router.executeModule(
            vaultAddr,
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.repayDebt,
                (USDC, repayAmount, WETH_MARKET_ID, USDC_MARKET_ID)
            )
        );
        console.log("Debt repaid. Vault WETH:", IERC20(WETH).balanceOf(vaultAddr));

        // --- 4c. Swap all WETH back to USDC so users can redeem ---
        uint256 wethBalance = IERC20(WETH).balanceOf(vaultAddr);
        router.executeModule(
            vaultAddr,
            keccak256("swap.odos"),
            abi.encodeCall(OdosModule.swap, (WETH, wethBalance, USDC, minUSDCOut, odosCalldata))
        );
        console.log("WETH swapped to USDC. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // --- 4d. Open withdrawals → user redeems all shares → close cycle ---
        router.openWithdrawals(vaultAddr);

        uint256 shares = vault.balanceOf(user);
        vault.approve(userRouterAddr, shares);
        uint256 usdcReceived = userRouter.redeemFromVault(vaultAddr, shares, user);

        router.closeCycle(vaultAddr);

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  ARBITRUM DOLOMITE TEST COMPLETE");
        console.log("=======================================");
        console.log("Shares redeemed:", shares);
        console.log("USDC returned to user:", usdcReceived);
        console.log("User USDC balance:", IERC20(USDC).balanceOf(user));
        console.log("(Net loss = Dolomite borrow interest + swap fees)");
    }

    // ============================================================
    // PHASE 5: Re-deposit + swap + supply + borrow (prep for repayDebtWithCollateral)
    // ============================================================
    function phase5_reopen() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address depositor = vm.addr(pk);
        address vaultAddr = vm.envAddress("ARB_VAULT_ADDR");
        address factoryAddr = vm.envAddress("ARB_FACTORY_ADDR");
        address routerAddr = vm.envAddress("ARB_ROUTER_ADDR");
        address userRouterAddr = vm.envAddress("ARB_USER_ROUTER_ADDR");
        uint256 borrowAmount = vm.envOr("ARB_BORROW_AMOUNT", uint256(40_000));

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        UserRouter userRouter = UserRouter(userRouterAddr);
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 odosModule = keccak256("swap.odos");

        console.log("=== Phase 5: Re-deposit + Supply + Borrow ===");

        vm.startBroadcast(pk);

        // Open deposits, deposit, start trading
        router.openDeposits(vaultAddr);
        IERC20(USDC).approve(userRouterAddr, DEPOSIT_AMOUNT);
        userRouter.depositIntoVault(vaultAddr, DEPOSIT_AMOUNT, depositor);
        router.startTrading(vaultAddr);

        vm.stopBroadcast();

        // Fetch Odos quote (outside broadcast)
        uint256 swapAmount = IERC20(USDC).balanceOf(vaultAddr);
        console.log("Vault USDC:", swapAmount);

        (uint256 minAmountOut, bytes memory odosCalldata) = _fetchOdosQuote(
            USDC, WETH, swapAmount, vaultAddr
        );

        vm.startBroadcast(pk);

        // Swap USDC → WETH
        router.executeModule(
            vaultAddr, keccak256("swap.odos"),
            abi.encodeCall(OdosModule.swap, (USDC, swapAmount, WETH, minAmountOut, odosCalldata))
        );
        uint256 wethBal = IERC20(WETH).balanceOf(vaultAddr);
        console.log("WETH after swap:", wethBal);

        // Supply WETH
        router.executeModule(
            vaultAddr, keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.supplyCollateral, (WETH, type(uint256).max, WETH_MARKET_ID))
        );

        // Borrow USDC
        router.executeModule(
            vaultAddr, keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.borrow, (borrowAmount, WETH_MARKET_ID, USDC_MARKET_ID))
        );

        vm.stopBroadcast();

        console.log("Position open. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Next: phase6_repayWithCollateral() --ffi");
    }

    // ============================================================
    // PHASE 6: repayDebtWithCollateral (swap collateral inside Dolomite)
    // ============================================================
    function phase6_repayWithCollateral() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        address vaultAddr = vm.envAddress("ARB_VAULT_ADDR");
        address factoryAddr = vm.envAddress("ARB_FACTORY_ADDR");
        address routerAddr = vm.envAddress("ARB_ROUTER_ADDR");
        address userRouterAddr = vm.envAddress("ARB_USER_ROUTER_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        UserRouter userRouter = UserRouter(userRouterAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");

        console.log("=== Phase 6: repayDebtWithCollateral ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault WETH:", IERC20(WETH).balanceOf(vaultAddr));

        // The WETH estimate for the swap quote — collateral currently in Dolomite
        uint256 wethEstimate = vm.envOr("ARB_WETH_ESTIMATE", uint256(43000000000000));

        // Fetch Odos quote: WETH → USDC (for the collateral swap)
        (uint256 minUSDCOut, bytes memory odosCalldata) = _fetchOdosQuote(
            WETH, USDC, wethEstimate, vaultAddr
        );
        console.log("Odos WETH->USDC minAmountOut:", minUSDCOut);

        vm.startBroadcast(pk);

        // Call repayDebtWithCollateral — withdraws collateral, swaps via Odos, repays debt
        router.executeModule(
            vaultAddr,
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.repayDebtWithCollateral,
                (WETH, USDC, minUSDCOut, 0, odosCalldata, WETH_MARKET_ID, USDC_MARKET_ID)
            )
        );
        console.log("repayDebtWithCollateral complete!");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault WETH:", IERC20(WETH).balanceOf(vaultAddr));

        // Withdraw remaining USDC to user
        router.openWithdrawals(vaultAddr);
        uint256 shares = vault.balanceOf(user);
        vault.approve(userRouterAddr, shares);
        uint256 usdcReceived = userRouter.redeemFromVault(vaultAddr, shares, user);
        router.closeCycle(vaultAddr);

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  REPAY WITH COLLATERAL TEST COMPLETE");
        console.log("=======================================");
        console.log("Shares redeemed:", shares);
        console.log("USDC returned:", usdcReceived);
        console.log("User USDC:", IERC20(USDC).balanceOf(user));
    }

    // ============================================================
    // HELPER: Balance Check
    // ============================================================
    function checkBalances() external view {
        address vaultAddr = vm.envAddress("ARB_VAULT_ADDR");
        address user = vm.addr(vm.envUint("PRIVATE_KEY"));

        console.log("=== Balance Check ===");
        console.log("User  USDC:", IERC20(USDC).balanceOf(user));
        console.log("User  WETH:", IERC20(WETH).balanceOf(user));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault WETH:", IERC20(WETH).balanceOf(vaultAddr));
        console.log("User shares:", DiracVault(payable(vaultAddr)).balanceOf(user));
    }

    // ============================================================
    // HELPER: Odos Quote (FFI — two-step: quote → assemble)
    // ============================================================

    /// @notice Fetch Odos swap quote using two curl calls via FFI (requires --ffi flag).
    /// @param tokenIn   Input token address
    /// @param tokenOut  Output token address
    /// @param amountIn  Input amount (in token's native decimals)
    /// @param fromAddr  Vault address that will execute the swap (used as userAddr in Odos)
    /// @return minAmountOut  Minimum output with 0.5% slippage applied
    /// @return odosCalldata  Pre-encoded calldata for OdosModule.swap()
    /// @dev Calls odos-quote.sh which handles both API steps internally.
    ///      The shell script outputs only the final assembled JSON (starts with '{'),
    ///      so Forge treats it as raw bytes and does not misinterpret it as hex.
    function _fetchOdosQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address fromAddr
    ) internal returns (uint256 minAmountOut, bytes memory odosCalldata) {
        string[] memory cmd = new string[](6);
        cmd[0] = "bash";
        cmd[1] = "script/mainnet-tests/arbitrum/odos-quote.sh";
        cmd[2] = vm.toString(tokenIn);
        cmd[3] = vm.toString(amountIn);
        cmd[4] = vm.toString(tokenOut);
        cmd[5] = vm.toString(fromAddr);

        console.log("Fetching Odos quote + assembling transaction...");
        bytes memory result = vm.ffi(cmd);
        string memory json = string(result);

        uint256 expectedOut = vm.parseJsonUint(json, ".outputTokens[0].amount");
        odosCalldata = vm.parseJsonBytes(json, ".transaction.data");

        minAmountOut = (expectedOut * 9950) / 10000;

        console.log("  expectedOut:", expectedOut);
        console.log("  minAmountOut:", minAmountOut);
    }
}
