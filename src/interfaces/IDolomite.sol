// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

interface IDolomiteMargin {
    enum ActionType {
        Deposit, // 0: Supply tokens
        Withdraw, // 1: Borrow tokens or withdraw
        Transfer, // 2: Transfer between accounts
        Buy, // 3: Buy tokens
        Sell, // 4: Sell tokens
        Trade, // 5: Trade tokens
        Liquidate, // 6: Liquidate account
        Vaporize, // 7: Vaporize account
        Call // 8: Call external contract
    }

    enum AssetDenomination {
        Wei, // 0: Token amount
        Par // 1: Principal amount
    }

    enum AssetReference {
        Delta, // 0: Relative amount
        Target // 1: Absolute amount
    }

    struct AssetAmount {
        bool sign; // true = positive, false = negative
        AssetDenomination denomination;
        AssetReference ref;
        uint256 value;
    }

    struct ActionArgs {
        ActionType actionType;
        uint256 accountId;
        AssetAmount amount;
        uint256 primaryMarketId;
        uint256 secondaryMarketId;
        address otherAddress;
        uint256 otherAccountId;
        bytes data;
    }

    struct AccountInfo {
        address owner;
        uint256 number;
    }

    struct OperatorArg {
        address operator;
        bool trusted;
    }

    struct Wei {
        bool sign; // true = positive, false = negative
        uint256 value; // absolute value
    }

    function getAccountWei(
        AccountInfo memory account,
        uint256 marketId
    ) external view returns (Wei memory);

    function getAccountMarketsWithBalances(
        AccountInfo calldata account
    ) external view returns (uint256[] memory);

    function setOperators(OperatorArg[] calldata args) external;

    function operate(
        AccountInfo[] calldata accounts,
        ActionArgs[] calldata actions
    ) external;

    function getMarketIdByTokenAddress(
        address token
    ) external view returns (uint256);

    function getMarketTokenAddress(
        uint256 marketId
    ) external view returns (address);
}

interface IDepositWithdrawalRouter {
    enum EventFlag {
        None
    }

    function depositWei(
        uint256 isolationModeMarketId,
        uint256 toAccountNumber,
        uint256 marketId,
        uint256 amountWei,
        EventFlag eventFlag
    ) external;

    function withdrawWei(
        uint256 isolationModeMarketId,
        uint256 fromAccountNumber,
        uint256 marketId,
        uint256 amountWei,
        EventFlag eventFlag
    ) external;
}
library AccountBalanceLib {
    /// Checks that either BOTH, FROM, or TO accounts do not have negative balances
    enum BalanceCheckFlag {
        Both,
        From,
        To,
        None
    }
}
interface IBorrowPositionRouter {
    enum BalanceCheckFlag {
        Both,
        From,
        To,
        None
    }

    function getAccountWei(
        address owner,
        uint256 accountNumber,
        uint256 marketId
    ) external view returns (int256);

    function openBorrowPosition(
        uint256 _isolationModeMarketId,
        uint256 _fromAccountNumber,
        uint256 _toAccountNumber,
        uint256 _marketId,
        uint256 _amount,
        BalanceCheckFlag _balanceCheckFlag
    ) external;

    function transferBetweenAccounts(
        uint256 _isolationModeMarketId,
        uint256 _fromAccountNumber,
        uint256 _toAccountNumber,
        uint256 _marketId,
        uint256 _amount,
        BalanceCheckFlag _balanceCheckFlag
    ) external;

    /**
     * @param _isolationModeMarketId    The market ID of the isolation mode token (0 if not using isolation mode)
     * @param _fromAccountNumber        The account number containing repayment funds
     * @param _borrowAccountNumber      The account number containing the borrow position
     * @param _marketId                 The ID of the market to repay
     * @param _balanceCheckFlag         Flag indicating how to validate account balances
     */
    function repayAllForBorrowPosition(
        uint256 _isolationModeMarketId,
        uint256 _fromAccountNumber,
        uint256 _borrowAccountNumber,
        uint256 _marketId,
        AccountBalanceLib.BalanceCheckFlag _balanceCheckFlag
    ) external;

    /**
     * @param _isolationModeMarketId  The market ID of the isolation mode token
     *                                (0 if not using isolation mode)
     * @param _borrowAccountNumber    The account number containing the borrow position
     * @param _toAccountNumber        The account number to send remaining collateral to
     * @param _collateralMarketIds    Array of market IDs for collateral to be returned
     */
    function closeBorrowPosition(
        uint256 _isolationModeMarketId,
        uint256 _borrowAccountNumber,
        uint256 _toAccountNumber,
        uint256[] calldata _collateralMarketIds
    ) external;
}

interface IDolomiteIsolationModeToken {
    function getVaultByAccount(
        address _account
    ) external view returns (address);
}

interface IsolationModeUpgradeableProxy {
    /**
     * @notice Claims rewards from the underlying staking protocol
     * @dev This is the standard getReward function used by many reward vaults
     */
    function getReward() external;

    /**
     * @notice  End-user function for closing a borrow position involving the vault factory's underlying token. Should
     *          only be executable by the vault owner. Reverts if `_borrowAccountNumber` is 0 or if `_toAccountNumber`
     *          is not 0.
     */
    function closeBorrowPositionWithUnderlyingVaultToken(
        uint256 _borrowAccountNumber,
        uint256 _toAccountNumber
    ) external;

    function swapExactInputForOutputAndRemoveCollateral(
        uint256 _toAccountNumber,
        uint256 _borrowAccountNumber,
        uint256[] calldata _marketIdsPath,
        uint256 _inputAmountWei,
        uint256 _minOutputAmountWei,
        IGenericTraderBase.TraderParam[] calldata _tradersPath,
        IDolomiteMargin.AccountInfo[] calldata _makerAccounts,
        IGenericTraderProxyV2.UserConfig calldata _userConfig
    ) external payable;
}

interface IGenericTraderBase {
    enum TraderType {
        ExternalLiquidity,
        InternalLiquidity,
        IsolationModeUnwrapper,
        IsolationModeWrapper
    }

    struct TraderParam {
        TraderType traderType;
        uint256 makerAccountIndex;
        address trader;
        bytes tradeData;
    }
}

interface IGenericTraderProxyV2 {
    enum EventEmissionType {
        None,
        BorrowPosition,
        MarginPosition
    }

    struct TransferAmount {
        uint256 marketId;
        uint256 amountWei;
    }

    struct TransferCollateralParam {
        uint256 fromAccountNumber;
        uint256 toAccountNumber;
        TransferAmount[] transferAmounts;
    }

    struct UserConfig {
        uint256 deadline;
        AccountBalanceLib.BalanceCheckFlag balanceCheckFlag;
        EventEmissionType eventType;
    }

    struct ExpiryParam {
        uint256 marketId;
        uint32 expiryTimeDelta;
    }

    struct SwapExactInputForOutputParams {
        uint256 accountNumber;
        uint256[] marketIdsPath;
        uint256 inputAmountWei;
        uint256 minOutputAmountWei;
        IGenericTraderBase.TraderParam[] tradersPath;
        IDolomiteMargin.AccountInfo[] makerAccounts;
        UserConfig userConfig;
    }

    struct SwapExactInputForOutputAndModifyPositionParams {
        uint256 accountNumber;
        uint256[] marketIdsPath;
        uint256 inputAmountWei;
        uint256 minOutputAmountWei;
        IGenericTraderBase.TraderParam[] tradersPath;
        IDolomiteMargin.AccountInfo[] makerAccounts;
        TransferCollateralParam transferCollateralParams;
        ExpiryParam expiryParams;
        UserConfig userConfig;
    }
}

interface IGenericTraderRouter {
    /**
     * @param _isolationModeMarketId Market ID of isolation mode token (0 if not using isolation mode)
     * @param _params                Trading parameters including:
     *                              - accountNumber: Account to trade from
     *                              - marketIdsPath: Array of market IDs for trading path
     *                              - inputAmountWei: Amount to swap (uint(-1) for entire balance)
     *                              - minOutputAmountWei: Minimum output amount
     *                              - tradersPath: Array of traders to use
     *                              - makerAccounts: Accounts for internal liquidity trades
     *                              - userConfig: Deadline, balance checks, and event config
     */
    function swapExactInputForOutput(
        uint256 _isolationModeMarketId,
        IGenericTraderProxyV2.SwapExactInputForOutputParams memory _params
    ) external;

    /**
     * @param _isolationModeMarketId Market ID of isolation mode token (0 if not using isolation mode)
     * @param _params                Trading parameters including:
     *                              - All parameters from SwapExactInputForOutputParams
     *                              - transferCollateralParams: Collateral transfer config
     *                              - expiryParams: Position expiry settings
     */
    function swapExactInputForOutputAndModifyPosition(
        uint256 _isolationModeMarketId,
        IGenericTraderProxyV2.SwapExactInputForOutputAndModifyPositionParams memory _params
    ) external;
}

interface IOogaBoogaRouter {
    /// @dev Contains all information needed to describe the input and output for a swap
    struct swapTokenInfo {
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 outputQuote;
        uint256 outputMin;
        address outputReceiver;
    }
}
