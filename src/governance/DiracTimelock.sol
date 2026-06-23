// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title DiracTimelock
/// @notice Thin named wrapper over OZ `TimelockController`. This is the contract
///         that actually HOLDS power in Phase 4: it becomes the `admin` of the
///         AttributionRegistry + SoulboundReceiptPool (and any other tunable
///         module), so every privileged change must pass through a governance
///         proposal + the timelock delay before it executes.
///
///         Role wiring (set at deploy, see DeployGovernance.s.sol):
///         - PROPOSER_ROLE  → DiracGovernor (only passed proposals can queue)
///         - CANCELLER_ROLE → DiracGovernor (+ optionally a guardian multisig)
///         - EXECUTOR_ROLE  → address(0) (anyone can execute a ready op; the
///           delay already provides the protection)
///         - admin          → renounced by the deployer after wiring, so the
///           timelock is self-administered via governance only.
contract DiracTimelock is TimelockController {
    /// @param minDelay  Seconds a queued op must wait before execution (uses
    ///                  block.timestamp, independent of the token vote-clock).
    /// @param proposers Initial proposers (the governor).
    /// @param executors Initial executors (use [address(0)] for "anyone").
    /// @param admin     Temporary admin used only to finish wiring; renounce
    ///                  after (pass the deployer, then renounce in the script).
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}
}
