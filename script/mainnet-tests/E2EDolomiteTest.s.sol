// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Data} from "../../src/libraries/Data.sol";
import {DiracVaultFactory} from "../../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../../src/vault/DiracVault.sol";
import {DolomiteBeraModule} from "../../src/modules/lending/dolomite/DolomiteBeraModule.sol";
import {DolomiteLendingBase} from "../../src/modules/lending/dolomite/DolomiteLendingBase.sol";
import {KodiakModule} from "../../src/modules/swap/KodiakModule.sol";
import {OrderlyModule} from "../../src/modules/perps/OrderlyModule.sol";
import {IKXRouter} from "../../src/interfaces/IKXRouter.sol";

/// @title E2EDolomiteTest
/// @notice E2E: Deploy → Deposit → Swap USDC→iBGT → Supply Dolomite → Withdraw Dolomite → Swap iBGT→USDC → Withdraw
/// @dev Run: forge script script/E2EDolomiteTest.s.sol:E2EDolomiteTest --rpc-url mainnet --broadcast
contract E2EDolomiteTest is Script {
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    uint256 public constant DIBGT_MARKET_ID = 38;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== E2E Dolomite Test ===");
        console.log("Deployer:", deployer);
        console.log("USDC balance:", IERC20(USDC).balanceOf(deployer));

        // Single broadcast block — vm.ffi is off-chain and works inside broadcast
        vm.startBroadcast(pk);

        // ========================================
        // STEP 1: Deploy Protocol
        // ========================================
        console.log("\n--- Step 1: Deploy Protocol ---");

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
            "Dirac Dolomite Test", "dDOL", USDC, 1_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.VaultFees({ performanceFeeBps: 1000, managementFeeBps: 50, feeRecipient: deployer }),
            0, // rebalanceThresholdBps
            0  // fundingRateThresholdBps
        );
        DiracVault vault = DiracVault(payable(vaultAddr));
        // deployer already has OPERATOR_ROLE (factory auto-grants to deployer)
        console.log("Vault:", vaultAddr);

        vault.openDeposits();

        uint256 depositAmount = 50_000; // 0.05 USDC
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount, deployer);
        console.log("Deposited 0.5 USDC");

        // ========================================
        // STEP 3: Start Trading + Initialize Dolomite
        // ========================================
        console.log("\n--- Step 3: Start Trading + Init Dolomite ---");
        vault.startTrading();

        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );
        console.log("Dolomite module initialized (operators set).");

        // ========================================
        // STEP 4: Swap USDC → iBGT (ffi works inside broadcast)
        // ========================================
        console.log("\n--- Step 4: Swap USDC -> iBGT ---");

        (
            IKXRouter.SwapData memory swapData1,
            IKXRouter.FeeData memory feeData1,
            uint256 minOut1
        ) = _fetchKodiakQuote(USDC, IBGT, depositAmount, vaultAddr);
        console.log("Quote: minAmountOut:", minOut1);

        vault.executeModule(
            keccak256("swap.kodiak"),
            abi.encodeCall(
                KodiakModule.swap,
                (USDC, false, depositAmount, IBGT, false, minOut1, swapData1, feeData1)
            )
        );

        console.log("Swap done. Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));

        // ========================================
        // STEP 5: Supply iBGT to Dolomite (use max to supply entire balance)
        // ========================================
        console.log("\n--- Step 5: Supply iBGT to Dolomite ---");

        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.supplyCollateral,
                (IBGT, type(uint256).max, DIBGT_MARKET_ID)
            )
        );

        console.log("Supplied to Dolomite. Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));

        // ========================================
        // STEP 6: Withdraw iBGT from Dolomite
        // ========================================
        console.log("\n--- Step 6: Withdraw iBGT from Dolomite ---");

        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.withdrawCollateral,
                (0, DIBGT_MARKET_ID) // 0 = withdraw all
            )
        );

        uint256 ibgtAfterWithdraw = IERC20(IBGT).balanceOf(vaultAddr);
        console.log("Withdrawn from Dolomite. Vault iBGT:", ibgtAfterWithdraw);

        // ========================================
        // STEP 7: Swap iBGT → USDC (ffi works inside broadcast)
        // ========================================
        console.log("\n--- Step 7: Swap iBGT -> USDC ---");

        (
            IKXRouter.SwapData memory swapData2,
            IKXRouter.FeeData memory feeData2,
            uint256 minOut2
        ) = _fetchKodiakQuote(IBGT, USDC, ibgtAfterWithdraw, vaultAddr);
        console.log("Quote: minAmountOut:", minOut2);

        // Use type(uint256).max to swap actual on-chain balance (may differ from simulation)
        vault.executeModule(
            keccak256("swap.kodiak"),
            abi.encodeCall(
                KodiakModule.swap,
                (IBGT, false, type(uint256).max, USDC, false, minOut2, swapData2, feeData2)
            )
        );

        console.log("Swap done. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // ========================================
        // STEP 8: Withdraw
        // ========================================
        console.log("\n--- Step 8: Withdraw ---");

        vault.openWithdrawals();
        uint256 sharesBal = vault.balanceOf(deployer);
        uint256 assetsOut = vault.redeem(sharesBal, deployer, deployer);
        console.log("Redeemed all shares, USDC received:", assetsOut);

        vault.closeCycle();
        console.log("Cycle closed.");

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  E2E DOLOMITE TEST COMPLETE");
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
