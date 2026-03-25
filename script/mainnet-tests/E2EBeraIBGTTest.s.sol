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

/// @title E2EBeraIBGTTest
/// @notice Berachain E2E using an existing factory (from DeployDirac):
///         Create Vault -> Deposit $1 USDC -> Swap to iBGT -> Supply to Dolomite
///         (isolation mode, diBGT market 38) -> Borrow USDC -> Repay -> Swap back -> Withdraw
///
/// Requires: FACTORY_ADDR set in .env (from DeployDirac deployment)
///
/// Run phases individually:
///   forge script script/mainnet-tests/E2EBeraIBGTTest.s.sol:E2EBeraIBGTTest \
///     --sig "phase1_createVault()" --rpc-url mainnet --broadcast --with-gas-price 10000000
///
///   forge script ... --sig "phase2_deposit()" --rpc-url mainnet --broadcast --with-gas-price 10000000
///
///   forge script ... --sig "phase3_swapSupplyBorrow()" --rpc-url mainnet --broadcast --ffi --with-gas-price 10000000
///
///   forge script ... --sig "phase4_repayAndWithdraw()" --rpc-url mainnet --broadcast --ffi --with-gas-price 10000000
contract E2EBeraIBGTTest is Script {
    // ============ Berachain Mainnet Addresses ============
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;

    // Dolomite market IDs on Berachain
    uint256 public constant DIBGT_MARKET_ID = 38; // diBGT (isolation mode wrapper)
    uint256 public constant IBGT_MARKET_ID  = 34;
    uint256 public constant USDC_MARKET_ID  = 2;

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

        console.log("=== Phase 1: Create Vault (existing factory) ===");
        console.log("Deployer:", deployer);
        console.log("Factory:", factoryAddr);
        console.log("DolomiteModule type hash set");
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));

        vm.startBroadcast(pk);

        address vaultAddr = factory.createVault(
            "Dirac iBGT Delta-Neutral Test",
            "diBGT-TEST",
            USDC,
            10_000_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.CuratorFeeConfig({ curatorFeeBps: 200, curatorFeeRecipient: deployer })
        );
        DiracVault vault = DiracVault(payable(vaultAddr));
        console.log("Vault:", vaultAddr);

        // Bootstrap: open -> 1 wei deposit -> start trading -> init Dolomite -> whitelist iBGT -> reset
        vault.openDeposits();
        IERC20(USDC).approve(vaultAddr, 1);
        vault.deposit(1, deployer);
        vault.startTrading();

        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );
        console.log("Dolomite module initialized.");

        vault.whitelistTargetAsset(IBGT);
        console.log("iBGT whitelisted as target asset on vault.");

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
    // PHASE 3: Swap USDC -> iBGT -> Supply -> Borrow
    // ============================================================
    function phase3_swapSupplyBorrow() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");

        uint256 swapAmount   = IERC20(USDC).balanceOf(vaultAddr);
        uint256 borrowAmount = vm.envOr("BORROW_AMOUNT", uint256(400_000));

        console.log("=== Phase 3: Swap USDC -> iBGT -> Supply -> Borrow ===");
        console.log("Vault USDC (swap in):", swapAmount);
        console.log("Borrow amount (USDC):", borrowAmount);

        (
            IKXRouter.SwapData memory swapData,
            IKXRouter.FeeData memory feeData,
            uint256 minIBGTOut
        ) = _fetchKodiakQuote(USDC, IBGT, swapAmount, vaultAddr);
        console.log("Kodiak minIBGTOut:", minIBGTOut);

        vm.startBroadcast(pk);

        // Step 1: Swap USDC -> iBGT
        vault.executeModule(
            kodiakModule,
            abi.encodeCall(KodiakModule.swap, (USDC, false, swapAmount, IBGT, false, minIBGTOut, swapData, feeData))
        );
        uint256 ibgtBalance = IERC20(IBGT).balanceOf(vaultAddr);
        console.log("Vault iBGT after swap:", ibgtBalance);

        // Step 2: Supply all iBGT to Dolomite (isolation mode — diBGT market 38)
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.supplyCollateral, (IBGT, type(uint256).max, DIBGT_MARKET_ID))
        );
        console.log("iBGT supplied to Dolomite (diBGT market 38). Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));

        // Step 3: Borrow USDC against iBGT collateral (isolation mode path — 6-param openBorrowPosition)
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.borrow, (borrowAmount, DIBGT_MARKET_ID, USDC_MARKET_ID))
        );

        vm.stopBroadcast();

        console.log("Borrowed:", borrowAmount, "USDC.");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("\nNext: phase4_repayAndWithdraw() --ffi");
    }

    // ============================================================
    // PHASE 4: Repay -> Swap iBGT back -> Withdraw
    // ============================================================
    function phase4_repayAndWithdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");

        uint256 borrowAmount = vm.envOr("BORROW_AMOUNT", uint256(400_000));
        uint256 repayAmount  = vm.envOr("REPAY_AMOUNT",  borrowAmount);

        console.log("=== Phase 4: Repay + Swap iBGT -> USDC + Withdraw ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("Repay amount:", repayAmount);
        console.log("User shares:", vault.balanceOf(user));

        // We need the iBGT estimate for the Kodiak quote after repay returns collateral
        // Use COLLATERAL_ESTIMATE from env, or default to checking the Dolomite position
        uint256 ibgtEstimate = vm.envOr("COLLATERAL_ESTIMATE", uint256(0));
        require(ibgtEstimate > 0, "Set COLLATERAL_ESTIMATE env var (iBGT amount in Dolomite)");

        // Pre-fetch Kodiak quote for iBGT -> USDC swap
        (
            IKXRouter.SwapData memory swapData,
            IKXRouter.FeeData memory feeData,
            uint256 minUSDCOut
        ) = _fetchKodiakQuote(IBGT, USDC, ibgtEstimate, vaultAddr);
        console.log("Kodiak iBGT->USDC minUSDCOut:", minUSDCOut);

        vm.startBroadcast(pk);

        // Step 1: Repay USDC debt -> iBGT collateral returned to vault
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.repayDebt, (USDC, repayAmount, DIBGT_MARKET_ID, USDC_MARKET_ID))
        );
        uint256 ibgtBack = IERC20(IBGT).balanceOf(vaultAddr);
        console.log("Debt repaid. Vault iBGT:", ibgtBack);
        console.log("           Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // Step 2: Swap all iBGT -> USDC
        vault.executeModule(
            kodiakModule,
            abi.encodeCall(KodiakModule.swap, (IBGT, false, ibgtBack, USDC, false, minUSDCOut, swapData, feeData))
        );
        console.log("iBGT swapped to USDC. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // Step 3: Open withdrawals -> user redeems -> close cycle
        vault.openWithdrawals();
        uint256 shares = vault.balanceOf(user);
        uint256 usdcReceived = vault.redeem(shares, user, user);
        vault.closeCycle();

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  BERACHAIN iBGT TEST COMPLETE");
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
        console.log("User  iBGT:", IERC20(IBGT).balanceOf(user));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("User shares:", DiracVault(payable(vaultAddr)).balanceOf(user));
    }

    // ============================================================
    // HELPER: Fund vault with extra USDC (for interest buffer)
    // ============================================================
    function fundVault(uint256 amount) external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        vm.startBroadcast(pk);
        IERC20(USDC).transfer(vaultAddr, amount);
        vm.stopBroadcast();
        console.log("Funded vault with USDC:", amount);
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
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
        console.log("Calldata length:", fullCalldata.length);

        bytes memory encoded = _stripSelector(fullCalldata);

        IKXRouter.InputAmount memory _input;
        IKXRouter.OutputAmount memory _output;

        (_input, _output, swapData, feeData) = abi.decode(
            encoded,
            (IKXRouter.InputAmount, IKXRouter.OutputAmount, IKXRouter.SwapData, IKXRouter.FeeData)
        );

        minAmountOut = _output.minAmountOut;
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
