// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TDIRAC} from "../src/token/TDIRAC.sol";
import {SoulboundReceiptToken} from "../src/token/SoulboundReceiptToken.sol";
import {SoulboundReceiptPool} from "../src/token/SoulboundReceiptPool.sol";
import {LockStaking} from "../src/staking/LockStaking.sol";
import {RevenueRouter} from "../src/revenue/RevenueRouter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract LockStakingTest is Test {
    TDIRAC internal dirac;
    MockUSDC internal usdc;
    LockStaking internal staking;

    address internal treasury = address(0xCAFE);
    address internal admin = address(0xAD);
    address internal distributor = address(0xD157);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant DURATION = 7 days;
    uint256 internal constant USDC1 = 1e6;

    function setUp() public {
        dirac = new TDIRAC(treasury);
        usdc = new MockUSDC();
        staking = new LockStaking(address(dirac), address(usdc), admin, distributor, DURATION, 4);

        vm.startPrank(treasury);
        dirac.transfer(alice, 1_000_000 * 1e18);
        dirac.transfer(bob, 1_000_000 * 1e18);
        vm.stopPrank();
        vm.prank(alice);
        dirac.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        dirac.approve(address(staking), type(uint256).max);

        usdc.mint(distributor, 10_000_000 * USDC1);
        vm.prank(distributor);
        usdc.approve(address(staking), type(uint256).max);
    }

    function _notify(uint256 amount) internal {
        vm.prank(distributor);
        staking.notifyRewardAmount(amount);
    }

    function test_wiring() public view {
        assertEq(address(staking.stakingToken()), address(dirac));
        assertEq(address(staking.rewardsToken()), address(usdc));
        assertEq(staking.admin(), admin);
        assertEq(staking.rewardsDistributor(), distributor);
        assertEq(staking.maxLockYears(), 4);
        assertEq(staking.earlyPenaltyBps(), 3000);
    }

    function test_lock_setsWeightByYears() public {
        vm.prank(alice);
        staking.lock(100e18, 2);
        assertEq(staking.weightOf(alice), 200e18);
        assertEq(staking.totalWeight(), 200e18);
        assertEq(dirac.balanceOf(address(staking)), 100e18);
    }

    function test_lock_badTermReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(LockStaking.LS__BadTerm.selector);
        staking.lock(100e18, 0);
        vm.expectRevert(LockStaking.LS__BadTerm.selector);
        staking.lock(100e18, 5); // > maxLockYears
        vm.stopPrank();
    }

    function test_rewards_splitByWeightWithYears() public {
        // alice: 100 DIRAC x 2yr = weight 200; bob: 100 DIRAC x 1yr = weight 100
        vm.prank(alice);
        staking.lock(100e18, 2);
        vm.prank(bob);
        staking.lock(100e18, 1);

        _notify(300 * USDC1);
        skip(DURATION);

        uint256 a = staking.earned(alice);
        uint256 b = staking.earned(bob);
        assertApproxEqAbs(a, 200 * USDC1, 1e6);
        assertApproxEqAbs(b, 100 * USDC1, 1e6);
        assertApproxEqRel(a, b * 2, 1e15); // alice (2yr) earns ~2x bob (1yr)
    }

    function test_withdraw_afterExpiry_fullPrincipal() public {
        vm.prank(bob);
        staking.lock(100e18, 1);
        skip(365 days + 1);
        uint256 before = dirac.balanceOf(bob);
        vm.prank(bob);
        staking.withdraw(0);
        assertEq(dirac.balanceOf(bob) - before, 100e18);
        assertEq(staking.weightOf(bob), 0);
    }

    function test_withdraw_early_burns30pct() public {
        uint256 supplyBefore = dirac.totalSupply();
        vm.prank(alice);
        staking.lock(100e18, 2);
        uint256 balBefore = dirac.balanceOf(alice);

        vm.prank(alice);
        staking.withdraw(0); // immediate, before end
        // 30% burned, 70% returned
        assertEq(dirac.balanceOf(alice) - balBefore, 70e18);
        assertEq(supplyBefore - dirac.totalSupply(), 30e18); // burned reduces supply
        assertEq(staking.weightOf(alice), 0);
    }

    function test_withdraw_early_keepsRewards() public {
        vm.prank(alice);
        staking.lock(100e18, 2);
        _notify(700 * USDC1);
        skip(DURATION / 2);

        // early withdraw principal; rewards stay claimable
        vm.prank(alice);
        staking.withdraw(0);
        uint256 earnedNow = staking.earned(alice);
        assertGt(earnedNow, 0);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        staking.getReward();
        assertApproxEqAbs(usdc.balanceOf(alice) - before, earnedNow, 1);
    }

    function test_withdraw_doubleReverts() public {
        vm.prank(alice);
        staking.lock(100e18, 1);
        skip(365 days + 1);
        vm.startPrank(alice);
        staking.withdraw(0);
        vm.expectRevert(LockStaking.LS__AlreadyWithdrawn.selector);
        staking.withdraw(0);
        vm.stopPrank();
    }

    function test_setEarlyPenalty_applies() public {
        vm.prank(admin);
        staking.setEarlyPenaltyBps(5000); // 50%
        vm.prank(alice);
        staking.lock(100e18, 2);
        uint256 balBefore = dirac.balanceOf(alice);
        vm.prank(alice);
        staking.withdraw(0);
        assertEq(dirac.balanceOf(alice) - balBefore, 50e18);
    }

    function test_notify_onlyDistributor() public {
        vm.expectRevert(LockStaking.LS__OnlyRewardsDistributor.selector);
        staking.notifyRewardAmount(100 * USDC1);
    }

    function test_setters_onlyAdmin() public {
        vm.expectRevert(LockStaking.LS__OnlyAdmin.selector);
        staking.setMaxLockYears(10);
        vm.expectRevert(LockStaking.LS__OnlyAdmin.selector);
        staking.setEarlyPenaltyBps(1000);
    }
}

contract RevenueRouterTest is Test {
    TDIRAC internal dirac;
    MockUSDC internal usdc;
    SoulboundReceiptToken internal sbt;
    SoulboundReceiptPool internal pool;
    LockStaking internal staking;
    RevenueRouter internal router;

    address internal treasury = address(0xCAFE);
    address internal admin = address(0xAD);
    address internal alice = address(0xA11CE); // SBT holder
    address internal bob = address(0xB0B);     // locker
    address internal payer; // set in setUp via makeAddr

    uint256 internal constant USDC1 = 1e6;

    function setUp() public {
        payer = makeAddr("payer");
        dirac = new TDIRAC(treasury);
        usdc = new MockUSDC();

        uint256 n = vm.getNonce(address(this));
        address futurePool = vm.computeCreateAddress(address(this), n + 1);
        sbt = new SoulboundReceiptToken(futurePool);
        pool = new SoulboundReceiptPool(address(dirac), address(sbt), address(usdc), admin, admin);

        staking = new LockStaking(address(dirac), address(usdc), admin, admin, 7 days, 4);
        router = new RevenueRouter(address(usdc), address(pool), address(staking), admin);

        // router must hold the staking rewardsDistributor role
        vm.prank(admin);
        staking.setRewardsDistributor(address(router));

        // seed pool burn reserve + give bob DIRAC to lock
        vm.startPrank(treasury);
        dirac.transfer(address(pool), 1_000_000 * 1e18);
        dirac.transfer(bob, 1_000 * 1e18);
        vm.stopPrank();
        vm.prank(bob);
        dirac.approve(address(staking), type(uint256).max);

        // payer funds revenue
        usdc.mint(payer, 1_000_000 * USDC1);
        vm.prank(payer);
        usdc.approve(address(router), type(uint256).max);
    }

    function _route(uint256 amount) internal {
        vm.prank(payer);
        router.route(amount);
    }

    /// 1 DIRAC locked 2yr should earn the same as 2 SBT.
    function test_oneDiracTwoYears_equalsTwoSbt() public {
        vm.prank(admin);
        pool.mintReceipt(alice, 2e18); // 2 SBT  -> S = 2e18
        vm.prank(bob);
        staking.lock(1e18, 2);          // weight 2e18 -> W = 2e18

        _route(1000 * USDC1);           // S:W = 1:1 -> 500 each side
        skip(7 days);                   // stream out staking rewards

        // alice (SBT) claims her half
        uint256 aBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pool.claim();
        uint256 aGot = usdc.balanceOf(alice) - aBefore;

        // bob (locker) claims his half
        vm.prank(bob);
        staking.getReward();
        uint256 bGot = usdc.balanceOf(bob);

        assertApproxEqAbs(aGot, 500 * USDC1, 2);
        assertApproxEqAbs(bGot, 500 * USDC1, 1e6);
        assertApproxEqRel(aGot, bGot, 1e15); // equal: 1 DIRAC*2yr == 2 SBT
    }

    function test_threeYears_threeXperToken() public {
        vm.prank(admin);
        pool.mintReceipt(alice, 3e18); // 3 SBT
        vm.prank(bob);
        staking.lock(1e18, 3);          // weight 3e18

        _route(600 * USDC1);            // S:W = 3:3 -> 300 each
        skip(7 days);

        uint256 aBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pool.claim();
        uint256 aGot = usdc.balanceOf(alice) - aBefore;
        vm.prank(bob);
        staking.getReward();
        uint256 bGot = usdc.balanceOf(bob);
        // bob's 1 DIRAC*3yr (weight 3) == alice's 3 SBT
        assertApproxEqRel(aGot, bGot, 1e15);
    }

    function test_route_allToPool_whenNoLocks() public {
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);
        _route(1000 * USDC1);
        // nothing staked -> all to pool
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pool.claim();
        assertApproxEqAbs(usdc.balanceOf(alice) - before, 1000 * USDC1, 2);
    }

    function test_route_allToStaking_whenNoSbt() public {
        vm.prank(bob);
        staking.lock(100e18, 1);
        _route(700 * USDC1);
        skip(7 days);
        vm.prank(bob);
        staking.getReward();
        assertApproxEqAbs(usdc.balanceOf(bob), 700 * USDC1, 1e6);
    }

    function test_route_revertsNoShares() public {
        vm.prank(payer);
        vm.expectRevert(RevenueRouter.RR__NoShares.selector);
        router.route(1000 * USDC1);
    }
}
