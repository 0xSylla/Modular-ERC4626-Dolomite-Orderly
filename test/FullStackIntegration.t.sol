// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {TDIRAC} from "../src/token/TDIRAC.sol";
import {SoulboundReceiptToken} from "../src/token/SoulboundReceiptToken.sol";
import {SoulboundReceiptPool} from "../src/token/SoulboundReceiptPool.sol";
import {AttributionRegistry} from "../src/registry/AttributionRegistry.sol";
import {DiracTimelock} from "../src/governance/DiracTimelock.sol";
import {DiracGovernor} from "../src/governance/DiracGovernor.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";
import {BuyBackEngine} from "../src/buyback/BuyBackEngine.sol";
import {Data} from "../src/libraries/Data.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract MockFactory {
    mapping(address => bool) public isVault;
    mapping(address => Data.VaultInfo) internal _info;
    function setVault(address vault, address creator, bytes32 templateId) external {
        isVault[vault] = true;
        _info[vault] = Data.VaultInfo({vault: vault, creator: creator, templateId: templateId, deployedAt: 1});
    }
    function vaultInfo(address vault) external view returns (Data.VaultInfo memory) { return _info[vault]; }
}

/// @dev V2 router: 1 USDC (1e6) -> `rate`/1e6 TDIRAC, pulls input, pays output.
contract MockV2Router {
    uint256 public rate;
    constructor(uint256 _rate) { rate = _rate; }
    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rate) / 1e6;
        require(out >= amountOutMin, "slippage");
        IERC20(path[path.length - 1]).transfer(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn; amounts[1] = out;
    }
}

/// @notice End-to-end wiring of the full tokenomics stack. Proves the pieces
///         compose: attribution mints SBT (burning TDIRAC), revenue flows to
///         SBT holders + stakers, the buyback feeds the pool, and — critically
///         — after the multisig hands admin to the timelock, the DAO can
///         actually tune the modules through a full governance proposal.
contract FullStackIntegrationTest is Test {
    // actors
    address internal treasury = address(0xCAFE);
    address internal multisig; // set in setUp via makeAddr
    address internal attester = address(0xA77E);
    address internal keeper = address(0x6EE9);
    address internal distributor = address(0xD157);
    address internal lp1 = address(0x1111);
    address internal lp2 = address(0x2222);
    address internal curator = address(0xC0A70);
    address internal strategist = address(0x57BA);
    address internal staker = address(0x57AE);

    // contracts
    TDIRAC internal dirac;
    MockUSDC internal usdc;
    SoulboundReceiptToken internal sbt;
    SoulboundReceiptPool internal pool;
    AttributionRegistry internal registry;
    DiracTimelock internal timelock;
    DiracGovernor internal governor;
    StakingContract internal staking;
    BuyBackEngine internal engine;
    MockFactory internal factory;
    MockV2Router internal router;

    address internal vault = address(0x7A017);
    bytes32 internal constant TEMPLATE = keccak256("delta-neutral-v1");

    uint256 internal constant USDC1 = 1e6;
    uint256 internal constant RATE = 2e18; // 1 USDC -> 2 TDIRAC

    // governance params
    uint256 internal constant MIN_DELAY = 1 days;
    uint48 internal constant V_DELAY = 1;
    uint32 internal constant V_PERIOD = 50;
    uint256 internal constant THRESHOLD = 1000 * 1e18;
    uint256 internal constant QUORUM_PCT = 4;

    function setUp() public {
        multisig = makeAddr("multisig");

        // --- tokens ---
        dirac = new TDIRAC(treasury);
        usdc = new MockUSDC();

        // --- soulbound layer (precomputed pool addr) ---
        uint256 n = vm.getNonce(address(this));
        address futurePool = vm.computeCreateAddress(address(this), n + 1);
        sbt = new SoulboundReceiptToken(futurePool);
        pool = new SoulboundReceiptPool(address(dirac), address(sbt), address(usdc), multisig, multisig);
        assertEq(address(pool), futurePool);

        // --- attribution ---
        factory = new MockFactory();
        factory.setVault(vault, curator, TEMPLATE);
        registry = new AttributionRegistry(address(pool), address(factory), multisig, attester, attester);

        // --- governance ---
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new DiracTimelock(MIN_DELAY, proposers, executors, address(this));
        governor = new DiracGovernor(IVotes(address(dirac)), timelock, V_DELAY, V_PERIOD, THRESHOLD, QUORUM_PCT);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        // --- staking ---
        staking = new StakingContract(address(dirac), address(usdc), multisig, distributor, 7 days);

        // --- buyback (recipient = pool) ---
        router = new MockV2Router(RATE);
        vm.prank(treasury);
        dirac.transfer(address(router), 100_000_000 * 1e18); // router liquidity
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dirac);
        engine = new BuyBackEngine(address(usdc), address(dirac), address(router), address(pool), multisig, keeper, path);

        // --- wiring: registry is the sole pool minter; seed burn reserve ---
        vm.prank(multisig);
        pool.setAttributor(address(registry));
        vm.prank(treasury);
        dirac.transfer(address(pool), 1_000_000_000 * 1e18); // 1B TDIRAC reserve

        // treasury delegates for governance voting power
        vm.prank(treasury);
        dirac.delegate(treasury);
        vm.roll(block.number + 1);
    }

    /// Full lifecycle in one flow.
    function test_endToEnd() public {
        // ===== 1. Attribution mints SBT (and burns TDIRAC reserve) =====
        uint256 reserveBefore = pool.diracReserve();

        address[] memory lps = new address[](2);
        uint256[] memory deps = new uint256[](2);
        lps[0] = lp1; deps[0] = 500 * USDC1;
        lps[1] = lp2; deps[1] = 1500 * USDC1;
        vm.prank(attester);
        registry.attestLpsForCycle(vault, 1, lps, deps);

        vm.prank(attester);
        registry.attestCuratorGate(vault, 20_000 * USDC1, 12);

        vm.prank(multisig);
        registry.setTemplateAuthor(TEMPLATE, strategist);
        vm.prank(attester);
        registry.attestStrategistPerformance(TEMPLATE, vault, 2);

        // SBT minted: lp1 500, lp2 1500, curator 1000, strategist 2000*2=4000
        assertEq(sbt.balanceOf(lp1), 500 * 1e18);
        assertEq(sbt.balanceOf(lp2), 1500 * 1e18);
        assertEq(sbt.balanceOf(curator), 1000 * 1e18);
        assertEq(sbt.balanceOf(strategist), 4000 * 1e18);
        uint256 totalSbt = sbt.totalSupply();
        assertEq(totalSbt, 7000 * 1e18);
        // Reserve burned 1:1 with SBT minted.
        assertEq(reserveBefore - pool.diracReserve(), totalSbt);

        // ===== 2. Revenue -> SBT holders (pro-rata), claim =====
        usdc.mint(treasury, 7000 * USDC1);
        vm.startPrank(treasury);
        usdc.approve(address(pool), 7000 * USDC1);
        pool.distributeRevenue(7000 * USDC1);
        vm.stopPrank();

        // lp1 holds 500/7000 of supply -> 500 USDC
        uint256 lp1Before = usdc.balanceOf(lp1);
        vm.prank(lp1);
        pool.claim();
        assertApproxEqAbs(usdc.balanceOf(lp1) - lp1Before, 500 * USDC1, 1);

        // ===== 3. Staking: stake TDIRAC, earn USDC over a window =====
        vm.prank(treasury);
        dirac.transfer(staker, 1000 * 1e18);
        vm.startPrank(staker);
        dirac.approve(address(staking), type(uint256).max);
        staking.stake(1000 * 1e18);
        vm.stopPrank();

        usdc.mint(distributor, 700 * USDC1);
        vm.startPrank(distributor);
        usdc.approve(address(staking), 700 * USDC1);
        staking.notifyRewardAmount(700 * USDC1);
        vm.stopPrank();

        skip(7 days);
        uint256 stakerBefore = usdc.balanceOf(staker);
        vm.prank(staker);
        staking.getReward();
        assertApproxEqAbs(usdc.balanceOf(staker) - stakerBefore, 700 * USDC1, 1e6);

        // ===== 4. Buyback: USDC -> TDIRAC -> pool reserve =====
        usdc.mint(address(engine), 1000 * USDC1);
        uint256 poolReserveBefore = pool.diracReserve();
        vm.prank(keeper);
        engine.buyback(1000 * USDC1, 2000 * 1e18, block.timestamp + 1);
        // pool received 1000 * RATE/1e6 = 2000 TDIRAC
        assertEq(pool.diracReserve() - poolReserveBefore, 2000 * 1e18);

        // ===== 5. Governance takeover: hand admin to timelock, then DAO tunes =====
        vm.startPrank(multisig);
        registry.setAdmin(address(timelock));
        pool.setAdmin(address(timelock));
        staking.setAdmin(address(timelock));
        engine.setAdmin(address(timelock));
        vm.stopPrank();

        // multisig can no longer tune the registry
        vm.prank(multisig);
        vm.expectRevert(AttributionRegistry.AR__OnlyAdmin.selector);
        registry.setMinLpDeposit(1);

        // DAO proposal: registry.setMinLpDeposit(250e6)
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(registry);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSelector(AttributionRegistry.setMinLpDeposit.selector, uint256(250 * USDC1));
        string memory desc = "raise minLpDeposit to 250 USDC";

        vm.prank(treasury);
        uint256 id = governor.propose(targets, values, calldatas, desc);
        vm.roll(block.number + V_DELAY + 1);
        vm.prank(treasury);
        governor.castVote(id, 1);
        vm.roll(block.number + V_PERIOD + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));

        bytes32 descHash = keccak256(bytes(desc));
        governor.queue(targets, values, calldatas, descHash);
        vm.warp(block.timestamp + MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descHash);

        assertEq(registry.minLpDeposit(), 250 * USDC1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Executed));
    }
}
