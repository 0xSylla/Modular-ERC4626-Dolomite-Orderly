// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ModuleBase} from "../ModuleBase.sol";
import {Events} from "../../libraries/Events.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title UniswapModule
/// @notice Swap module using Uniswap V3 SwapRouter directly — no external aggregator.
/// @dev Stateless — executes via delegatecall from the vault.
///      The API builds the multi-hop path and exactInput calldata off-chain (deterministic;
///      no API dependency that can return stale routes). Same approve-call-revoke pattern
///      as OdosModule.
contract UniswapModule is ModuleBase {
    using SafeERC20 for IERC20;

    /// @notice Uniswap V3 SwapRouter (canonical address on Arbitrum, Ethereum, Optimism, Polygon).
    address public constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    function moduleType() external pure override returns (bytes32) {
        return keccak256("swap.uniswap");
    }

    /// @notice Swap tokens via Uniswap V3 SwapRouter.
    /// @param tokenIn     Token to swap from
    /// @param amountIn    Amount to swap (type(uint256).max = full vault balance)
    /// @param tokenOut    Token to receive
    /// @param minAmountOut Slippage protection — revert if received < this
    /// @param uniswapCalldata Pre-encoded calldata for the Uniswap V3 router (exactInput or exactInputSingle)
    function swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        bytes calldata uniswapCalldata
    ) external payable onlyDelegatecall {
        uint256 amount = amountIn == type(uint256).max
            ? IERC20(tokenIn).balanceOf(address(this))
            : amountIn;
        if (amount == 0) revert Events.ZeroAmount();

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(UNISWAP_ROUTER, amount);
        (bool success, ) = UNISWAP_ROUTER.call(uniswapCalldata);
        if (!success) revert Events.OperationFailed();
        IERC20(tokenIn).forceApprove(UNISWAP_ROUTER, 0);

        uint256 received = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
        if (received < minAmountOut) revert Events.InsufficientBalance();

        emit Events.Swapped(tokenIn, tokenOut, amount, received);
    }
}
