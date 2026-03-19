// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Data} from "../../src/libraries/Data.sol";
import {DiracVaultFactory} from "../../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../../src/vault/DiracVault.sol";
import {DolomiteLendingBase} from "../../src/modules/lending/dolomite/DolomiteLendingBase.sol";
import {KodiakModule} from "../../src/modules/swap/KodiakModule.sol";
import {IKXRouter} from "../../src/interfaces/IKXRouter.sol";

/// @title E2ESingleVaultDualTest
/// @notice Single vault with 2 positions (iBGT + WETH) on per-market Dolomite accounts.
///         Tests that positions are truly isolated within one vault.
///
/// Phases:
///   phase1_createVault()   - Create vault, whitelist both assets, deposit 2 USDC
///   phase2_supplyBorrow()  - Swap USDC->collateral, supply to Dolomite, borrow USDC (both positions)
///   phase3_repayWithdraw() - Repay debt, withdraw collateral, swap back, redeem
contract E2ESingleVaultDualTest is Script {
    // ============ Berachain Mainnet Addresses ============
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    address public constant WETH = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;

    // Dolomite market IDs
    uint256 public constant DIBGT_MARKET_ID = 38;
    uint256 public constant IBGT_MARKET_ID  = 34;
    uint256 public constant WETH_MARKET_ID  = 0;
    uint256 public constant USDC_MARKET_ID  = 2;

    uint256 public constant DEPOSIT_AMOUNT = 2_000_000; // 2 USDC
    uint256 public constant HALF_USDC      = 1_000_000; // 1 USDC per position
    uint256 public constant BORROW_AMOUNT  = 350_000;   // 0.35 USDC per position

    // ============================================================
    // PHASE 1: Create vault, whitelist both assets, deposit
    // ============================================================
    function phase1_createVault() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));

        console.log("=== Phase 1: Create Single Vault (Dual Position) ===");
        console.log("Deployer:", deployer);
        console.log("Factory:", factoryAddr);
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));

        vm.startBroadcast(pk);

        // Ensure WETH lending config is set
        factory.setModuleLendingConfig(keccak256("lending.dolomite"), WETH, abi.encode(WETH_MARKET_ID));

        // Create vault
        address vaultAddr = factory.createVault(
            "Dirac Dual Position Test",
            "dDUAL",
            USDC,
            10_000_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.CuratorFeeConfig({ curatorFeeBps: 200, curatorFeeRecipient: deployer })
        );
        console.log("Vault:", vaultAddr);

        DiracVault vault = DiracVault(payable(vaultAddr));

        // Bootstrap
        vault.openDeposits();
        IERC20(USDC).approve(vaultAddr, 1);
        vault.deposit(1, deployer);
        vault.startTrading();

        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );

        // Whitelist BOTH target assets
        vault.whitelistTargetAsset(IBGT);
        vault.whitelistTargetAsset(WETH);
        console.log("Both iBGT and WETH whitelisted.");

        vault.openWithdrawals();
        vault.closeCycle();

        // Deposit 2 USDC
        vault.openDeposits();
        IERC20(USDC).approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, deployer);
        vault.startTrading();
        console.log("Deposited 2 USDC, trading started.");

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  PHASE 1 COMPLETE");
        console.log("=======================================");
        console.log("Set in .env: DUAL_VAULT_ADDR=", vaultAddr);
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("\nNext: phase2_supplyBorrow() --ffi");
    }

    // ============================================================
    // PHASE 2: Swap -> Supply -> Borrow (both positions)
    // ============================================================
    function phase2_supplyBorrow() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address vaultAddr = vm.envAddress("DUAL_VAULT_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));
        address kodiakModule   = factory.getModule(keccak256("swap.kodiak"));

        console.log("=== Phase 2: Swap + Supply + Borrow (Both Positions) ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // Fetch Kodiak quotes for both swaps
        (
            IKXRouter.SwapData memory ibgtSwapData,
            IKXRouter.FeeData memory ibgtFeeData,
            uint256 ibgtMinOut
        ) = _fetchKodiakQuote(USDC, IBGT, HALF_USDC, vaultAddr);
        console.log("USDC->iBGT minOut:", ibgtMinOut);

        (
            IKXRouter.SwapData memory wethSwapData,
            IKXRouter.FeeData memory wethFeeData,
            uint256 wethMinOut
        ) = _fetchKodiakQuote(USDC, WETH, HALF_USDC, vaultAddr);
        console.log("USDC->WETH minOut:", wethMinOut);

        vm.startBroadcast(pk);

        // ===== iBGT Position: Swap -> Supply -> Borrow =====
        console.log("\n--- iBGT Position ---");
        vault.executeModule(
            kodiakModule,
            abi.encodeCall(KodiakModule.swap, (USDC, false, HALF_USDC, IBGT, false, ibgtMinOut, ibgtSwapData, ibgtFeeData))
        );
        uint256 ibgtBal = IERC20(IBGT).balanceOf(vaultAddr);
        console.log("iBGT after swap:", ibgtBal);

        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.supplyCollateral, (IBGT, type(uint256).max, DIBGT_MARKET_ID))
        );
        console.log("iBGT supplied to Dolomite (diBGT market 38).");

        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.borrow, (BORROW_AMOUNT, DIBGT_MARKET_ID, USDC_MARKET_ID))
        );
        console.log("iBGT position: borrowed", BORROW_AMOUNT, "USDC.");

        // ===== WETH Position: Swap -> Supply -> Borrow =====
        console.log("\n--- WETH Position ---");
        vault.executeModule(
            kodiakModule,
            abi.encodeCall(KodiakModule.swap, (USDC, false, HALF_USDC, WETH, false, wethMinOut, wethSwapData, wethFeeData))
        );
        uint256 wethBal = IERC20(WETH).balanceOf(vaultAddr);
        console.log("WETH after swap:", wethBal);

        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.supplyCollateral, (WETH, type(uint256).max, WETH_MARKET_ID))
        );
        console.log("WETH supplied to Dolomite (market 0).");

        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.borrow, (BORROW_AMOUNT, WETH_MARKET_ID, USDC_MARKET_ID))
        );
        console.log("WETH position: borrowed", BORROW_AMOUNT, "USDC.");

        vm.stopBroadcast();

        console.log("\nVault USDC after borrows:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("\n=======================================");
        console.log("  PHASE 2 COMPLETE - Both positions open");
        console.log("=======================================");
        console.log("Next: phase3_repayWithdraw() --ffi");
    }

    // ============================================================
    // PHASE 3: Repay -> Withdraw -> Swap back -> Redeem
    // ============================================================
    function phase3_repayWithdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address vaultAddr = vm.envAddress("DUAL_VAULT_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));
        address kodiakModule   = factory.getModule(keccak256("swap.kodiak"));

        // Estimates for swap quotes (collateral amounts returned from Dolomite)
        uint256 ibgtEstimate = vm.envOr("IBGT_COLLATERAL_ESTIMATE", uint256(0));
        uint256 wethEstimate = vm.envOr("WETH_COLLATERAL_ESTIMATE", uint256(0));
        require(ibgtEstimate > 0, "Set IBGT_COLLATERAL_ESTIMATE in env");
        require(wethEstimate > 0, "Set WETH_COLLATERAL_ESTIMATE in env");

        console.log("=== Phase 3: Repay + Withdraw + Swap + Redeem ===");

        // Fetch swap quotes for collateral -> USDC
        (
            IKXRouter.SwapData memory ibgtSwapData,
            IKXRouter.FeeData memory ibgtFeeData,
            uint256 ibgtMinUSDC
        ) = _fetchKodiakQuote(IBGT, USDC, ibgtEstimate, vaultAddr);
        console.log("iBGT->USDC minOut:", ibgtMinUSDC);

        (
            IKXRouter.SwapData memory wethSwapData,
            IKXRouter.FeeData memory wethFeeData,
            uint256 wethMinUSDC
        ) = _fetchKodiakQuote(WETH, USDC, wethEstimate, vaultAddr);
        console.log("WETH->USDC minOut:", wethMinUSDC);

        vm.startBroadcast(pk);

        // ===== iBGT Position: Repay + Withdraw + Swap =====
        console.log("\n--- iBGT Position: Repay ---");
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.repayDebt, (USDC, BORROW_AMOUNT, DIBGT_MARKET_ID, USDC_MARKET_ID))
        );
        uint256 ibgtBack = IERC20(IBGT).balanceOf(vaultAddr);
        console.log("iBGT returned:", ibgtBack);

        vault.executeModule(
            kodiakModule,
            abi.encodeCall(KodiakModule.swap, (IBGT, false, ibgtBack, USDC, false, ibgtMinUSDC, ibgtSwapData, ibgtFeeData))
        );
        console.log("iBGT->USDC swapped. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // ===== WETH Position: Repay + Withdraw + Swap =====
        console.log("\n--- WETH Position: Repay ---");
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.repayDebt, (USDC, BORROW_AMOUNT, WETH_MARKET_ID, USDC_MARKET_ID))
        );
        uint256 wethBack = IERC20(WETH).balanceOf(vaultAddr);
        console.log("WETH returned:", wethBack);

        vault.executeModule(
            kodiakModule,
            abi.encodeCall(KodiakModule.swap, (WETH, false, wethBack, USDC, false, wethMinUSDC, wethSwapData, wethFeeData))
        );
        console.log("WETH->USDC swapped. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // ===== Redeem =====
        vault.openWithdrawals();
        uint256 shares = vault.balanceOf(user);
        uint256 redeemed = vault.redeem(shares, user, user);
        vault.closeCycle();
        console.log("Redeemed:", redeemed, "USDC");

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  SINGLE VAULT DUAL TEST COMPLETE");
        console.log("=======================================");
        console.log("User USDC:", IERC20(USDC).balanceOf(user));
    }

    // ============================================================
    // HELPER: Check Balances
    // ============================================================
    function checkBalances() external view {
        address user = vm.addr(vm.envUint("PRIVATE_KEY"));
        address vaultAddr = vm.envAddress("DUAL_VAULT_ADDR");

        console.log("=== Balance Check ===");
        console.log("User USDC:", IERC20(USDC).balanceOf(user));
        console.log("");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("Vault WETH:", IERC20(WETH).balanceOf(vaultAddr));
        console.log("Vault shares:", DiracVault(payable(vaultAddr)).balanceOf(user));
    }

    // ============================================================
    // HELPER: Recover funds
    // ============================================================
    function recoverVault() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        address vaultAddr = vm.envAddress("DUAL_VAULT_ADDR");

        DiracVault vault = DiracVault(payable(vaultAddr));
        uint256 shares = vault.balanceOf(user);

        console.log("=== Recovering Funds ===");
        vm.startBroadcast(pk);

        if (shares > 0) {
            vault.openWithdrawals();
            uint256 got = vault.redeem(shares, user, user);
            vault.closeCycle();
            console.log("Redeemed:", got, "USDC");
        }

        vm.stopBroadcast();
        console.log("User USDC:", IERC20(USDC).balanceOf(user));
    }

    // ============================================================
    // HELPER: Kodiak Quote (FFI)
    // ============================================================
    function _fetchKodiakQuote(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        address recipient
    ) internal returns (
        IKXRouter.SwapData memory swapData,
        IKXRouter.FeeData memory feeData,
        uint256 minAmountOut
    ) {
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

    function _stripSelector(bytes memory data) internal pure returns (bytes memory) {
        require(data.length >= 4, "calldata too short");
        bytes memory result = new bytes(data.length - 4);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[i + 4];
        }
        return result;
    }
}
