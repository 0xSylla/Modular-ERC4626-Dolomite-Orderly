// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DiracVault} from "../../src/vault/DiracVault.sol";
import {DiracVaultFactory} from "../../src/factory/DiracVaultFactory.sol";
import {KodiakModule} from "../../src/modules/swap/KodiakModule.sol";
import {IKXRouter} from "../../src/interfaces/IKXRouter.sol";

/// @title RecoverVault
/// @notice Recover funds from stuck vault (CLOSED cycle): emergency swap iBGT → USDC, then start new cycle to withdraw
/// @dev Run: forge script script/RecoverVault.s.sol:RecoverVault --rpc-url mainnet --broadcast --ffi
contract RecoverVault is Script {
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    address public constant VAULT = 0xd2C28AE8b4fFF6EB5DA06C69B9FB2120040C559F;
    address public constant FACTORY = 0x7d45718c79186Da8889111b5D8d7eDe6d128fb14;
    address public constant KODIAK_MODULE = 0x28BCeDd2c26dDcBE9485Bf9f4394A6ACa4491690;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        DiracVault vault = DiracVault(payable(VAULT));
        DiracVaultFactory factory = DiracVaultFactory(FACTORY);

        uint256 ibgtBal = IERC20(IBGT).balanceOf(VAULT);
        console.log("=== Recover Vault ===");
        console.log("Vault iBGT:", ibgtBal);
        console.log("Vault USDC:", IERC20(USDC).balanceOf(VAULT));
        console.log("User shares:", vault.balanceOf(deployer));

        // Fetch Kodiak quote for iBGT → USDC
        (
            IKXRouter.SwapData memory swapData,
            IKXRouter.FeeData memory feeData,
            uint256 minOut
        ) = _fetchKodiakQuote(IBGT, USDC, ibgtBal, VAULT);
        console.log("Quote minAmountOut:", minOut);

        vm.startBroadcast(pk);

        // Step 1: Emergency swap iBGT → USDC (bypasses cycle check via factory → OWNER_ROLE)
        // Note: use exact balance, not type(uint256).max — the on-chain module predates that fix
        factory.emergencyExecute(
            VAULT,
            keccak256("swap.kodiak"),
            abi.encodeCall(
                KodiakModule.swap,
                (IBGT, false, ibgtBal, USDC, false, minOut, swapData, feeData)
            )
        );
        console.log("Swapped. Vault USDC:", IERC20(USDC).balanceOf(VAULT));

        // Step 2: Open deposits → trading → withdrawals
        vault.openDeposits();
        vault.startTrading();
        vault.openWithdrawals();
        console.log("Cycle fast-forwarded to WITHDRAW_OPEN.");

        // Step 3: Withdraw max available (capped by vault USDC balance and totalTVL)
        uint256 maxW = vault.maxWithdraw(deployer);
        console.log("Max withdrawable:", maxW);
        uint256 assetsOut = vault.withdraw(maxW, deployer, deployer);
        console.log("Withdrawn, USDC received:", assetsOut);

        // Step 4: Close cycle
        vault.closeCycle();
        console.log("Cycle closed.");

        vm.stopBroadcast();

        console.log("\nUser USDC balance:", IERC20(USDC).balanceOf(deployer));
    }

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

    function _stripSelector(bytes memory data) internal pure returns (bytes memory) {
        require(data.length >= 4, "calldata too short");
        bytes memory r = new bytes(data.length - 4);
        for (uint256 i = 0; i < r.length; i++) {
            r[i] = data[i + 4];
        }
        return r;
    }
}
