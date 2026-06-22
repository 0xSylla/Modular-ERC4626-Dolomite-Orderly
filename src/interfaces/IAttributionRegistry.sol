// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IAttributionRegistry
/// @notice Attestation surface of the AttributionRegistry for the V4 +
///         multisig path. The registry decides eligibility, applies
///         DAO-tunable thresholds, and calls `SoulboundReceiptPool.mintReceipt`
///         for qualified actors. Nobody mints receipts except the registry —
///         the pool's `attributor` role is held by it alone.
///
///         In Phase 3 the attester roles are the Dirac multisig: it pushes the
///         facts the chain can't cheaply prove (per-cycle LP lists, curator
///         milestone confirmation, strategist performance judgment), and the
///         registry verifies what it can on-chain. In Phase 4 these roles
///         become the DAO governor and the attestations can be tightened to
///         on-chain enforcement.
interface IAttributionRegistry {
    /// @notice Attester pushes the LP list for a vault's cycle. The registry
    ///         mints LP SBT to each entry whose `deposit >= minLpDeposit`,
    ///         de-duped per `(vault, cycleId, lp)`.
    /// @param vault    Must be a factory vault (`factory.isVault`).
    /// @param cycleId  Vault-internal cycle counter; part of the de-dup key.
    /// @param lps      LP addresses for this cycle.
    /// @param deposits Per-LP deposit amounts (deposit-token units), index-aligned with `lps`.
    function attestLpsForCycle(
        address vault,
        uint256 cycleId,
        address[] calldata lps,
        uint256[] calldata deposits
    ) external;

    /// @notice Attester confirms a vault first jointly satisfied the curator
    ///         gate (`tvl >= minTvlForCurator` AND `uniqueLps >= minUniqueLps`).
    ///         One-time per vault. The registry re-checks the attested numbers
    ///         against the thresholds and mints `curatorBaseSbt` to the vault
    ///         creator.
    function attestCuratorGate(address vault, uint256 tvl, uint256 uniqueLps) external;

    /// @notice Strategist attester confirms `templateId` deployed in `vault`
    ///         performed in line with its backtest. Mints SBT to the template
    ///         author (set via `setTemplateAuthor`) scaled by
    ///         `min(vaultsUsingTemplate, maxStrategistVaultsCounted)`.
    function attestStrategistPerformance(
        bytes32 templateId,
        address vault,
        uint256 vaultsUsingTemplate
    ) external;

    // === Read-only thresholds ===
    function minLpDeposit() external view returns (uint256);
    function minTvlForCurator() external view returns (uint256);
    function minUniqueLps() external view returns (uint256);
}
