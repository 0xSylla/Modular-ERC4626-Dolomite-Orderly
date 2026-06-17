// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// V6 router pairs with DiracVaultV3 (no openWithdrawals, inner-revert bubble).
// Aliased import keeps the rest of this file structurally identical to V5.
import {DiracVaultV3 as DiracVaultV2} from "../vault/DiracVaultV3.sol";
import {IDiracVaultFactory} from "../interfaces/IDiracVaultFactory.sol";
import {Data} from "../libraries/Data.sol";
import {Events} from "../libraries/Events.sol";

/// @title VaultCuratorRouterV6
/// @notice V6 of the curator/operator orchestration layer for Dirac vaults.
///         Single change vs V5: drops the `openWithdrawals(vault)` passthrough,
///         because DiracVaultV3 collapses the cycle to 3 states (TRADING →
///         CLOSED transitions directly). Position lifecycle, leg config,
///         escape hatch, auto-rebalance — all identical to V5.
contract VaultCuratorRouterV6 {
    IDiracVaultFactory public immutable factory;

    // ============ Position Storage ============

    /// @dev 5 fields — no allocation. Same layout as V5.
    struct PositionRecord {
        uint256 id;
        address vault;
        address collateralAsset;
        string perpsAsset;
        Data.PositionStatus status;
    }

    /// vault => positionId => PositionRecord
    mapping(address => mapping(uint256 => PositionRecord)) public positions;
    /// vault => next position id (kept for backwards-compat tooling; effectively max 1)
    mapping(address => uint256) public nextPositionId;
    /// vault => number of positions (0 or 1)
    mapping(address => uint256) public positionCount;
    /// vault => leg config (module type hashes, set once by curator, shared across all positions)
    mapping(address => Data.LegConfig) public vaultLegs;
    /// vault => curator-set flag allowing operator to trigger atomic rebalance without a separate
    /// requestRebalance signature. Off by default; opt-in.
    mapping(address => bool) public allowOperatorAutoRebalance;

    /// @notice Emitted when an operator overrides position status via the escape hatch.
    event PositionStatusUpdated(
        address indexed vault,
        uint256 indexed positionId,
        Data.PositionStatus oldStatus,
        Data.PositionStatus newStatus,
        address indexed by
    );

    constructor(address _factory) {
        factory = IDiracVaultFactory(_factory);
    }

    modifier onlyFactoryVault(address vault) {
        if (!factory.isVault(vault)) revert Events.NotFactoryVault();
        _;
    }

    modifier onlyCurator(address vault) {
        if (!DiracVaultV2(payable(vault)).hasRole(DiracVaultV2(payable(vault)).CURATOR_ROLE(), msg.sender))
            revert Events.Unauthorized();
        _;
    }

    modifier onlyOperator(address vault) {
        if (!DiracVaultV2(payable(vault)).hasRole(DiracVaultV2(payable(vault)).OPERATOR_ROLE(), msg.sender))
            revert Events.Unauthorized();
        _;
    }

    // ============ Vault Leg Configuration (Curator) ============

    function setVaultLegs(
        address vault,
        Data.LegConfig calldata legs
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        if (legs.swapModuleType == bytes32(0) || legs.lendingModuleType == bytes32(0) || legs.perpsModuleType == bytes32(0))
            revert Events.ModuleNotWhitelisted();
        vaultLegs[vault] = legs;
        emit Events.VaultLegsSet(vault, legs.swapModuleType, legs.lendingModuleType, legs.perpsModuleType);
    }

    // ============ Position Definition (Curator) ============

    /// @notice Define the strategy spec for this vault. Only one position per
    ///         vault — call once at setup, then re-open across cycles without
    ///         redefining.
    function definePosition(
        address vault,
        address collateralAsset,
        string calldata perpsAsset
    ) external onlyFactoryVault(vault) onlyCurator(vault) returns (uint256 positionId) {
        if (positionCount[vault] != 0) revert Events.PositionExists();

        if (!DiracVaultV2(payable(vault)).isTargetAssetWhitelisted(collateralAsset))
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
            status: Data.PositionStatus.IDLE
        });
        positionCount[vault] = 1;

        emit Events.PositionDefined(positionId, collateralAsset, perpsAsset, 0);
    }

    function removePosition(
        address vault,
        uint256 positionId
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.IDLE) revert Events.PositionNotIdle();

        delete positions[vault][positionId];
        positionCount[vault] = 0;

        emit Events.PositionRemoved(positionId);
    }

    // ============ Position Requests (Curator) ============

    function requestOpeningPosition(
        address vault,
        uint256 positionId
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.IDLE) revert Events.PositionNotIdle();

        p.status = Data.PositionStatus.OPEN_REQUESTED;
        emit Events.OpenRequested(positionId);
    }

    function requestRebalance(
        address vault,
        uint256 positionId
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.ACTIVE) revert Events.PositionNotActive();

        p.status = Data.PositionStatus.REBALANCE_REQUESTED;
        emit Events.RebalanceRequested(positionId);
    }

    function requestClosingPosition(
        address vault,
        uint256 positionId
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.ACTIVE) revert Events.PositionNotActive();

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

        results = DiracVaultV2(payable(vault)).executeBatch{value: msg.value}(moduleTypes, datas);
        emit Events.PositionOpening(positionId);
    }

    function confirmOpen(
        address vault,
        uint256 positionId
    ) external onlyFactoryVault(vault) onlyOperator(vault) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.OPENING) revert Events.PositionNotOpening();

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

        results = DiracVaultV2(payable(vault)).executeBatch{value: msg.value}(moduleTypes, datas);
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

        results = DiracVaultV2(payable(vault)).executeBatch{value: msg.value}(moduleTypes, datas);
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
        if (p.status != Data.PositionStatus.REBALANCING) revert Events.PositionNotRebalancing();

        _validateModuleTypes(vaultLegs[vault], moduleTypes);
        p.status = Data.PositionStatus.ACTIVE;

        results = DiracVaultV2(payable(vault)).executeBatch{value: msg.value}(moduleTypes, datas);
        emit Events.PositionRebalanced(positionId);
    }

    // ============ Auto-Rebalance (curator opt-in) ============

    function setOperatorAutoRebalance(
        address vault,
        bool allowed
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        allowOperatorAutoRebalance[vault] = allowed;
        emit Events.OperatorAutoRebalanceSet(vault, allowed);
    }

    /// @notice Operator-triggered atomic rebalance close. Requires curator opt-in
    ///         via setOperatorAutoRebalance.
    function operatorRebalanceClose(
        address vault,
        uint256 positionId,
        bytes32[] calldata moduleTypes,
        bytes[] calldata datas
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes[] memory results) {
        if (!allowOperatorAutoRebalance[vault]) revert Events.OperatorAutoRebalanceDisabled();
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.ACTIVE) revert Events.PositionNotActive();

        _validateModuleTypes(vaultLegs[vault], moduleTypes);
        p.status = Data.PositionStatus.REBALANCING;

        results = DiracVaultV2(payable(vault)).executeBatch{value: msg.value}(moduleTypes, datas);
        emit Events.PositionRebalancing(positionId);
    }

    // ============ Status Recovery (operator escape hatch) ============

    /// @notice Override a position's on-chain status. For unsticking partial-flow incidents
    ///         (e.g. an open that failed after Morpho borrow but before HL bridge). No automated
    ///         flow uses this — manual operations only. Status changes are emitted for audit.
    function setPositionStatus(
        address vault,
        uint256 positionId,
        Data.PositionStatus newStatus
    ) external onlyFactoryVault(vault) onlyOperator(vault) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        Data.PositionStatus old = p.status;
        p.status = newStatus;
        emit PositionStatusUpdated(vault, positionId, old, newStatus, msg.sender);
    }

    // ============ Vault Configuration (Curator) ============

    function whitelistTargetAsset(
        address vault,
        address asset
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        DiracVaultV2(payable(vault)).whitelistTargetAsset(asset);
    }

    // ============ Low-level (Operator) ============

    function setupModule(
        address vault,
        bytes32 moduleType,
        bytes calldata data
    ) external onlyFactoryVault(vault) onlyOperator(vault) returns (bytes memory) {
        return DiracVaultV2(payable(vault)).setupModule(moduleType, data);
    }

    function executeModule(
        address vault,
        bytes32 moduleType,
        bytes calldata data
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes memory) {
        return DiracVaultV2(payable(vault)).executeModule{value: msg.value}(moduleType, data);
    }

    function executeBatch(
        address vault,
        bytes32[] calldata moduleTypes,
        bytes[] calldata datas
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes[] memory) {
        return DiracVaultV2(payable(vault)).executeBatch{value: msg.value}(moduleTypes, datas);
    }

    // ============ Cycle Management (Curator) ============
    //
    // V6 drops `openWithdrawals` — V3 vaults collapse TRADING → CLOSED directly.

    function openDeposits(address vault) external onlyFactoryVault(vault) onlyCurator(vault) {
        DiracVaultV2(payable(vault)).openDeposits();
    }

    function startTrading(address vault) external onlyFactoryVault(vault) onlyCurator(vault) {
        DiracVaultV2(payable(vault)).startTrading();
    }

    function closeCycle(address vault) external onlyFactoryVault(vault) onlyCurator(vault) {
        DiracVaultV2(payable(vault)).closeCycle();
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
