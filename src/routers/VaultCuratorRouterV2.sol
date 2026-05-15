// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DiracVault} from "../vault/DiracVault.sol";
import {IDiracVaultFactory} from "../interfaces/IDiracVaultFactory.sol";
import {Data} from "../libraries/Data.sol";
import {Events} from "../libraries/Events.sol";

/// @title VaultCuratorRouterV2
/// @notice Identical to VaultCuratorRouter v1 with two additions for automated rebalancing:
///
///         1. allowOperatorAutoRebalance[vault] — per-vault opt-in flag the curator sets at deploy
///         2. operatorRebalanceClose(...)       — operator-callable atomic ACTIVE → REBALANCING transition,
///                                                replaces the two-step (curator requestRebalance + operator
///                                                executeRebalanceClose) for vaults that opted in.
///
///         The existing curator-side requestRebalance + operator-side executeRebalanceClose flow is
///         preserved unchanged for backward compatibility and for vaults that prefer manual control.
///         The cron just uses the new single-call path on vaults that opted in.
contract VaultCuratorRouterV2 {
    IDiracVaultFactory public immutable factory;

    // ============ Position Storage ============

    struct PositionRecord {
        uint256 id;
        address vault;
        address collateralAsset;
        string perpsAsset;
        uint256 allocation;
        Data.PositionStatus status;
    }

    /// vault => positionId => PositionRecord
    mapping(address => mapping(uint256 => PositionRecord)) public positions;
    /// vault => next position id
    mapping(address => uint256) public nextPositionId;
    /// vault => number of active positions (for enumeration)
    mapping(address => uint256) public positionCount;
    /// vault => leg config (module type hashes, set once by curator, shared across all positions)
    mapping(address => Data.LegConfig) public vaultLegs;

    /// vault => curator has authorized operator to trigger rebalances unilaterally.
    /// Defaults false. Curator opts in via setOperatorAutoRebalance(vault, true).
    /// Required for operatorRebalanceClose. Does not affect the curator-driven flow.
    mapping(address => bool) public allowOperatorAutoRebalance;

    constructor(address _factory) {
        factory = IDiracVaultFactory(_factory);
    }

    modifier onlyFactoryVault(address vault) {
        if (!factory.isVault(vault)) revert Events.NotFactoryVault();
        _;
    }

    modifier onlyCurator(address vault) {
        if (!DiracVault(payable(vault)).hasRole(DiracVault(payable(vault)).CURATOR_ROLE(), msg.sender))
            revert Events.Unauthorized();
        _;
    }

    modifier onlyOperator(address vault) {
        if (!DiracVault(payable(vault)).hasRole(DiracVault(payable(vault)).OPERATOR_ROLE(), msg.sender))
            revert Events.Unauthorized();
        _;
    }

    // ============ Vault Leg Configuration (Curator) ============

    function setVaultLegs(
        address vault,
        Data.LegConfig calldata legs
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        if (legs.swapModuleType == bytes32(0) || legs.lendingModuleType == bytes32(0) || legs.perpsModuleType == bytes32(0))
            revert Events.ZeroAddress();
        vaultLegs[vault] = legs;
        emit Events.VaultLegsSet(vault, legs.swapModuleType, legs.lendingModuleType, legs.perpsModuleType);
    }

    // ============ Position Definition (Curator) ============

    function definePosition(
        address vault,
        address collateralAsset,
        string calldata perpsAsset,
        uint256 allocation
    ) external onlyFactoryVault(vault) onlyCurator(vault) returns (uint256 positionId) {
        if (!DiracVault(payable(vault)).isTargetAssetWhitelisted(collateralAsset))
            revert Events.AssetNotWhitelisted();
        if (!factory.isPerpsAssetAllowed(collateralAsset, perpsAsset))
            revert Events.PerpsAssetNotAllowed();
        Data.LegConfig storage legs = vaultLegs[vault];
        if (legs.swapModuleType == bytes32(0)) revert Events.ModuleNotWhitelisted();

        positionId = nextPositionId[vault]++;
        positions[vault][positionId] = PositionRecord({
            id: positionId,
            vault: vault,
            collateralAsset: collateralAsset,
            perpsAsset: perpsAsset,
            allocation: allocation,
            status: Data.PositionStatus.IDLE
        });
        positionCount[vault]++;

        emit Events.PositionDefined(positionId, collateralAsset, perpsAsset, allocation);
    }

    function removePosition(
        address vault,
        uint256 positionId
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.IDLE)
            revert Events.PositionNotIdle();

        delete positions[vault][positionId];
        positionCount[vault]--;

        emit Events.PositionRemoved(positionId);
    }

    function updatePosition(
        address vault,
        uint256 positionId,
        uint256 allocation
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.IDLE)
            revert Events.PositionNotIdle();

        p.allocation = allocation;

        emit Events.PositionUpdated(positionId);
    }

    // ============ Position Requests (Curator) ============

    function requestOpeningPosition(
        address vault,
        uint256 positionId
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.IDLE)
            revert Events.PositionNotIdle();

        p.status = Data.PositionStatus.OPEN_REQUESTED;
        emit Events.OpenRequested(positionId);
    }

    function requestRebalance(
        address vault,
        uint256 positionId
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.ACTIVE)
            revert Events.PositionNotActive();

        p.status = Data.PositionStatus.REBALANCE_REQUESTED;
        emit Events.RebalanceRequested(positionId);
    }

    function requestClosingPosition(
        address vault,
        uint256 positionId
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.ACTIVE)
            revert Events.PositionNotActive();

        p.status = Data.PositionStatus.CLOSE_REQUESTED;
        emit Events.CloseRequested(positionId);
    }

    // ============ Position Execution (Operator) ============

    function executeOpeningRequest(
        address vault,
        uint256 positionId,
        bytes32[] calldata moduleTypes,
        bytes[] calldata datas
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes[] memory results) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.OPEN_REQUESTED)
            revert Events.PositionNotOpenRequested();

        _validateModuleTypes(vaultLegs[vault], moduleTypes);
        p.status = Data.PositionStatus.OPENING;

        results = DiracVault(payable(vault)).executeBatch{value: msg.value}(moduleTypes, datas);
        emit Events.PositionOpening(positionId);
    }

    function confirmOpen(
        address vault,
        uint256 positionId
    ) external onlyFactoryVault(vault) onlyOperator(vault) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.OPENING)
            revert Events.PositionNotOpening();

        p.status = Data.PositionStatus.ACTIVE;
        emit Events.PositionOpenConfirmed(positionId);
    }

    function executeClosingRequest(
        address vault,
        uint256 positionId,
        bytes32[] calldata moduleTypes,
        bytes[] calldata datas
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes[] memory results) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.CLOSE_REQUESTED)
            revert Events.PositionNotCloseRequested();

        _validateModuleTypes(vaultLegs[vault], moduleTypes);
        p.status = Data.PositionStatus.IDLE;

        results = DiracVault(payable(vault)).executeBatch{value: msg.value}(moduleTypes, datas);
        emit Events.PositionClosed(positionId);
    }

    function executeRebalanceClose(
        address vault,
        uint256 positionId,
        bytes32[] calldata moduleTypes,
        bytes[] calldata datas
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes[] memory results) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.REBALANCE_REQUESTED)
            revert Events.PositionNotRebalanceRequested();

        _validateModuleTypes(vaultLegs[vault], moduleTypes);
        p.status = Data.PositionStatus.REBALANCING;

        results = DiracVault(payable(vault)).executeBatch{value: msg.value}(moduleTypes, datas);
        emit Events.PositionRebalancing(positionId);
    }

    function executeRebalanceOpen(
        address vault,
        uint256 positionId,
        bytes32[] calldata moduleTypes,
        bytes[] calldata datas
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes[] memory results) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.REBALANCING)
            revert Events.PositionNotRebalancing();

        _validateModuleTypes(vaultLegs[vault], moduleTypes);
        p.status = Data.PositionStatus.ACTIVE;

        results = DiracVault(payable(vault)).executeBatch{value: msg.value}(moduleTypes, datas);
        emit Events.PositionRebalanced(positionId);
    }

    // ============ Auto-Rebalance (V2 addition) ============

    /// @notice Curator opts their vault into operator-triggered auto-rebalancing.
    /// Off by default — the curator must call this with `true` at deploy time (or any time after)
    /// for the funding-monitor cron to be able to rebalance their position without their signature.
    /// Can be flipped back to `false` at any time to revoke that authority.
    function setOperatorAutoRebalance(
        address vault,
        bool allowed
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        allowOperatorAutoRebalance[vault] = allowed;
        emit Events.OperatorAutoRebalanceSet(vault, allowed);
    }

    /// @notice Operator-initiated rebalance close. Atomic ACTIVE → REBALANCING transition,
    /// replacing the two-step (curator requestRebalance + operator executeRebalanceClose).
    /// Requires the curator to have explicitly opted in via setOperatorAutoRebalance.
    /// Used by the funding-monitor cron when TP/SL fires off-chain.
    function operatorRebalanceClose(
        address vault,
        uint256 positionId,
        bytes32[] calldata moduleTypes,
        bytes[] calldata datas
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes[] memory results) {
        if (!allowOperatorAutoRebalance[vault]) revert Events.OperatorAutoRebalanceDisabled();
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.ACTIVE)
            revert Events.PositionNotActive();

        _validateModuleTypes(vaultLegs[vault], moduleTypes);
        p.status = Data.PositionStatus.REBALANCING;

        results = DiracVault(payable(vault)).executeBatch{value: msg.value}(moduleTypes, datas);
        emit Events.PositionRebalancing(positionId);
    }

    // ============ Vault Configuration (Curator) ============

    function whitelistTargetAsset(
        address vault,
        address asset
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        DiracVault(payable(vault)).whitelistTargetAsset(asset);
    }

    // ============ Low-level (Operator) ============

    function setupModule(
        address vault,
        bytes32 moduleType,
        bytes calldata data
    ) external onlyFactoryVault(vault) onlyOperator(vault) returns (bytes memory) {
        return DiracVault(payable(vault)).setupModule(moduleType, data);
    }

    function executeModule(
        address vault,
        bytes32 moduleType,
        bytes calldata data
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes memory) {
        return DiracVault(payable(vault)).executeModule{value: msg.value}(moduleType, data);
    }

    function executeBatch(
        address vault,
        bytes32[] calldata moduleTypes,
        bytes[] calldata datas
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes[] memory) {
        return DiracVault(payable(vault)).executeBatch{value: msg.value}(moduleTypes, datas);
    }

    // ============ Cycle Management (Curator) ============

    function openDeposits(
        address vault
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        DiracVault(payable(vault)).openDeposits();
    }

    function startTrading(
        address vault
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        DiracVault(payable(vault)).startTrading();
    }

    function openWithdrawals(
        address vault
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        DiracVault(payable(vault)).openWithdrawals();
    }

    function closeCycle(
        address vault
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        DiracVault(payable(vault)).closeCycle();
    }

    // ============ View ============

    function getPosition(
        address vault,
        uint256 positionId
    ) external view returns (PositionRecord memory) {
        PositionRecord memory p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        return p;
    }

    function getPositionsCount(address vault) external view returns (uint256) {
        return positionCount[vault];
    }

    // ============ Internal ============

    function _validateModuleTypes(
        Data.LegConfig storage legs,
        bytes32[] calldata moduleTypes
    ) internal view {
        for (uint256 i = 0; i < moduleTypes.length; i++) {
            bytes32 mt = moduleTypes[i];
            if (
                mt != legs.swapModuleType &&
                mt != legs.lendingModuleType &&
                mt != legs.perpsModuleType
            ) revert Events.ModuleNotWhitelisted();
        }
    }
}
