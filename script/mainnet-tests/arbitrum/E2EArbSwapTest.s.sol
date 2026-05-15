// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Data} from "../../../src/libraries/Data.sol";
import {DiracVaultFactory} from "../../../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../../../src/vault/DiracVault.sol";
import {OdosModule} from "../../../src/modules/swap/OdosModule.sol";

/// @title E2EArbSwapTest
/// @notice Arbitrum E2E swap test: Deploy → Deposit USDC → Swap USDC→wstETH → Swap wstETH→USDC → Withdraw
///
/// @dev Run phases:
///   Phase 1 (deploy + deposit + swap both ways + withdraw):
///     forge script script/mainnet-tests/arbitrum/E2EArbSwapTest.s.sol:E2EArbSwapTest \
///       --sig "phase1_deployAndSwap()" --rpc-url arbitrum --broadcast --ffi
///
///   Or use an existing vault:
///     forge script script/mainnet-tests/arbitrum/E2EArbSwapTest.s.sol:E2EArbSwapTest \
///       --sig "phase2_swapExistingVault()" --rpc-url arbitrum --broadcast --ffi
///
/// @dev Env vars:
///   PRIVATE_KEY           — deployer wallet
///   ARB_FACTORY_ADDR      — (phase2 only) existing factory
///   VAULT_ADDR            — (phase2 only) existing vault in TRADING state
///   SWAP_AMOUNT           — (optional) USDC amount to swap, default 300000 (0.30 USDC)
contract E2EArbSwapTest is Script {
    // ============ Arbitrum Mainnet Addresses ============
    address constant USDC   = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant WETH   = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WBTC   = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    bytes32 constant SWAP_ODOS = keccak256("swap.odos");

    // ============================================================
    // PHASE 1: Full deploy + swap test + withdraw
    // ============================================================
    function phase1_deployAndSwap() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint256 swapAmount = vm.envOr("SWAP_AMOUNT", uint256(300_000)); // 0.30 USDC default

        console.log("=== Arbitrum Swap Test ===");
        console.log("Deployer:", deployer);
        console.log("Swap amount:", swapAmount);

        vm.startBroadcast(pk);

        // --- Deploy ---
        DiracVaultFactory factory = new DiracVaultFactory(deployer, deployer);
        console.log("Factory:", address(factory));

        OdosModule odosModule = new OdosModule();
        factory.registerModule(SWAP_ODOS, address(odosModule));
        factory.registerTemplate(keccak256("delta-neutral-v1"));
        factory.whitelistDepositToken(USDC);

        string[] memory perps = new string[](1);
        perps[0] = "ETH";
        factory.whitelistStrategyAsset(Data.AssetInfo({token: WSTETH, allowedPerpsAssets: perps}));

        // --- Create vault ---
        address vaultAddr = factory.createVault(
            "Swap Test",
            "SWT",
            USDC,
            10_000_000e6, // 10M max
            keccak256("delta-neutral-v1"),
            Data.VaultFees({performanceFeeBps: 0, managementFeeBps: 0, feeRecipient: deployer}),
            0, 0
        );
        DiracVault vault = DiracVault(payable(vaultAddr));
        console.log("Vault:", vaultAddr);

        vault.whitelistTargetAsset(WSTETH);

        // --- Deposit ---
        vault.openDeposits();
        IERC20(USDC).approve(vaultAddr, swapAmount * 2); // deposit more than swap amount
        vault.deposit(swapAmount * 2, deployer);
        vault.startTrading();

        uint256 usdcBefore = IERC20(USDC).balanceOf(vaultAddr);
        console.log("Vault USDC before swap:", usdcBefore);

        vm.stopBroadcast();

        // --- Swap 1: USDC → wstETH ---
        console.log("");
        console.log("=== SWAP 1: USDC -> wstETH ===");
        bytes memory odosData1 = _getOdosSwapData(USDC, swapAmount, WSTETH, vaultAddr);

        vm.startBroadcast(pk);
        bytes memory swapCalldata1 = abi.encodeCall(
            OdosModule.swap,
            (USDC, swapAmount, WSTETH, 0, odosData1)
        );
        vault.executeModule(SWAP_ODOS, swapCalldata1);
        vm.stopBroadcast();

        uint256 wstethAfterSwap1 = IERC20(WSTETH).balanceOf(vaultAddr);
        uint256 usdcAfterSwap1 = IERC20(USDC).balanceOf(vaultAddr);
        console.log("[OK] Swap 1 complete");
        console.log("  wstETH received:", wstethAfterSwap1);
        console.log("  USDC remaining:", usdcAfterSwap1);

        // --- Swap 2: wstETH → USDC ---
        console.log("");
        console.log("=== SWAP 2: wstETH -> USDC ===");
        bytes memory odosData2 = _getOdosSwapData(WSTETH, wstethAfterSwap1, USDC, vaultAddr);

        vm.startBroadcast(pk);
        bytes memory swapCalldata2 = abi.encodeCall(
            OdosModule.swap,
            (WSTETH, wstethAfterSwap1, USDC, 0, odosData2)
        );
        vault.executeModule(SWAP_ODOS, swapCalldata2);
        vm.stopBroadcast();

        uint256 wstethAfterSwap2 = IERC20(WSTETH).balanceOf(vaultAddr);
        uint256 usdcAfterSwap2 = IERC20(USDC).balanceOf(vaultAddr);
        console.log("[OK] Swap 2 complete");
        console.log("  wstETH remaining:", wstethAfterSwap2);
        console.log("  USDC recovered:", usdcAfterSwap2);

        // --- Withdraw ---
        console.log("");
        console.log("=== WITHDRAW ===");
        vm.startBroadcast(pk);
        vault.openWithdrawals();
        uint256 shares = vault.balanceOf(deployer);
        vault.redeem(shares, deployer, deployer);
        vm.stopBroadcast();

        uint256 finalUsdc = IERC20(USDC).balanceOf(deployer);
        console.log("[OK] Withdrawn");
        console.log("  Deployer USDC:", finalUsdc);

        // --- Summary ---
        console.log("");
        console.log("=======================================");
        console.log("  SWAP TEST COMPLETE");
        console.log("=======================================");
        console.log("  Deposited USDC:", swapAmount * 2);
        console.log("  Swapped to wstETH:", wstethAfterSwap1);
        console.log("  Swapped back USDC:", usdcAfterSwap2);
        uint256 slippage = (swapAmount * 2) - usdcAfterSwap2;
        console.log("  Round-trip cost:", slippage, "USDC (swap fees)");
        console.log("=======================================");
    }

    // ============================================================
    // PHASE 2: Swap on existing vault (must be in TRADING state)
    // ============================================================
    function phase2_swapExistingVault() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        uint256 swapAmount = vm.envOr("SWAP_AMOUNT", uint256(300_000));

        DiracVault vault = DiracVault(payable(vaultAddr));
        uint256 usdcBefore = IERC20(USDC).balanceOf(vaultAddr);
        console.log("=== Swap on existing vault ===");
        console.log("Vault:", vaultAddr);
        console.log("Vault USDC:", usdcBefore);

        // --- Swap 1: USDC → wstETH ---
        console.log("=== SWAP 1: USDC -> wstETH ===");
        bytes memory odosData1 = _getOdosSwapData(USDC, swapAmount, WSTETH, vaultAddr);

        vm.startBroadcast(pk);
        vault.executeModule(SWAP_ODOS, abi.encodeCall(
            OdosModule.swap, (USDC, swapAmount, WSTETH, 0, odosData1)
        ));
        vm.stopBroadcast();

        uint256 wstethBal = IERC20(WSTETH).balanceOf(vaultAddr);
        console.log("[OK] wstETH received:", wstethBal);

        // --- Swap 2: wstETH → USDC ---
        console.log("=== SWAP 2: wstETH -> USDC ===");
        bytes memory odosData2 = _getOdosSwapData(WSTETH, wstethBal, USDC, vaultAddr);

        vm.startBroadcast(pk);
        vault.executeModule(SWAP_ODOS, abi.encodeCall(
            OdosModule.swap, (WSTETH, wstethBal, USDC, 0, odosData2)
        ));
        vm.stopBroadcast();

        console.log("[OK] USDC recovered:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("[OK] wstETH remaining:", IERC20(WSTETH).balanceOf(vaultAddr));
    }

    // ============================================================
    // Internal: Odos quote + assemble via vm.ffi
    // ============================================================
    /// @dev Calls script/mainnet-tests/arbitrum/odos-quote.sh via ffi
    ///      Returns the assembled transaction data (bytes) for the Odos router
    function _getOdosSwapData(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        address fromAddr
    ) internal returns (bytes memory) {
        string[] memory cmd = new string[](6);
        cmd[0] = "bash";
        cmd[1] = "script/mainnet-tests/arbitrum/odos-quote.sh";
        cmd[2] = vm.toString(tokenIn);
        cmd[3] = vm.toString(amountIn);
        cmd[4] = vm.toString(tokenOut);
        cmd[5] = vm.toString(fromAddr);

        console.log("  Fetching Odos quote...");
        bytes memory result = vm.ffi(cmd);

        // The shell script returns JSON. Parse out the transaction.data field.
        string memory json = string(result);
        bytes memory txData = vm.parseJsonBytes(json, ".transaction.data");
        console.log("  Odos data length:", txData.length);

        return txData;
    }
}
