// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ModuleBase} from "../../ModuleBase.sol";
import {MorphoStorage} from "../../../libraries/MorphoStorage.sol";
import {Events} from "../../../libraries/Events.sol";
import {IMorpho, IMorphoOracle, MarketParams} from "../../../interfaces/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MorphoModule
/// @notice Morpho Blue lending module for Arbitrum.
///         Executes via delegatecall from DiracVault.
///
///         Morpho Blue uses isolated markets identified by MarketParams.
///         Each market has a unique (loanToken, collateralToken, oracle, irm, lltv) tuple.
///
///         Operations:
///         - Supply collateral to a Morpho market
///         - Borrow loan token against collateral
///         - Repay debt
///         - Withdraw collateral
///         - Repay debt with collateral (swap via Odos)
contract MorphoModule is ModuleBase {
    using SafeERC20 for IERC20;

    // ============ Arbitrum Constants ============

    /// @notice Morpho Blue on Arbitrum (different from Ethereum mainnet address)
    IMorpho public constant MORPHO = IMorpho(0x6c247b1F6182318877311737BaC0844bAa518F5e);

    /// @notice Odos Router V2 on Arbitrum (for repayDebtWithCollateral swaps)
    address public constant ODOS_ROUTER = 0xa669e7A0d4b3e4Fa48af2dE86BD4CD7126Be4e13;

    // ============ Module Identity ============

    function moduleType() external pure override returns (bytes32) {
        return keccak256("lending.morpho");
    }

    // ============ View ============

    /// @notice Get position info for a specific Morpho market
    /// @param marketId The Morpho market ID (keccak256 of MarketParams)
    function getPosition(bytes32 marketId)
        external view returns (uint256 collateral, uint256 borrowed)
    {
        MorphoStorage.Layout storage s = MorphoStorage.layout();
        return (s.collateralDeposited[marketId], s.assetBorrowed[marketId]);
    }

    // ============ Initialize ============

    /// @notice No-op for Morpho — no operator authorization needed.
    ///         Morpho Blue is fully permissionless.
    function initializeModule() external payable onlyDelegatecall {
        // Nothing to do — Morpho is permissionless
    }

    // ============ Supply Collateral ============

    /// @notice Supply collateral to a Morpho Blue market
    /// @param collateralAsset The ERC20 collateral token
    /// @param _amount Amount to supply
    /// @param loanToken The loan token of the market
    /// @param oracle The oracle address of the market
    /// @param irm The interest rate model address of the market
    /// @param lltv The LLTV of the market
    function supplyCollateral(
        address collateralAsset,
        uint256 _amount,
        address loanToken,
        address oracle,
        address irm,
        uint256 lltv
    ) external payable onlyDelegatecall {
        if (_amount == 0) revert Events.ZeroAmount();

        MorphoStorage.Layout storage s = MorphoStorage.layout();

        MarketParams memory params = MarketParams({
            loanToken: loanToken,
            collateralToken: collateralAsset,
            oracle: oracle,
            irm: irm,
            lltv: lltv
        });

        bytes32 marketId = _marketId(params);

        IERC20(collateralAsset).forceApprove(address(MORPHO), _amount);
        MORPHO.supplyCollateral(params, _amount, address(this), "");

        s.collateralDeposited[marketId] += _amount;
    }

    // ============ Borrow ============

    /// @notice Borrow loan token from a Morpho Blue market
    /// @param borrowAsset The loan token to borrow
    /// @param _borrowAmount Amount to borrow
    /// @param collateralAsset The collateral token of the market
    /// @param oracle The oracle address
    /// @param irm The IRM address
    /// @param lltv The LLTV
    function borrowAsset(
        address borrowAsset,
        uint256 _borrowAmount,
        address collateralAsset,
        address oracle,
        address irm,
        uint256 lltv
    ) external payable onlyDelegatecall {
        if (_borrowAmount == 0) revert Events.ZeroAmount();

        MorphoStorage.Layout storage s = MorphoStorage.layout();

        MarketParams memory params = MarketParams({
            loanToken: borrowAsset,
            collateralToken: collateralAsset,
            oracle: oracle,
            irm: irm,
            lltv: lltv
        });

        bytes32 marketId = _marketId(params);

        MORPHO.borrow(params, _borrowAmount, 0, address(this), address(this));

        s.assetBorrowed[marketId] += _borrowAmount;
    }

    // ============ Repay Debt ============

    /// @notice Repay borrowed asset to a Morpho Blue market
    /// @param borrowAsset The loan token to repay
    /// @param _amount Amount to repay (use type(uint256).max for full repay via shares)
    /// @param collateralAsset The collateral token of the market
    /// @param oracle The oracle address
    /// @param irm The IRM address
    /// @param lltv The LLTV
    function repayDebt(
        address borrowAsset,
        uint256 _amount,
        address collateralAsset,
        address oracle,
        address irm,
        uint256 lltv
    ) external payable onlyDelegatecall {
        if (_amount == 0) revert Events.ZeroAmount();

        MorphoStorage.Layout storage s = MorphoStorage.layout();

        MarketParams memory params = MarketParams({
            loanToken: borrowAsset,
            collateralToken: collateralAsset,
            oracle: oracle,
            irm: irm,
            lltv: lltv
        });

        bytes32 marketId = _marketId(params);

        uint256 actualRepaid;

        if (_amount == type(uint256).max) {
            // Full repay: use share-based mode to avoid overflow
            // Read borrow shares from Morpho
            (, uint128 borrowShares, ) = MORPHO.position(marketId, address(this));
            if (borrowShares == 0) return; // nothing to repay

            // Approve generous amount (Morpho will only take what's needed)
            uint256 available = IERC20(borrowAsset).balanceOf(address(this));
            IERC20(borrowAsset).forceApprove(address(MORPHO), available);
            (actualRepaid, ) = MORPHO.repay(params, 0, borrowShares, address(this), "");
        } else {
            uint256 repayAmount = _amount;
            uint256 available = IERC20(borrowAsset).balanceOf(address(this));
            if (available < repayAmount) repayAmount = available;

            IERC20(borrowAsset).forceApprove(address(MORPHO), repayAmount);
            (actualRepaid, ) = MORPHO.repay(params, repayAmount, 0, address(this), "");
        }

        if (s.assetBorrowed[marketId] >= actualRepaid) {
            s.assetBorrowed[marketId] -= actualRepaid;
        } else {
            s.assetBorrowed[marketId] = 0;
        }
    }

    // ============ Withdraw Collateral ============

    /// @notice Withdraw collateral from a Morpho Blue market
    /// @param collateralAsset The collateral token
    /// @param _amount Amount to withdraw
    /// @param loanToken The loan token of the market
    /// @param oracle The oracle address
    /// @param irm The IRM address
    /// @param lltv The LLTV
    function withdrawCollateral(
        address collateralAsset,
        uint256 _amount,
        address loanToken,
        address oracle,
        address irm,
        uint256 lltv
    ) external payable onlyDelegatecall {
        if (_amount == 0) revert Events.ZeroAmount();

        MorphoStorage.Layout storage s = MorphoStorage.layout();

        MarketParams memory params = MarketParams({
            loanToken: loanToken,
            collateralToken: collateralAsset,
            oracle: oracle,
            irm: irm,
            lltv: lltv
        });

        bytes32 marketId = _marketId(params);

        MORPHO.withdrawCollateral(params, _amount, address(this), address(this));

        if (s.collateralDeposited[marketId] >= _amount) {
            s.collateralDeposited[marketId] -= _amount;
        } else {
            s.collateralDeposited[marketId] = 0;
        }
    }

    // ============ Repay Debt With Collateral ============

    /// @notice Withdraw collateral, swap to loan token via Odos, then repay debt.
    ///         Works in both profit (USDC >= debt) and loss (USDC < debt) scenarios.
    ///         Loss scenario: partial repay → partial withdraw → swap → full repay → withdraw rest.
    /// @param collateralAsset The collateral token
    /// @param borrowAsset The loan token (e.g. USDC)
    /// @param minAmountOut Minimum swap output (slippage protection)
    /// @param swapData Odos router calldata
    /// @param oracle The oracle address of the market
    /// @param irm The IRM address
    /// @param lltv The LLTV
    function repayDebtWithCollateral(
        address collateralAsset,
        address borrowAsset,
        uint256 minAmountOut,
        bytes calldata swapData,
        address oracle,
        address irm,
        uint256 lltv
    ) external payable onlyDelegatecall {
        MorphoStorage.Layout storage s = MorphoStorage.layout();

        MarketParams memory params = MarketParams({
            loanToken: borrowAsset,
            collateralToken: collateralAsset,
            oracle: oracle,
            irm: irm,
            lltv: lltv
        });

        bytes32 marketId = _marketId(params);
        uint256 collateralAmount = s.collateralDeposited[marketId];
        if (collateralAmount == 0) revert Events.NoCollateralToZap();

        // Step 1: Try full repay with available USDC
        (, uint128 borrowShares, ) = MORPHO.position(marketId, address(this));
        uint256 available = IERC20(borrowAsset).balanceOf(address(this));
        bool debtCleared = false;

        if (borrowShares > 0 && available > 0) {
            IERC20(borrowAsset).forceApprove(address(MORPHO), available);
            try MORPHO.repay(params, 0, borrowShares, address(this), "") {
                debtCleared = true;
            } catch {
                // Not enough — partial repay with what we have
                MORPHO.repay(params, available, 0, address(this), "");
            }
        } else if (borrowShares == 0) {
            debtCleared = true;
        }

        if (debtCleared) {
            // Profit path: debt is 0, withdraw all collateral
            MORPHO.withdrawCollateral(params, collateralAmount, address(this), address(this));
        } else {
            // Loss path: still have debt, can only withdraw partial collateral
            // Calculate remaining debt in asset terms
            (, uint128 remainShares, ) = MORPHO.position(marketId, address(this));
            (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(marketId);
            uint256 debtAssets = uint256(remainShares) * uint256(totalBorrowAssets) / uint256(totalBorrowShares);

            // Get oracle price: collateral value in loan token units (36 decimal precision)
            uint256 oraclePrice = IMorphoOracle(oracle).price();

            // Morpho health check: collateral * oraclePrice / 1e36 * lltv / 1e18 >= debt
            // So minCollateral = debt * 1e36 * 1e18 / (oraclePrice * lltv)
            // Add 5% buffer to be safe
            uint256 minCollateral = (debtAssets * 1e36 * 1e18 * 105) / (oraclePrice * lltv * 100);
            if (minCollateral >= collateralAmount) minCollateral = collateralAmount * 3 / 4; // fallback: keep 75%

            uint256 withdrawAmount = collateralAmount - minCollateral;
            MORPHO.withdrawCollateral(params, withdrawAmount, address(this), address(this));
        }

        // Step 2: Swap collateral → loan token via Odos
        uint256 actualCollateral = IERC20(collateralAsset).balanceOf(address(this));
        uint256 borrowBefore = IERC20(borrowAsset).balanceOf(address(this));
        IERC20(collateralAsset).forceApprove(ODOS_ROUTER, actualCollateral);
        (bool success, ) = ODOS_ROUTER.call(swapData);
        if (!success) revert Events.OperationFailed();
        IERC20(collateralAsset).forceApprove(ODOS_ROUTER, 0);

        uint256 received = IERC20(borrowAsset).balanceOf(address(this)) - borrowBefore;
        if (received < minAmountOut) revert Events.InsufficientBalance();

        // Step 3: Repay remaining debt (if any) with swap proceeds
        (, uint128 finalShares, ) = MORPHO.position(marketId, address(this));
        if (finalShares > 0) {
            uint256 availableAfter = IERC20(borrowAsset).balanceOf(address(this));
            IERC20(borrowAsset).forceApprove(address(MORPHO), availableAfter);
            MORPHO.repay(params, 0, finalShares, address(this), "");
        }

        // Step 4: Withdraw any remaining collateral (debt should be 0 now)
        (, , uint128 remainingCollateral) = MORPHO.position(marketId, address(this));
        if (remainingCollateral > 0) {
            MORPHO.withdrawCollateral(params, uint256(remainingCollateral), address(this), address(this));
        }

        // Reset storage
        s.collateralDeposited[marketId] = 0;
        s.assetBorrowed[marketId] = 0;
    }

    // ============ Internals ============

    /// @dev Compute Morpho market ID from MarketParams (same as Morpho's internal hashing)
    function _marketId(MarketParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }
}
