// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Data} from "./Data.sol";

library Events {
    // ============ Factory Events ============
    event VaultCreated(
        address indexed vault,
        address indexed curator,
        address indexed depositToken,
        string name,
        string symbol,
        uint256 maxDeposit,
        uint256 performanceFeeBps,
        uint256 managementFeeBps,
        address feeRecipient,
        uint256 rebalanceThresholdBps,
        uint256 fundingRateThresholdBps
    );
    event DepositTokenWhitelisted(address indexed token);
    event DepositTokenRemoved(address indexed token);
    event StrategyAssetWhitelisted(address indexed token, Data.AssetInfo info);
    event StrategyAssetRemoved(address indexed token);
    event PerpsModuleSymbolSet(address indexed token, bytes32 indexed moduleTypeHash, bytes symbol);
    event ModuleLendingConfigSet(bytes32 indexed moduleTypeHash, address indexed token, bytes config);
    event ModuleRegistered(
        bytes32 indexed moduleType,
        address indexed moduleAddress
    );
    event ModuleRemoved(bytes32 indexed moduleType);
    event ProtocolFeeUpdated(uint256 feeBps, address recipient);
    event DaoFeeUpdated(uint256 feeBps, address recipient);
    event TemplateRegistered(bytes32 indexed templateId);
    event TemplateRemoved(bytes32 indexed templateId);
    event EmergencyAction(address indexed vault, string action);

    // ============ Vault Events ============
    event CycleStatusChanged(Data.TradeCycleStatus newStatus);
    event TargetAssetWhitelisted(address indexed asset);
    event TargetAssetRemoved(address indexed asset);
    event VaultLegsSet(address indexed vault, bytes32 swapModuleType, bytes32 lendingModuleType, bytes32 perpsModuleType);
    event PositionDefined(uint256 indexed positionId, address indexed collateralAsset, string perpsAsset, uint256 allocation);
    event PositionRemoved(uint256 indexed positionId);
    event PositionUpdated(uint256 indexed positionId);
    event OpenRequested(uint256 indexed positionId);
    event CloseRequested(uint256 indexed positionId);
    event RebalanceRequested(uint256 indexed positionId);
    event PositionOpening(uint256 indexed positionId);
    event PositionOpenConfirmed(uint256 indexed positionId);
    event PositionClosed(uint256 indexed positionId);
    event PositionRebalancing(uint256 indexed positionId);
    event PositionRebalanced(uint256 indexed positionId);
    event ModuleExecuted(address indexed module, bool success);
    event FeesCollected(uint256 performanceFee, uint256 managementFee, uint256 totalFees);
    event MaxDepositUpdated(uint256 newMaxDeposit);

    // ============ Module Events ============
    // Dolomite
    event CollateralSupplied(uint256 amount);
    event AssetBorrowed(uint256 amount);
    event DebtRepaid(uint256 amount);
    event CollateralWithdrawn(uint256 amount);
    event ClaimedRewards();
    event DebtRepaidWithCollateralAsset(uint256 remainingCollateral);

    // Orderly
    event DelegateSignerSet(
        bytes32 indexed brokerHash,
        address indexed delegateSigner
    );
    event DepositedToOrderly(uint256 amount);

    // Swap
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    // ============ Errors ============
    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error InsufficientBalance();
    error OperationFailed();
    error DebtExists();
    error NoCollateralToZap();
    error ModuleNotWhitelisted();
    error NotInTradingPeriod();
    error NotInDepositWindow();
    error NotInWithdrawWindow();
    error DepositTokenNotWhitelisted();
    error CuratorFeeExceedsCap();
    error AssetNotWhitelisted();
    error PerpsAssetNotAllowed();
    error PositionNotIdle();
    error PositionNotOpenRequested();
    error PositionNotOpening();
    error PositionNotActive();
    error PositionNotCloseRequested();
    error PositionNotRebalanceRequested();
    error PositionNotRebalancing();
    error TemplateNotRegistered();
    error AllocationExceedsBalance();
    error MaxDepositExceeded();
    error NotFactoryVault();
    error ModuleExecutionFailed();
    error ArrayLengthMismatch();
    error TotalFeesExceedCap();
    error OnlyDelegatecall();
    error DebtNotFullyRepaid();
}
