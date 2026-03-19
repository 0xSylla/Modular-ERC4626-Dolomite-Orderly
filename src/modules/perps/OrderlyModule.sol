// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ModuleBase} from "../ModuleBase.sol";
import {OrderlyStorage} from "../../libraries/OrderlyStorage.sol";
import {Events} from "../../libraries/Events.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault, VaultTypes} from "../../interfaces/IOrderly.sol";

/// @title OrderlyModule
/// @notice Perpetuals module for Orderly Network
/// @dev Executes via delegatecall from the vault
contract OrderlyModule is ModuleBase {
    using SafeERC20 for IERC20;

    function moduleType() external pure override returns (bytes32) {
        return keccak256("perps.orderly");
    }

    /// @notice One-time setup: set the Orderly vault address
    function initializeModule(address _orderlyVault) external payable onlyDelegatecall {
        if (_orderlyVault == address(0)) revert Events.ZeroAddress();
        OrderlyStorage.layout().orderlyVault = _orderlyVault;
    }

    /// @notice Delegate signer for Orderly orders
    function delegateSigner(
        VaultTypes.VaultDelegate calldata data
    ) external payable onlyDelegatecall {
        address vault = OrderlyStorage.layout().orderlyVault;
        if (vault == address(0)) revert Events.ZeroAddress();
        IVault(vault).delegateSigner(data);
        emit Events.DelegateSignerSet(data.brokerHash, data.delegateSigner);
    }

    /// @notice Deposit margin to Orderly for shorting
    function deposit(
        address depositAsset,
        VaultTypes.VaultDepositFE calldata data,
        uint256 fee
    ) external payable onlyDelegatecall {
        address vault = OrderlyStorage.layout().orderlyVault;
        if (vault == address(0)) revert Events.ZeroAddress();
        IERC20(depositAsset).forceApprove(vault, data.tokenAmount);
        IVault(vault).deposit{value: fee}(data);
        emit Events.DepositedToOrderly(data.tokenAmount);
    }
}
