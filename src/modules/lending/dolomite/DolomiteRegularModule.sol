// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DolomiteLendingBase} from "./DolomiteLendingBase.sol";
import {DolomiteStorage} from "../../../libraries/DolomiteStorage.sol";
import {Events} from "../../../libraries/Events.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDolomiteMargin, IDepositWithdrawalRouter} from "../../../interfaces/IDolomite.sol";

/// @title DolomiteRegularModule
/// @notice Universal Dolomite module for regular (non-isolation-mode) collateral.
///         Uses DolomiteMargin.operate() directly — works on any chain.
///
///         Architecture: single account (account 0) holds both collateral and debt.
///         - Supply: DepositWithdrawalRouter.depositWei(isolationModeMarketId=0)
///         - Borrow: DolomiteMargin.operate() with Withdraw action (negative = borrow)
///         - Repay:  DolomiteMargin.operate() with Deposit action (repay debt)
///         - Withdraw: DepositWithdrawalRouter.withdrawWei(isolationModeMarketId=0)
///
///         Chain-specific subclasses override _dolomiteMargin() and _swapRouter().
abstract contract DolomiteRegularModule is DolomiteLendingBase {
    using SafeERC20 for IERC20;

    // ============ Chain-specific (override in subclass) ============

    function _dolomiteMargin() internal view virtual returns (IDolomiteMargin);
    function _swapRouter() internal view virtual returns (address);

    // ============ Initialize ============

    function initializeModule() external payable virtual override onlyDelegatecall {
        IDolomiteMargin.OperatorArg[] memory args = new IDolomiteMargin.OperatorArg[](1);
        args[0] = IDolomiteMargin.OperatorArg({
            operator: address(DEPOSIT_WITHDRAWAL_ROUTER),
            trusted: true
        });
        _dolomiteMargin().setOperators(args);
    }

    // ============ Supply ============

    function supplyCollateral(
        address collateralAsset,
        uint256 _amount,
        uint256 _collateralMarketId
    ) external payable virtual override onlyDelegatecall {
        _supplyRegular(collateralAsset, _amount, _collateralMarketId);
    }

    // ============ Borrow ============

    function borrow(
        uint256 _borrowAmount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) external payable virtual override onlyDelegatecall {
        _borrowRegular(_borrowAmount, _collateralMarketId, _borrowMarketId);
    }

    // ============ Repay Debt ============

    function repayDebt(
        address borrowAssetAddr,
        uint256 _amount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) external payable virtual override onlyDelegatecall {
        _repayDebtRegular(borrowAssetAddr, _amount, _collateralMarketId, _borrowMarketId);
    }

    // ============ Withdraw Collateral ============

    function withdrawCollateral(
        uint256 _amount,
        uint256 _collateralMarketId
    ) external payable virtual override onlyDelegatecall {
        _withdrawCollateralRegular(_amount, _collateralMarketId);
    }

    // ============ Repay Debt With Collateral ============

    function repayDebtWithCollateral(
        address collateralAsset,
        address borrowAssetAddr,
        uint256 minAmountOut,
        uint256 /*expectedAmountOut*/,
        bytes calldata swapData,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) external payable virtual override onlyDelegatecall {
        _repayDebtWithCollateralRegular(
            collateralAsset, borrowAssetAddr, minAmountOut, swapData,
            _collateralMarketId, _borrowMarketId
        );
    }

    // ============ Regular Market Internals ============

    function _supplyRegular(
        address collateralAsset,
        uint256 _amount,
        uint256 _collateralMarketId
    ) internal {
        DolomiteStorage.Layout storage s = DolomiteStorage.layout();

        uint256 balance = IERC20(collateralAsset).balanceOf(address(this));
        uint256 amount = _amount == type(uint256).max ? balance : _amount;
        if (amount == 0) revert Events.ZeroAmount();
        if (amount > balance) revert Events.InsufficientBalance();

        IERC20(collateralAsset).forceApprove(address(DEPOSIT_WITHDRAWAL_ROUTER), amount);

        DEPOSIT_WITHDRAWAL_ROUTER.depositWei(
            0, // isolationModeMarketId = 0 for regular markets
            _accountForMarket(_collateralMarketId),
            _collateralMarketId,
            amount,
            IDepositWithdrawalRouter.EventFlag.None
        );

        s.collateralDeposited[_collateralMarketId] += amount;
        emit Events.CollateralSupplied(amount);
    }

    function _borrowRegular(
        uint256 _borrowAmount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) internal {
        if (_borrowAmount == 0) revert Events.ZeroAmount();
        DolomiteStorage.Layout storage s = DolomiteStorage.layout();
        IDolomiteMargin dolomite = _dolomiteMargin();

        uint256 acct = _accountForMarket(_collateralMarketId);
        IDolomiteMargin.AccountInfo[] memory accounts = new IDolomiteMargin.AccountInfo[](1);
        accounts[0] = IDolomiteMargin.AccountInfo({
            owner: address(this),
            number: acct
        });

        IDolomiteMargin.ActionArgs[] memory actions = new IDolomiteMargin.ActionArgs[](1);
        actions[0] = IDolomiteMargin.ActionArgs({
            actionType: IDolomiteMargin.ActionType.Withdraw,
            accountId: 0,
            amount: IDolomiteMargin.AssetAmount({
                sign: false, // negative = borrow
                denomination: IDolomiteMargin.AssetDenomination.Wei,
                ref: IDolomiteMargin.AssetReference.Delta,
                value: _borrowAmount
            }),
            primaryMarketId: _borrowMarketId,
            secondaryMarketId: 0,
            otherAddress: address(this),
            otherAccountId: 0,
            data: ""
        });

        dolomite.operate(accounts, actions);
        s.assetBorrowed[_borrowMarketId] += _borrowAmount;

        emit Events.AssetBorrowed(_borrowAmount);
    }

    function _repayDebtRegular(
        address borrowAssetAddr,
        uint256 _amount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) internal {
        DolomiteStorage.Layout storage s = DolomiteStorage.layout();
        IDolomiteMargin dolomite = _dolomiteMargin();

        uint256 repayAmount = _amount;
        if (repayAmount == 0) {
            repayAmount = (s.assetBorrowed[_borrowMarketId] * 107) / 100;
        }
        if (repayAmount == 0) revert Events.ZeroAmount();

        uint256 acct = _accountForMarket(_collateralMarketId);
        IERC20(borrowAssetAddr).forceApprove(address(dolomite), repayAmount);

        IDolomiteMargin.AccountInfo[] memory accounts = new IDolomiteMargin.AccountInfo[](1);
        accounts[0] = IDolomiteMargin.AccountInfo({
            owner: address(this),
            number: acct
        });

        IDolomiteMargin.ActionArgs[] memory actions = new IDolomiteMargin.ActionArgs[](1);
        actions[0] = IDolomiteMargin.ActionArgs({
            actionType: IDolomiteMargin.ActionType.Deposit,
            accountId: 0,
            amount: IDolomiteMargin.AssetAmount({
                sign: true,
                denomination: IDolomiteMargin.AssetDenomination.Wei,
                ref: IDolomiteMargin.AssetReference.Delta,
                value: repayAmount
            }),
            primaryMarketId: _borrowMarketId,
            secondaryMarketId: 0,
            otherAddress: address(this),
            otherAccountId: 0,
            data: ""
        });

        dolomite.operate(accounts, actions);

        s.assetBorrowed[_borrowMarketId] = 0;
        _withdrawCollateralInternal(s, 0, _collateralMarketId);

        emit Events.DebtRepaid(repayAmount);
    }

    function _withdrawCollateralRegular(
        uint256 _amount,
        uint256 _collateralMarketId
    ) internal {
        DolomiteStorage.Layout storage s = DolomiteStorage.layout();
        if (s.assetBorrowed[_collateralMarketId] > 0) revert Events.DebtExists();
        _withdrawCollateralInternal(s, _amount, _collateralMarketId);
    }

    function _repayDebtWithCollateralRegular(
        address collateralAsset,
        address borrowAssetAddr,
        uint256 minAmountOut,
        bytes calldata swapData,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) internal {
        DolomiteStorage.Layout storage s = DolomiteStorage.layout();
        IDolomiteMargin dolomite = _dolomiteMargin();
        uint256 acct = _accountForMarket(_collateralMarketId);

        // Step 1: Repay debt using vault's available borrow asset.
        //         This must happen BEFORE withdrawing collateral, because
        //         Dolomite checks account health after each operate/withdraw call.
        uint256 repayAmount = (s.assetBorrowed[_borrowMarketId] * 107) / 100;
        uint256 available = IERC20(borrowAssetAddr).balanceOf(address(this));
        if (available < repayAmount) repayAmount = available;
        if (repayAmount == 0) revert Events.ZeroAmount();

        IERC20(borrowAssetAddr).forceApprove(address(dolomite), repayAmount);

        IDolomiteMargin.AccountInfo[] memory accounts = new IDolomiteMargin.AccountInfo[](1);
        accounts[0] = IDolomiteMargin.AccountInfo({ owner: address(this), number: acct });

        IDolomiteMargin.ActionArgs[] memory actions = new IDolomiteMargin.ActionArgs[](1);
        actions[0] = IDolomiteMargin.ActionArgs({
            actionType: IDolomiteMargin.ActionType.Deposit,
            accountId: 0,
            amount: IDolomiteMargin.AssetAmount({
                sign: true,
                denomination: IDolomiteMargin.AssetDenomination.Wei,
                ref: IDolomiteMargin.AssetReference.Delta,
                value: repayAmount
            }),
            primaryMarketId: _borrowMarketId,
            secondaryMarketId: 0,
            otherAddress: address(this),
            otherAccountId: 0,
            data: ""
        });

        dolomite.operate(accounts, actions);

        // Step 2: Withdraw collateral (safe now — debt is repaid)
        IDolomiteMargin.Wei memory collWei = dolomite.getAccountWei(
            IDolomiteMargin.AccountInfo({ owner: address(this), number: acct }),
            _collateralMarketId
        );
        if (!collWei.sign || collWei.value == 0) revert Events.NoCollateralToZap();
        uint256 zapAmount = collWei.value;

        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            0, acct, _collateralMarketId, zapAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );

        // Step 3: Swap collateral → borrow asset via swap router
        address router = _swapRouter();
        uint256 borrowBefore = IERC20(borrowAssetAddr).balanceOf(address(this));
        IERC20(collateralAsset).forceApprove(router, zapAmount);
        (bool success, ) = router.call(swapData);
        if (!success) revert Events.OperationFailed();
        IERC20(collateralAsset).forceApprove(router, 0);

        uint256 received = IERC20(borrowAssetAddr).balanceOf(address(this)) - borrowBefore;
        if (received < minAmountOut) revert Events.InsufficientBalance();

        // Step 4: Withdraw any surplus borrow asset from Dolomite
        IDolomiteMargin.Wei memory borrowWei = dolomite.getAccountWei(
            IDolomiteMargin.AccountInfo({ owner: address(this), number: acct }),
            _borrowMarketId
        );
        if (borrowWei.sign && borrowWei.value > 0) {
            DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
                0, acct, _borrowMarketId, borrowWei.value,
                IDepositWithdrawalRouter.EventFlag.None
            );
        }

        s.assetBorrowed[_borrowMarketId] = 0;
        s.collateralDeposited[_collateralMarketId] = 0;

        emit Events.DebtRepaidWithCollateralAsset(received);
    }

    // ============ Shared Internal ============

    function _withdrawCollateralInternal(
        DolomiteStorage.Layout storage s,
        uint256 _amount,
        uint256 _collateralMarketId
    ) internal {
        uint256 deposited = s.collateralDeposited[_collateralMarketId];
        uint256 withdrawAmount = _amount == 0 ? deposited : _amount;
        if (withdrawAmount == 0) revert Events.ZeroAmount();
        if (withdrawAmount > deposited) revert Events.InsufficientBalance();

        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            0, // isolationModeMarketId = 0 for regular markets
            _accountForMarket(_collateralMarketId),
            _collateralMarketId,
            withdrawAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );

        s.collateralDeposited[_collateralMarketId] -= withdrawAmount;
        emit Events.CollateralWithdrawn(withdrawAmount);
    }
}
