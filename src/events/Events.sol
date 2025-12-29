// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

library Events {
    // Trade Cycle Events
    event DelegateSignerSet(
        bytes32 indexed brokerHash,
        address indexed delegateSigner
    );
    event TradeCycleStarted(
        uint256 indexed tradeCycleId,
        uint256 honeyDeposit,
        uint256 startedAt,
        uint256 expiresAt
    );
    event TradeCyclePendingEnd(uint256 indexed tradeCycleId);
    event TradeCycleInit(uint256 indexed tradeCycleId);
    event TradeCycleEnded(uint256 indexed tradeCycleId, uint256 endedAt);
    event Deposit(uint256 indexed tradeCycleId, uint256 amount);

    // Dolomite Events
    event CollateralSupplied(uint256 amount);
    event AssetBorrowed(uint256 amount);
    event DebtRepaid(uint256 amount);
    event CollateralWithdrawn(uint256 amount);
    event ContractFunded(uint256 amount);
    event ContractWithdrawn(uint256 amount);
    event ClaimedRewards();
    event OperatorsSet(address[] operators, bool[] trusted);
    event BorrowPositionOpened(uint256 collateralAmount, uint256 borrowAmount);

    // Errors
    error InsufficientFunds();
    error OperationFailed();
    error TradeNotMatured();
    error UserExceedMaxDepositAmount();
    error UserNotWhitelisted();
    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error InsufficientBalance();
    error TransferFailed();
    error DebtExists();
    error NoCollateralToZap();
}
