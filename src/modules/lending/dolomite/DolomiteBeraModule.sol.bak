// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DolomiteRegularModule} from "./DolomiteRegularModule.sol";
import {DolomiteStorage} from "../../../libraries/DolomiteStorage.sol";
import {Events} from "../../../libraries/Events.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IDolomiteMargin,
    IDepositWithdrawalRouter,
    AccountBalanceLib,
    IBorrowPositionRouter,
    IDolomiteIsolationModeToken,
    IsolationModeUpgradeableProxy,
    IGenericTraderRouter,
    IGenericTraderBase,
    IGenericTraderProxyV2,
    IOogaBoogaRouter
} from "../../../interfaces/IDolomite.sol";

/// @title DolomiteBeraModule
/// @notice Berachain Dolomite module — supports BOTH isolation-mode (diBGT) and
///         regular (WBTC/WETH) collateral in the same vault.
///
///         Per-call detection: checks isolationProxies[marketId] to decide which path.
///         - Isolation mode: BorrowPositionRouter + GenericTrader + OogaBooga
///         - Regular mode:   DolomiteMargin.operate() (inherited from DolomiteRegularModule)
contract DolomiteBeraModule is DolomiteRegularModule {
    using SafeERC20 for IERC20;

    // ============ Berachain Constants ============

    IDolomiteMargin internal constant DOLOMITE_MARGIN =
        IDolomiteMargin(0x003Ca23Fd5F0ca87D01F6eC6CD14A8AE60c2b97D);

    address public constant DOLOMITE_OOGA_ADAPTER = 0x0CE205f7bCBa70E4c03f826918c8c21073386ED3;
    address public constant OOGABOOGA_EXECUTOR    = 0x27F66bA3fDa600239F48526Bb26A1F8D5700ccf7;
    address public constant DIBGT_UNWRAPPER_TRADER = 0x34E08961BFF5FE27b44F814A470970dB6e90108A;

    /// @notice OogaBooga router (used as swap router for regular market repayDebtWithCollateral)
    address internal constant OOGABOOGA_ROUTER = 0x27F66bA3fDa600239F48526Bb26A1F8D5700ccf7;

    IGenericTraderRouter public constant GENERIC_TRADER_ROUTER =
        IGenericTraderRouter(0x7b61CbA306CfdB02493b94757143132B1b72Bc6b);

    uint256 public constant IBGT_MARKET_ID = 34;

    // ============ Chain-specific overrides ============

    function _dolomiteMargin() internal view override returns (IDolomiteMargin) {
        return DOLOMITE_MARGIN;
    }

    function _swapRouter() internal view override returns (address) {
        return OOGABOOGA_ROUTER;
    }

    // ============ Initialize ============

    function initializeModule() external payable override onlyDelegatecall {
        IDolomiteMargin.OperatorArg[] memory args = new IDolomiteMargin.OperatorArg[](3);
        args[0] = IDolomiteMargin.OperatorArg({
            operator: address(DEPOSIT_WITHDRAWAL_ROUTER),
            trusted: true
        });
        args[1] = IDolomiteMargin.OperatorArg({
            operator: address(BORROW_POSITION_ROUTER),
            trusted: true
        });
        args[2] = IDolomiteMargin.OperatorArg({
            operator: address(GENERIC_TRADER_ROUTER),
            trusted: true
        });
        DOLOMITE_MARGIN.setOperators(args);
    }

    // ============ Supply (branches on market type) ============

    function supplyCollateral(
        address collateralAsset,
        uint256 _amount,
        uint256 _collateralMarketId
    ) external payable override onlyDelegatecall {
        DolomiteStorage.Layout storage s = DolomiteStorage.layout();

        // Already known isolation-mode market
        if (s.isolationProxies[_collateralMarketId] != address(0)) {
            _supplyIsolation(s, collateralAsset, _amount, _collateralMarketId);
            return;
        }

        // Detect isolation mode BEFORE depositing: if the market token supports
        // getVaultByAccount(), it's an isolation-mode wrapper (diBGT etc.)
        bool isIsolation = _detectIsolationMode(_collateralMarketId);

        if (isIsolation) {
            _supplyIsolation(s, collateralAsset, _amount, _collateralMarketId);
            // After first isolation deposit, Dolomite creates a proxy — record it
            address marketToken = DOLOMITE_MARGIN.getMarketTokenAddress(_collateralMarketId);
            try IDolomiteIsolationModeToken(marketToken).getVaultByAccount(address(this)) returns (address proxy) {
                if (proxy != address(0)) {
                    s.isolationProxies[_collateralMarketId] = proxy;
                }
            } catch {}
        } else {
            // On Berachain, deposit regular collateral to per-market account.
            // Account 0 cannot participate in borrow operations on Berachain.
            _supplyRegularBera(s, collateralAsset, _amount, _collateralMarketId);
        }
    }

    // ============ Borrow (branches on market type) ============

    function borrow(
        uint256 _borrowAmount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) external payable override onlyDelegatecall {
        DolomiteStorage.Layout storage s = DolomiteStorage.layout();

        if (s.isolationProxies[_collateralMarketId] != address(0)) {
            _borrowIsolation(s, _borrowAmount, _collateralMarketId, _borrowMarketId);
        } else {
            _borrowRegularBera(s, _borrowAmount, _collateralMarketId, _borrowMarketId);
        }
    }

    // ============ Repay Debt (branches on market type) ============

    function repayDebt(
        address borrowAssetAddr,
        uint256 _amount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) external payable override onlyDelegatecall {
        DolomiteStorage.Layout storage s = DolomiteStorage.layout();

        if (s.isolationProxies[_collateralMarketId] != address(0)) {
            _repayDebtIsolation(s, borrowAssetAddr, _amount, _collateralMarketId, _borrowMarketId);
        } else {
            _repayDebtRegularBera(s, borrowAssetAddr, _amount, _collateralMarketId, _borrowMarketId);
        }
    }

    // ============ Withdraw Collateral (branches on market type) ============

    function withdrawCollateral(
        uint256 _amount,
        uint256 _collateralMarketId
    ) external payable override onlyDelegatecall {
        DolomiteStorage.Layout storage s = DolomiteStorage.layout();

        if (s.isolationProxies[_collateralMarketId] != address(0)) {
            _withdrawCollateralIsolation(s, _amount, _collateralMarketId);
        } else {
            if (s.assetBorrowed[_collateralMarketId] > 0) revert Events.DebtExists();
            _withdrawCollateralBera(s, _amount, _collateralMarketId);
        }
    }

    // ============ Repay Debt With Collateral (branches on market type) ============

    function repayDebtWithCollateral(
        address collateralAsset,
        address borrowAssetAddr,
        uint256 minAmountOut,
        uint256 expectedAmountOut,
        bytes calldata swapData,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) external payable override onlyDelegatecall {
        DolomiteStorage.Layout storage s = DolomiteStorage.layout();

        if (s.isolationProxies[_collateralMarketId] != address(0)) {
            _repayDebtWithCollateralIsolation(
                s, collateralAsset, borrowAssetAddr, minAmountOut, expectedAmountOut,
                swapData, _collateralMarketId, _borrowMarketId
            );
        } else {
            _repayDebtWithCollateralRegularBera(
                s, collateralAsset, borrowAssetAddr, minAmountOut, swapData,
                _collateralMarketId, _borrowMarketId
            );
        }
    }

    // ============ Berachain-only Functions ============

    function setIsolationProxy(uint256 marketId, address _proxy) external payable onlyDelegatecall {
        if (_proxy == address(0)) revert Events.ZeroAddress();
        DolomiteStorage.layout().isolationProxies[marketId] = _proxy;
    }

    function claimRewards(uint256 marketId) external payable onlyDelegatecall {
        DolomiteStorage.Layout storage s = DolomiteStorage.layout();
        address proxy = s.isolationProxies[marketId];
        if (proxy == address(0)) revert Events.ZeroAddress();
        IsolationModeUpgradeableProxy(proxy).getReward();
        emit Events.ClaimedRewards();
    }

    // ============ Bera Regular Market Internals ============
    // On Berachain, account 0 cannot have debt (AccountRiskOverrideSetter blocks it).
    // For regular markets, we use per-market accounts (1000 + marketId) for BOTH collateral
    // and debt, bypassing account 0 entirely. Each position gets its own isolated account.

    function _supplyRegularBera(
        DolomiteStorage.Layout storage s,
        address collateralAsset,
        uint256 _amount,
        uint256 _collateralMarketId
    ) internal {
        uint256 balance = IERC20(collateralAsset).balanceOf(address(this));
        uint256 amount = _amount == type(uint256).max ? balance : _amount;
        if (amount == 0) revert Events.ZeroAmount();
        if (amount > balance) revert Events.InsufficientBalance();

        // Deposit to per-market account — never touches account 0
        uint256 acct = _accountForMarket(_collateralMarketId);
        IERC20(collateralAsset).forceApprove(address(DEPOSIT_WITHDRAWAL_ROUTER), amount);
        DEPOSIT_WITHDRAWAL_ROUTER.depositWei(
            0, // isolationModeMarketId = 0 for regular markets
            acct,
            _collateralMarketId,
            amount,
            IDepositWithdrawalRouter.EventFlag.None
        );

        s.collateralDeposited[_collateralMarketId] += amount;
        emit Events.CollateralSupplied(amount);
    }

    function _borrowRegularBera(
        DolomiteStorage.Layout storage s,
        uint256 _borrowAmount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) internal {
        if (_borrowAmount == 0) revert Events.ZeroAmount();
        IDolomiteMargin dolomite = _dolomiteMargin();

        // Borrow via operate() on per-market account — avoids account 0
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

    function _repayDebtRegularBera(
        DolomiteStorage.Layout storage s,
        address borrowAssetAddr,
        uint256 _amount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) internal {
        IDolomiteMargin dolomite = _dolomiteMargin();

        uint256 repayAmount = _amount;
        if (repayAmount == 0) {
            repayAmount = (s.assetBorrowed[_borrowMarketId] * 107) / 100;
        }
        if (repayAmount == 0) revert Events.ZeroAmount();

        // Repay via operate() on per-market account — deposit borrow asset
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
        // Withdraw collateral from per-market account
        _withdrawCollateralBera(s, 0, _collateralMarketId);

        emit Events.DebtRepaid(repayAmount);
    }

    function _withdrawCollateralBera(
        DolomiteStorage.Layout storage s,
        uint256 _amount,
        uint256 _collateralMarketId
    ) internal {
        uint256 deposited = s.collateralDeposited[_collateralMarketId];
        uint256 withdrawAmount = _amount == 0 ? deposited : _amount;
        if (withdrawAmount == 0) revert Events.ZeroAmount();
        if (withdrawAmount > deposited) revert Events.InsufficientBalance();

        // Withdraw from per-market account
        uint256 acct = _accountForMarket(_collateralMarketId);
        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            0,
            acct,
            _collateralMarketId,
            withdrawAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );

        s.collateralDeposited[_collateralMarketId] -= withdrawAmount;
        emit Events.CollateralWithdrawn(withdrawAmount);
    }

    function _repayDebtWithCollateralRegularBera(
        DolomiteStorage.Layout storage s,
        address collateralAsset,
        address borrowAssetAddr,
        uint256 minAmountOut,
        bytes calldata swapData,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) internal {
        IDolomiteMargin dolomite = _dolomiteMargin();

        // Collateral is on per-market account
        uint256 acct = _accountForMarket(_collateralMarketId);
        IDolomiteMargin.Wei memory collWei = dolomite.getAccountWei(
            IDolomiteMargin.AccountInfo({ owner: address(this), number: acct }),
            _collateralMarketId
        );
        if (!collWei.sign || collWei.value == 0) revert Events.NoCollateralToZap();
        uint256 zapAmount = collWei.value;

        // Withdraw collateral from per-market account
        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            0, acct, _collateralMarketId, zapAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );

        // Swap collateral → borrow asset via swap router
        address router = _swapRouter();
        uint256 borrowBefore = IERC20(borrowAssetAddr).balanceOf(address(this));
        IERC20(collateralAsset).forceApprove(router, zapAmount);
        (bool success, ) = router.call(swapData);
        if (!success) revert Events.OperationFailed();
        IERC20(collateralAsset).forceApprove(router, 0);

        uint256 received = IERC20(borrowAssetAddr).balanceOf(address(this)) - borrowBefore;
        if (received < minAmountOut) revert Events.InsufficientBalance();

        // Repay via operate() on per-market account
        IERC20(borrowAssetAddr).forceApprove(address(dolomite), received);

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
                value: received
            }),
            primaryMarketId: _borrowMarketId,
            secondaryMarketId: 0,
            otherAddress: address(this),
            otherAccountId: 0,
            data: ""
        });

        dolomite.operate(accounts, actions);

        // Check debt is fully repaid
        IDolomiteMargin.Wei memory borrowWei = dolomite.getAccountWei(
            IDolomiteMargin.AccountInfo({ owner: address(this), number: acct }),
            _borrowMarketId
        );
        if (!borrowWei.sign && borrowWei.value > 0) revert Events.DebtNotFullyRepaid();

        // Withdraw any surplus from per-market account
        if (borrowWei.sign && borrowWei.value > 0) {
            DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
                0, acct, _borrowMarketId, borrowWei.value,
                IDepositWithdrawalRouter.EventFlag.None
            );
        }

        s.assetBorrowed[_borrowMarketId] = 0;
        s.collateralDeposited[_collateralMarketId] = 0;

        emit Events.DebtRepaidWithCollateralAsset(borrowWei.sign ? borrowWei.value : 0);
    }

    // ============ Isolation Mode Internals ============

    function _supplyIsolation(
        DolomiteStorage.Layout storage s,
        address collateralAsset,
        uint256 _amount,
        uint256 _collateralMarketId
    ) internal {
        uint256 balance = IERC20(collateralAsset).balanceOf(address(this));
        uint256 amount = _amount == type(uint256).max ? balance : _amount;
        if (amount == 0) revert Events.ZeroAmount();
        if (amount > balance) revert Events.InsufficientBalance();

        IERC20(collateralAsset).forceApprove(address(DEPOSIT_WITHDRAWAL_ROUTER), amount);

        DEPOSIT_WITHDRAWAL_ROUTER.depositWei(
            _collateralMarketId, // isolationModeMarketId = collateralMarketId
            MAIN_ACCOUNT,
            _collateralMarketId,
            amount,
            IDepositWithdrawalRouter.EventFlag.None
        );

        s.collateralDeposited[_collateralMarketId] += amount;
        emit Events.CollateralSupplied(amount);
    }

    function _borrowIsolation(
        DolomiteStorage.Layout storage s,
        uint256 _borrowAmount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) internal {
        if (_borrowAmount == 0) revert Events.ZeroAmount();

        BORROW_POSITION_ROUTER.openBorrowPosition(
            _collateralMarketId, // isolationModeMarketId
            MAIN_ACCOUNT,
            BORROW_ACCOUNT,
            _collateralMarketId,
            s.collateralDeposited[_collateralMarketId],
            IBorrowPositionRouter.BalanceCheckFlag.From
        );

        BORROW_POSITION_ROUTER.transferBetweenAccounts(
            _collateralMarketId, // isolationModeMarketId
            BORROW_ACCOUNT,
            MAIN_ACCOUNT,
            _borrowMarketId,
            _borrowAmount,
            IBorrowPositionRouter.BalanceCheckFlag.To
        );

        s.assetBorrowed[_borrowMarketId] += _borrowAmount;

        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            0,
            MAIN_ACCOUNT,
            _borrowMarketId,
            _borrowAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );

        emit Events.AssetBorrowed(_borrowAmount);
    }

    function _repayDebtIsolation(
        DolomiteStorage.Layout storage s,
        address borrowAssetAddr,
        uint256 _amount,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) internal {
        uint256 repayAmount = _amount;
        if (repayAmount == 0) {
            (, int256 borrowBalance) = _getDebtAccountBalance(_collateralMarketId, _borrowMarketId);
            if (borrowBalance < 0) {
                repayAmount = (uint256(-borrowBalance) * 107) / 100;
            } else {
                repayAmount = (s.assetBorrowed[_borrowMarketId] * 107) / 100;
            }
        }
        if (repayAmount == 0) revert Events.ZeroAmount();

        IERC20(borrowAssetAddr).forceApprove(address(DEPOSIT_WITHDRAWAL_ROUTER), repayAmount);

        DEPOSIT_WITHDRAWAL_ROUTER.depositWei(
            0,
            MAIN_ACCOUNT,
            _borrowMarketId,
            repayAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );

        BORROW_POSITION_ROUTER.repayAllForBorrowPosition(
            _collateralMarketId, // isolationModeMarketId
            MAIN_ACCOUNT,
            BORROW_ACCOUNT,
            _borrowMarketId,
            AccountBalanceLib.BalanceCheckFlag.From
        );

        // Close via isolation proxy
        address proxy = s.isolationProxies[_collateralMarketId];
        IsolationModeUpgradeableProxy(proxy)
            .closeBorrowPositionWithUnderlyingVaultToken(BORROW_ACCOUNT, MAIN_ACCOUNT);

        s.assetBorrowed[_borrowMarketId] = 0;
        _withdrawCollateralIsolationInternal(s, 0, _collateralMarketId);

        emit Events.DebtRepaid(repayAmount);
    }

    function _withdrawCollateralIsolation(
        DolomiteStorage.Layout storage s,
        uint256 _amount,
        uint256 _collateralMarketId
    ) internal {
        // For isolation mode, check debt on the borrow market — but we don't know which
        // borrow market here. The caller must ensure debt is zero before calling.
        _withdrawCollateralIsolationInternal(s, _amount, _collateralMarketId);
    }

    function _withdrawCollateralIsolationInternal(
        DolomiteStorage.Layout storage s,
        uint256 _amount,
        uint256 _collateralMarketId
    ) internal {
        uint256 deposited = s.collateralDeposited[_collateralMarketId];
        uint256 withdrawAmount = _amount == 0 ? deposited : _amount;
        if (withdrawAmount == 0) revert Events.ZeroAmount();
        if (withdrawAmount > deposited) revert Events.InsufficientBalance();

        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            _collateralMarketId, // isolationModeMarketId = collateralMarketId
            MAIN_ACCOUNT,
            _collateralMarketId,
            withdrawAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );

        s.collateralDeposited[_collateralMarketId] -= withdrawAmount;
        emit Events.CollateralWithdrawn(withdrawAmount);
    }

    function _repayDebtWithCollateralIsolation(
        DolomiteStorage.Layout storage s,
        address collateralAsset,
        address borrowAssetAddr,
        uint256 minAmountOut,
        uint256 expectedAmountOut,
        bytes calldata swapData,
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) internal {
        (int256 collateralBalance, ) = _getDebtAccountBalance(_collateralMarketId, _borrowMarketId);
        if (collateralBalance <= 0) revert Events.NoCollateralToZap();
        uint256 zapAmount = uint256(collateralBalance);

        IGenericTraderBase.TraderParam[] memory tradersPath = new IGenericTraderBase.TraderParam[](2);

        tradersPath[0] = IGenericTraderBase.TraderParam({
            traderType: IGenericTraderBase.TraderType.IsolationModeUnwrapper,
            makerAccountIndex: 0,
            trader: DIBGT_UNWRAPPER_TRADER,
            tradeData: bytes("")
        });

        IOogaBoogaRouter.swapTokenInfo memory tokenInfo = IOogaBoogaRouter.swapTokenInfo({
            inputToken: collateralAsset,
            inputAmount: zapAmount,
            outputToken: borrowAssetAddr,
            outputQuote: expectedAmountOut,
            outputMin: minAmountOut,
            outputReceiver: DOLOMITE_OOGA_ADAPTER
        });

        tradersPath[1] = IGenericTraderBase.TraderParam({
            traderType: IGenericTraderBase.TraderType.ExternalLiquidity,
            makerAccountIndex: 0,
            trader: DOLOMITE_OOGA_ADAPTER,
            tradeData: abi.encode(tokenInfo, swapData, OOGABOOGA_EXECUTOR, 2)
        });

        uint256[] memory marketIdsPath = new uint256[](3);
        marketIdsPath[0] = _collateralMarketId;
        marketIdsPath[1] = IBGT_MARKET_ID;
        marketIdsPath[2] = _borrowMarketId;

        GENERIC_TRADER_ROUTER.swapExactInputForOutput(
            _collateralMarketId,
            IGenericTraderProxyV2.SwapExactInputForOutputParams({
                accountNumber: BORROW_ACCOUNT,
                marketIdsPath: marketIdsPath,
                inputAmountWei: zapAmount,
                minOutputAmountWei: minAmountOut,
                tradersPath: tradersPath,
                makerAccounts: new IDolomiteMargin.AccountInfo[](0),
                userConfig: IGenericTraderProxyV2.UserConfig({
                    deadline: block.timestamp + 300,
                    balanceCheckFlag: AccountBalanceLib.BalanceCheckFlag.Both,
                    eventType: IGenericTraderProxyV2.EventEmissionType.None
                })
            })
        );

        (, int256 remainingBorrow) = _getDebtAccountBalance(_collateralMarketId, _borrowMarketId);
        if (remainingBorrow < 0) revert Events.DebtNotFullyRepaid();

        s.assetBorrowed[_borrowMarketId] = 0;
        s.collateralDeposited[_collateralMarketId] = 0;

        uint256 surplus = uint256(remainingBorrow);
        if (surplus > 0) {
            BORROW_POSITION_ROUTER.transferBetweenAccounts(
                _collateralMarketId,
                BORROW_ACCOUNT,
                MAIN_ACCOUNT,
                _borrowMarketId,
                surplus,
                IBorrowPositionRouter.BalanceCheckFlag.None
            );
            DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
                0, MAIN_ACCOUNT, _borrowMarketId, surplus,
                IDepositWithdrawalRouter.EventFlag.None
            );
        }

        emit Events.DebtRepaidWithCollateralAsset(surplus);
    }

    // ============ Isolation Mode Helpers ============

    function _positionOwner(uint256 collateralMarketId) internal view returns (address) {
        address proxy = DolomiteStorage.layout().isolationProxies[collateralMarketId];
        if (proxy != address(0)) return proxy;
        address marketToken = DOLOMITE_MARGIN.getMarketTokenAddress(collateralMarketId);
        address found = IDolomiteIsolationModeToken(marketToken).getVaultByAccount(address(this));
        return found != address(0) ? found : address(this);
    }

    function _getDebtAccountBalance(
        uint256 _collateralMarketId,
        uint256 _borrowMarketId
    ) internal view returns (int256 collateralBalance, int256 borrowBalance) {
        address owner = _positionOwner(_collateralMarketId);
        // Isolation mode uses BORROW_ACCOUNT within the proxy; regular uses per-market account
        bool isIso = DolomiteStorage.layout().isolationProxies[_collateralMarketId] != address(0);
        uint256 acct = isIso ? BORROW_ACCOUNT : _accountForMarket(_collateralMarketId);

        IDolomiteMargin.Wei memory collateralWei = DOLOMITE_MARGIN.getAccountWei(
            IDolomiteMargin.AccountInfo({ owner: owner, number: acct }),
            _collateralMarketId
        );
        IDolomiteMargin.Wei memory borrowWei = DOLOMITE_MARGIN.getAccountWei(
            IDolomiteMargin.AccountInfo({ owner: owner, number: acct }),
            _borrowMarketId
        );

        collateralBalance = collateralWei.sign ? int256(collateralWei.value) : -int256(collateralWei.value);
        borrowBalance     = borrowWei.sign     ? int256(borrowWei.value)     : -int256(borrowWei.value);
    }

    /// @dev Detect if a Dolomite market is isolation mode by probing the market token
    ///      for getVaultByAccount(). Isolation-mode tokens implement this; regular tokens don't.
    ///      Uses low-level staticcall to avoid false positives from fallback functions.
    function _detectIsolationMode(uint256 marketId) internal view returns (bool) {
        address marketToken = DOLOMITE_MARGIN.getMarketTokenAddress(marketId);
        (bool success, bytes memory data) = marketToken.staticcall(
            abi.encodeCall(IDolomiteIsolationModeToken.getVaultByAccount, (address(this)))
        );
        // Must succeed AND return at least 32 bytes (a valid ABI-encoded address)
        return success && data.length >= 32;
    }
}
