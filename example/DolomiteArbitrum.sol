// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title DolomiteVault
 * @notice Owner-controlled vault that deposits USDC to Dolomite and borrows ETH
 * @dev Uses Dolomite account 0 (default account for the contract address)
 */

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDolomiteMargin {
    function getMarketIdByTokenAddress(address token) external view returns (uint256);
    function getAccountWei(
        address owner,
        uint256 accountNumber,
        uint256 marketId
    ) external view returns (int256);
    
    struct OperatorArg {
        address operator;
        bool trusted;
    }
    
    function setOperators(OperatorArg[] calldata args) external;
    
    // For direct operations
    struct Info {
        address owner;
        uint256 number;
    }
    
    struct AssetAmount {
        bool sign;
        AssetDenomination denomination;
        AssetReference ref;
        uint256 value;
    }
    
    enum AssetDenomination {
        Wei,
        Par
    }
    
    enum AssetReference {
        Delta,
        Target
    }
    
    enum ActionType {
        Deposit,
        Withdraw,
        Transfer,
        Buy,
        Sell,
        Trade,
        Liquidate,
        Vaporize,
        Call
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
    
    function operate(
        Info[] calldata accounts,
        ActionArgs[] calldata actions
    ) external;
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

contract DolomiteVault {
    
    // Dolomite contract addresses
    IDolomiteMargin public constant DOLOMITE_MARGIN = 
        IDolomiteMargin(0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072);
    
    IDepositWithdrawalRouter public constant DEPOSIT_WITHDRAWAL_ROUTER = 
        IDepositWithdrawalRouter(0xf8b2c637A68cF6A17b1DF9F8992EeBeFf63d2dFf);
    
    // Token addresses
    IERC20 public immutable USDC;
    IERC20 public immutable WETH;
    
    // Market IDs
    uint256 public immutable usdcMarketId;
    uint256 public immutable wethMarketId;
    
    // Owner
    address public owner;
    
    // Use Dolomite account 0 (default account for this contract)
    uint256 public constant VAULT_ACCOUNT = 0;
    
    // Position tracking
    uint256 public totalUSDCDeposited;
    uint256 public totalETHBorrowed;
    
    // Events
    event USDCSupplied(uint256 amount);
    event ETHBorrowed(uint256 amount);
    event ETHRepaid(uint256 amount);
    event USDCWithdrawn(uint256 amount);
    event ContractFunded(uint256 amount);
    event ContractWithdrawn(uint256 amount);
    event OperatorsSet(address[] operators, bool[] trusted);
    
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
     * @param _usdc USDC token address
     * @param _weth WETH token address
     */
    constructor(address _usdc, address _weth) {
        require(_usdc != address(0), "Invalid USDC");
        require(_weth != address(0), "Invalid WETH");
        
        owner = msg.sender;
        USDC = IERC20(_usdc);
        WETH = IERC20(_weth);
        
        // Get market IDs from Dolomite
        usdcMarketId = DOLOMITE_MARGIN.getMarketIdByTokenAddress(_usdc);
        wethMarketId = DOLOMITE_MARGIN.getMarketIdByTokenAddress(_weth);
        
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
     * @notice Transfer USDC from owner to contract
     * @param amount Amount of USDC to transfer
     */
    function fundContract(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        
        bool success = USDC.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        
        emit ContractFunded(amount);
    }

    /**
     * @notice Withdraw USDC from contract balance (not from Dolomite)
     * @param amount Amount to withdraw (0 = all)
     */
    function withdrawFromContract(uint256 amount) external onlyOwner {
        uint256 balance = USDC.balanceOf(address(this));
        uint256 withdrawAmount = amount == 0 ? balance : amount;
        
        if (withdrawAmount > balance) revert InsufficientBalance();
        
        USDC.transfer(owner, withdrawAmount);
        
        emit ContractWithdrawn(withdrawAmount);
    }

    // ============ Dolomite Position Management ============
    
    /**
     * @notice Supply USDC to Dolomite as collateral
     * @param amount Amount of USDC to supply
     */
    function supplyUSDC(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        
        uint256 contractBalance = USDC.balanceOf(address(this));
        if (amount > contractBalance) revert InsufficientBalance();
        
        // Approve Dolomite router
        USDC.approve(address(DEPOSIT_WITHDRAWAL_ROUTER), amount);
        
        // Deposit to Dolomite account 0
        DEPOSIT_WITHDRAWAL_ROUTER.depositWei(
            0,              // isolationModeMarketId (0 for normal markets)
            VAULT_ACCOUNT,  // toAccountNumber (account 0)
            usdcMarketId,
            amount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        totalUSDCDeposited += amount;
        
        emit USDCSupplied(amount);
    }
    
    /**
     * @notice Borrow ETH against USDC collateral
     * @param ethAmount Amount of ETH to borrow (in wei, 18 decimals)
     */
    function borrowETH(uint256 ethAmount) external onlyOwner {
        if (ethAmount == 0) revert ZeroAmount();
        
        // Create account info for account 0
        IDolomiteMargin.Info[] memory accounts = new IDolomiteMargin.Info[](1);
        accounts[0] = IDolomiteMargin.Info({
            owner: address(this),
            number: VAULT_ACCOUNT
        });
        
        // Create withdraw action (negative amount = borrow)
        IDolomiteMargin.ActionArgs[] memory actions = new IDolomiteMargin.ActionArgs[](1);
        actions[0] = IDolomiteMargin.ActionArgs({
            actionType: IDolomiteMargin.ActionType.Withdraw,
            accountId: 0,
            amount: IDolomiteMargin.AssetAmount({
                sign: false,  // false = negative (borrow)
                denomination: IDolomiteMargin.AssetDenomination.Wei,
                ref: IDolomiteMargin.AssetReference.Delta,
                value: ethAmount
            }),
            primaryMarketId: wethMarketId,
            secondaryMarketId: 0,
            otherAddress: address(this),  // withdraw to this contract
            otherAccountId: 0,
            data: ""
        });
        
        // Execute the operation
        DOLOMITE_MARGIN.operate(accounts, actions);
        
        totalETHBorrowed += ethAmount;
        
        // Transfer borrowed WETH to owner
        bool success = WETH.transfer(owner, ethAmount);
        if (!success) revert TransferFailed();
        
        emit ETHBorrowed(ethAmount);
    }
    
    /**
     * @notice Repay ETH debt
     * @param ethAmount Amount of ETH to repay (0 = repay all)
     */
    function repayETH(uint256 ethAmount) external onlyOwner {
        uint256 repayAmount = ethAmount;
        
        // If amount is 0, repay all debt
        if (repayAmount == 0) {
            repayAmount = totalETHBorrowed;
        }
        
        if (repayAmount == 0) revert ZeroAmount();
        if (repayAmount > totalETHBorrowed) revert InsufficientBalance();
        
        // Transfer WETH from owner to contract
        bool success = WETH.transferFrom(msg.sender, address(this), repayAmount);
        if (!success) revert TransferFailed();
        
        // Approve and deposit WETH to repay debt
        WETH.approve(address(DEPOSIT_WITHDRAWAL_ROUTER), repayAmount);
        
        DEPOSIT_WITHDRAWAL_ROUTER.depositWei(
            0,
            VAULT_ACCOUNT,
            wethMarketId,
            repayAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        totalETHBorrowed -= repayAmount;
        
        emit ETHRepaid(repayAmount);
    }
    
    /**
     * @notice Withdraw USDC from Dolomite
     * @param usdcAmount Amount of USDC to withdraw (0 = withdraw all)
     * @dev Requires all debt to be repaid first
     */
    function withdrawUSDC(uint256 usdcAmount) external onlyOwner {
        if (totalETHBorrowed > 0) revert DebtExists();
        
        uint256 withdrawAmount = usdcAmount;
        
        // If amount is 0, withdraw all
        if (withdrawAmount == 0) {
            withdrawAmount = totalUSDCDeposited;
        }
        
        if (withdrawAmount == 0) revert ZeroAmount();
        if (withdrawAmount > totalUSDCDeposited) revert InsufficientBalance();
        
        // Withdraw USDC from Dolomite
        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            0,
            VAULT_ACCOUNT,
            usdcMarketId,
            withdrawAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        totalUSDCDeposited -= withdrawAmount;
        
        // Transfer to owner
        USDC.transfer(owner, withdrawAmount);
        
        emit USDCWithdrawn(withdrawAmount);
    }

    // ============ View Functions ============
    
    /**
     * @notice Get vault's tracked position
     * @return usdcCollateral Total USDC deposited to Dolomite
     * @return ethDebt Total ETH borrowed from Dolomite
     * @return contractUSDC USDC balance in contract (not in Dolomite)
     * @return contractWETH WETH balance in contract
     */
    function getPosition() 
        external 
        view 
        returns (
            uint256 usdcCollateral,
            uint256 ethDebt,
            uint256 contractUSDC,
            uint256 contractWETH
        ) 
    {
        usdcCollateral = totalUSDCDeposited;
        ethDebt = totalETHBorrowed;
        contractUSDC = USDC.balanceOf(address(this));
        contractWETH = WETH.balanceOf(address(this));
    }
    
    /**
     * @notice Get actual balances from Dolomite
     * @return usdcBalance USDC balance in Dolomite (positive = collateral)
     * @return ethBalance ETH balance in Dolomite (negative = debt)
     */
    function getDolomiteBalances() 
        external 
        view 
        returns (int256 usdcBalance, int256 ethBalance) 
    {
        usdcBalance = DOLOMITE_MARGIN.getAccountWei(
            address(this),
            VAULT_ACCOUNT,
            usdcMarketId
        );
        
        ethBalance = DOLOMITE_MARGIN.getAccountWei(
            address(this),
            VAULT_ACCOUNT,
            wethMarketId
        );
    }

    /**
     * @notice Get market IDs
     */
    function getMarketIds() 
        external 
        view 
        returns (uint256 usdc, uint256 weth) 
    {
        return (usdcMarketId, wethMarketId);
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