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

/// @title E2EBorrowTest
/// @notice E2E: Deploy → Deposit → Swap → Supply → Borrow → RepayDebt → Borrow → RepayDebtWithCollateral → Withdraw
/// @dev Run: forge script script/mainnet-tests/E2EBorrowTest.s.sol:E2EBorrowTest --rpc-url mainnet --broadcast --ffi
contract E2EBorrowTest is Script {
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    uint256 public constant DIBGT_MARKET_ID = 38;
    uint256 public constant USDC_MARKET_ID = 2;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== E2E Borrow Test ===");
        console.log("Deployer:", deployer);
        console.log("USDC balance:", IERC20(USDC).balanceOf(deployer));

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
            "Dirac Borrow Test", "dBRW", USDC, 1_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.CuratorFeeConfig({curatorFeeBps: 200, curatorFeeRecipient: deployer})
        );
        DiracVault vault = DiracVault(payable(vaultAddr));
        // deployer already has OPERATOR_ROLE (factory auto-grants to deployer)
        console.log("Vault:", vaultAddr);

        vault.openDeposits();

        uint256 depositAmount = 50_000; // 0.05 USDC
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount, deployer);
        console.log("Deposited:", depositAmount);

        // ========================================
        // STEP 3: Start Trading + Init Dolomite
        // ========================================
        console.log("\n--- Step 3: Start Trading + Init Dolomite ---");
        vault.startTrading();

        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );
        console.log("Dolomite module initialized.");

        // ========================================
        // STEP 4: Transfer iBGT from deployer to vault (bypasses swap, uses existing balance)
        // ========================================
        console.log("\n--- Step 4: Transfer iBGT from deployer to vault ---");

        uint256 ibgtTransfer = 200_000_000_000_000_000; // 0.2 iBGT
        IERC20(IBGT).transfer(vaultAddr, ibgtTransfer);

        uint256 ibgtBal = IERC20(IBGT).balanceOf(vaultAddr);
        console.log("Vault iBGT:", ibgtBal);
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // ========================================
        // STEP 5: Supply all iBGT to Dolomite
        // ========================================
        console.log("\n--- Step 5: Supply iBGT to Dolomite ---");

        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.supplyCollateral,
                (IBGT, type(uint256).max, DIBGT_MARKET_ID)
            )
        );
        console.log("Supplied. Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));

        // ========================================
        // STEP 6: Borrow USDC (small conservative amount)
        // ========================================
        console.log("\n--- Step 6: Borrow 10000 USDC ---");

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
        // STEP 7: RepayDebt (0 = auto 101% to cover interest)
        // ========================================
        console.log("\n--- Step 7: RepayDebt ---");

        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.repayDebt,
                (USDC, 0, DIBGT_MARKET_ID, USDC_MARKET_ID)
            )
        );

        console.log("Debt repaid. Collateral returned.");
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // ========================================
        // STEP 8: Supply iBGT again + Borrow again
        // ========================================
        console.log("\n--- Step 8: Supply again + Borrow again ---");

        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.supplyCollateral,
                (IBGT, type(uint256).max, DIBGT_MARKET_ID)
            )
        );
        console.log("Re-supplied. Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));

        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteLendingBase.borrow,
                (borrowAmount, DIBGT_MARKET_ID, USDC_MARKET_ID)
            )
        );
        console.log("Borrowed again. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // ========================================
        // STEP 9: RepayDebtWithCollateral (zap iBGT → USDC inside Dolomite)
        // ========================================
        console.log("\n--- Step 9: RepayDebtWithCollateral ---");

        // The collateral amount in the borrow account equals what we supplied
        // Fetch OogaBooga quote for iBGT → USDC swap path
        uint256 collateralInDolomite = IERC20(IBGT).balanceOf(vaultAddr) == 0 ? ibgtBal : IERC20(IBGT).balanceOf(vaultAddr);
        // All iBGT was supplied, so use the original ibgtBal as estimate for the quote
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
        // STEP 10: Swap remaining iBGT → USDC (if any)
        // ========================================
        uint256 remainingIbgt = IERC20(IBGT).balanceOf(vaultAddr);
        if (remainingIbgt > 0) {
            console.log("\n--- Step 10: Swap remaining iBGT -> USDC ---");

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
        console.log("\n--- Step 11: Withdraw ---");

        vault.openWithdrawals();
        uint256 sharesBal = vault.balanceOf(deployer);
        uint256 assetsOut = vault.redeem(sharesBal, deployer, deployer);
        console.log("Redeemed, USDC received:", assetsOut);

        vault.closeCycle();
        console.log("Cycle closed.");

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  E2E BORROW TEST COMPLETE");
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
        // OogaBooga aggregator API on Berachain mainnet (requires API key)
        string memory apiKey = vm.envString("OOGABOOGA_API_KEY");
        string memory curlCmd = string.concat(
            "curl -s -H 'Authorization: Bearer ", apiKey, "' "
            "'https://mainnet.api.oogabooga.io/v1/swap"
            "?tokenIn=", vm.toString(tokenIn),
            "&tokenOut=", vm.toString(tokenOut),
            "&amount=", vm.toString(amount),
            "&to=", vm.toString(address(0x0CE205f7bCBa70E4c03f826918c8c21073386ED3)), // DOLOMITE_OOGA_ADAPTER
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
        minOut = (expectedOut * 95) / 100; // 5% slippage
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
