// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TDIRAC} from "../src/token/TDIRAC.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract StakingContractTest is Test {
    TDIRAC internal dirac;
    MockUSDC internal usdc;
    StakingContract internal staking;

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
        staking = new StakingContract(address(dirac), address(usdc), admin, distributor, DURATION);

        // Seed stakers with TDIRAC + approve.
        vm.startPrank(treasury);
        dirac.transfer(alice, 1_000_000 * 1e18);
        dirac.transfer(bob, 1_000_000 * 1e18);
        vm.stopPrank();
        vm.prank(alice);
        dirac.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        dirac.approve(address(staking), type(uint256).max);

        // Distributor holds USDC + approves.
        usdc.mint(distributor, 10_000_000 * USDC1);
        vm.prank(distributor);
        usdc.approve(address(staking), type(uint256).max);
    }

    function _notify(uint256 amount) internal {
        vm.prank(distributor);
        staking.notifyRewardAmount(amount);
    }

    // ============ Construction ============

    function test_wiring() public view {
        assertEq(address(staking.stakingToken()), address(dirac));
        assertEq(address(staking.rewardsToken()), address(usdc));
        assertEq(staking.admin(), admin);
        assertEq(staking.rewardsDistributor(), distributor);
        assertEq(staking.rewardsDuration(), DURATION);
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(StakingContract.Staking__ZeroAddress.selector);
        new StakingContract(address(0), address(usdc), admin, distributor, DURATION);
        vm.expectRevert(StakingContract.Staking__ZeroDuration.selector);
        new StakingContract(address(dirac), address(usdc), admin, distributor, 0);
    }

    // ============ Stake / withdraw ============

    function test_stake_updatesBalances() public {
        vm.prank(alice);
        staking.stake(100 * 1e18);
        assertEq(staking.balanceOf(alice), 100 * 1e18);
        assertEq(staking.totalSupply(), 100 * 1e18);
        assertEq(dirac.balanceOf(address(staking)), 100 * 1e18);
    }

    function test_stake_zeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingContract.Staking__ZeroAmount.selector);
        staking.stake(0);
    }

    function test_withdraw_returnsStake() public {
        vm.startPrank(alice);
        staking.stake(100 * 1e18);
        staking.withdraw(40 * 1e18);
        vm.stopPrank();
        assertEq(staking.balanceOf(alice), 60 * 1e18);
        assertEq(staking.totalSupply(), 60 * 1e18);
    }

    // ============ Rewards ============

    function test_earned_zeroBeforeNotify() public {
        vm.prank(alice);
        staking.stake(100 * 1e18);
        skip(1 days);
        assertEq(staking.earned(alice), 0);
    }

    function test_singleStaker_earnsFullWindow() public {
        vm.prank(alice);
        staking.stake(100 * 1e18);

        uint256 reward = 700 * USDC1; // 100 USDC/day over 7 days
        _notify(reward);

        skip(DURATION);
        // ~all of the reward (minus integer-division dust) accrues to the sole staker.
        assertApproxEqAbs(staking.earned(alice), reward, 1e6);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        staking.getReward();
        assertApproxEqAbs(usdc.balanceOf(alice) - before, reward, 1e6);
        assertEq(staking.rewards(alice), 0);
    }

    function test_twoStakers_splitProportionally() public {
        // alice 3x bob's stake → alice earns ~3x.
        vm.prank(alice);
        staking.stake(300 * 1e18);
        vm.prank(bob);
        staking.stake(100 * 1e18);

        _notify(800 * USDC1);
        skip(DURATION);

        uint256 a = staking.earned(alice);
        uint256 b = staking.earned(bob);
        assertApproxEqAbs(a, 600 * USDC1, 1e6);
        assertApproxEqAbs(b, 200 * USDC1, 1e6);
        assertApproxEqRel(a, b * 3, 1e15); // within 0.1%
    }

    function test_rewardRolloverExtendsRate() public {
        vm.prank(alice);
        staking.stake(100 * 1e18);

        _notify(700 * USDC1);
        skip(DURATION / 2); // half streamed
        // Notify again mid-window — leftover rolls into the new rate.
        _notify(700 * USDC1);
        assertEq(staking.periodFinish(), block.timestamp + DURATION);

        skip(DURATION);
        // Total payable ≈ first-half-streamed + full second notify's stream.
        assertApproxEqAbs(staking.earned(alice), 1400 * USDC1, 5e6);
    }

    function test_exit_withdrawsAndClaims() public {
        vm.prank(alice);
        staking.stake(100 * 1e18);
        _notify(700 * USDC1);
        skip(DURATION);

        uint256 diracBefore = dirac.balanceOf(alice);
        vm.prank(alice);
        staking.exit();
        assertEq(staking.balanceOf(alice), 0);
        assertEq(dirac.balanceOf(alice) - diracBefore, 100 * 1e18);
        assertGt(usdc.balanceOf(alice), 0);
    }

    function test_lateStaker_doesNotEarnPast() public {
        vm.prank(alice);
        staking.stake(100 * 1e18);
        _notify(700 * USDC1);
        skip(DURATION / 2);

        // bob joins halfway — should only earn from the second half.
        vm.prank(bob);
        staking.stake(100 * 1e18);
        skip(DURATION / 2);

        uint256 a = staking.earned(alice);
        uint256 b = staking.earned(bob);
        assertGt(a, b); // alice earned the full first half alone + half the second
        assertApproxEqAbs(b, 175 * USDC1, 5e6); // ~half of the second-half pot
    }

    // ============ Funding guards ============

    function test_notify_onlyDistributor() public {
        vm.expectRevert(StakingContract.Staking__OnlyRewardsDistributor.selector);
        staking.notifyRewardAmount(100 * USDC1);
    }

    function test_notify_zeroReverts() public {
        vm.prank(distributor);
        vm.expectRevert(StakingContract.Staking__ZeroAmount.selector);
        staking.notifyRewardAmount(0);
    }

    // ============ Admin ============

    function test_setRewardsDuration_onlyBetweenWindows() public {
        _notify(700 * USDC1); // starts a window
        vm.prank(admin);
        vm.expectRevert(StakingContract.Staking__PeriodNotFinished.selector);
        staking.setRewardsDuration(14 days);

        skip(DURATION + 1);
        vm.prank(admin);
        staking.setRewardsDuration(14 days);
        assertEq(staking.rewardsDuration(), 14 days);
    }

    function test_setRewardsDuration_onlyAdmin() public {
        vm.expectRevert(StakingContract.Staking__OnlyAdmin.selector);
        staking.setRewardsDuration(14 days);
    }

    function test_setAdminAndDistributor() public {
        vm.prank(admin);
        staking.setAdmin(bob);
        assertEq(staking.admin(), bob);
        vm.prank(bob);
        staking.setRewardsDistributor(alice);
        assertEq(staking.rewardsDistributor(), alice);
    }

    function test_admin_rotationToTimelockStyle() public {
        // sanity: old admin loses power after handoff
        vm.prank(admin);
        staking.setAdmin(bob);
        vm.prank(admin);
        vm.expectRevert(StakingContract.Staking__OnlyAdmin.selector);
        staking.setRewardsDistributor(alice);
    }
}
