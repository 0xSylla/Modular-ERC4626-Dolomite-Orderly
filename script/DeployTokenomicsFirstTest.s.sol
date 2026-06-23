// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {TestUSDC} from "../src/mocks/TestUSDC.sol";
import {MockV2Router} from "../src/mocks/MockV2Router.sol";
import {TDIRAC} from "../src/token/TDIRAC.sol";
import {SoulboundReceiptToken} from "../src/token/SoulboundReceiptToken.sol";
import {SoulboundReceiptPool} from "../src/token/SoulboundReceiptPool.sol";
import {AttributionRegistry} from "../src/registry/AttributionRegistry.sol";
import {DiracTimelock} from "../src/governance/DiracTimelock.sol";
import {DiracGovernor} from "../src/governance/DiracGovernor.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";
import {BuyBackEngine} from "../src/buyback/BuyBackEngine.sol";

/// @title DeployTokenomicsFirstTest
/// @notice One-shot deploy of the FULL tokenomics stack for a first test on
///         Arbitrum mainnet. Every admin/attester/keeper/distributor role goes
///         to the DEPLOYER (no multisig, per the first-test plan). Revenue is
///         simulated with a mock TestUSDC + mock V2 router (TDIRAC has no real
///         DEX pool yet). The AttributionRegistry binds to the REAL live V4
///         factory so attribution can be tested against actual vaults.
///
///         Deploys, in order (deployer is also the TDIRAC treasury):
///           TestUSDC -> TDIRAC -> SBT + Pool -> AttributionRegistry ->
///           Timelock + Governor -> Staking -> MockV2Router -> BuyBackEngine
///         then wires: pool.attributor = registry, seeds the pool burn reserve,
///         seeds the mock router with TDIRAC, self-delegates votes.
///
/// @dev Required env:
///   PRIVATE_KEY   deployer (becomes every role + TDIRAC treasury)
///   FACTORY_ADDR  the live V4 DiracVaultFactory on Arbitrum
///                 (handoff value: 0xfB1dD48e7b353690938c7c2aBf213e67e4CF8ed2 —
///                  VERIFY before broadcast; do NOT trust stale ARB_FACTORY_ADDR)
///
///   Optional (test-friendly defaults):
///   POOL_RESERVE         TDIRAC seeded into the pool burn reserve (default 100,000,000e18)
///   ROUTER_LIQUIDITY     TDIRAC seeded into the mock router        (default 100,000,000e18)
///   BUYBACK_RATE         TDIRAC out per 1 USDC in (default 1e18 = 1:1)
///   TIMELOCK_MIN_DELAY   seconds (default 300 = 5 min, test-fast)
///   VOTING_DELAY_BLOCKS  blocks (default 1)
///   VOTING_PERIOD_BLOCKS blocks (default 300 ≈ 1h @ 12s)
///   PROPOSAL_THRESHOLD   token units (default 1000e18)
///   QUORUM_PERCENT       (default 4)
contract DeployTokenomicsFirstTest is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address factory = vm.envAddress("FACTORY_ADDR");
        require(factory != address(0), "FACTORY_ADDR required");
        require(factory.code.length > 0, "FACTORY_ADDR is not a contract");

        uint256 poolReserve = vm.envOr("POOL_RESERVE", uint256(100_000_000 * 1e18));
        uint256 routerLiquidity = vm.envOr("ROUTER_LIQUIDITY", uint256(100_000_000 * 1e18));
        uint256 buybackRate = vm.envOr("BUYBACK_RATE", uint256(1e18));
        uint256 minDelay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(300));
        uint48 vDelay = uint48(vm.envOr("VOTING_DELAY_BLOCKS", uint256(1)));
        uint32 vPeriod = uint32(vm.envOr("VOTING_PERIOD_BLOCKS", uint256(300)));
        uint256 threshold = vm.envOr("PROPOSAL_THRESHOLD", uint256(1000 * 1e18));
        uint256 quorumPct = vm.envOr("QUORUM_PERCENT", uint256(4));

        console.log("Deployer (all roles + treasury):", deployer);
        console.log("V4 factory (registry binds to):  ", factory);

        vm.startBroadcast(pk);

        // 1. Mock revenue token.
        TestUSDC usdc = new TestUSDC();

        // 2. TDIRAC — full supply mints to the deployer (treasury).
        TDIRAC dirac = new TDIRAC(deployer);

        // 3. Soulbound layer (precompute pool addr: SBT at nonce, Pool at nonce+1).
        uint256 nonce = vm.getNonce(deployer);
        address futurePool = vm.computeCreateAddress(deployer, nonce + 1);
        SoulboundReceiptToken sbt = new SoulboundReceiptToken(futurePool);
        SoulboundReceiptPool pool = new SoulboundReceiptPool(
            address(dirac), address(sbt), address(usdc), deployer, deployer
        );
        require(address(pool) == futurePool, "pool addr prediction broke");

        // 4. Attribution registry — bound to the REAL V4 factory; deployer holds
        //    admin + both attester roles.
        AttributionRegistry registry = new AttributionRegistry(
            address(pool), factory, deployer, deployer, deployer
        );

        // 5. Governance.
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        DiracTimelock timelock = new DiracTimelock(minDelay, proposers, executors, deployer);
        DiracGovernor governor = new DiracGovernor(
            IVotes(address(dirac)), timelock, vDelay, vPeriod, threshold, quorumPct
        );
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        // 6. Staking (deployer = admin + rewards distributor).
        StakingContract staking = new StakingContract(
            address(dirac), address(usdc), deployer, deployer, 7 days
        );

        // 7. Buyback via mock router (seeded with TDIRAC), recipient = pool.
        MockV2Router router = new MockV2Router(buybackRate);
        dirac.transfer(address(router), routerLiquidity);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dirac);
        BuyBackEngine engine = new BuyBackEngine(
            address(usdc), address(dirac), address(router), address(pool), deployer, deployer, path
        );

        // 8. Wiring.
        pool.setAttributor(address(registry));          // deployer is pool admin
        dirac.transfer(address(pool), poolReserve);     // seed burn reserve
        dirac.delegate(deployer);                        // make deployer's votes count

        vm.stopBroadcast();

        // ===== Sanity =====
        require(pool.attributor() == address(registry), "attributor not registry");
        require(address(registry.factory()) == factory, "registry factory mismatch");
        require(registry.admin() == deployer, "registry admin");
        require(pool.diracReserve() == poolReserve, "reserve mismatch");
        require(IERC20(address(dirac)).balanceOf(address(router)) == routerLiquidity, "router liq mismatch");
        require(engine.recipient() == address(pool), "buyback recipient");
        require(staking.rewardsDistributor() == deployer, "staking distributor");
        require(governor.proposalThreshold() == threshold, "threshold");

        console.log("");
        console.log("=== TOKENOMICS FIRST-TEST DEPLOY (Arbitrum) ===");
        console.log("  TestUSDC:            ", address(usdc));
        console.log("  TDIRAC:              ", address(dirac));
        console.log("  SBT:                 ", address(sbt));
        console.log("  SoulboundReceiptPool:", address(pool));
        console.log("  AttributionRegistry: ", address(registry));
        console.log("  DiracTimelock:       ", address(timelock));
        console.log("  DiracGovernor:       ", address(governor));
        console.log("  StakingContract:     ", address(staking));
        console.log("  MockV2Router:        ", address(router));
        console.log("  BuyBackEngine:       ", address(engine));
        console.log("");
        console.log("  V4 factory (real):   ", factory);
        console.log("  Pool burn reserve:   ", poolReserve);
        console.log("  Router TDIRAC liq:   ", routerLiquidity);
        console.log("");
        console.log("Simulate revenue from another wallet:");
        console.log("  usdc.mint(wallet, amt)");
        console.log("  -> SBT holders: usdc.approve(pool, amt); pool.distributeRevenue(amt)");
        console.log("  -> stakers:     usdc.approve(staking, amt); staking.notifyRewardAmount(amt)  [deployer=distributor]");
        console.log("  -> buyback:     usdc.mint(buyback, amt); engine.buyback(amt, minOut, deadline) [deployer=keeper]");
    }
}
