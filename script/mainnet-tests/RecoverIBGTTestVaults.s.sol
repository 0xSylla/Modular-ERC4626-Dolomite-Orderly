// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DiracVaultFactory} from "../../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../../src/vault/DiracVault.sol";
import {DolomiteLendingBase} from "../../src/modules/lending/dolomite/DolomiteLendingBase.sol";
import {KodiakModule} from "../../src/modules/swap/KodiakModule.sol";
import {IKXRouter} from "../../src/interfaces/IKXRouter.sol";

/// @title RecoverIBGTTestVaults
/// @notice Recover funds from abandoned iBGT test vaults that have active Dolomite positions.
///
///   forge script script/mainnet-tests/RecoverIBGTTestVaults.s.sol:RecoverIBGTTestVaults \
///     --sig "recover(address)" <VAULT_ADDR> --rpc-url mainnet --broadcast --ffi --with-gas-price 10000000
contract RecoverIBGTTestVaults is Script {
    address constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    uint256 constant DIBGT_MARKET_ID = 38;
    uint256 constant USDC_MARKET_ID  = 2;

    function recover(address vaultAddr) external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");

        uint256 vaultUSDC = IERC20(USDC).balanceOf(vaultAddr);
        uint256 vaultIBGT = IERC20(IBGT).balanceOf(vaultAddr);
        uint256 userShares = vault.balanceOf(user);

        console.log("=== Recover Vault ===");
        console.log("Vault:", vaultAddr);
        console.log("Vault USDC:", vaultUSDC);
        console.log("Vault iBGT:", vaultIBGT);
        console.log("User shares:", userShares);

        vm.startBroadcast(pk);

        // Step 1: Repay Dolomite debt (pass 0 for auto-detect with 7% buffer)
        if (vaultUSDC > 0) {
            vault.executeModule(
                dolomiteModule,
                abi.encodeCall(DolomiteLendingBase.repayDebt, (USDC, 0, DIBGT_MARKET_ID, USDC_MARKET_ID))
            );
            console.log("Debt repaid.");
            console.log("  Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
            console.log("  Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        }

        // Step 2: Swap iBGT -> USDC if vault has iBGT
        uint256 ibgtBalance = IERC20(IBGT).balanceOf(vaultAddr);
        if (ibgtBalance > 0) {
            (
                IKXRouter.SwapData memory swapData,
                IKXRouter.FeeData memory feeData,
                uint256 minOut
            ) = _fetchKodiakQuote(IBGT, USDC, ibgtBalance, vaultAddr);

            vault.executeModule(
                kodiakModule,
                abi.encodeCall(KodiakModule.swap, (IBGT, false, ibgtBalance, USDC, false, minOut, swapData, feeData))
            );
            console.log("iBGT swapped to USDC.");
            console.log("  Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        }

        vm.stopBroadcast();

        console.log("\n=== Recovery Complete ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
    }

    /// @notice Withdraw using asset amount = totalTVL to avoid underflow from direct transfers.
    ///   forge script script/mainnet-tests/RecoverIBGTTestVaults.s.sol:RecoverIBGTTestVaults \
    ///     --sig "withdraw(address)" <VAULT_ADDR> --rpc-url mainnet --broadcast --with-gas-price 10000000
    function withdraw(address vaultAddr) external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        DiracVault vault = DiracVault(payable(vaultAddr));

        console.log("=== Withdraw ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("User USDC before:", IERC20(USDC).balanceOf(user));

        vm.startBroadcast(pk);

        vault.openWithdrawals();

        // Withdraw exactly totalTVL to avoid totalTVL -= assets underflow
        uint256 withdrawable = vault.getTotalTVL();
        console.log("Withdrawable (totalTVL):", withdrawable);
        vault.withdraw(withdrawable, user, user);
        vault.closeCycle();

        vm.stopBroadcast();

        console.log("Withdrawn USDC:", withdrawable);
        console.log("User USDC after:", IERC20(USDC).balanceOf(user));
        console.log("Vault USDC remaining:", IERC20(USDC).balanceOf(vaultAddr));
    }

    function _fetchKodiakQuote(
        address tokenIn, address tokenOut, uint256 amount, address recipient
    ) internal returns (
        IKXRouter.SwapData memory swapData, IKXRouter.FeeData memory feeData, uint256 minAmountOut
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
        cmd[0] = "bash"; cmd[1] = "-c"; cmd[2] = curlCmd;
        bytes memory result = vm.ffi(cmd);
        bytes memory fullCalldata = vm.parseJsonBytes(string(result), ".methodParameters.calldata");
        bytes memory encoded = new bytes(fullCalldata.length - 4);
        for (uint256 i = 0; i < encoded.length; i++) encoded[i] = fullCalldata[i + 4];

        IKXRouter.InputAmount memory _input;
        IKXRouter.OutputAmount memory _output;
        (_input, _output, swapData, feeData) = abi.decode(
            encoded, (IKXRouter.InputAmount, IKXRouter.OutputAmount, IKXRouter.SwapData, IKXRouter.FeeData)
        );
        minAmountOut = _output.minAmountOut;
    }
}
