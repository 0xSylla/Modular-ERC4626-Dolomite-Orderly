// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title DiracGovernor
/// @notice Phase 4 on-chain governance for the Dirac protocol. Standard OZ v5
///         Governor over TDIRAC's `ERC20Votes` checkpoints, with a timelock.
///         Proposals that pass are queued in the `DiracTimelock`, which is the
///         address that actually holds admin power over the registry + pool +
///         buyback + staking modules. This realizes Step 6 of the tokenomics
///         roadmap and lets the DAO replace the Phase 2-3 multisig roles.
///
///         **Vote clock = block number.** TDIRAC uses the default `ERC20Votes`
///         clock (it does NOT override `clock()`/`CLOCK_MODE`), so `votingDelay`
///         and `votingPeriod` are denominated in BLOCKS, not seconds. The
///         deploy script picks block counts based on the target chain's block
///         cadence; both are `GovernorSettings`-tunable by governance later.
///         (The timelock's `minDelay`, by contrast, is in seconds — it uses
///         `block.timestamp`.)
///
///         Composition (canonical OZ Wizard layout):
///         - GovernorSettings          — votingDelay / votingPeriod / proposalThreshold
///         - GovernorCountingSimple    — For / Against / Abstain
///         - GovernorVotes             — reads TDIRAC voting power
///         - GovernorVotesQuorumFraction — quorum as a % of total supply
///         - GovernorTimelockControl   — queue/execute through DiracTimelock
contract DiracGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /// @param token              TDIRAC (must implement IVotes via ERC20Votes).
    /// @param timelock           DiracTimelock controller.
    /// @param votingDelayBlocks  Blocks between proposal creation and vote start.
    /// @param votingPeriodBlocks Blocks the vote stays open.
    /// @param proposalThreshold_ Min voting power to create a proposal (token units).
    /// @param quorumPercent      Quorum as a whole-number percent of total supply (e.g. 4 = 4%).
    constructor(
        IVotes token,
        TimelockController timelock,
        uint48 votingDelayBlocks,
        uint32 votingPeriodBlocks,
        uint256 proposalThreshold_,
        uint256 quorumPercent
    )
        Governor("DiracGovernor")
        GovernorSettings(votingDelayBlocks, votingPeriodBlocks, proposalThreshold_)
        GovernorVotes(token)
        GovernorVotesQuorumFraction(quorumPercent)
        GovernorTimelockControl(timelock)
    {}

    // ============ Required overrides (OZ v5 multiple inheritance) ============

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function quorum(uint256 timepoint)
        public
        view
        override(Governor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(timepoint);
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
