// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title HyperliquidStorage
/// @notice Diamond-style storage slot for the Hyperliquid perps module.
/// @dev Hyperliquid (unlike Orderly) has no on-chain delegate primitive.
///      The vault tracks the operator EOA that custodies margin USDC while it's
///      bridged to Hyperliquid L1, plus rolling totals so user-share pricing
///      includes the off-chain margin balance.
library HyperliquidStorage {
    bytes32 constant SLOT = keccak256("dirac.module.hyperliquid.v1");

    struct Layout {
        /// @notice EOA that receives margin USDC, bridges it to Hyperliquid L1,
        ///         signs Hyperliquid API requests, and returns USDC after close.
        address operator;
        /// @notice Lifetime USDC sent from vault → operator → Hyperliquid bridge.
        uint256 totalDeposited;
        /// @notice Lifetime USDC returned from operator → vault after withdrawal.
        uint256 totalReturned;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
