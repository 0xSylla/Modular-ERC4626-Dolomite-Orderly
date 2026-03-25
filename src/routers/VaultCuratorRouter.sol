// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DiracVault} from "../vault/DiracVault.sol";
import {IDiracVaultFactory} from "../interfaces/IDiracVaultFactory.sol";
import {Data} from "../libraries/Data.sol";
import {Events} from "../libraries/Events.sol";

/// @title VaultCuratorRouter
/// @notice Orchestration layer for curators and operators — owns position definitions and
///         hardcodes the delta-neutral recipe: swap → supply → borrow → deposit to perps (open),
///         and the reverse for close.
/// @dev Position records live here (not on the vault). The vault remains a dumb execution layer
///      (ERC4626 + cycle + delegatecall modules).
///
///      Module references use bytes32 type hashes (e.g. keccak256("swap.kodiak")).
///      The vault resolves these to current implementation addresses from the factory registry.
///
///      Lifecycle:
///        Curator: definePosition → requestOpeningPosition → (operator fulfills) → requestClosingPosition → (operator fulfills)
///        Status:  IDLE → OPEN_REQUESTED → OPENING → ACTIVE → CLOSE_REQUESTED → IDLE
contract VaultCuratorRouter {
    IDiracVaultFactory public immutable factory;

    // ============ Position Storage ============

    struct PositionRecord {
        uint256 id;
        address vault;
        address collateralAsset;
        string perpsAsset; // e.g. "BERA", "WBTC", "WETH" — the asset to short/hedge
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

    /// @notice Set the module types used for all positions in this vault. Called once during setup.
    /// @dev Legs are vault-scoped — all positions share the same swap/lending/perps module types.
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
        // Validate collateral asset is whitelisted on the vault
        if (!DiracVault(payable(vault)).isTargetAssetWhitelisted(collateralAsset))
            revert Events.AssetNotWhitelisted();
        // Validate perps asset is allowed for this collateral at protocol level
        if (!factory.isPerpsAssetAllowed(collateralAsset, perpsAsset))
            revert Events.PerpsAssetNotAllowed();
        // Validate vault legs have been configured
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

    /// @notice Curator signals intent to open a position. Operator bot detects and fulfills.
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

    /// @notice Curator signals intent to rebalance a position (close + reopen with same config).
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

    /// @notice Curator signals intent to close a position. Operator bot detects and fulfills.
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

    /// @notice Operator fulfills an open request. Passes module type hashes and calldata.
    ///         The vault resolves type hashes to current implementation addresses from the factory.
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

    /// @notice Operator confirms the off-chain short has been placed on Orderly.
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

    /// @notice Operator fulfills a close request.
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

    /// @notice Operator step 1 of rebalance: unwind on-chain legs.
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

    /// @notice Operator step 2 of rebalance: re-open on-chain legs.
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

    // ============ Vault Configuration (Curator) ============

    function whitelistTargetAsset(
        address vault,
        address asset
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        DiracVault(payable(vault)).whitelistTargetAsset(asset);
    }

    // ============ Low-level (Operator) ============

    /// @notice One-time module setup — no cycle state check. Used for initialization before trading.
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

    /// @dev Validates that every module type in the array is one of the vault's declared leg types
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
