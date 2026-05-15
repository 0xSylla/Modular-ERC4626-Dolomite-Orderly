// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ModuleBase} from "../ModuleBase.sol";
import {HyperliquidStorage} from "../../libraries/HyperliquidStorage.sol";
import {Events} from "../../libraries/Events.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title HyperliquidModule
/// @notice Perpetuals module for Hyperliquid L1.
/// @dev Hyperliquid was designed for EOA users, not vault contracts: the bridge
///      (`Bridge2.batchedDepositWithPermit`) expects an EOA-signed EIP-2612
///      permit, and trading on Hyperliquid L1 requires a private key per
///      request. This module therefore implements an *operator-custodial*
///      pattern: the vault transfers margin USDC to an operator EOA, which
///      then bridges to Hyperliquid L1 and signs trades. After a close, the
///      operator returns USDC and `recordReturn` updates the rolling totals
///      that user-share pricing uses to value the off-chain margin.
///
///      Trust note: while funds are in transit (vault → operator → bridge →
///      Hyperliquid → bridge → operator → vault) they are custodied by the
///      operator EOA. The vault contract cannot enforce that they return.
///      This is documented in the curation UI's perps selector.
///
///      Executes via delegatecall from the vault.
contract HyperliquidModule is ModuleBase {
    using SafeERC20 for IERC20;

    function moduleType() external pure override returns (bytes32) {
        return keccak256("perps.hyperliquid");
    }

    /// @notice One-time setup: bind this vault to the operator EOA that will
    ///         custody margin and sign Hyperliquid trades.
    /// @param _operator EOA whose private key is held by the Dirac API.
    function initializeModule(address _operator) external payable onlyDelegatecall {
        if (_operator == address(0)) revert Events.ZeroAddress();
        HyperliquidStorage.layout().operator = _operator;
        emit Events.HyperliquidOperatorSet(_operator);
    }

    /// @notice Push margin USDC to the operator EOA. The off-chain bot picks
    ///         this up, signs the EIP-2612 permit, and calls the Hyperliquid
    ///         bridge. The on-chain side ends here.
    /// @param depositAsset USDC (passed in so the vault's whitelisted-asset
    ///         logic still flows through standard module entrypoints).
    /// @param amount       USDC amount in 6-decimal raw units.
    function deposit(
        address depositAsset,
        uint256 amount
    ) external payable onlyDelegatecall {
        if (amount == 0) revert Events.ZeroAmount();
        address operator = HyperliquidStorage.layout().operator;
        if (operator == address(0)) revert Events.ZeroAddress();
        IERC20(depositAsset).safeTransfer(operator, amount);
        HyperliquidStorage.layout().totalDeposited += amount;
        emit Events.HyperliquidDeposited(operator, amount);
    }

    /// @notice Account for USDC returned to the vault after a Hyperliquid
    ///         withdrawal completes (operator bridges back and ERC20-transfers
    ///         to this vault, then the executor delegatecalls this to update
    ///         the rolling total).
    /// @dev    The USDC transfer itself is a standard ERC20 send to the vault
    ///         address — no module call needed. This entrypoint exists only
    ///         to record the inflow for share-price accounting.
    function recordReturn(uint256 amountReceived) external payable onlyDelegatecall {
        HyperliquidStorage.layout().totalReturned += amountReceived;
        emit Events.HyperliquidReturnRecorded(amountReceived);
    }
}
