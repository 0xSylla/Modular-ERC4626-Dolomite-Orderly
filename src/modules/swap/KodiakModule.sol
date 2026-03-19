// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ModuleBase} from "../ModuleBase.sol";
import {IKXRouter} from "../../interfaces/IKXRouter.sol";
import {Events} from "../../libraries/Events.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

/// @title KodiakModule
/// @notice Swap module for Kodiak DEX (KXRouter)
/// @dev Stateless — executes via delegatecall from the vault
contract KodiakModule is ModuleBase {
    IKXRouter public constant KX_ROUTER =
        IKXRouter(0x43Dac637c4383f91B4368041E7A8687da3806Cae);

    function moduleType() external pure override returns (bytes32) {
        return keccak256("swap.kodiak");
    }

    /// @notice Swap tokens via Kodiak DEX
    /// @param amountIn Amount to swap, or type(uint256).max for entire balance
    function swap(
        address tokenIn,
        bool wrapIn,
        uint256 amountIn,
        address tokenOut,
        bool unwrapOut,
        uint256 minAmountOut,
        IKXRouter.SwapData calldata swapData,
        IKXRouter.FeeData calldata feeData
    ) external payable onlyDelegatecall {
        uint256 amount = amountIn == type(uint256).max
            ? IERC20(tokenIn).balanceOf(address(this))
            : amountIn;
        if (amount == 0) revert Events.ZeroAmount();

        IKXRouter.InputAmount memory input = IKXRouter.InputAmount({
            token: tokenIn,
            wrap: wrapIn,
            amount: amount
        });

        IKXRouter.OutputAmount memory output = IKXRouter.OutputAmount({
            token: tokenOut,
            unwrap: unwrapOut,
            minAmountOut: minAmountOut,
            receiver: address(this) // vault address in delegatecall context
        });

        TransferHelper.safeApprove(tokenIn, address(KX_ROUTER), amount);
        KX_ROUTER.swap(input, output, swapData, feeData);
        TransferHelper.safeApprove(tokenIn, address(KX_ROUTER), 0);

        emit Events.Swapped(tokenIn, tokenOut, amount, minAmountOut);
    }
}
