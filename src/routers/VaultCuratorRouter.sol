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
    /// vault => leg config (set once by curator, shared across all positions)
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

    /// @notice Set the modules used for all positions in this vault. Called once during setup.
    /// @dev Legs are vault-scoped — all positions share the same swap/lending/perps modules.
    function setVaultLegs(
        address vault,
        Data.LegConfig calldata legs
    ) external onlyFactoryVault(vault) onlyCurator(vault) {
        if (legs.swapModule == address(0) || legs.lendingModule == address(0) || legs.perpsModule == address(0))
            revert Events.ZeroAddress();
        vaultLegs[vault] = legs;
        emit Events.VaultLegsSet(vault, legs.swapModule, legs.lendingModule, legs.perpsModule);
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
        if (legs.swapModule == address(0)) revert Events.ModuleNotWhitelisted();

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
    ///         Operator bot detects, closes on-chain legs, runs Orderly cycle off-chain, then reopens.
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

    /// @notice Operator fulfills an open request. The API builds the modules array and calldata
    ///         based on the vault's strategy template (recipe order determined off-chain).
    /// @param vault The vault address
    /// @param positionId The position to open
    /// @param modules Ordered module addresses (built by API from strategy template)
    /// @param datas Encoded calldata for each module call
    function executeOpeningRequest(
        address vault,
        uint256 positionId,
        address[] calldata modules,
        bytes[] calldata datas
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes[] memory results) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.OPEN_REQUESTED)
            revert Events.PositionNotOpenRequested();

        _validateModules(vaultLegs[vault], modules);
        p.status = Data.PositionStatus.OPENING;

        results = DiracVault(payable(vault)).executeBatch{value: msg.value}(modules, datas);
        emit Events.PositionOpening(positionId);
    }

    /// @notice Operator confirms the off-chain short has been placed on Orderly.
    ///         Called after executeOpeningRequest once the deposit settles and the short is live.
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

    /// @notice Operator fulfills a close request. The API builds the modules array and calldata
    ///         based on the vault's strategy template (reverse recipe).
    /// @dev Perps withdrawal (closing the short + withdrawing margin) happens off-chain
    ///      via Orderly before this function is called.
    /// @param vault The vault address
    /// @param positionId The position to close
    /// @param modules Ordered module addresses (built by API from strategy template)
    /// @param datas Encoded calldata for each module call
    function executeClosingRequest(
        address vault,
        uint256 positionId,
        address[] calldata modules,
        bytes[] calldata datas
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes[] memory results) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.CLOSE_REQUESTED)
            revert Events.PositionNotCloseRequested();

        _validateModules(vaultLegs[vault], modules);
        p.status = Data.PositionStatus.IDLE;

        results = DiracVault(payable(vault)).executeBatch{value: msg.value}(modules, datas);
        emit Events.PositionClosed(positionId);
    }

    /// @notice Operator step 1 of rebalance: unwind on-chain legs (repay borrow, withdraw collateral).
    ///         After this, the operator runs the Orderly close+reopen cycle off-chain, then calls
    ///         executeRebalanceOpen to complete the rebalance.
    function executeRebalanceClose(
        address vault,
        uint256 positionId,
        address[] calldata modules,
        bytes[] calldata datas
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes[] memory results) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.REBALANCE_REQUESTED)
            revert Events.PositionNotRebalanceRequested();

        _validateModules(vaultLegs[vault], modules);
        p.status = Data.PositionStatus.REBALANCING;

        results = DiracVault(payable(vault)).executeBatch{value: msg.value}(modules, datas);
        emit Events.PositionRebalancing(positionId);
    }

    /// @notice Operator step 2 of rebalance: re-open on-chain legs (swap, supply, borrow, deposit to perps).
    ///         Called after Orderly has been re-initialized off-chain.
    function executeRebalanceOpen(
        address vault,
        uint256 positionId,
        address[] calldata modules,
        bytes[] calldata datas
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes[] memory results) {
        PositionRecord storage p = positions[vault][positionId];
        if (p.vault == address(0)) revert Events.OperationFailed();
        if (p.status != Data.PositionStatus.REBALANCING)
            revert Events.PositionNotRebalancing();

        _validateModules(vaultLegs[vault], modules);
        p.status = Data.PositionStatus.ACTIVE;

        results = DiracVault(payable(vault)).executeBatch{value: msg.value}(modules, datas);
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
        address module,
        bytes calldata data
    ) external onlyFactoryVault(vault) onlyOperator(vault) returns (bytes memory) {
        return DiracVault(payable(vault)).setupModule(module, data);
    }

    function executeModule(
        address vault,
        address module,
        bytes calldata data
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes memory) {
        return DiracVault(payable(vault)).executeModule{value: msg.value}(module, data);
    }

    function executeBatch(
        address vault,
        address[] calldata modules,
        bytes[] calldata datas
    ) external payable onlyFactoryVault(vault) onlyOperator(vault) returns (bytes[] memory) {
        return DiracVault(payable(vault)).executeBatch{value: msg.value}(modules, datas);
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

    /// @dev Validates that every module in the array is one of the vault's declared legs
    function _validateModules(
        Data.LegConfig storage legs,
        address[] calldata modules
    ) internal view {
        for (uint256 i = 0; i < modules.length; i++) {
            address m = modules[i];
            if (
                m != legs.swapModule &&
                m != legs.lendingModule &&
                m != legs.perpsModule
            ) revert Events.ModuleNotWhitelisted();
        }
    }
}
