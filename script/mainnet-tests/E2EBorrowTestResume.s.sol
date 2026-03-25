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
import {IKXRouter} from "../../src/interfaces/IKXRouter.sol";

/// @title E2EBorrowTestResume
/// @notice Resume from partially-broadcast E2EBorrowTest (txs 0-15 landed, 16-26 dropped)
/// @dev Run: forge script script/mainnet-tests/E2EBorrowTestResume.s.sol:E2EBorrowTestResume --rpc-url mainnet --broadcast --ffi --with-gas-price 200000
contract E2EBorrowTestResume is Script {
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    uint256 public constant DIBGT_MARKET_ID = 38;
    uint256 public constant USDC_MARKET_ID = 2;

    // Deployed addresses from first broadcast
    DiracVault public constant vault = DiracVault(payable(0xe166477D5Cd2995383D237637A6cC17D37E951EF));
    DolomiteBeraModule public constant dolomiteModule = DolomiteBeraModule(0x1e64BfbA544865eb08646e9b17087805B8506648);
    KodiakModule public constant kodiakModule = KodiakModule(0xCd3F9482b1eb0031a1C33f76f9b2F2B82d3451Ba);

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddr = address(vault);

        console.log("=== E2E Borrow Test RESUME ===");
        console.log("Vault:", vaultAddr);
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        vm.startBroadcast(pk);

        // ========================================
        // STEP 3b: Init Dolomite (was tx 16, dropped)
        // ========================================
        console.log("\n--- Init Dolomite ---");
        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );
        console.log("Dolomite module initialized.");

        // ========================================
        // STEP 4: Swap 40000 USDC → iBGT
        // ========================================
        console.log("\n--- Swap 40000 USDC -> iBGT ---");

        uint256 swapAmount = 40_000;
        (
            IKXRouter.SwapData memory swapData1,
            IKXRouter.FeeData memory feeData1,
            uint256 minOut1
        ) = _fetchKodiakQuote(USDC, IBGT, swapAmount, vaultAddr);

        vault.executeModule(
            keccak256("swap.kodiak"),
            abi.encodeCall(
                KodiakModule.swap,
                (USDC, false, swapAmount, IBGT, false, minOut1, swapData1, feeData1)
            )
        );

        uint256 ibgtBal = IERC20(IBGT).balanceOf(vaultAddr);
        console.log("Vault iBGT:", ibgtBal);
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // ========================================
        // STEP 5: Supply all iBGT to Dolomite
        // ========================================
        console.log("\n--- Supply iBGT to Dolomite ---");
        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.supplyCollateral,
                (IBGT, type(uint256).max, DIBGT_MARKET_ID)
            )
        );
        console.log("Supplied. Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));

        // ========================================
        // STEP 6: Borrow 10000 USDC
        // ========================================
        console.log("\n--- Borrow 10000 USDC ---");
        uint256 borrowAmount = 10_000;
        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.borrow,
                (borrowAmount, DIBGT_MARKET_ID, USDC_MARKET_ID)
            )
        );
        console.log("Borrowed. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // ========================================
        // STEP 7: RepayDebt (0 = auto 101%)
        // ========================================
        console.log("\n--- RepayDebt ---");
        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.repayDebt,
                (USDC, 0, DIBGT_MARKET_ID, USDC_MARKET_ID)
            )
        );
        console.log("Debt repaid.");
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // ========================================
        // STEP 8: Supply again + Borrow again
        // ========================================
        console.log("\n--- Supply again + Borrow again ---");
        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.supplyCollateral,
                (IBGT, type(uint256).max, DIBGT_MARKET_ID)
            )
        );

        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.borrow,
                (borrowAmount, DIBGT_MARKET_ID, USDC_MARKET_ID)
            )
        );
        console.log("Borrowed again. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // ========================================
        // STEP 9: RepayDebtWithCollateral
        // ========================================
        console.log("\n--- RepayDebtWithCollateral ---");
        (
            uint256 expectedUSDCOut,
            uint256 minUSDCOut,
            bytes memory pathDefinition
        ) = _fetchOogaBoogaQuote(IBGT, USDC, ibgtBal);
        console.log("OogaBooga quote - expectedOut:", expectedUSDCOut, "minOut:", minUSDCOut);

        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteBeraModule.repayDebtWithCollateral,
                (IBGT, USDC, minUSDCOut, expectedUSDCOut, pathDefinition, DIBGT_MARKET_ID, USDC_MARKET_ID)
            )
        );

        console.log("Debt repaid with collateral zap.");
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // ========================================
        // STEP 10: Swap remaining iBGT → USDC
        // ========================================
        uint256 remainingIbgt = IERC20(IBGT).balanceOf(vaultAddr);
        if (remainingIbgt > 0) {
            console.log("\n--- Swap remaining iBGT -> USDC ---");
            (
                IKXRouter.SwapData memory swapData2,
                IKXRouter.FeeData memory feeData2,
                uint256 minOut2
            ) = _fetchKodiakQuote(IBGT, USDC, remainingIbgt, vaultAddr);

            vault.executeModule(
            keccak256("swap.kodiak"),
                abi.encodeCall(
                    KodiakModule.swap,
                    (IBGT, false, type(uint256).max, USDC, false, minOut2, swapData2, feeData2)
                )
            );
            console.log("Swapped. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        }

        // ========================================
        // STEP 11: Withdraw
        // ========================================
        console.log("\n--- Withdraw ---");
        vault.openWithdrawals();
        uint256 maxW = vault.maxWithdraw(deployer);
        vault.withdraw(maxW, deployer, deployer);
        console.log("Withdrawn:", maxW);

        vault.closeCycle();
        console.log("Cycle closed.");

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  E2E BORROW TEST RESUME COMPLETE");
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

    // ============ OogaBooga Quote Helper ============

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
        bytes memory r = new bytes(data.length - 4);
        for (uint256 i = 0; i < r.length; i++) {
            r[i] = data[i + 4];
        }
        return r;
    }
}
