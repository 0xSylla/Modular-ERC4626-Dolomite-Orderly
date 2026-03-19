// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DiracVault} from "../../src/vault/DiracVault.sol";
import {DiracVaultFactory} from "../../src/factory/DiracVaultFactory.sol";
import {DolomiteLendingBase} from "../../src/modules/lending/dolomite/DolomiteLendingBase.sol";
import {KodiakModule} from "../../src/modules/swap/KodiakModule.sol";
import {IKXRouter} from "../../src/interfaces/IKXRouter.sol";

/// @title RecoverOldVaults
/// @notice Recover funds from old test vaults
contract RecoverOldVaults is Script {
    address constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;

    address constant OLD_FACTORY = 0xa056E2DECBb3aCA01ef4C0cC5b3fC2b7126D086d;
    address constant OLD_VAULT_A = 0xeAb9A3679ba5e7808D8c147E4b3776e7e5B6D22D;
    address constant OLD_VAULT_B = 0x806789fa42560292fAB37221dB01Aa0D4b828a5e;

    uint256 constant DIBGT_MARKET_ID = 38;
    uint256 constant USDC_MARKET_ID  = 2;

    /// @notice Recover Vault B (no Dolomite position - just USDC sitting in vault)
    function recoverVaultB() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        DiracVault vault = DiracVault(payable(OLD_VAULT_B));

        console.log("=== Recover Vault B (WETH) ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(OLD_VAULT_B));
        console.log("User shares:", vault.balanceOf(user));

        vm.startBroadcast(pk);
        vault.openWithdrawals();
        uint256 shares = vault.balanceOf(user);
        uint256 received = vault.redeem(shares, user, user);
        vault.closeCycle();
        vm.stopBroadcast();

        console.log("Redeemed:", received, "USDC");
        console.log("User USDC:", IERC20(USDC).balanceOf(user));
    }

    /// @notice Recover Vault A (has active Dolomite isolation-mode position)
    ///         Step 1: Repay debt + get iBGT back
    function recoverVaultA_repay() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        DiracVault vault = DiracVault(payable(OLD_VAULT_A));
        DiracVaultFactory factory = DiracVaultFactory(OLD_FACTORY);
        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));

        uint256 usdcBal = IERC20(USDC).balanceOf(OLD_VAULT_A);
        console.log("=== Recover Vault A - Step 1: Repay ===");
        console.log("Vault USDC:", usdcBal);
        console.log("Module:", dolomiteModule);

        vm.startBroadcast(pk);
        // Repay debt with exact vault USDC balance (107% auto-calc exceeds balance)
        vault.executeModule(dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.repayDebt, (USDC, usdcBal, DIBGT_MARKET_ID, USDC_MARKET_ID)));
        vm.stopBroadcast();

        console.log("Debt repaid.");
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(OLD_VAULT_A));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(OLD_VAULT_A));
    }

    /// @notice Recover Vault A using repayDebtWithCollateral (GenericTrader path)
    ///         This avoids the account 0 AccountRiskOverrideSetter issue by operating
    ///         entirely on BORROW_ACCOUNT via GenericTrader + OogaBooga.
    ///         After repay, the vault will have USDC (surplus + borrowed) ready to withdraw.
    function recoverVaultA_repayWithCollateral() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        DiracVault vault = DiracVault(payable(OLD_VAULT_A));
        DiracVaultFactory factory = DiracVaultFactory(OLD_FACTORY);
        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));

        console.log("=== Recover Vault A: repayDebtWithCollateral ===");
        console.log("Module:", dolomiteModule);
        console.log("Vault USDC before:", IERC20(USDC).balanceOf(OLD_VAULT_A));

        // OogaBooga pathDefinition for iBGT -> USDC swap
        // Fetched from mainnet.api.oogabooga.io
        bytes memory oogaSwapData = vm.envBytes("OOGA_PATH_DEFINITION");

        uint256 minAmountOut = vm.envOr("MIN_AMOUNT_OUT", uint256(400004));
        uint256 expectedAmountOut = vm.envOr("EXPECTED_AMOUNT_OUT", uint256(997426));

        console.log("minAmountOut:", minAmountOut);
        console.log("expectedAmountOut:", expectedAmountOut);

        vm.startBroadcast(pk);
        vault.executeModule(dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.repayDebtWithCollateral, (
                IBGT,           // collateralAsset (underlying)
                USDC,           // borrowAssetAddr
                minAmountOut,
                expectedAmountOut,
                oogaSwapData,
                DIBGT_MARKET_ID,
                USDC_MARKET_ID
            )));
        vm.stopBroadcast();

        console.log("Vault USDC after:", IERC20(USDC).balanceOf(OLD_VAULT_A));
        console.log("Vault iBGT after:", IERC20(IBGT).balanceOf(OLD_VAULT_A));
    }

    /// @notice Recover Vault A final step: withdraw all USDC from vault
    function recoverVaultA_withdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        DiracVault vault = DiracVault(payable(OLD_VAULT_A));

        console.log("=== Recover Vault A: Withdraw ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(OLD_VAULT_A));

        vm.startBroadcast(pk);
        vault.openWithdrawals();
        uint256 shares = vault.balanceOf(user);
        uint256 received = vault.redeem(shares, user, user);
        vault.closeCycle();
        vm.stopBroadcast();

        console.log("Redeemed:", received, "USDC");
        console.log("User USDC:", IERC20(USDC).balanceOf(user));
    }

    /// @notice Recover Vault A - Step 2: Swap iBGT back to USDC and withdraw
    function recoverVaultA_swapAndWithdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        DiracVault vault = DiracVault(payable(OLD_VAULT_A));
        DiracVaultFactory factory = DiracVaultFactory(OLD_FACTORY);
        address kodiakModule = factory.getModule(keccak256("swap.kodiak"));

        uint256 ibgtBal = IERC20(IBGT).balanceOf(OLD_VAULT_A);
        console.log("=== Recover Vault A - Step 2: Swap + Withdraw ===");
        console.log("Vault iBGT:", ibgtBal);

        (IKXRouter.SwapData memory sd, IKXRouter.FeeData memory fd, uint256 minOut) =
            _fetchKodiakQuote(IBGT, USDC, ibgtBal, OLD_VAULT_A);

        vm.startBroadcast(pk);
        vault.executeModule(kodiakModule,
            abi.encodeCall(KodiakModule.swap, (IBGT, false, ibgtBal, USDC, false, minOut * 90 / 100, sd, fd)));

        vault.openWithdrawals();
        uint256 shares = vault.balanceOf(user);
        uint256 received = vault.redeem(shares, user, user);
        vault.closeCycle();
        vm.stopBroadcast();

        console.log("Redeemed:", received, "USDC");
        console.log("User USDC:", IERC20(USDC).balanceOf(user));
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
        string memory json = string(result);
        bytes memory fullCalldata = vm.parseJsonBytes(json, ".methodParameters.calldata");
        bytes memory encoded = _stripSelector(fullCalldata);
        IKXRouter.InputAmount memory _input;
        IKXRouter.OutputAmount memory _output;
        (_input, _output, swapData, feeData) = abi.decode(
            encoded, (IKXRouter.InputAmount, IKXRouter.OutputAmount, IKXRouter.SwapData, IKXRouter.FeeData)
        );
        minAmountOut = _output.minAmountOut;
    }

    function _stripSelector(bytes memory data) internal pure returns (bytes memory) {
        require(data.length >= 4, "calldata too short");
        bytes memory r = new bytes(data.length - 4);
        for (uint256 i = 0; i < r.length; i++) { r[i] = data[i + 4]; }
        return r;
    }
}
