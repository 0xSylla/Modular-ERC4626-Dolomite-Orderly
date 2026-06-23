// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TDIRAC} from "../src/token/TDIRAC.sol";
import {DiracTimelock} from "../src/governance/DiracTimelock.sol";
import {DiracGovernor} from "../src/governance/DiracGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

/// @dev A target the timelock is meant to control. `setValue` is only callable
///      by the timelock — i.e., only via a passed + queued + executed proposal.
contract MockGoverned {
    uint256 public value;
    address public immutable gov;

    error NotGov();

    constructor(address _gov) {
        gov = _gov;
    }

    function setValue(uint256 v) external {
        if (msg.sender != gov) revert NotGov();
        value = v;
    }
}

contract GovernanceTest is Test {
    TDIRAC internal dirac;
    DiracTimelock internal timelock;
    DiracGovernor internal governor;
    MockGoverned internal target;

    address internal treasury = address(0xCAFE);
    address internal alice = address(0xA11CE);

    // Small, test-friendly settings.
    uint256 internal constant MIN_DELAY = 1 days;
    uint48 internal constant VOTING_DELAY = 1;       // blocks
    uint32 internal constant VOTING_PERIOD = 50;     // blocks
    uint256 internal constant PROPOSAL_THRESHOLD = 1000 * 1e18;
    uint256 internal constant QUORUM_PCT = 4;        // 4% of supply

    function setUp() public {
        dirac = new TDIRAC(treasury);

        // Treasury delegates to itself so its full balance counts as votes.
        vm.prank(treasury);
        dirac.delegate(treasury);

        // Timelock: no proposers yet, open executor, this test is temp admin.
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new DiracTimelock(MIN_DELAY, proposers, executors, address(this));

        governor = new DiracGovernor(
            IVotes(address(dirac)), timelock, VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD, QUORUM_PCT
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        // Mirror prod: deployer renounces admin.
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        target = new MockGoverned(address(timelock));

        // Advance a block so delegation checkpoints are in the past.
        vm.roll(block.number + 1);
    }

    // ============ Wiring ============

    function test_wiring() public view {
        assertEq(address(governor.timelock()), address(timelock));
        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), PROPOSAL_THRESHOLD);
        // quorum = 4% of 10B supply
        assertEq(governor.quorum(block.number - 1), dirac.totalSupply() * QUORUM_PCT / 100);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    // ============ Full lifecycle ============

    function _buildProposal()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory desc)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(target);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSelector(MockGoverned.setValue.selector, uint256(42));
        desc = "set value to 42";
    }

    function test_fullLifecycle_proposeVoteQueueExecute() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _buildProposal();

        vm.prank(treasury);
        uint256 id = governor.propose(t, v, c, d);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));

        // Past the voting delay → Active.
        vm.roll(block.number + VOTING_DELAY + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active));

        vm.prank(treasury);
        governor.castVote(id, 1); // For

        // Past the voting period → Succeeded (treasury alone exceeds quorum).
        vm.roll(block.number + VOTING_PERIOD + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));

        bytes32 descHash = keccak256(bytes(d));
        governor.queue(t, v, c, descHash);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Queued));

        // Past the timelock delay → executable.
        vm.warp(block.timestamp + MIN_DELAY + 1);
        governor.execute(t, v, c, descHash);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Executed));

        assertEq(target.value(), 42);
    }

    // ============ Gating ============

    function test_proposeBelowThresholdReverts() public {
        // alice has no votes.
        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _buildProposal();
        vm.prank(alice);
        vm.expectRevert();
        governor.propose(t, v, c, d);
    }

    function test_quorumNotReachedDefeats() public {
        // Give alice just enough to propose, far below the 4% quorum.
        vm.prank(treasury);
        dirac.transfer(alice, PROPOSAL_THRESHOLD);
        vm.prank(alice);
        dirac.delegate(alice);
        vm.roll(block.number + 1);

        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _buildProposal();
        vm.prank(alice);
        uint256 id = governor.propose(t, v, c, d);

        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(alice);
        governor.castVote(id, 1); // For, but below quorum

        vm.roll(block.number + VOTING_PERIOD + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_againstVotesDefeat() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _buildProposal();
        vm.prank(treasury);
        uint256 id = governor.propose(t, v, c, d);

        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(treasury);
        governor.castVote(id, 0); // Against

        vm.roll(block.number + VOTING_PERIOD + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_cannotExecuteBeforeTimelockDelay() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _buildProposal();
        vm.prank(treasury);
        uint256 id = governor.propose(t, v, c, d);
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(treasury);
        governor.castVote(id, 1);
        vm.roll(block.number + VOTING_PERIOD + 1);

        bytes32 descHash = keccak256(bytes(d));
        governor.queue(t, v, c, descHash);

        // No warp — timelock op not ready yet.
        vm.expectRevert();
        governor.execute(t, v, c, descHash);
        assertEq(target.value(), 0);
    }

    function test_directCallToTargetReverts() public {
        // Confirms the target really is timelock-gated.
        vm.expectRevert(MockGoverned.NotGov.selector);
        target.setValue(99);
    }
}
