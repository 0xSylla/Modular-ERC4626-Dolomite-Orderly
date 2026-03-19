// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ModuleBase} from "../../ModuleBase.sol";
import {DolomiteStorage} from "../../../libraries/DolomiteStorage.sol";
import {Events} from "../../../libraries/Events.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IDolomiteMargin,
    IDepositWithdrawalRouter,
    IBorrowPositionRouter
} from "../../../interfaces/IDolomite.sol";

/// @title DolomiteLendingBase
/// @notice Thin shared base for Dolomite lending modules.
///         Contains only constants, storage helpers, and getPosition.
///         Each chain module (Bera, Arb) implements its own supply/borrow/repay logic.
abstract contract DolomiteLendingBase is ModuleBase {
    using SafeERC20 for IERC20;

    // ============ Shared Constants ============
    uint256 public constant MAIN_ACCOUNT   = 0;
    uint256 public constant BORROW_ACCOUNT = 123; // deprecated — use _accountForMarket()
    uint256 public constant ACCOUNT_BASE   = 1000;

    /// @dev Derive a unique Dolomite sub-account per collateral market.
    ///      Keeps each position's debt isolated from the others.
    function _accountForMarket(uint256 marketId) internal pure returns (uint256) {
        return ACCOUNT_BASE + marketId;
    }

    /// @dev Dolomite routers — same addresses on all chains (deployed via CREATE2)
    IDepositWithdrawalRouter public constant DEPOSIT_WITHDRAWAL_ROUTER =
        IDepositWithdrawalRouter(0xf8b2c637A68cF6A17b1DF9F8992EeBeFf63d2dFf);
    IBorrowPositionRouter public constant BORROW_POSITION_ROUTER =
        IBorrowPositionRouter(0xF579b345cdA0860668b857De10ABD62442133D0F);

    // ============ Module Identity ============

    function moduleType() external pure override returns (bytes32) {
        return keccak256("lending.dolomite");
    }

    // ============ Shared View ============

    /// @notice Get position info for a specific collateral/borrow market pair
    function getPosition(uint256 collateralMarketId, uint256 borrowMarketId)
        external view returns (uint256 collateral, uint256 borrowed)
    {
        DolomiteStorage.Layout storage s = DolomiteStorage.layout();
        return (s.collateralDeposited[collateralMarketId], s.assetBorrowed[borrowMarketId]);
    }

    /// @notice Check if a market is isolation mode (has a proxy)
    function isIsolationMode(uint256 marketId) external view returns (bool) {
        return DolomiteStorage.layout().isolationProxies[marketId] != address(0);
    }

    // ============ Virtual ============

    /// @notice Initialize module (authorize Dolomite operators). Chain-specific.
    function initializeModule() external payable virtual;

    /// @notice Supply collateral to Dolomite
    function supplyCollateral(
        address collateralAsset,
        uint256 _amount,
        uint256 _collateralMarketId
    ) external payable virtual;

    /// @notice Borrow asset against collateral
    function borrow(
        uint256 _borrowAmount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) external payable virtual;

    /// @notice Repay debt and close borrow position
    function repayDebt(
        address borrowAssetAddr,
        uint256 _amount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) external payable virtual;

    /// @notice Repay debt by swapping collateral → borrow asset
    function repayDebtWithCollateral(
        address collateralAsset,
        address borrowAssetAddr,
        uint256 minUSDCOut,
        uint256 expectedUSDCOut,
        bytes calldata swapData,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) external payable virtual;

    /// @notice Withdraw collateral from Dolomite (requires zero debt)
    function withdrawCollateral(
        uint256 _amount,
        uint256 _collateralMarketId
    ) external payable virtual;
}
