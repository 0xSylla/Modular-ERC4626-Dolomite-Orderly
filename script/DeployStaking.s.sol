// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";

/// @title DeployStaking
/// @notice Phase 4 deploy — StakingContract (stake TDIRAC, earn USDC streamed
///         over a reward window). Independent revenue sink; funded via
///         `notifyRewardAmount` by the rewards distributor.
///
/// @dev Required env:
///   PRIVATE_KEY     deployer signer (covers gas)
///   ADMIN           multisig — admin (handed to DiracTimelock later)
///   TDIRAC_ADDR     staking token (TDIRAC)
///   REVENUE_TOKEN   reward token (USDC on the target chain)
///
///   Optional (defaults shown):
///   REWARDS_DISTRIBUTOR  who funds rewards (default ADMIN)
///   REWARDS_DURATION     reward window seconds (default 604800 = 7 days)
contract DeployStaking is Script {
    function run() external {
        address admin = vm.envAddress("ADMIN");
        address tdirac = vm.envAddress("TDIRAC_ADDR");
        address revenueToken = vm.envAddress("REVENUE_TOKEN");
        require(admin != address(0), "ADMIN required");
        require(tdirac != address(0), "TDIRAC_ADDR required");
        require(revenueToken != address(0), "REVENUE_TOKEN required");

        address distributor = vm.envOr("REWARDS_DISTRIBUTOR", admin);
        uint256 duration = vm.envOr("REWARDS_DURATION", uint256(7 days));

        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPk != 0) vm.startBroadcast(deployerPk);
        else vm.startBroadcast();

        StakingContract staking = new StakingContract(
            tdirac, revenueToken, admin, distributor, duration
        );
        console.log("StakingContract deployed at:", address(staking));

        vm.stopBroadcast();

        require(address(staking.stakingToken()) == tdirac, "stakingToken mismatch");
        require(address(staking.rewardsToken()) == revenueToken, "rewardsToken mismatch");
        require(staking.admin() == admin, "admin mismatch");
        require(staking.rewardsDistributor() == distributor, "distributor mismatch");
        require(staking.rewardsDuration() == duration, "duration mismatch");

        console.log("");
        console.log("=== StakingContract deployment summary ===");
        console.log("  Staking token (TDIRAC):", tdirac);
        console.log("  Reward token (USDC):   ", revenueToken);
        console.log("  Staking:               ", address(staking));
        console.log("  Admin:                 ", admin);
        console.log("  Rewards distributor:   ", distributor);
        console.log("  Rewards duration (s):  ", duration);
        console.log("");
        console.log("To fund a reward window (distributor):");
        console.log("  USDC.approve(staking, amount); staking.notifyRewardAmount(amount)");
        console.log("Hand admin to governance later: staking.setAdmin(timelock)");
    }
}
