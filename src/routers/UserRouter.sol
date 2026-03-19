// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DiracVault} from "../vault/DiracVault.sol";
import {IDiracVaultFactory} from "../interfaces/IDiracVaultFactory.sol";
import {Events} from "../libraries/Events.sol";
import {Data} from "../libraries/Data.sol";

/// @title UserRouter
/// @notice UX helper for depositors — holds no funds, no admin state
contract UserRouter {
    using SafeERC20 for IERC20;

    IDiracVaultFactory public immutable factory;

    constructor(address _factory) {
        factory = IDiracVaultFactory(_factory);
    }

    modifier onlyFactoryVault(address vault) {
        if (!factory.isVault(vault)) revert Events.NotFactoryVault();
        _;
    }

    /// @notice Deposit assets into a vault
    function depositIntoVault(
        address vault,
        uint256 amount,
        address receiver
    ) external onlyFactoryVault(vault) returns (uint256 shares) {
        IERC20 depositToken = IERC20(DiracVault(payable(vault)).asset());
        depositToken.safeTransferFrom(msg.sender, address(this), amount);
        depositToken.safeIncreaseAllowance(vault, amount);
        shares = DiracVault(payable(vault)).deposit(amount, receiver);
    }

    /// @notice Withdraw assets from a vault
    function withdrawFromVault(
        address vault,
        uint256 amount,
        address receiver
    ) external onlyFactoryVault(vault) returns (uint256 shares) {
        shares = DiracVault(payable(vault)).withdraw(
            amount,
            receiver,
            msg.sender
        );
    }

    /// @notice Redeem shares from a vault
    function redeemFromVault(
        address vault,
        uint256 shares,
        address receiver
    ) external onlyFactoryVault(vault) returns (uint256 assets) {
        assets = DiracVault(payable(vault)).redeem(
            shares,
            receiver,
            msg.sender
        );
    }

    /// @notice Deposit into multiple vaults in one tx
    function batchDeposit(
        address[] calldata vaults,
        uint256[] calldata amounts,
        address[] calldata receivers
    ) external returns (uint256[] memory sharesArray) {
        if (vaults.length != amounts.length || amounts.length != receivers.length)
            revert Events.ArrayLengthMismatch();
        sharesArray = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            if (!factory.isVault(vaults[i])) revert Events.NotFactoryVault();
            IERC20 depositToken = IERC20(
                DiracVault(payable(vaults[i])).asset()
            );
            depositToken.safeTransferFrom(
                msg.sender,
                address(this),
                amounts[i]
            );
            depositToken.safeIncreaseAllowance(vaults[i], amounts[i]);
            sharesArray[i] = DiracVault(payable(vaults[i])).deposit(
                amounts[i],
                receivers[i]
            );
        }
    }

    // ============ View Functions ============

    function previewDeposit(
        address vault,
        uint256 amount
    ) external view returns (uint256) {
        return DiracVault(payable(vault)).previewDeposit(amount);
    }

    function previewWithdraw(
        address vault,
        uint256 assets
    ) external view returns (uint256) {
        return DiracVault(payable(vault)).previewWithdraw(assets);
    }

    function getVaultInfo(
        address vault
    )
        external
        view
        returns (
            uint256 totalAssets,
            Data.TradeCycleStatus cycleStatus,
            uint256 sharePrice,
            uint256 maxDeposit
        )
    {
        DiracVault v = DiracVault(payable(vault));
        totalAssets = v.totalAssets();
        cycleStatus = v.getCurrentCycle().status;
        sharePrice = v.convertToAssets(1e18);
        maxDeposit = v.getMaxDeposit();
    }
}
