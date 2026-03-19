// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title DolomiteVault - Berachain
 * @notice Owner-controlled vault that deposits iBGT to Dolomite and borrows USDC on Berachain
 * @dev Uses Dolomite account 0 (default account for the contract address)
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
        bool sign;                  // true = positive, false = negative
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

    function operate(
        AccountInfo[] calldata accounts,
        ActionArgs[] calldata actions
    ) external;

    function getMarketIdByTokenAddress(address token) external view returns (uint256);
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
        uint256 _fromAccountNumber,
        uint256 _toAccountNumber,
        uint256 _marketId,
        uint256 _amount,
        BalanceCheckFlag _balanceCheckFlag
    ) external;

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

contract DolomiteVault {
    
    // Dolomite contract addresses on Berachain
    IDolomiteMargin public constant DOLOMITE_MARGIN = 
        IDolomiteMargin(0x003Ca23Fd5F0ca87D01F6eC6CD14A8AE60c2b97D);
    
    IDepositWithdrawalRouter public constant DEPOSIT_WITHDRAWAL_ROUTER = 
        IDepositWithdrawalRouter(0xf8b2c637A68cF6A17b1DF9F8992EeBeFf63d2dFf);

    IBorrowPositionRouter public constant BORROW_POSITION_ROUTER = 
        IBorrowPositionRouter(0xF579b345cdA0860668b857De10ABD62442133D0F);
    
    // Token addresses
    IERC20 public immutable iBGT;
    IERC20 public immutable USDC;
    
    // Market IDs
    uint256 public immutable iBGTMarketId;
    uint256 public immutable USDCMarketId;
    
    // Owner
    address public owner;
    
    // Use Dolomite account 0 (default account for this contract)
    uint256 public constant VAULT_ACCOUNT = 0;
    uint256 public constant BORROW_ACCOUNT = 123;
    uint256 public constant DIBGT_MARKET_ID = 38;
    
    // Position tracking
    uint256 public totaliBGTDeposited;
    uint256 public totalUSDCBorrowed;
    
    // Events
    event iBGTSupplied(uint256 amount);
    event USDCBorrowed(uint256 amount);
    event USDCRepaid(uint256 amount);
    event iBGTWithdrawn(uint256 amount);
    event ContractFunded(uint256 amount);
    event ContractWithdrawn(uint256 amount);
    event OperatorsSet(address[] operators, bool[] trusted);
    event BorrowPositionOpened(uint256 collateralAmount, uint256 borrowAmount);
    
    // Errors
    error Unauthorized();
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();
    error DebtExists();
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    /**
     * @notice Constructor
     * @param _iBGT iBGT token address on Berachain
     * @param _USDC USDC token address on Berachain (or WBERA: 0x6969696969696969696969696969696969696969)
     */
    constructor(address _iBGT, address _USDC) {
        require(_iBGT != address(0), "Invalid iBGT");
        require(_USDC != address(0), "Invalid USDC");
        
        owner = msg.sender;
        iBGT = IERC20(_iBGT);
        USDC = IERC20(_USDC);
        
        // Get market IDs from Dolomite
        iBGTMarketId = DOLOMITE_MARGIN.getMarketIdByTokenAddress(_iBGT);
        USDCMarketId = DOLOMITE_MARGIN.getMarketIdByTokenAddress(_USDC);
        
        // Authorize routers as operators (for deposit/withdraw)
        _setOperators();
    }
    
    /**
     * @notice Internal function to authorize Dolomite routers
     * @dev Must be called to allow routers to manipulate this contract's accounts
     */
    function _setOperators() internal {
        IDolomiteMargin.OperatorArg[] memory args = new IDolomiteMargin.OperatorArg[](1);
        
        args[0] = IDolomiteMargin.OperatorArg({
            operator: address(DEPOSIT_WITHDRAWAL_ROUTER),
            trusted: true
        });
        
        DOLOMITE_MARGIN.setOperators(args);
    }

    // ============ Contract Balance Management ============

    /**
     * @notice Transfer iBGT from owner to contract
     * @param amount Amount of iBGT to transfer
     */
    function fundContract(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        
        bool success = iBGT.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        
        emit ContractFunded(amount);
    }

    /**
     * @notice Withdraw iBGT from contract balance (not from Dolomite)
     * @param amount Amount to withdraw (0 = all)
     */
    function withdrawFromContract(uint256 amount) external onlyOwner {
        uint256 balance = iBGT.balanceOf(address(this));
        uint256 withdrawAmount = amount == 0 ? balance : amount;
        
        if (withdrawAmount > balance) revert InsufficientBalance();
        
        iBGT.transfer(owner, withdrawAmount);
        
        emit ContractWithdrawn(withdrawAmount);
    }

    // ============ Dolomite Position Management ============
    
    /**
     * @notice Supply iBGT to Dolomite as collateral
     * @param amount Amount of iBGT to supply
     */
    function supplyiBGT(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        
        uint256 contractBalance = iBGT.balanceOf(address(this));
        if (amount > contractBalance) revert InsufficientBalance();
        
        // Approve Dolomite router
        iBGT.approve(address(DEPOSIT_WITHDRAWAL_ROUTER), amount);
        
        // Deposit to Dolomite account 0
        DEPOSIT_WITHDRAWAL_ROUTER.depositWei(
            DIBGT_MARKET_ID,              // isolationModeMarketId (0 for normal markets)
            VAULT_ACCOUNT,  // toAccountNumber (account 0)
            DIBGT_MARKET_ID,
            amount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        totaliBGTDeposited += amount;
        
        emit iBGTSupplied(amount);
    }
    

   /**
     * @notice Borrow ETH against USDC collateral
     * @param borrowAmount Amount of ETH to borrow (in wei, 18 decimals)
     */
    function borrowUSDC(uint256 borrowAmount) external onlyOwner {
        if (borrowAmount == 0) revert ZeroAmount();
        
        // Open borrow position and transfer collateral from account0 to account 123
        BORROW_POSITION_ROUTER.openBorrowPosition(
            DIBGT_MARKET_ID,   // isolationModeMarketId
            VAULT_ACCOUNT,     // fromAccountNumber
            BORROW_ACCOUNT,    // toAccountNumber
            DIBGT_MARKET_ID,   // collateralMarketId
            totaliBGTDeposited,// collateralAmount
            IBorrowPositionRouter.BalanceCheckFlag.From
        );
        //Transfering borrowed USD back to account 0
        BORROW_POSITION_ROUTER.transferBetweenAccounts(
        /* _isolationModeMarketId = */ DIBGT_MARKET_ID,
        /* _fromAccountNumber = */ 123,
        /* _toAccountNumber = */ 0,
        /* _marketId = */ USDCMarketId,
        /* _amount = */ borrowAmount,
        /* _balanceCheckFlag = */ IBorrowPositionRouter.BalanceCheckFlag.To
        );
        
        totalUSDCBorrowed += borrowAmount;

        // Withdraw USDC borrowed from Dolomite
        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            0,
            VAULT_ACCOUNT,
            USDCMarketId,
            borrowAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        // Transfer borrowed WETH to owner
        bool success = USDC.transfer(owner, borrowAmount);
        if (!success) revert TransferFailed();
        
        emit USDCBorrowed(borrowAmount);
    }

    /**
     * @notice Repay USDC debt and close borrow position
     * @param amount Amount to repay (0 = repay with 10% buffer for interest)
     * @dev After this, collateral will be back in account 0 (still in Dolomite)
     */
    function repayUSDC(uint256 amount) external onlyOwner {
        uint256 repayAmount = amount;

        if (repayAmount == 0) {
            // Add 10% buffer for accrued interest
            repayAmount = (totalUSDCBorrowed * 110) / 100;
        }

        if (repayAmount == 0) revert ZeroAmount();
        
        // Transfer USDC from owner to contract
        bool success = USDC.transferFrom(msg.sender, address(this), repayAmount);
        if (!success) revert TransferFailed();

        // Approve and deposit USDC to account 0
        USDC.approve(address(DEPOSIT_WITHDRAWAL_ROUTER), repayAmount);
        
        DEPOSIT_WITHDRAWAL_ROUTER.depositWei(
            0,
            VAULT_ACCOUNT,
            USDCMarketId,
            repayAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        // Repay all debt in borrow account 123 using funds from account 0
        BORROW_POSITION_ROUTER.repayAllForBorrowPosition(
            DIBGT_MARKET_ID, // isolationModeMarketId for diBGT
            VAULT_ACCOUNT,   // fromAccountNumber (where the USDC is)
            BORROW_ACCOUNT,  // borrowAccountNumber (account with debt)
            USDCMarketId,
            AccountBalanceLib.BalanceCheckFlag.From
        );

        BORROW_POSITION_ROUTER.transferBetweenAccounts(
            DIBGT_MARKET_ID,  // isolationModeMarketId
            BORROW_ACCOUNT,   // fromAccountNumber (account 123)
            VAULT_ACCOUNT,    // toAccountNumber (account 0)
            DIBGT_MARKET_ID,  // marketId (diBGT)
            totaliBGTDeposited, // amount to transfer back
            IBorrowPositionRouter.BalanceCheckFlag.None
        );

        // Reset debt tracking
        totalUSDCBorrowed = 0;

        emit USDCRepaid(repayAmount);
        //emit BorrowPositionClosed(repayAmount);
    }

    
    /**
     * @notice Withdraw iBGT from Dolomite
     * @param iBGTAmount Amount of iBGT to withdraw (0 = withdraw all)
     * @dev Requires all debt to be repaid first
     */
    function withdrawiBGT(uint256 iBGTAmount) external onlyOwner {
        if (totalUSDCBorrowed > 0) revert DebtExists();
        
        uint256 withdrawAmount = iBGTAmount;
        
        // If amount is 0, withdraw all
        if (withdrawAmount == 0) {
            withdrawAmount = totaliBGTDeposited;
        }
        
        if (withdrawAmount == 0) revert ZeroAmount();
        if (withdrawAmount > totaliBGTDeposited) revert InsufficientBalance();
        
        // Withdraw iBGT from Dolomite
        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            DIBGT_MARKET_ID,
            VAULT_ACCOUNT,
            DIBGT_MARKET_ID,
            withdrawAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        totaliBGTDeposited -= withdrawAmount;
        
        // Transfer to owner
        iBGT.transfer(owner, withdrawAmount);
        
        emit iBGTWithdrawn(withdrawAmount);
    }

    // ============ View Functions ============
    
    /**
     * @notice Get vault's tracked position
     * @return iBGTCollateral Total iBGT deposited to Dolomite
     * @return USDCDebt Total USDC borrowed from Dolomite
     * @return contractiBGT iBGT balance in contract (not in Dolomite)
     * @return contractUSDC USDC balance in contract
     */
    function getPosition() 
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
        USDCDebt = totalUSDCBorrowed;
        contractiBGT = iBGT.balanceOf(address(this));
        contractUSDC = USDC.balanceOf(address(this));
    }
    
    /**
     * @notice Get actual balances from Dolomite
     * @return iBGTBalance iBGT balance in Dolomite (positive = collateral)
     * @return USDCBalance USDC balance in Dolomite (negative = debt)
     */
    // function getDolomiteBalances() 
    //     external 
    //     view 
    //     returns (int256 iBGTBalance, int256 USDCBalance) 
    // {
    //     iBGTBalance = DOLOMITE_MARGIN.getAccountWei(
    //         address(this),
    //         VAULT_ACCOUNT,
    //         iBGTMarketId
    //     );
        
    //     USDCBalance = DOLOMITE_MARGIN.getAccountWei(
    //         address(this),
    //         VAULT_ACCOUNT,
    //         USDCMarketId
    //     );
    // }

    /**
     * @notice Get market IDs
     */
    function getMarketIds() 
        external 
        view 
        returns (uint256 iBGTID, uint256 USDCID) 
    {
        return (iBGTMarketId, USDCMarketId);
    }

    // ============ Admin Functions ============
    
    /**
     * @notice Manually authorize Dolomite routers (in case constructor call failed)
     * @dev Call this if you're getting authorization errors
     */
    function authorizeRouters() external onlyOwner {
        _setOperators();
    }
    
    /**
     * @notice Set operators for Dolomite account
     * @param operators Array of operator addresses
     * @param trusted Array of trusted flags corresponding to operators
     */
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
    
    /**
     * @notice Emergency withdraw any token
     * @param token Token address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner, amount);
    }
    
    /**
     * @notice Transfer ownership
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }
}