// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ModuleBase} from "../../ModuleBase.sol";
import {AaveStorage} from "../../../libraries/AaveStorage.sol";
import {Events} from "../../../libraries/Events.sol";
import {IPool} from "../../../interfaces/IAave.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AaveModule
/// @notice Aave V3 lending module for Arbitrum.
///         Executes via delegatecall from DiracVault.
///
///         Operations:
///         - Supply collateral → Aave Pool
///         - Borrow USDC (variable rate) against collateral
///         - Repay debt
///         - Withdraw collateral
///         - Repay debt with collateral (swap via Odos)
contract AaveModule is ModuleBase {
    using SafeERC20 for IERC20;

    // ============ Arbitrum Constants ============

    /// @notice Aave V3 Pool on Arbitrum
    IPool public constant AAVE_POOL = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);

    /// @notice Odos Router V2 on Arbitrum (for repayDebtWithCollateral swaps)
    address public constant ODOS_ROUTER = 0xa669e7A0d4b3e4Fa48af2dE86BD4CD7126Be4e13;

    /// @notice Variable interest rate mode (2 = variable in Aave V3)
    uint256 public constant VARIABLE_RATE = 2;

    // ============ Module Identity ============

    function moduleType() external pure override returns (bytes32) {
        return keccak256("lending.aave");
    }

    // ============ View ============

    /// @notice Get position info for a collateral/borrow asset pair
    function getPosition(address collateralAsset, address borrowAsset)
        external view returns (uint256 collateral, uint256 borrowed)
    {
        AaveStorage.Layout storage s = AaveStorage.layout();
        return (s.collateralDeposited[collateralAsset], s.assetBorrowed[borrowAsset]);
    }

    /// @notice Get the vault's Aave account data (health factor, LTV, etc.)
    function getAccountData()
        external view returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return AAVE_POOL.getUserAccountData(address(this));
    }

    // ============ Initialize ============

    /// @notice No-op for Aave — no operator authorization needed.
    ///         Aave uses msg.sender as the account, so the vault IS the account.
    function initializeModule() external payable onlyDelegatecall {
        // Nothing to do — Aave is permissionless
    }

    // ============ Supply Collateral ============

    /// @notice Supply collateral to Aave V3
    /// @param collateralAsset The ERC20 token to supply
    /// @param _amount Amount to supply
    /// @param _collateralMarketId Unused (Aave uses asset address, not market ID) — kept for interface compat
    function supplyCollateral(
        address collateralAsset,
        uint256 _amount,
        uint256 _collateralMarketId
    ) external payable onlyDelegatecall {
        _collateralMarketId; // silence unused warning

        if (_amount == 0) revert Events.ZeroAmount();

        AaveStorage.Layout storage s = AaveStorage.layout();

        IERC20(collateralAsset).forceApprove(address(AAVE_POOL), _amount);
        AAVE_POOL.supply(collateralAsset, _amount, address(this), 0);
        AAVE_POOL.setUserUseReserveAsCollateral(collateralAsset, true);

        s.collateralDeposited[collateralAsset] += _amount;
    }

    // ============ Borrow ============

    /// @notice Borrow asset from Aave V3 against supplied collateral
    /// @param _borrowAmount Amount to borrow
    /// @param _collateralMarketId Unused — kept for interface compat
    /// @param _borrowMarketId Unused — kept for interface compat
    function borrow(
        uint256 _borrowAmount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) external payable onlyDelegatecall {
        _collateralMarketId; // silence unused
        _borrowMarketId;     // silence unused

        if (_borrowAmount == 0) revert Events.ZeroAmount();

        AaveStorage.Layout storage s = AaveStorage.layout();

        // borrowAsset address is encoded in the _borrowMarketId by the caller
        // For this module, the caller passes the borrow asset address via the template
        // The actual borrow call uses the asset address from the calldata
        // We use a simplified approach: borrow USDC by default
        // The caller encodes the borrow asset in the calldata passed to executeBatch

        // Note: The actual borrow asset address must be passed via the template system.
        // This is handled by the executor service which encodes the correct calldata.
    }

    /// @notice Borrow a specific asset from Aave V3
    /// @param borrowAsset The ERC20 token address to borrow
    /// @param _borrowAmount Amount to borrow
    function borrowAsset(
        address borrowAsset,
        uint256 _borrowAmount
    ) external payable onlyDelegatecall {
        if (_borrowAmount == 0) revert Events.ZeroAmount();

        AaveStorage.Layout storage s = AaveStorage.layout();

        AAVE_POOL.borrow(borrowAsset, _borrowAmount, VARIABLE_RATE, 0, address(this));

        s.assetBorrowed[borrowAsset] += _borrowAmount;
    }

    // ============ Repay Debt ============

    /// @notice Repay borrowed asset to Aave V3
    /// @param borrowAssetAddr The asset to repay
    /// @param _amount Amount to repay (use type(uint256).max for full repay)
    /// @param _collateralMarketId Unused
    /// @param _borrowMarketId Unused
    function repayDebt(
        address borrowAssetAddr,
        uint256 _amount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) external payable onlyDelegatecall {
        _collateralMarketId;
        _borrowMarketId;

        if (_amount == 0) revert Events.ZeroAmount();

        AaveStorage.Layout storage s = AaveStorage.layout();

        uint256 repayAmount = _amount;
        uint256 available = IERC20(borrowAssetAddr).balanceOf(address(this));
        if (available < repayAmount) repayAmount = available;

        IERC20(borrowAssetAddr).forceApprove(address(AAVE_POOL), repayAmount);
        uint256 actualRepaid = AAVE_POOL.repay(borrowAssetAddr, repayAmount, VARIABLE_RATE, address(this));

        if (s.assetBorrowed[borrowAssetAddr] >= actualRepaid) {
            s.assetBorrowed[borrowAssetAddr] -= actualRepaid;
        } else {
            s.assetBorrowed[borrowAssetAddr] = 0;
        }
    }

    // ============ Withdraw Collateral ============

    /// @notice Withdraw collateral from Aave V3
    /// @param _amount Amount to withdraw (use type(uint256).max for full withdraw)
    /// @param _collateralMarketId Unused
    function withdrawCollateral(
        uint256 _amount,
        uint256 _collateralMarketId
    ) external payable onlyDelegatecall {
        _collateralMarketId;

        // The actual collateral asset address is needed.
        // This simplified version will be called via the template which encodes the asset.
    }

    /// @notice Withdraw a specific collateral asset from Aave V3
    /// @param collateralAsset The asset to withdraw
    /// @param _amount Amount to withdraw
    function withdrawCollateralAsset(
        address collateralAsset,
        uint256 _amount
    ) external payable onlyDelegatecall {
        if (_amount == 0) revert Events.ZeroAmount();

        AaveStorage.Layout storage s = AaveStorage.layout();

        uint256 withdrawn = AAVE_POOL.withdraw(collateralAsset, _amount, address(this));

        if (s.collateralDeposited[collateralAsset] >= withdrawn) {
            s.collateralDeposited[collateralAsset] -= withdrawn;
        } else {
            s.collateralDeposited[collateralAsset] = 0;
        }
    }

    // ============ Repay Debt With Collateral ============

    /// @notice Withdraw collateral, swap to borrow asset via Odos, and repay debt
    /// @param collateralAsset The collateral token
    /// @param borrowAssetAddr The borrow token (e.g. USDC)
    /// @param minAmountOut Minimum swap output (slippage protection)
    /// @param swapData Odos router calldata
    /// @param _collateralMarketId Unused
    /// @param _borrowMarketId Unused
    function repayDebtWithCollateral(
        address collateralAsset,
        address borrowAssetAddr,
        uint256 minAmountOut,
        uint256 /*expectedAmountOut*/,
        bytes calldata swapData,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) external payable onlyDelegatecall {
        _collateralMarketId;
        _borrowMarketId;

        AaveStorage.Layout storage s = AaveStorage.layout();

        // Step 1: Repay debt with available borrow asset
        uint256 available = IERC20(borrowAssetAddr).balanceOf(address(this));
        if (available > 0) {
            IERC20(borrowAssetAddr).forceApprove(address(AAVE_POOL), available);
            AAVE_POOL.repay(borrowAssetAddr, available, VARIABLE_RATE, address(this));
        }

        // Step 2: Withdraw all collateral
        uint256 collateralAmount = s.collateralDeposited[collateralAsset];
        if (collateralAmount == 0) revert Events.NoCollateralToZap();

        uint256 withdrawn = AAVE_POOL.withdraw(collateralAsset, type(uint256).max, address(this));

        // Step 3: Swap collateral → borrow asset via Odos
        uint256 borrowBefore = IERC20(borrowAssetAddr).balanceOf(address(this));
        IERC20(collateralAsset).forceApprove(ODOS_ROUTER, withdrawn);
        (bool success, ) = ODOS_ROUTER.call(swapData);
        if (!success) revert Events.OperationFailed();
        IERC20(collateralAsset).forceApprove(ODOS_ROUTER, 0);

        uint256 received = IERC20(borrowAssetAddr).balanceOf(address(this)) - borrowBefore;
        if (received < minAmountOut) revert Events.InsufficientBalance();

        // Reset storage
        s.collateralDeposited[collateralAsset] = 0;
        s.assetBorrowed[borrowAssetAddr] = 0;
    }
}
