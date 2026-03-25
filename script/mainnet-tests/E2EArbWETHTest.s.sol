// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Data} from "../../src/libraries/Data.sol";
import {DiracVaultFactory} from "../../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../../src/vault/DiracVault.sol";
import {DolomiteLendingBase} from "../../src/modules/lending/dolomite/DolomiteLendingBase.sol";
import {OdosModule} from "../../src/modules/swap/OdosModule.sol";

/// @title E2EArbWETHTest
/// @notice Arbitrum E2E using an existing factory (from DeployDirac):
///         Create Vault -> Deposit USDC -> Swap to WETH -> Supply to Dolomite
///         (regular market, WETH market 0) -> Borrow USDC -> Repay -> Swap back -> Withdraw
///
/// Requires: FACTORY_ADDR set in .env (from DeployDirac deployment on Arbitrum)
///
/// Run phases individually:
///   forge script script/mainnet-tests/E2EArbWETHTest.s.sol:E2EArbWETHTest \
///     --sig "phase1_createVault()" --rpc-url arbitrum --broadcast --ffi
///
///   forge script ... --sig "phase2_deposit()" --rpc-url arbitrum --broadcast --ffi
///
///   forge script ... --sig "phase3_swapSupplyBorrow()" --rpc-url arbitrum --broadcast --ffi
///
///   forge script ... --sig "phase4_repayAndWithdraw()" --rpc-url arbitrum --broadcast --ffi
contract E2EArbWETHTest is Script {
    // ============ Arbitrum Mainnet Addresses ============
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    // Dolomite market IDs on Arbitrum
    uint256 public constant WETH_MARKET_ID = 0;
    uint256 public constant USDC_MARKET_ID = 17; // Native USDC on Arbitrum Dolomite

    uint256 public constant DEPOSIT_AMOUNT = 1_000_000; // 1 USDC (6 decimals)

    // ============================================================
    // PHASE 1: Create Vault (uses existing factory from DeployDirac)
    // ============================================================
    function phase1_createVault() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        bytes32 dolomiteModule = keccak256("lending.dolomite");

        console.log("=== Phase 1: Create Vault (Arbitrum WETH) ===");
        console.log("Deployer:", deployer);
        console.log("Factory:", factoryAddr);
        console.log("DolomiteModule type hash set");
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));

        vm.startBroadcast(pk);

        address vaultAddr = factory.createVault(
            "Dirac WETH Delta-Neutral Test",
            "dWETH-TEST",
            USDC,
            10_000_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.CuratorFeeConfig({ curatorFeeBps: 200, curatorFeeRecipient: deployer })
        );
        DiracVault vault = DiracVault(payable(vaultAddr));
        console.log("Vault:", vaultAddr);

        // Bootstrap: open -> 1 wei deposit -> start trading -> init Dolomite -> whitelist WETH -> reset
        vault.openDeposits();
        IERC20(USDC).approve(vaultAddr, 1);
        vault.deposit(1, deployer);
        vault.startTrading();

        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );
        console.log("Dolomite module initialized.");

        vault.whitelistTargetAsset(WETH);
        console.log("WETH whitelisted as target asset on vault.");

        // Reset cycle
        vault.openWithdrawals();
        vault.closeCycle();

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  PHASE 1 COMPLETE");
        console.log("=======================================");
        console.log("Set in .env:");
        console.log("  VAULT_ADDR=", vaultAddr);
        console.log("\nNext: phase2_deposit()");
    }

    // ============================================================
    // PHASE 2: Deposit $1 USDC
    // ============================================================
    function phase2_deposit() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address depositor = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        DiracVault vault = DiracVault(payable(vaultAddr));

        console.log("=== Phase 2: Deposit $1 USDC ===");
        console.log("Depositor:", depositor);
        console.log("USDC balance:", IERC20(USDC).balanceOf(depositor));

        vm.startBroadcast(pk);

        vault.openDeposits();
        IERC20(USDC).approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, depositor);
        vault.startTrading();

        vm.stopBroadcast();

        console.log("Deposited:", DEPOSIT_AMOUNT, "(1 USDC)");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("User shares:", vault.balanceOf(depositor));
        console.log("\nNext: phase3_swapSupplyBorrow() --ffi");
    }

    // ============================================================
    // PHASE 3: Swap USDC -> WETH -> Supply -> Borrow
    // ============================================================
    function phase3_swapSupplyBorrow() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 odosModule = keccak256("swap.odos");

        uint256 swapAmount   = IERC20(USDC).balanceOf(vaultAddr);
        uint256 borrowAmount = vm.envOr("BORROW_AMOUNT", uint256(350_000)); // 0.35 USDC

        console.log("=== Phase 3: Swap USDC -> WETH -> Supply -> Borrow ===");
        console.log("Vault USDC (swap in):", swapAmount);
        console.log("Borrow amount (USDC):", borrowAmount);

        (bytes memory odosCalldata, uint256 minWETHOut) = _fetchOdosQuote(
            USDC, WETH, swapAmount, vaultAddr
        );
        console.log("Odos minWETHOut:", minWETHOut);

        vm.startBroadcast(pk);

        // Step 1: Swap USDC -> WETH via Odos
        vault.executeModule(
            odosModule,
            abi.encodeCall(OdosModule.swap, (USDC, swapAmount, WETH, minWETHOut, odosCalldata))
        );
        uint256 wethBalance = IERC20(WETH).balanceOf(vaultAddr);
        console.log("Vault WETH after swap:", wethBalance);

        // Step 2: Supply all WETH to Dolomite (regular market — WETH market 0)
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.supplyCollateral, (WETH, type(uint256).max, WETH_MARKET_ID))
        );
        console.log("WETH supplied to Dolomite (market 0). Vault WETH:", IERC20(WETH).balanceOf(vaultAddr));

        // Step 3: Borrow USDC against WETH collateral (regular market path)
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.borrow, (borrowAmount, WETH_MARKET_ID, USDC_MARKET_ID))
        );

        vm.stopBroadcast();

        console.log("Borrowed:", borrowAmount, "USDC.");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault WETH:", IERC20(WETH).balanceOf(vaultAddr));
        console.log("\nNext: phase4_repayAndWithdraw() --ffi");
    }

    // ============================================================
    // PHASE 4: Repay -> Swap WETH back -> Withdraw
    // ============================================================
    function phase4_repayAndWithdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 odosModule = keccak256("swap.odos");

        console.log("=== Phase 4: Repay + Swap WETH -> USDC + Withdraw ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault WETH:", IERC20(WETH).balanceOf(vaultAddr));
        console.log("User shares:", vault.balanceOf(user));

        // Estimate WETH collateral for the Odos quote
        uint256 wethEstimate = vm.envOr("COLLATERAL_ESTIMATE", uint256(0));
        require(wethEstimate > 0, "Set COLLATERAL_ESTIMATE env var (WETH amount in Dolomite)");

        // Pre-fetch Odos quote for WETH -> USDC swap
        (bytes memory odosCalldata, uint256 minUSDCOut) = _fetchOdosQuote(
            WETH, USDC, wethEstimate, vaultAddr
        );
        console.log("Odos WETH->USDC minUSDCOut:", minUSDCOut);

        vm.startBroadcast(pk);

        // Step 1: Repay USDC debt -> WETH collateral returned to vault
        // Pass exact vault USDC balance (not 0) to avoid 7% buffer exceeding balance
        uint256 repayAmount = IERC20(USDC).balanceOf(vaultAddr);
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.repayDebt, (USDC, repayAmount, WETH_MARKET_ID, USDC_MARKET_ID))
        );
        uint256 wethBack = IERC20(WETH).balanceOf(vaultAddr);
        console.log("Debt repaid. Vault WETH:", wethBack);
        console.log("           Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // Step 2: Swap all WETH -> USDC (use 95% of quote minOut for slippage buffer)
        vault.executeModule(
            odosModule,
            abi.encodeCall(OdosModule.swap, (WETH, wethBack, USDC, minUSDCOut * 95 / 100, odosCalldata))
        );
        console.log("WETH swapped to USDC. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // Step 3: Open withdrawals -> user redeems -> close cycle
        vault.openWithdrawals();
        uint256 shares = vault.balanceOf(user);
        uint256 usdcReceived = vault.redeem(shares, user, user);
        vault.closeCycle();

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  ARBITRUM WETH TEST COMPLETE");
        console.log("=======================================");
        console.log("Shares redeemed:", shares);
        console.log("USDC returned to user:", usdcReceived);
        console.log("User USDC balance:", IERC20(USDC).balanceOf(user));
        console.log("(Net loss = Dolomite borrow interest + swap fees)");
    }

    // ============================================================
    // HELPER: Balance Check
    // ============================================================
    function checkBalances() external view {
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address user = vm.addr(vm.envUint("PRIVATE_KEY"));

        console.log("=== Balance Check ===");
        console.log("User  USDC:", IERC20(USDC).balanceOf(user));
        console.log("User  WETH:", IERC20(WETH).balanceOf(user));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault WETH:", IERC20(WETH).balanceOf(vaultAddr));
        console.log("User shares:", DiracVault(payable(vaultAddr)).balanceOf(user));
    }

    // ============================================================
    // HELPER: Odos Quote (FFI) — 2-step: quote → assemble
    // ============================================================
    function _fetchOdosQuote(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        address userAddr
    ) internal returns (bytes memory odosCalldata, uint256 minAmountOut) {
        // Step 1: Get quote
        string memory quoteCmd = string.concat(
            "curl -s -X POST 'https://api.odos.xyz/sor/quote/v2' ",
            "-H 'Content-Type: application/json' ",
            "-d '{",
            "\"chainId\": 42161,",
            "\"inputTokens\": [{\"tokenAddress\": \"", vm.toString(tokenIn), "\", \"amount\": \"", vm.toString(amount), "\"}],",
            "\"outputTokens\": [{\"tokenAddress\": \"", vm.toString(tokenOut), "\", \"proportion\": 1}],",
            "\"slippageLimitPercent\": 5,",
            "\"userAddr\": \"", vm.toString(userAddr), "\",",
            "\"referralCode\": 0,",
            "\"disableRFQs\": true,",
            "\"compact\": true",
            "}'"
        );

        string[] memory cmd = new string[](3);
        cmd[0] = "bash"; cmd[1] = "-c"; cmd[2] = quoteCmd;

        console.log("Fetching Odos quote...");
        bytes memory quoteResult = vm.ffi(cmd);
        string memory quoteJson = string(quoteResult);

        string memory pathId = vm.parseJsonString(quoteJson, ".pathId");
        minAmountOut = vm.parseJsonUint(quoteJson, ".outAmounts[0]");
        console.log("PathId obtained, minAmountOut:", minAmountOut);

        // Step 2: Assemble transaction
        string memory assembleCmd = string.concat(
            "curl -s -X POST 'https://api.odos.xyz/sor/assemble' ",
            "-H 'Content-Type: application/json' ",
            "-d '{",
            "\"userAddr\": \"", vm.toString(userAddr), "\",",
            "\"pathId\": \"", pathId, "\",",
            "\"simulate\": false",
            "}'"
        );

        cmd[2] = assembleCmd;
        console.log("Assembling Odos transaction...");
        bytes memory assembleResult = vm.ffi(cmd);
        string memory assembleJson = string(assembleResult);

        odosCalldata = vm.parseJsonBytes(assembleJson, ".transaction.data");
        console.log("Odos calldata length:", odosCalldata.length);
    }
}
