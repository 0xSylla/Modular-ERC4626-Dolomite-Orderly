// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

library Data {
    // ============ Trade Cycle ============

    enum TradeCycleStatus {
        CLOSED,
        DEPOSIT_OPEN,
        TRADING,
        WITHDRAW_OPEN
    }

    struct TradeCycle {
        TradeCycleStatus status;
        uint256 assetsAtCycleStart; // snapshot for P&L calculation
    }

    // ============ Position ============

    enum PositionStatus {
        IDLE,
        OPEN_REQUESTED,
        OPENING,             // on-chain legs done, waiting for off-chain short confirmation
        ACTIVE,
        CLOSE_REQUESTED,
        REBALANCE_REQUESTED, // curator triggered rebalance; operator will close on-chain then run Orderly cycle
        REBALANCING          // on-chain legs closed, waiting for off-chain Orderly close+reopen to complete
    }

    struct LegConfig {
        bytes32 swapModuleType;
        bytes32 lendingModuleType;
        bytes32 perpsModuleType;
    }

    struct Position {
        uint256 id;
        address collateralAsset;
        string perpsAsset; // e.g. "BERA", "WBTC", "WETH" — the asset to short/hedge
        uint256 allocation; // exact deposit token amount (e.g., 600_000e6 = 600k USDC)
        PositionStatus status;
        LegConfig legs;
    }

    // ============ Vault Info ============

    struct VaultInfo {
        address vault;
        address creator;
        bytes32 templateId;
        uint256 deployedAt;
    }

    // ============ Asset Info ============

    struct AssetInfo {
        address token;
        string[] allowedPerpsAssets; // e.g. ["BERA", "WBTC"] — perps symbols allowed to hedge this collateral
    }

    // ============ Fees ============

    struct ProtocolFees {
        uint256 protocolFeeBps; // default 1000 = 10%
        uint256 daoFeeBps; // default 300 = 3%
        address protocolFeeRecipient;
        address daoFeeRecipient;
    }

    struct CuratorFeeConfig {
        uint256 curatorFeeBps; // max 200 = 2%
        address curatorFeeRecipient;
    }

    /// @notice All parameters needed to create a vault, packed into one struct
    struct VaultParams {
        string name;
        string symbol;
        address depositToken;
        uint256 maxDeposit;
        bytes32 templateId;
        VaultFees fees;
        uint256 rebalanceThresholdBps;
        uint256 fundingRateThresholdBps;
    }

    /// @notice Simplified fee structure set by vault creator at deployment
    struct VaultFees {
        uint256 performanceFeeBps; // e.g. 1000 = 10%
        uint256 managementFeeBps;  // e.g. 50 = 0.5%
        address feeRecipient;
    }
}
