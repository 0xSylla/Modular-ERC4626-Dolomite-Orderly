// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IAttributionRegistry
/// @notice Minimal interface that V5 vault + V5 factory use to notify the
///         AttributionRegistry of events that may qualify a contributor
///         (LP / Curator / Strategist) for a SoulboundReceipt mint.
///
///         Hooks are intentionally narrow: vaults push events; the registry
///         decides eligibility, applies DAO-tunable thresholds, and calls
///         `SoulboundReceiptPool.mintReceipt` for qualified actors. Vaults
///         do NOT call the pool directly — the registry mediates so that:
///           1. Eligibility logic is centralized + governable.
///           2. The pool's `attributor` role is held by the registry alone.
///           3. Adding new attribution paths in the future (referrals, bug
///              bounties, etc.) doesn't require new vault deployments.
///
///         All hooks must be SAFE TO REVERT — calling vaults wrap them in
///         try/catch so a malfunctioning registry can't brick `closeCycle`
///         or `deposit`.
interface IAttributionRegistry {
    /// @notice Notify registry that a vault's cycle has just transitioned
    ///         TRADING → CLOSED. Registry iterates the vault's depositor
    ///         list and mints LP SBT to each who meets `minLpDeposit`.
    /// @param cycleId Vault-internal counter incremented at each closeCycle.
    ///                Registry uses (msg.sender, cycleId) as the de-dup key.
    function onCycleClose(uint256 cycleId) external;

    /// @notice Notify registry that a vault has FIRST jointly satisfied
    ///         `totalAssets >= minTvlForCurator` AND `uniqueDepositorCount >=
    ///         minUniqueLps`. One-time per vault — the vault is responsible
    ///         for the `bool curatorAttributed` latch.
    function onCuratorGateHit() external;

    // === Read-only — used by V5 vault to know the LP gate ===
    function minLpDeposit() external view returns (uint256);
    function minTvlForCurator() external view returns (uint256);
    function minUniqueLps() external view returns (uint256);
}
