// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title DolomiteVault - Berachain Dual Mode
 * @notice Owner-controlled vault supporting both isolation mode (iBGT) and non-isolation mode (WETH)
 * @dev Uses Dolomite account 0 for collateral, account 123 for iBGT borrows, account 456 for WETH borrows
 */

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDolomiteMargin {
    enum ActionType {
        Deposit,   // 0: Supply tokens
        Withdraw,  // 1: Borrow tokens or withdraw
        Transfer,  // 2: Transfer between accounts
        Buy,       // 3: Buy tokens
        Sell,      // 4: Sell tokens
        Trade,     // 5: Trade tokens
        Liquidate, // 6: Liquidate account
        Vaporize,  // 7: Vaporize account
        Call       // 8: Call external contract
    }

    enum AssetDenomination {
        Wei, // 0: Token amount
        Par  // 1: Principal amount
    }

    enum AssetReference {
        Delta,  // 0: Relative amount
        Target  // 1: Absolute amount
    }

    struct AssetAmount {
        bool sign;
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
    
    function setOperators(OperatorArg[] calldata args) external;
    function operate(AccountInfo[] calldata accounts, ActionArgs[] calldata actions) external;
    function getMarketIdByTokenAddress(address token) external view returns (uint256);
    function getAccountWei(AccountInfo calldata account, uint256 marketId) external view returns (bool sign, uint256 value);
}

interface IDepositWithdrawalRouter {
    enum EventFlag {
        None
    }
    
    // Isolation mode version (5 params)
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

interface IDepositWithdrawalRouterSimple {
    // Non-isolation mode version (3 params)
    function depositWei(
        uint256 toAccountNumber,
        uint256 marketId,
        uint256 amountWei
    ) external;
    
    function withdrawWei(
        uint256 fromAccountNumber,
        uint256 marketId,
        uint256 amountWei
    ) external;
}

library AccountBalanceLib {
    enum BalanceCheckFlag {
        Both,
        From,
        To,
        None
    }
}

interface IGenericTraderRouter {
    struct SwapExactInputForOutputParams {
        uint256 accountNumber;
        uint256[] marketIdsPath;
        uint256 inputAmountWei;
        uint256 minOutputAmountWei;
        IGenericTraderBase.TraderParam[] tradersPath;
        IDolomiteMargin.AccountInfo[] makerAccounts;
        UserConfig userConfig;
    }

    struct UserConfig {
        uint256 deadline;
        AccountBalanceLib.BalanceCheckFlag balanceCheckFlag;
        EventEmissionType eventType;
    }

    enum EventEmissionType { None, BorrowPosition, MarginPosition }

    function swapExactInputForOutput(
        uint256 _isolationModeMarketId,
        SwapExactInputForOutputParams calldata _params
    ) external;
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

interface IDolomiteIsolationModeToken {
    function getVaultByAccount(address account) external view returns (address);
}

interface IOogaBoogaRouter {
    struct swapTokenInfo {
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 outputQuote;
        uint256 outputMin;
        address outputReceiver;
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

    // Isolation mode version (6 params)
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

    function repayAllForBorrowPosition(
        uint256 _isolationModeMarketId,
        uint256 _fromAccountNumber,
        uint256 _borrowAccountNumber,
        uint256 _marketId,
        AccountBalanceLib.BalanceCheckFlag _balanceCheckFlag
    ) external;
    
    function closeBorrowPosition(
        uint256 _isolationModeMarketId,
        uint256 _borrowAccountNumber,
        uint256 _toAccountNumber,
        uint256[] calldata _collateralMarketIds
    ) external;
}

interface IBorrowPositionRouterSimple {
    enum BalanceCheckFlag {
        Both,
        From,
        To,
        None
    }

    // Non-isolation mode versions
    function openBorrowPosition(
        uint256 _fromAccountNumber,
        uint256 _toAccountNumber,
        uint256 _marketId,
        uint256 _amount,
        BalanceCheckFlag _balanceCheckFlag
    ) external;

    function transferBetweenAccounts(
        uint256 _fromAccountNumber,
        uint256 _toAccountNumber,
        uint256 _marketId,
        uint256 _amount,
        BalanceCheckFlag _balanceCheckFlag
    ) external;

    function repayAllForBorrowPosition(
        uint256 _fromAccountNumber,
        uint256 _borrowAccountNumber,
        uint256 _marketId,
        AccountBalanceLib.BalanceCheckFlag _balanceCheckFlag
    ) external;

    function closeBorrowPositionWithOtherTokens(
        uint256 _borrowAccountNumber,
        uint256 _toAccountNumber,
        uint256[] calldata _collateralMarketIds,
        AccountBalanceLib.BalanceCheckFlag _balanceCheckFlag
    ) external;
}

contract DolomiteVault {
    
    // ============================================
    // BERACHAIN ADDRESSES (HARDCODED)
    // ============================================
    
    // Dolomite contracts
    IDolomiteMargin public constant DOLOMITE_MARGIN = 
        IDolomiteMargin(0x003Ca23Fd5F0ca87D01F6eC6CD14A8AE60c2b97D);
    
    IDepositWithdrawalRouter public constant DEPOSIT_WITHDRAWAL_ROUTER = 
        IDepositWithdrawalRouter(0xf8b2c637A68cF6A17b1DF9F8992EeBeFf63d2dFf);
    
    IBorrowPositionRouter public constant BORROW_POSITION_ROUTER =
        IBorrowPositionRouter(0xF579b345cdA0860668b857De10ABD62442133D0F);

    IGenericTraderRouter public constant GENERIC_TRADER_ROUTER =
        IGenericTraderRouter(0x7b61CbA306CfdB02493b94757143132B1b72Bc6b);

    // OogaBooga / GenericTrader addresses
    address public constant DOLOMITE_OOGA_ADAPTER = 0x0CE205f7bCBa70E4c03f826918c8c21073386ED3;
    address public constant OOGABOOGA_EXECUTOR    = 0x27F66bA3fDa600239F48526Bb26A1F8D5700ccf7;
    address public constant DIBGT_UNWRAPPER_TRADER = 0x34E08961BFF5FE27b44F814A470970dB6e90108A;
    address public constant DIBGT_TOKEN = 0x589B3B5E75D5475908C6C2EBD1F2f68eeCA52eE4;
    uint256 public constant IBGT_MARKET_ID = 34; // Underlying iBGT market (not isolation wrapper)

    // Token addresses (HARDCODED - Berachain Bartio Testnet)
    address public constant IBGT_ADDRESS = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    address public constant USDC_ADDRESS = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant WETH_ADDRESS = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
    
    IERC20 public immutable iBGT;
    IERC20 public immutable USDC;
    IERC20 public immutable WETH;
    
    // Market IDs
    uint256 public immutable iBGTMarketId;
    uint256 public immutable USDCMarketId;
    uint256 public immutable WETHMarketId;
    uint256 public constant DIBGT_MARKET_ID = 38; // Isolation mode market ID
    
    // Owner
    address public owner;
    
    // Account numbers
    uint256 public constant VAULT_ACCOUNT = 0;        // Main collateral account
    uint256 public constant IBGT_BORROW_ACCOUNT = 123; // iBGT borrow position
    uint256 public constant WETH_BORROW_ACCOUNT = 456; // WETH borrow position
    
    // Position tracking - iBGT (isolation mode)
    uint256 public totaliBGTDeposited;
    uint256 public totalUSDCBorrowedFromiBGT;
    
    // Isolation proxy (set after first iBGT supply)
    address public isolationProxy;

    // Position tracking - WETH (non-isolation mode)
    uint256 public totalWETHDeposited;
    uint256 public totalUSDCBorrowedFromWETH;
    
    // Events
    event iBGTSupplied(uint256 amount);
    event USDCBorrowedFromiBGT(uint256 amount);
    event USDCRepaidToiBGT(uint256 amount);
    event iBGTWithdrawn(uint256 amount);
    
    event WETHSupplied(uint256 amount);
    event USDCBorrowedFromWETH(uint256 amount);
    event USDCRepaidToWETH(uint256 amount);
    event WETHWithdrawn(uint256 amount);
    
    event iBGTDebtRepaidWithCollateral(uint256 surplus);
    event WETHDebtRepaidWithCollateral(uint256 surplus);
    event ContractFunded(address indexed token, uint256 amount);
    event ContractWithdrawn(address indexed token, uint256 amount);
    event OperatorsSet(address[] operators, bool[] trusted);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Errors
    error Unauthorized();
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();
    error DebtExists();
    error InvalidAddress();
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    constructor() {
        owner = msg.sender;
        
        iBGT = IERC20(IBGT_ADDRESS);
        USDC = IERC20(USDC_ADDRESS);
        WETH = IERC20(WETH_ADDRESS);
        
        // Get market IDs
        iBGTMarketId = DOLOMITE_MARGIN.getMarketIdByTokenAddress(IBGT_ADDRESS);
        USDCMarketId = DOLOMITE_MARGIN.getMarketIdByTokenAddress(USDC_ADDRESS);
        WETHMarketId = DOLOMITE_MARGIN.getMarketIdByTokenAddress(WETH_ADDRESS);
        
        _setOperators();
    }
    
    function _setOperators() internal {
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

    // ============================================
    // IBGT FUNCTIONS (ISOLATION MODE)
    // ============================================
    
    function fundContractiBGT(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        bool success = iBGT.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        emit ContractFunded(IBGT_ADDRESS, amount);
    }

    function withdrawFromContractiBGT(uint256 amount) external onlyOwner {
        uint256 balance = iBGT.balanceOf(address(this));
        uint256 withdrawAmount = amount == 0 ? balance : amount;
        if (withdrawAmount > balance) revert InsufficientBalance();
        bool success = iBGT.transfer(owner, withdrawAmount);
        if (!success) revert TransferFailed();
        emit ContractWithdrawn(IBGT_ADDRESS, withdrawAmount);
    }

    function withdrawFromContractUSDC(uint256 amount) external onlyOwner {
        uint256 balance = USDC.balanceOf(address(this));
        uint256 withdrawAmount = amount == 0 ? balance : amount;
        if (withdrawAmount > balance) revert InsufficientBalance();
        bool success = USDC.transfer(owner, withdrawAmount);
        if (!success) revert TransferFailed();
        emit ContractWithdrawn(USDC_ADDRESS, withdrawAmount);
    }

    function supplyiBGT(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        
        uint256 contractBalance = iBGT.balanceOf(address(this));
        if (amount > contractBalance) revert InsufficientBalance();
        
        iBGT.approve(address(DEPOSIT_WITHDRAWAL_ROUTER), amount);
        
        DEPOSIT_WITHDRAWAL_ROUTER.depositWei(
            DIBGT_MARKET_ID,
            VAULT_ACCOUNT,
            DIBGT_MARKET_ID,
            amount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        totaliBGTDeposited += amount;

        // Record isolation proxy (created by diBGT token on first deposit)
        if (isolationProxy == address(0)) {
            isolationProxy = IDolomiteIsolationModeToken(DIBGT_TOKEN).getVaultByAccount(address(this));
        }

        emit iBGTSupplied(amount);
    }
    
    function borrowUSDCFromiBGT(uint256 borrowAmount) external onlyOwner {
        if (borrowAmount == 0) revert ZeroAmount();
        
        BORROW_POSITION_ROUTER.openBorrowPosition(
            DIBGT_MARKET_ID,
            VAULT_ACCOUNT,
            IBGT_BORROW_ACCOUNT,
            DIBGT_MARKET_ID,
            totaliBGTDeposited,
            IBorrowPositionRouter.BalanceCheckFlag.From
        );
        
        BORROW_POSITION_ROUTER.transferBetweenAccounts(
            DIBGT_MARKET_ID,
            IBGT_BORROW_ACCOUNT,
            VAULT_ACCOUNT,
            USDCMarketId,
            borrowAmount,
            IBorrowPositionRouter.BalanceCheckFlag.To
        );
        
        totalUSDCBorrowedFromiBGT += borrowAmount;
        
        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            0,
            VAULT_ACCOUNT,
            USDCMarketId,
            borrowAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        // bool success = USDC.transfer(owner, borrowAmount);
        // if (!success) revert TransferFailed();
        
        emit USDCBorrowedFromiBGT(borrowAmount);
    }
    
    function repayUSDCToiBGT(uint256 amount) external onlyOwner {
        uint256 repayAmount = amount == 0 ? (totalUSDCBorrowedFromiBGT * 102) / 100 : amount;
        if (repayAmount == 0) revert ZeroAmount();
        
        // bool success = USDC.transferFrom(msg.sender, address(this), repayAmount);
        // if (!success) revert TransferFailed();
        
        USDC.approve(address(DEPOSIT_WITHDRAWAL_ROUTER), repayAmount);
        
        DEPOSIT_WITHDRAWAL_ROUTER.depositWei(
            0,
            VAULT_ACCOUNT,
            USDCMarketId,
            repayAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        BORROW_POSITION_ROUTER.repayAllForBorrowPosition(
            DIBGT_MARKET_ID,
            VAULT_ACCOUNT,
            IBGT_BORROW_ACCOUNT,
            USDCMarketId,
            AccountBalanceLib.BalanceCheckFlag.From
        );
        
        BORROW_POSITION_ROUTER.transferBetweenAccounts(
            DIBGT_MARKET_ID,
            IBGT_BORROW_ACCOUNT,
            VAULT_ACCOUNT,
            DIBGT_MARKET_ID,
            totaliBGTDeposited,
            IBorrowPositionRouter.BalanceCheckFlag.None
        );
        
        totalUSDCBorrowedFromiBGT = 0;
        emit USDCRepaidToiBGT(repayAmount);
    }
    
    function withdrawiBGT(uint256 amount) external onlyOwner {
        if (totalUSDCBorrowedFromiBGT > 0) revert DebtExists();
        
        uint256 withdrawAmount = amount == 0 ? totaliBGTDeposited : amount;
        if (withdrawAmount == 0) revert ZeroAmount();
        if (withdrawAmount > totaliBGTDeposited) revert InsufficientBalance();
        
        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            DIBGT_MARKET_ID,
            VAULT_ACCOUNT,
            DIBGT_MARKET_ID,
            withdrawAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        totaliBGTDeposited -= withdrawAmount;
        
        bool success = iBGT.transfer(owner, withdrawAmount);
        if (!success) revert TransferFailed();
        
        emit iBGTWithdrawn(withdrawAmount);
    }

    /// @notice Repay iBGT-backed USDC debt by swapping collateral via GenericTrader + OogaBooga.
    ///         Operates entirely on BORROW_ACCOUNT (123) — avoids account 0.
    /// @param minAmountOut   Minimum USDC to accept from the swap
    /// @param expectedAmountOut Expected USDC output (used by OogaBooga adapter)
    /// @param pathDefinition OogaBooga pathDefinition bytes (from /v1/swap API)
    function repayiBGTDebtWithCollateral(
        uint256 minAmountOut,
        uint256 expectedAmountOut,
        bytes calldata pathDefinition
    ) external onlyOwner {
        // 1. Read collateral balance on the isolation proxy's BORROW_ACCOUNT (123)
        //    For isolation mode, the proxy (created by diBGT token) owns the Dolomite position
        IDolomiteMargin.AccountInfo memory borrowAcct = IDolomiteMargin.AccountInfo({
            owner: address(this),
            number: IBGT_BORROW_ACCOUNT
        });
        // Note: In isolation mode, getAccountWei must be called on the PROXY address.
        //       But GenericTraderRouter handles this internally — we just pass the collateral amount.
        uint256 zapAmount = totaliBGTDeposited;
        if (zapAmount == 0) revert ZeroAmount();

        // 2. Build GenericTrader path: [IsolationModeUnwrapper] → [OogaBooga swap]
        IGenericTraderBase.TraderParam[] memory tradersPath = new IGenericTraderBase.TraderParam[](2);

        // Step 1: Unwrap diBGT → iBGT (isolation mode unwrapper)
        tradersPath[0] = IGenericTraderBase.TraderParam({
            traderType: IGenericTraderBase.TraderType.IsolationModeUnwrapper,
            makerAccountIndex: 0,
            trader: DIBGT_UNWRAPPER_TRADER,
            tradeData: bytes("")
        });

        // Step 2: Swap iBGT → USDC via OogaBooga
        IOogaBoogaRouter.swapTokenInfo memory tokenInfo = IOogaBoogaRouter.swapTokenInfo({
            inputToken: IBGT_ADDRESS,
            inputAmount: zapAmount,
            outputToken: USDC_ADDRESS,
            outputQuote: expectedAmountOut,
            outputMin: minAmountOut,
            outputReceiver: DOLOMITE_OOGA_ADAPTER
        });

        tradersPath[1] = IGenericTraderBase.TraderParam({
            traderType: IGenericTraderBase.TraderType.ExternalLiquidity,
            makerAccountIndex: 0,
            trader: DOLOMITE_OOGA_ADAPTER,
            tradeData: abi.encode(tokenInfo, pathDefinition, OOGABOOGA_EXECUTOR, 2)
        });

        // 3. Market IDs path: diBGT (38) → iBGT (34) → USDC (2)
        uint256[] memory marketIdsPath = new uint256[](3);
        marketIdsPath[0] = DIBGT_MARKET_ID;
        marketIdsPath[1] = IBGT_MARKET_ID;
        marketIdsPath[2] = USDCMarketId;

        // 4. Execute the swap via GenericTraderRouter
        GENERIC_TRADER_ROUTER.swapExactInputForOutput(
            DIBGT_MARKET_ID,
            IGenericTraderRouter.SwapExactInputForOutputParams({
                accountNumber: IBGT_BORROW_ACCOUNT,
                marketIdsPath: marketIdsPath,
                inputAmountWei: zapAmount,
                minOutputAmountWei: minAmountOut,
                tradersPath: tradersPath,
                makerAccounts: new IDolomiteMargin.AccountInfo[](0),
                userConfig: IGenericTraderRouter.UserConfig({
                    deadline: block.timestamp + 300,
                    balanceCheckFlag: AccountBalanceLib.BalanceCheckFlag.Both,
                    eventType: IGenericTraderRouter.EventEmissionType.None
                })
            })
        );

        // 5. Read USDC surplus from isolation proxy's BORROW_ACCOUNT
        //    The isolation proxy owns the position — query via DolomiteMargin
        (bool sign, uint256 surplus) = DOLOMITE_MARGIN.getAccountWei(
            IDolomiteMargin.AccountInfo({ owner: isolationProxy, number: IBGT_BORROW_ACCOUNT }),
            USDCMarketId
        );

        // 6. If surplus USDC exists (positive balance), withdraw it
        if (sign && surplus > 0) {
            BORROW_POSITION_ROUTER.transferBetweenAccounts(
                DIBGT_MARKET_ID,
                IBGT_BORROW_ACCOUNT,
                VAULT_ACCOUNT,
                USDCMarketId,
                surplus,
                IBorrowPositionRouter.BalanceCheckFlag.None
            );

            DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
                0,
                VAULT_ACCOUNT,
                USDCMarketId,
                surplus,
                IDepositWithdrawalRouter.EventFlag.None
            );
        }

        // 7. Reset tracking
        totalUSDCBorrowedFromiBGT = 0;
        totaliBGTDeposited = 0;

        uint256 usdcBalance = USDC.balanceOf(address(this));
        emit iBGTDebtRepaidWithCollateral(usdcBalance);
    }

    // ============================================
    // WETH FUNCTIONS (NON-ISOLATION MODE)
    // ============================================
    
    function fundContractWETH(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        bool success = WETH.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        emit ContractFunded(WETH_ADDRESS, amount);
    }

    function withdrawFromContractWETH(uint256 amount) external onlyOwner {
        uint256 balance = WETH.balanceOf(address(this));
        uint256 withdrawAmount = amount == 0 ? balance : amount;
        if (withdrawAmount > balance) revert InsufficientBalance();
        bool success = WETH.transfer(owner, withdrawAmount);
        if (!success) revert TransferFailed();
        emit ContractWithdrawn(WETH_ADDRESS, withdrawAmount);
    }
    
    function supplyWETH(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();

        uint256 contractBalance = WETH.balanceOf(address(this));
        if (amount > contractBalance) revert InsufficientBalance();

        // On Berachain, use 5-param router with isolationModeMarketId=0 for regular tokens.
        // Deposit directly to WETH_BORROW_ACCOUNT — account 0 is blocked by AccountRiskOverrideSetter.
        WETH.approve(address(DEPOSIT_WITHDRAWAL_ROUTER), amount);

        DEPOSIT_WITHDRAWAL_ROUTER.depositWei(
            0, // isolationModeMarketId = 0 for regular markets
            WETH_BORROW_ACCOUNT,
            WETHMarketId,
            amount,
            IDepositWithdrawalRouter.EventFlag.None
        );

        totalWETHDeposited += amount;
        emit WETHSupplied(amount);
    }

    function borrowUSDCFromWETH(uint256 borrowAmount) external onlyOwner {
        if (borrowAmount == 0) revert ZeroAmount();

        // On Berachain, borrow via operate() on WETH_BORROW_ACCOUNT (456) directly.
        // Collateral is already in this account from supplyWETH.
        IDolomiteMargin.AccountInfo[] memory accounts = new IDolomiteMargin.AccountInfo[](1);
        accounts[0] = IDolomiteMargin.AccountInfo({
            owner: address(this),
            number: WETH_BORROW_ACCOUNT
        });

        IDolomiteMargin.ActionArgs[] memory actions = new IDolomiteMargin.ActionArgs[](1);
        actions[0] = IDolomiteMargin.ActionArgs({
            actionType: IDolomiteMargin.ActionType.Withdraw,
            accountId: 0,
            amount: IDolomiteMargin.AssetAmount({
                sign: false, // negative = borrow
                denomination: IDolomiteMargin.AssetDenomination.Wei,
                ref: IDolomiteMargin.AssetReference.Delta,
                value: borrowAmount
            }),
            primaryMarketId: USDCMarketId,
            secondaryMarketId: 0,
            otherAddress: address(this),
            otherAccountId: 0,
            data: ""
        });

        DOLOMITE_MARGIN.operate(accounts, actions);

        totalUSDCBorrowedFromWETH += borrowAmount;

        emit USDCBorrowedFromWETH(borrowAmount);
    }
    
    function repayUSDCToWETH(uint256 amount) external onlyOwner {
        uint256 repayAmount = amount == 0 ? (totalUSDCBorrowedFromWETH * 102) / 100 : amount;
        if (repayAmount == 0) revert ZeroAmount();

        // Deposit USDC into WETH_BORROW_ACCOUNT to repay debt via operate()
        USDC.approve(address(DOLOMITE_MARGIN), repayAmount);

        IDolomiteMargin.AccountInfo[] memory accounts = new IDolomiteMargin.AccountInfo[](1);
        accounts[0] = IDolomiteMargin.AccountInfo({
            owner: address(this),
            number: WETH_BORROW_ACCOUNT
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
            primaryMarketId: USDCMarketId,
            secondaryMarketId: 0,
            otherAddress: address(this),
            otherAccountId: 0,
            data: ""
        });

        DOLOMITE_MARGIN.operate(accounts, actions);

        totalUSDCBorrowedFromWETH = 0;
        emit USDCRepaidToWETH(repayAmount);
    }
    
    function withdrawWETH(uint256 amount) external onlyOwner {
        if (totalUSDCBorrowedFromWETH > 0) revert DebtExists();

        uint256 withdrawAmount = amount == 0 ? totalWETHDeposited : amount;
        if (withdrawAmount == 0) revert ZeroAmount();
        if (withdrawAmount > totalWETHDeposited) revert InsufficientBalance();

        // Withdraw from WETH_BORROW_ACCOUNT using 5-param router
        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            0, // isolationModeMarketId = 0 for regular markets
            WETH_BORROW_ACCOUNT,
            WETHMarketId,
            withdrawAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );

        totalWETHDeposited -= withdrawAmount;

        bool success = WETH.transfer(owner, withdrawAmount);
        if (!success) revert TransferFailed();

        emit WETHWithdrawn(withdrawAmount);
    }

    /// @notice Repay WETH-backed USDC debt by swapping collateral via GenericTrader + OogaBooga.
    ///         Operates entirely on WETH_BORROW_ACCOUNT (456) — no external token movement needed.
    /// @param minAmountOut   Minimum USDC to accept from the swap
    /// @param expectedAmountOut Expected USDC output (used by OogaBooga adapter)
    /// @param pathDefinition OogaBooga pathDefinition bytes (from /v1/swap API)
    function repayWETHDebtWithCollateral(
        uint256 minAmountOut,
        uint256 expectedAmountOut,
        bytes calldata pathDefinition
    ) external onlyOwner {
        uint256 zapAmount = totalWETHDeposited;
        if (zapAmount == 0) revert ZeroAmount();

        // 1. Build GenericTrader path: single step WETH → USDC via OogaBooga
        IGenericTraderBase.TraderParam[] memory tradersPath = new IGenericTraderBase.TraderParam[](1);

        IOogaBoogaRouter.swapTokenInfo memory tokenInfo = IOogaBoogaRouter.swapTokenInfo({
            inputToken: WETH_ADDRESS,
            inputAmount: zapAmount,
            outputToken: USDC_ADDRESS,
            outputQuote: expectedAmountOut,
            outputMin: minAmountOut,
            outputReceiver: DOLOMITE_OOGA_ADAPTER
        });

        tradersPath[0] = IGenericTraderBase.TraderParam({
            traderType: IGenericTraderBase.TraderType.ExternalLiquidity,
            makerAccountIndex: 0,
            trader: DOLOMITE_OOGA_ADAPTER,
            tradeData: abi.encode(tokenInfo, pathDefinition, OOGABOOGA_EXECUTOR, 2)
        });

        // 2. Market IDs path: WETH (0) → USDC (2)
        uint256[] memory marketIdsPath = new uint256[](2);
        marketIdsPath[0] = WETHMarketId;
        marketIdsPath[1] = USDCMarketId;

        // 3. Execute the swap via GenericTraderRouter (non-isolation mode: first param = 0)
        GENERIC_TRADER_ROUTER.swapExactInputForOutput(
            0, // non-isolation mode
            IGenericTraderRouter.SwapExactInputForOutputParams({
                accountNumber: WETH_BORROW_ACCOUNT,
                marketIdsPath: marketIdsPath,
                inputAmountWei: zapAmount,
                minOutputAmountWei: minAmountOut,
                tradersPath: tradersPath,
                makerAccounts: new IDolomiteMargin.AccountInfo[](0),
                userConfig: IGenericTraderRouter.UserConfig({
                    deadline: block.timestamp + 300,
                    balanceCheckFlag: AccountBalanceLib.BalanceCheckFlag.Both,
                    eventType: IGenericTraderRouter.EventEmissionType.None
                })
            })
        );

        // 4. Withdraw any USDC surplus from BORROW_ACCOUNT (456)
        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            0, // non-isolation mode
            WETH_BORROW_ACCOUNT,
            USDCMarketId,
            type(uint256).max,
            IDepositWithdrawalRouter.EventFlag.None
        );

        // 5. Reset tracking
        totalUSDCBorrowedFromWETH = 0;
        totalWETHDeposited = 0;

        uint256 usdcBalance = USDC.balanceOf(address(this));
        emit WETHDebtRepaidWithCollateral(usdcBalance);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================
    
    function getiBGTPosition() 
        external 
        view 
        returns (
            uint256 iBGTCollateral,
            uint256 USDCDebt,
            uint256 contractiBGT,
            uint256 contractUSDC
        ) 
    {
        iBGTCollateral = totaliBGTDeposited;
        USDCDebt = totalUSDCBorrowedFromiBGT;
        contractiBGT = iBGT.balanceOf(address(this));
        contractUSDC = USDC.balanceOf(address(this));
    }
    
    function getWETHPosition() 
        external 
        view 
        returns (
            uint256 WETHCollateral,
            uint256 USDCDebt,
            uint256 contractWETH,
            uint256 contractUSDC
        ) 
    {
        WETHCollateral = totalWETHDeposited;
        USDCDebt = totalUSDCBorrowedFromWETH;
        contractWETH = WETH.balanceOf(address(this));
        contractUSDC = USDC.balanceOf(address(this));
    }
    
    function getAllPositions()
        external
        view
        returns (
            uint256 iBGTCol,
            uint256 iBGTDebt,
            uint256 WETHCol,
            uint256 WETHDebt,
            uint256 totalDebt
        )
    {
        iBGTCol = totaliBGTDeposited;
        iBGTDebt = totalUSDCBorrowedFromiBGT;
        WETHCol = totalWETHDeposited;
        WETHDebt = totalUSDCBorrowedFromWETH;
        totalDebt = iBGTDebt + WETHDebt;
    }
    
    function getMarketIds() 
        external 
        view 
        returns (uint256 iBGTID, uint256 WETHID, uint256 USDCID) 
    {
        return (iBGTMarketId, WETHMarketId, USDCMarketId);
    }
    
    function getAddresses()
        external
        pure
        returns (address iBGTAddr, address WETHAddr, address USDCAddr)
    {
        return (IBGT_ADDRESS, WETH_ADDRESS, USDC_ADDRESS);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================
    
    function authorizeRouters() external onlyOwner {
        _setOperators();
    }
    
    function setOperators(address[] calldata operators, bool[] calldata trusted) external onlyOwner {
        require(operators.length == trusted.length, "Length mismatch");
        
        IDolomiteMargin.OperatorArg[] memory args = new IDolomiteMargin.OperatorArg[](operators.length);
        
        for (uint256 i = 0; i < operators.length; i++) {
            args[i] = IDolomiteMargin.OperatorArg({
                operator: operators[i],
                trusted: trusted[i]
            });
        }
        
        DOLOMITE_MARGIN.setOperators(args);
        emit OperatorsSet(operators, trusted);
    }
    
    function emergencyWithdraw(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroAmount();
        bool success = IERC20(token).transfer(owner, balance);
        if (!success) revert TransferFailed();
    }
    
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }
    
    receive() external payable {}
}