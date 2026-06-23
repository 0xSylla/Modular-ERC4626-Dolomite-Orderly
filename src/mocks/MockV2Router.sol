// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockV2Router
/// @notice Minimal Uniswap-V2-style router for the first tokenomics test, where
///         TDIRAC has no real DEX pool yet. Pays out `path[last]` at a fixed
///         `rate` per 1e6 of `path[0]` (so for USDC->TDIRAC: 1e18 = 1 TDIRAC
///         per 1 USDC). Must be pre-funded with the output token. Test-only.
contract MockV2Router {
    /// @notice Output tokens paid per 1e6 units of input (scaled to output decimals).
    uint256 public rate;
    address public owner;

    error NotOwner();

    constructor(uint256 _rate) {
        rate = _rate;
        owner = msg.sender;
    }

    function setRate(uint256 _rate) external {
        if (msg.sender != owner) revert NotOwner();
        rate = _rate;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /*deadline*/
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rate) / 1e6;
        require(out >= amountOutMin, "MockV2Router: INSUFFICIENT_OUTPUT");
        IERC20(path[path.length - 1]).transfer(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}
