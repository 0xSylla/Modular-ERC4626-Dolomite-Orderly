// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TDIRAC} from "../src/token/TDIRAC.sol";
import {SoulboundReceiptToken} from "../src/token/SoulboundReceiptToken.sol";
import {SoulboundReceiptPool} from "../src/token/SoulboundReceiptPool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal USDC stand-in for the revenue token in tests.
contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract SoulboundLayerTest is Test {
    TDIRAC internal dirac;
    SoulboundReceiptToken internal sbt;
    SoulboundReceiptPool internal pool;
    MockUSDC internal usdc;

    address internal admin = address(0xAD);
    address internal treasury = address(0xCAFE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA701);

    function setUp() public {
        // Deploy TDIRAC, mint full supply to treasury
        dirac = new TDIRAC(treasury);
        usdc = new MockUSDC();

        // Two-step deploy with precomputed Pool address (mirrors DeploySoulboundLayer.s.sol)
        uint256 thisNonce = vm.getNonce(address(this));
        address futurePool = vm.computeCreateAddress(address(this), thisNonce + 1);
        sbt = new SoulboundReceiptToken(futurePool);
        pool = new SoulboundReceiptPool(address(dirac), address(sbt), address(usdc), admin, admin);
        assertEq(address(pool), futurePool, "futurePool prediction broke");

        // Treasury seeds the pool with a TDIRAC reserve
        vm.prank(treasury);
        dirac.transfer(address(pool), 1_000_000 * 1e18);
    }

    // ============ Deployment integrity ============

    function test_wiring() public view {
        assertEq(address(sbt.pool()), address(pool));
        assertEq(address(pool.sbt()), address(sbt));
        assertEq(address(pool.dirac()), address(dirac));
        assertEq(address(pool.revenueToken()), address(usdc));
        assertEq(pool.admin(), admin);
        assertEq(pool.attributor(), admin);
        assertEq(pool.burnRatio(), 1e18);
        assertEq(pool.diracReserve(), 1_000_000 * 1e18);
    }

    // ============ Soulbound enforcement ============

    function test_sbt_transferRevertsAfterMint() public {
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(SoulboundReceiptToken.SoulboundReceiptToken__NonTransferable.selector);
        sbt.transfer(bob, 1);
    }

    function test_sbt_transferFromRevertsAfterMint() public {
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);

        vm.prank(alice);
        sbt.approve(bob, 1e18); // approval itself is fine
        vm.prank(bob);
        vm.expectRevert(SoulboundReceiptToken.SoulboundReceiptToken__NonTransferable.selector);
        sbt.transferFrom(alice, bob, 1);
    }

    function test_sbt_directMintFromNonPoolReverts() public {
        vm.expectRevert(SoulboundReceiptToken.SoulboundReceiptToken__OnlyPool.selector);
        sbt.mint(alice, 1e18);
    }

    function test_sbt_directBurnFromNonPoolReverts() public {
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);

        vm.expectRevert(SoulboundReceiptToken.SoulboundReceiptToken__OnlyPool.selector);
        sbt.burn(alice, 1);
    }

    // ============ Auto-delegation on mint ============

    function test_autoDelegate_onFirstMint() public {
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);

        assertEq(sbt.delegates(alice), alice, "alice should self-delegate on first mint");
        assertEq(sbt.getVotes(alice), 100e18);
    }

    function test_autoDelegate_secondMintDoesNotResetCustomDelegate() public {
        vm.prank(admin);
        pool.mintReceipt(alice, 50e18);

        // Alice manually re-delegates to bob
        vm.prank(alice);
        sbt.delegate(bob);
        assertEq(sbt.delegates(alice), bob);
        assertEq(sbt.getVotes(bob), 50e18);

        // Second mint: auto-delegate should NOT clobber alice's choice
        vm.prank(admin);
        pool.mintReceipt(alice, 50e18);
        assertEq(sbt.delegates(alice), bob, "second mint shouldn't reset delegation");
        assertEq(sbt.getVotes(bob), 100e18);
        assertEq(sbt.getVotes(alice), 0);
    }

    // ============ Burn TDIRAC on mint ============

    function test_mintReceipt_burnsExactDiracAtDefaultRatio() public {
        uint256 reserveBefore = pool.diracReserve();
        uint256 diracTotalBefore = dirac.totalSupply();

        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);

        assertEq(sbt.balanceOf(alice), 100e18);
        assertEq(pool.diracReserve(), reserveBefore - 100e18);
        assertEq(dirac.totalSupply(), diracTotalBefore - 100e18);
    }

    function test_mintReceipt_respectsBurnRatio() public {
        vm.prank(admin);
        pool.setBurnRatio(2e18); // 2 TDIRAC per 1 SBT

        uint256 reserveBefore = pool.diracReserve();
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);

        assertEq(sbt.balanceOf(alice), 100e18);
        assertEq(pool.diracReserve(), reserveBefore - 200e18);
    }

    function test_mintReceipt_zeroBurnRatioStillMints() public {
        vm.prank(admin);
        pool.setBurnRatio(0); // free mint

        uint256 reserveBefore = pool.diracReserve();
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);

        assertEq(sbt.balanceOf(alice), 100e18);
        assertEq(pool.diracReserve(), reserveBefore, "no TDIRAC should burn");
    }

    function test_mintReceipt_revertsIfReserveInsufficient() public {
        // Pool has 1M TDIRAC. Try to mint requiring 2M burn at ratio=2:1.
        vm.prank(admin);
        pool.setBurnRatio(3e18); // 3M needed for 1M SBT

        vm.prank(admin);
        vm.expectRevert(SoulboundReceiptPool.Pool__InsufficientReserve.selector);
        pool.mintReceipt(alice, 1_000_000e18);
    }

    function test_mintReceipt_revertsFromNonAttributor() public {
        vm.expectRevert(SoulboundReceiptPool.Pool__OnlyAttributor.selector);
        pool.mintReceipt(alice, 1);
    }

    function test_mintReceipt_revertsOnZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(SoulboundReceiptPool.Pool__ZeroAmount.selector);
        pool.mintReceipt(alice, 0);
    }

    function test_mintReceipt_revertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(SoulboundReceiptPool.Pool__ZeroAddress.selector);
        pool.mintReceipt(address(0), 1);
    }

    // ============ Revenue distribution + claim ============

    function test_distributeRevenue_revertsBeforeAnyMint() public {
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(SoulboundReceiptPool.Pool__NoSharesYet.selector);
        pool.distributeRevenue(1_000e6);
    }

    function test_singleHolder_claimsFullRevenue() public {
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);

        // Some entity distributes 1000 USDC to the pool
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(pool), 1_000e6);
        pool.distributeRevenue(1_000e6);

        assertEq(pool.pendingRewards(alice), 1_000e6);
        vm.prank(alice);
        uint256 claimed = pool.claim();
        assertEq(claimed, 1_000e6);
        assertEq(usdc.balanceOf(alice), 1_000e6);
        assertEq(pool.pendingRewards(alice), 0);
    }

    function test_twoHolders_proRataSplit() public {
        vm.startPrank(admin);
        pool.mintReceipt(alice, 75e18);
        pool.mintReceipt(bob, 25e18);
        vm.stopPrank();

        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(pool), 1_000e6);
        pool.distributeRevenue(1_000e6);

        assertEq(pool.pendingRewards(alice), 750e6);
        assertEq(pool.pendingRewards(bob), 250e6);
    }

    function test_lateJoiner_doesNotGetPastRevenue() public {
        // 1. Alice mints, distribution happens
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(pool), 1_000e6);
        pool.distributeRevenue(1_000e6);

        // 2. Bob mints AFTER the distribution
        vm.prank(admin);
        pool.mintReceipt(bob, 100e18);

        // Bob should see zero pending
        assertEq(pool.pendingRewards(bob), 0);
        // Alice should still see her full claim
        assertEq(pool.pendingRewards(alice), 1_000e6);

        // 3. Second distribution after both hold shares
        usdc.mint(address(this), 500e6);
        usdc.approve(address(pool), 500e6);
        pool.distributeRevenue(500e6);

        // Both have equal shares now → split 250 / 250
        assertEq(pool.pendingRewards(alice), 1_000e6 + 250e6);
        assertEq(pool.pendingRewards(bob), 250e6);
    }

    function test_mintAfterRevenue_settlesPriorPending() public {
        // Alice gets 100 SBT, revenue 1000, then alice gets 50 more SBT.
        // The 1000 of pre-existing pending must NOT be lost / re-rated.
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(pool), 1_000e6);
        pool.distributeRevenue(1_000e6);

        vm.prank(admin);
        pool.mintReceipt(alice, 50e18);

        // After the second mint, alice's claimable bucket should have 1000.
        // pendingRewards = claimable + fresh; fresh = 0 (no new revenue).
        assertEq(pool.pendingRewards(alice), 1_000e6);

        // Now a 300 revenue distribution. Alice has 150 SBT, total = 150.
        // She owns 100% → +300. Total pending = 1000 + 300 = 1300.
        usdc.mint(address(this), 300e6);
        usdc.approve(address(pool), 300e6);
        pool.distributeRevenue(300e6);
        assertEq(pool.pendingRewards(alice), 1_300e6);
    }

    function test_claim_revertsWhenNothingToClaim() public {
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(SoulboundReceiptPool.Pool__NothingToClaim.selector);
        pool.claim();
    }

    // ============ Burn (slash) flow ============

    function test_burnReceipt_revertsFromNonAdmin() public {
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(SoulboundReceiptPool.Pool__OnlyAdmin.selector);
        pool.burnReceipt(alice, 50e18);
    }

    function test_burnReceipt_zerosVotes() public {
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);
        assertEq(sbt.getVotes(alice), 100e18);

        vm.prank(admin);
        pool.burnReceipt(alice, 100e18);
        assertEq(sbt.balanceOf(alice), 0);
        assertEq(sbt.getVotes(alice), 0);
    }

    function test_burnReceipt_preservesPriorRewards() public {
        vm.prank(admin);
        pool.mintReceipt(alice, 100e18);
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(pool), 1_000e6);
        pool.distributeRevenue(1_000e6);

        // Slash 50% of alice's shares
        vm.prank(admin);
        pool.burnReceipt(alice, 50e18);

        // Prior earnings (1000) should still be claimable
        assertEq(pool.pendingRewards(alice), 1_000e6);
    }

    // ============ Admin rotation ============

    function test_setAttributor() public {
        vm.prank(admin);
        pool.setAttributor(alice);
        assertEq(pool.attributor(), alice);

        // Old attributor (admin) can no longer mint
        vm.prank(admin);
        vm.expectRevert(SoulboundReceiptPool.Pool__OnlyAttributor.selector);
        pool.mintReceipt(bob, 1e18);

        // New attributor can
        vm.prank(alice);
        pool.mintReceipt(bob, 1e18);
        assertEq(sbt.balanceOf(bob), 1e18);
    }

    function test_setAdmin_handover() public {
        vm.prank(admin);
        pool.setAdmin(alice);
        assertEq(pool.admin(), alice);

        // Old admin can no longer change anything
        vm.prank(admin);
        vm.expectRevert(SoulboundReceiptPool.Pool__OnlyAdmin.selector);
        pool.setBurnRatio(5);
    }

    function test_setBurnRatio_emits() public {
        vm.expectEmit(true, true, true, true);
        emit SoulboundReceiptPool.BurnRatioChanged(1e18, 5e17);
        vm.prank(admin);
        pool.setBurnRatio(5e17);
        assertEq(pool.burnRatio(), 5e17);
    }
}
