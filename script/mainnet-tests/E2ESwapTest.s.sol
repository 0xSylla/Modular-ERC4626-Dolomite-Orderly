// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Data} from "../../src/libraries/Data.sol";
import {DiracVaultFactory} from "../../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../../src/vault/DiracVault.sol";
import {DolomiteBeraModule} from "../../src/modules/lending/dolomite/DolomiteBeraModule.sol";
import {KodiakModule} from "../../src/modules/swap/KodiakModule.sol";
import {OrderlyModule} from "../../src/modules/perps/OrderlyModule.sol";
import {IKXRouter} from "../../src/interfaces/IKXRouter.sol";

/// @title E2ESwapTest
/// @notice E2E test: Deploy → Deposit → Swap USDC→iBGT → Swap iBGT→USDC → Withdraw
/// @dev Run: forge script script/E2ESwapTest.s.sol:E2ESwapTest --rpc-url mainnet --broadcast
contract E2ESwapTest is Script {
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== E2E Swap Test ===");
        console.log("Deployer:", deployer);
        console.log("USDC balance:", IERC20(USDC).balanceOf(deployer));

        // ========================================
        // STEP 1: Deploy Protocol
        // ========================================
        console.log("\n--- Step 1: Deploy Protocol ---");

        vm.startBroadcast(pk);

        Data.ProtocolFees memory fees = Data.ProtocolFees({
            protocolFeeBps: 1000,
            daoFeeBps: 300,
            protocolFeeRecipient: deployer,
            daoFeeRecipient: deployer
        });

        DiracVaultFactory factory = new DiracVaultFactory(deployer, deployer, fees);
        DolomiteBeraModule dolomiteModule = new DolomiteBeraModule();
        KodiakModule kodiakModule = new KodiakModule();
        OrderlyModule orderlyModule = new OrderlyModule();

        factory.registerModule(keccak256("lending.dolomite"), address(dolomiteModule));
        factory.registerModule(keccak256("swap.kodiak"), address(kodiakModule));
        factory.registerModule(keccak256("perps.orderly"), address(orderlyModule));
        factory.whitelistDepositToken(USDC);
        string[] memory ibgtPerps = new string[](1);
        ibgtPerps[0] = "BERA";
        factory.whitelistStrategyAsset(
            Data.AssetInfo({token: IBGT, allowedPerpsAssets: ibgtPerps})
        );
        factory.setModuleLendingConfig(keccak256("lending.dolomite"), IBGT, abi.encode(uint256(34)));
        console.log("Factory:", address(factory));

        factory.registerTemplate(keccak256("delta-neutral-v1"));

        // ========================================
        // STEP 2: Create Vault + Deposit
        // ========================================
        console.log("\n--- Step 2: Create Vault + Deposit ---");

        address vaultAddr = factory.createVault(
            "Dirac Swap Test", "dSWAP", USDC, 1_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.VaultFees({ performanceFeeBps: 1000, managementFeeBps: 50, feeRecipient: deployer }),
            0, // rebalanceThresholdBps
            0  // fundingRateThresholdBps
        );
        DiracVault vault = DiracVault(payable(vaultAddr));
        // deployer already has OPERATOR_ROLE (factory auto-grants to deployer)
        console.log("Vault:", vaultAddr);

        vault.openDeposits();

        uint256 depositAmount = 500_000; // 0.5 USDC
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount, deployer);
        console.log("Deposited 0.5 USDC");
        console.log("Vault USDC balance:", IERC20(USDC).balanceOf(vaultAddr));

        // ========================================
        // STEP 3: Start Trading
        // ========================================
        vault.startTrading();
        console.log("\n--- Step 3: Trading Started ---");

        vm.stopBroadcast();

        // ========================================
        // STEP 4: Fetch Kodiak Quote USDC → iBGT
        // ========================================
        console.log("\n--- Step 4: Swap USDC -> iBGT ---");

        (
            IKXRouter.SwapData memory swapData1,
            IKXRouter.FeeData memory feeData1,
            uint256 minOut1
        ) = _fetchKodiakQuote(USDC, IBGT, depositAmount, vaultAddr);

        console.log("Quote received. minAmountOut:", minOut1);

        vm.startBroadcast(pk);

        vault.executeModule(
            keccak256("swap.kodiak"),
            abi.encodeCall(
                KodiakModule.swap,
                (USDC, false, depositAmount, IBGT, false, minOut1, swapData1, feeData1)
            )
        );

        uint256 ibgtBalance = IERC20(IBGT).balanceOf(vaultAddr);
        console.log("Swap complete! Vault iBGT balance:", ibgtBalance);
        console.log("Vault USDC balance:", IERC20(USDC).balanceOf(vaultAddr));

        vm.stopBroadcast();

        // ========================================
        // STEP 5: Fetch Kodiak Quote iBGT → USDC
        // ========================================
        console.log("\n--- Step 5: Swap iBGT -> USDC ---");

        (
            IKXRouter.SwapData memory swapData2,
            IKXRouter.FeeData memory feeData2,
            uint256 minOut2
        ) = _fetchKodiakQuote(IBGT, USDC, ibgtBalance, vaultAddr);

        console.log("Quote received. minAmountOut:", minOut2);

        vm.startBroadcast(pk);

        vault.executeModule(
            keccak256("swap.kodiak"),
            abi.encodeCall(
                KodiakModule.swap,
                (IBGT, false, ibgtBalance, USDC, false, minOut2, swapData2, feeData2)
            )
        );

        console.log("Swap complete! Vault USDC balance:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT balance:", IERC20(IBGT).balanceOf(vaultAddr));

        // ========================================
        // STEP 6: Withdraw
        // ========================================
        console.log("\n--- Step 6: Withdraw ---");

        vault.openWithdrawals();
        uint256 sharesBal = vault.balanceOf(deployer);
        uint256 assetsOut = vault.redeem(sharesBal, deployer, deployer);
        console.log("Redeemed all shares, USDC received:", assetsOut);

        vault.closeCycle();
        console.log("Cycle closed.");

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  E2E SWAP TEST COMPLETE");
        console.log("=======================================");
        console.log("USDC final balance:", IERC20(USDC).balanceOf(deployer));
    }

    // ============ Kodiak Quote Helper ============

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
        // Build curl command to fetch Kodiak quote
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

        // Parse the KXRouter.swap calldata from response
        bytes memory fullCalldata = vm.parseJsonBytes(json, ".methodParameters.calldata");
        console.log("Calldata length:", fullCalldata.length);

        // Strip 4-byte selector, then abi.decode the KXRouter.swap arguments:
        // swap(InputAmount, OutputAmount, SwapData, FeeData)
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
        console.log("  SwapData.data length:", swapData.data.length);
        console.log("  FeeData.feeQuote:", feeData.feeQuote);
        console.log("  minAmountOut:", minAmountOut);
    }

    /// @dev Remove the first 4 bytes (function selector) from calldata
    function _stripSelector(bytes memory data) internal pure returns (bytes memory) {
        require(data.length >= 4, "calldata too short");
        bytes memory result = new bytes(data.length - 4);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[i + 4];
        }
        return result;
    }
}
