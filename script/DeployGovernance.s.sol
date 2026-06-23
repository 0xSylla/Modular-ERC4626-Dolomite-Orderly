// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DiracTimelock} from "../src/governance/DiracTimelock.sol";
import {DiracGovernor} from "../src/governance/DiracGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title DeployGovernance
/// @notice Phase 4 deploy — DiracTimelock + DiracGovernor over the existing
///         TDIRAC token. After deploy the timelock is self-administered:
///         the only way to act through it is a governance proposal.
///
///         Sequence:
///         1. Deploy DiracTimelock with proposers = [] and executors =
///            [address(0)] (anyone can execute a ready op). Deployer is the
///            temporary admin only to finish wiring.
///         2. Deploy DiracGovernor bound to TDIRAC + the timelock.
///         3. Grant PROPOSER_ROLE + CANCELLER_ROLE to the governor.
///         4. Renounce the deployer's admin role on the timelock.
///
/// @dev VOTE CLOCK IS BLOCK NUMBER (TDIRAC uses the default ERC20Votes clock),
///      so VOTING_DELAY_BLOCKS / VOTING_PERIOD_BLOCKS are in BLOCKS. Defaults
///      assume a ~12s block cadence (Arbitrum's L1 block.number). TIMELOCK_
///      MIN_DELAY is in SECONDS (timelock uses block.timestamp).
///
/// @dev Required env:
///   PRIVATE_KEY          deployer signer (covers gas; becomes temp timelock admin)
///   TDIRAC_ADDR          deployed TDIRAC token
///
///   Optional (defaults shown):
///   TIMELOCK_MIN_DELAY   seconds a queued op waits         (default 172800 = 2 days)
///   VOTING_DELAY_BLOCKS  blocks before voting starts       (default 7200  ≈ 1 day @ 12s)
///   VOTING_PERIOD_BLOCKS blocks voting stays open          (default 50400 ≈ 7 days @ 12s)
///   PROPOSAL_THRESHOLD   min votes to propose (token units)(default 10_000_000e18 = 0.1% of supply)
///   QUORUM_PERCENT       quorum as whole % of supply       (default 4)
contract DeployGovernance is Script {
    function run() external {
        address tdirac = vm.envAddress("TDIRAC_ADDR");
        require(tdirac != address(0), "TDIRAC_ADDR required");

        uint256 minDelay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(2 days));
        uint48 votingDelayBlocks = uint48(vm.envOr("VOTING_DELAY_BLOCKS", uint256(7200)));
        uint32 votingPeriodBlocks = uint32(vm.envOr("VOTING_PERIOD_BLOCKS", uint256(50400)));
        uint256 proposalThreshold = vm.envOr("PROPOSAL_THRESHOLD", uint256(10_000_000 * 1e18));
        uint256 quorumPercent = vm.envOr("QUORUM_PERCENT", uint256(4));

        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = deployerPk != 0 ? vm.addr(deployerPk) : msg.sender;

        if (deployerPk != 0) vm.startBroadcast(deployerPk);
        else vm.startBroadcast();

        // 1. Timelock — proposers empty (granted to governor below), executors
        //    open (address(0)), deployer is temp admin.
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone can execute a ready op
        DiracTimelock timelock = new DiracTimelock(minDelay, proposers, executors, deployer);
        console.log("DiracTimelock deployed at:", address(timelock));

        // 2. Governor.
        DiracGovernor governor = new DiracGovernor(
            IVotes(tdirac),
            timelock,
            votingDelayBlocks,
            votingPeriodBlocks,
            proposalThreshold,
            quorumPercent
        );
        console.log("DiracGovernor deployed at:", address(governor));

        // 3. Wire roles: governor can propose + cancel.
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        // 4. Deployer renounces admin — timelock is now governance-only.
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        // Sanity
        require(address(governor.timelock()) == address(timelock), "governor.timelock mismatch");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)), "proposer not set");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)), "canceller not set");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "executor not open");
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer), "deployer admin not renounced");
        require(governor.votingDelay() == votingDelayBlocks, "votingDelay mismatch");
        require(governor.votingPeriod() == votingPeriodBlocks, "votingPeriod mismatch");
        require(governor.proposalThreshold() == proposalThreshold, "proposalThreshold mismatch");

        console.log("");
        console.log("=== Governance deployment summary ===");
        console.log("  TDIRAC (existing):     ", tdirac);
        console.log("  DiracTimelock:         ", address(timelock));
        console.log("  DiracGovernor:         ", address(governor));
        console.log("  Timelock minDelay (s): ", minDelay);
        console.log("  votingDelay (blocks):  ", votingDelayBlocks);
        console.log("  votingPeriod (blocks): ", votingPeriodBlocks);
        console.log("  proposalThreshold:     ", proposalThreshold);
        console.log("  quorum (% of supply):  ", quorumPercent);
        console.log("");
        console.log("Hand off the Phase 2-3 multisig roles to the timelock (current admin calls):");
        console.log("  registry.setAdmin(timelock)");
        console.log("  registry.setAttester(timelock)            // or keep multisig as a faster attester");
        console.log("  registry.setStrategistAttester(timelock)  // or keep multisig");
        console.log("  pool.setAdmin(timelock)");
        console.log("  // pool.attributor stays the AttributionRegistry");
        console.log("");
        console.log("Reminder: holders must delegate() (to self or another) for voting power to count.");
    }
}
