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

/// @title E2EDualDolomiteTest
/// @notice E2E test for both iBGT (isolation mode) and WETH (regular mode) on the Dirac vault system.
///         Uses existing factory. Creates 2 vaults: one for iBGT, one for WETH.
///
/// Run phases:
///   forge script script/mainnet-tests/E2EDualDolomiteTest.s.sol:E2EDualDolomiteTest \
///     --sig "phase1_createVaults()" --rpc-url mainnet --broadcast --with-gas-price 10000000
///
///   forge script ... --sig "phase2_deposit()" --rpc-url mainnet --broadcast --with-gas-price 10000000
///
///   forge script ... --sig "phase3_swapSupplyBorrow()" --rpc-url mainnet --broadcast --ffi --with-gas-price 10000000
///
///   forge script ... --sig "phase4_repayAndWithdraw()" --rpc-url mainnet --broadcast --ffi --with-gas-price 10000000
contract E2EDualDolomiteTest is Script {
    // ============ Berachain Mainnet Addresses ============
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    address public constant WETH = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;

    // Dolomite market IDs
    uint256 public constant DIBGT_MARKET_ID = 38; // diBGT (isolation mode wrapper)
    uint256 public constant IBGT_MARKET_ID  = 34;
    uint256 public constant WETH_MARKET_ID  = 0;
    uint256 public constant USDC_MARKET_ID  = 2;

    uint256 public constant DEPOSIT_AMOUNT = 1_000_000; // 1 USDC (6 decimals)

    // ============================================================
    // PHASE 1: Create 2 Vaults (iBGT + WETH) on existing factory
    // ============================================================
    function phase1_createVaults() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        bytes32 dolomiteModule = keccak256("lending.dolomite");

        console.log("=== Phase 1: Create Dual Vaults ===");
        console.log("Deployer:", deployer);
        console.log("Factory:", factoryAddr);
        console.log("DolomiteModule type hash set");
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));

        vm.startBroadcast(pk);

        // Ensure WETH lending config is set (market ID 0)
        factory.setModuleLendingConfig(keccak256("lending.dolomite"), WETH, abi.encode(WETH_MARKET_ID));
        console.log("WETH lending config set (market ID: 0).");

        // --- Create iBGT Vault ---
        address ibgtVault = factory.createVault(
            "Dirac iBGT Dual Test",
            "diBGT-DUAL",
            USDC,
            10_000_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.CuratorFeeConfig({ curatorFeeBps: 200, curatorFeeRecipient: deployer })
        );
        console.log("iBGT Vault:", ibgtVault);

        // Bootstrap iBGT vault
        _bootstrapVault(DiracVault(payable(ibgtVault)), dolomiteModule, IBGT, deployer);
        console.log("iBGT vault bootstrapped.");

        // --- Create WETH Vault ---
        address wethVault = factory.createVault(
            "Dirac WETH Dual Test",
            "dWETH-DUAL",
            USDC,
            10_000_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.CuratorFeeConfig({ curatorFeeBps: 200, curatorFeeRecipient: deployer })
        );
        console.log("WETH Vault:", wethVault);

        // Bootstrap WETH vault
        _bootstrapVault(DiracVault(payable(wethVault)), dolomiteModule, WETH, deployer);
        console.log("WETH vault bootstrapped.");

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  PHASE 1 COMPLETE");
        console.log("=======================================");
        console.log("Set in .env:");
        console.log("  IBGT_VAULT_ADDR=", ibgtVault);
        console.log("  WETH_VAULT_ADDR=", wethVault);
        console.log("\nNext: phase2_deposit()");
    }

    function _bootstrapVault(DiracVault vault, bytes32 dolomiteModule, address targetAsset, address deployer) internal {
        vault.openDeposits();
        IERC20(USDC).approve(address(vault), 1);
        vault.deposit(1, deployer);
        vault.startTrading();

        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );

        vault.whitelistTargetAsset(targetAsset);

        vault.openWithdrawals();
        vault.closeCycle();
    }

    // ============================================================
    // PHASE 2: Deposit $1 USDC to each vault
    // ============================================================
    function phase2_deposit() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address depositor = vm.addr(pk);
        address ibgtVaultAddr = vm.envAddress("IBGT_VAULT_ADDR");
        address wethVaultAddr = vm.envAddress("WETH_VAULT_ADDR");

        DiracVault ibgtVault = DiracVault(payable(ibgtVaultAddr));
        DiracVault wethVault = DiracVault(payable(wethVaultAddr));

        console.log("=== Phase 2: Deposit $1 USDC to each vault ===");
        console.log("Depositor USDC:", IERC20(USDC).balanceOf(depositor));

        vm.startBroadcast(pk);

        // iBGT vault deposit
        ibgtVault.openDeposits();
        IERC20(USDC).approve(ibgtVaultAddr, DEPOSIT_AMOUNT);
        ibgtVault.deposit(DEPOSIT_AMOUNT, depositor);
        ibgtVault.startTrading();
        console.log("iBGT vault: deposited 1 USDC, trading started.");

        // WETH vault deposit
        wethVault.openDeposits();
        IERC20(USDC).approve(wethVaultAddr, DEPOSIT_AMOUNT);
        wethVault.deposit(DEPOSIT_AMOUNT, depositor);
        wethVault.startTrading();
        console.log("WETH vault: deposited 1 USDC, trading started.");

        vm.stopBroadcast();

        console.log("iBGT vault USDC:", IERC20(USDC).balanceOf(ibgtVaultAddr));
        console.log("WETH vault USDC:", IERC20(USDC).balanceOf(wethVaultAddr));
        console.log("\nNext: phase3_swapSupplyBorrow() --ffi");
    }

    // ============================================================
    // PHASE 3: Swap -> Supply -> Borrow (both vaults)
    // ============================================================
    function phase3_swapSupplyBorrow() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address ibgtVaultAddr = vm.envAddress("IBGT_VAULT_ADDR");
        address wethVaultAddr = vm.envAddress("WETH_VAULT_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault ibgtVault = DiracVault(payable(ibgtVaultAddr));
        DiracVault wethVault = DiracVault(payable(wethVaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");

        uint256 borrowAmount = vm.envOr("BORROW_AMOUNT", uint256(400_000)); // 0.4 USDC

        console.log("=== Phase 3: Swap -> Supply -> Borrow ===");

        // --- iBGT vault ---
        uint256 ibgtSwapAmount = IERC20(USDC).balanceOf(ibgtVaultAddr);
        console.log("\n--- iBGT Vault ---");
        console.log("Swap amount:", ibgtSwapAmount);

        (
            IKXRouter.SwapData memory ibgtSwapData,
            IKXRouter.FeeData memory ibgtFeeData,
            uint256 minIBGTOut
        ) = _fetchKodiakQuote(USDC, IBGT, ibgtSwapAmount, ibgtVaultAddr);

        // --- WETH vault ---
        uint256 wethSwapAmount = IERC20(USDC).balanceOf(wethVaultAddr);
        console.log("\n--- WETH Vault ---");
        console.log("Swap amount:", wethSwapAmount);

        (
            IKXRouter.SwapData memory wethSwapData,
            IKXRouter.FeeData memory wethFeeData,
            uint256 minWETHOut
        ) = _fetchKodiakQuote(USDC, WETH, wethSwapAmount, wethVaultAddr);

        vm.startBroadcast(pk);

        // ===== iBGT: Swap -> Supply -> Borrow =====
        ibgtVault.executeModule(
            kodiakModule,
            abi.encodeCall(KodiakModule.swap, (USDC, false, ibgtSwapAmount, IBGT, false, minIBGTOut, ibgtSwapData, ibgtFeeData))
        );
        uint256 ibgtBalance = IERC20(IBGT).balanceOf(ibgtVaultAddr);
        console.log("iBGT vault iBGT after swap:", ibgtBalance);

        ibgtVault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.supplyCollateral, (IBGT, type(uint256).max, DIBGT_MARKET_ID))
        );
        console.log("iBGT supplied to Dolomite (diBGT market 38).");

        ibgtVault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.borrow, (borrowAmount, DIBGT_MARKET_ID, USDC_MARKET_ID))
        );
        console.log("iBGT vault: borrowed", borrowAmount, "USDC.");

        // ===== WETH: Swap -> Supply -> Borrow =====
        wethVault.executeModule(
            kodiakModule,
            abi.encodeCall(KodiakModule.swap, (USDC, false, wethSwapAmount, WETH, false, minWETHOut, wethSwapData, wethFeeData))
        );
        uint256 wethBalance = IERC20(WETH).balanceOf(wethVaultAddr);
        console.log("WETH vault WETH after swap:", wethBalance);

        wethVault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.supplyCollateral, (WETH, type(uint256).max, WETH_MARKET_ID))
        );
        console.log("WETH supplied to Dolomite (market 0).");

        wethVault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.borrow, (borrowAmount, WETH_MARKET_ID, USDC_MARKET_ID))
        );
        console.log("WETH vault: borrowed", borrowAmount, "USDC.");

        vm.stopBroadcast();

        console.log("\niBGT vault USDC:", IERC20(USDC).balanceOf(ibgtVaultAddr));
        console.log("WETH vault USDC:", IERC20(USDC).balanceOf(wethVaultAddr));
        console.log("\nNext: phase4_repayAndWithdraw() --ffi");
    }

    // ============================================================
    // PHASE 4: Repay -> Swap back -> Withdraw (both vaults)
    // ============================================================
    function phase4_repayAndWithdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address ibgtVaultAddr = vm.envAddress("IBGT_VAULT_ADDR");
        address wethVaultAddr = vm.envAddress("WETH_VAULT_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault ibgtVault = DiracVault(payable(ibgtVaultAddr));
        DiracVault wethVault = DiracVault(payable(wethVaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");

        uint256 borrowAmount = vm.envOr("BORROW_AMOUNT", uint256(400_000));
        uint256 repayAmount  = vm.envOr("REPAY_AMOUNT",  borrowAmount);

        // Collateral estimates for swap quotes (needed since collateral is in Dolomite, not vault)
        uint256 ibgtEstimate = vm.envOr("IBGT_COLLATERAL_ESTIMATE", uint256(0));
        uint256 wethEstimate = vm.envOr("WETH_COLLATERAL_ESTIMATE", uint256(0));
        require(ibgtEstimate > 0, "Set IBGT_COLLATERAL_ESTIMATE in env");
        require(wethEstimate > 0, "Set WETH_COLLATERAL_ESTIMATE in env");

        console.log("=== Phase 4: Repay + Swap + Withdraw ===");

        // Fetch swap quotes for collateral -> USDC
        (
            IKXRouter.SwapData memory ibgtSwapData,
            IKXRouter.FeeData memory ibgtFeeData,
            uint256 ibgtMinUSDC
        ) = _fetchKodiakQuote(IBGT, USDC, ibgtEstimate, ibgtVaultAddr);
        console.log("iBGT->USDC minOut:", ibgtMinUSDC);

        (
            IKXRouter.SwapData memory wethSwapData,
            IKXRouter.FeeData memory wethFeeData,
            uint256 wethMinUSDC
        ) = _fetchKodiakQuote(WETH, USDC, wethEstimate, wethVaultAddr);
        console.log("WETH->USDC minOut:", wethMinUSDC);

        vm.startBroadcast(pk);

        // ===== iBGT Vault: Repay -> Swap -> Withdraw =====
        console.log("\n--- iBGT Vault: Repay ---");
        ibgtVault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.repayDebt, (USDC, repayAmount, DIBGT_MARKET_ID, USDC_MARKET_ID))
        );
        uint256 ibgtBack = IERC20(IBGT).balanceOf(ibgtVaultAddr);
        console.log("iBGT returned:", ibgtBack);

        ibgtVault.executeModule(
            kodiakModule,
            abi.encodeCall(KodiakModule.swap, (IBGT, false, ibgtBack, USDC, false, ibgtMinUSDC, ibgtSwapData, ibgtFeeData))
        );
        console.log("iBGT vault USDC after swap:", IERC20(USDC).balanceOf(ibgtVaultAddr));

        ibgtVault.openWithdrawals();
        uint256 ibgtShares = ibgtVault.balanceOf(user);
        uint256 ibgtUSDC = ibgtVault.redeem(ibgtShares, user, user);
        ibgtVault.closeCycle();
        console.log("iBGT vault redeemed:", ibgtUSDC, "USDC");

        // ===== WETH Vault: Repay -> Swap -> Withdraw =====
        console.log("\n--- WETH Vault: Repay ---");
        wethVault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.repayDebt, (USDC, repayAmount, WETH_MARKET_ID, USDC_MARKET_ID))
        );
        uint256 wethBack = IERC20(WETH).balanceOf(wethVaultAddr);
        console.log("WETH returned:", wethBack);

        wethVault.executeModule(
            kodiakModule,
            abi.encodeCall(KodiakModule.swap, (WETH, false, wethBack, USDC, false, wethMinUSDC, wethSwapData, wethFeeData))
        );
        console.log("WETH vault USDC after swap:", IERC20(USDC).balanceOf(wethVaultAddr));

        wethVault.openWithdrawals();
        uint256 wethShares = wethVault.balanceOf(user);
        uint256 wethUSDC = wethVault.redeem(wethShares, user, user);
        wethVault.closeCycle();
        console.log("WETH vault redeemed:", wethUSDC, "USDC");

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  DUAL DOLOMITE TEST COMPLETE");
        console.log("=======================================");
        console.log("User USDC:", IERC20(USDC).balanceOf(user));
    }

    // ============================================================
    // HELPER: Check Balances
    // ============================================================
    function checkBalances() external view {
        address user = vm.addr(vm.envUint("PRIVATE_KEY"));
        address ibgtVaultAddr = vm.envAddress("IBGT_VAULT_ADDR");
        address wethVaultAddr = vm.envAddress("WETH_VAULT_ADDR");

        console.log("=== Balance Check ===");
        console.log("User USDC:", IERC20(USDC).balanceOf(user));
        console.log("User iBGT:", IERC20(IBGT).balanceOf(user));
        console.log("User WETH:", IERC20(WETH).balanceOf(user));
        console.log("");
        console.log("iBGT Vault USDC:", IERC20(USDC).balanceOf(ibgtVaultAddr));
        console.log("iBGT Vault iBGT:", IERC20(IBGT).balanceOf(ibgtVaultAddr));
        console.log("iBGT Vault shares:", DiracVault(payable(ibgtVaultAddr)).balanceOf(user));
        console.log("");
        console.log("WETH Vault USDC:", IERC20(USDC).balanceOf(wethVaultAddr));
        console.log("WETH Vault WETH:", IERC20(WETH).balanceOf(wethVaultAddr));
        console.log("WETH Vault shares:", DiracVault(payable(wethVaultAddr)).balanceOf(user));
    }

    // ============================================================
    // HELPER: Recover funds from both vaults (withdraw all USDC)
    // ============================================================
    function recoverVaults() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        address ibgtVaultAddr = vm.envAddress("IBGT_VAULT_ADDR");
        address wethVaultAddr = vm.envAddress("WETH_VAULT_ADDR");

        DiracVault ibgtVault = DiracVault(payable(ibgtVaultAddr));
        DiracVault wethVault = DiracVault(payable(wethVaultAddr));

        console.log("=== Recovering Funds ===");

        vm.startBroadcast(pk);

        // iBGT vault
        uint256 ibgtShares = ibgtVault.balanceOf(user);
        if (ibgtShares > 0) {
            ibgtVault.openWithdrawals();
            uint256 got = ibgtVault.redeem(ibgtShares, user, user);
            ibgtVault.closeCycle();
            console.log("iBGT vault: redeemed", got, "USDC");
        }

        // WETH vault
        uint256 wethShares = wethVault.balanceOf(user);
        if (wethShares > 0) {
            wethVault.openWithdrawals();
            uint256 got = wethVault.redeem(wethShares, user, user);
            wethVault.closeCycle();
            console.log("WETH vault: redeemed", got, "USDC");
        }

        vm.stopBroadcast();

        console.log("User USDC after recovery:", IERC20(USDC).balanceOf(user));
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
