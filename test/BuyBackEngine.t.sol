// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TDIRAC} from "../src/token/TDIRAC.sol";
import {BuyBackEngine} from "../src/buyback/BuyBackEngine.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @dev Minimal V2 router: pulls `amountIn` of path[0] from the caller and
///      sends `amountIn * rate / 1e6` of path[last] to `to`, enforcing minOut.
///      Pre-funded with the output token.
contract MockV2Router {
    uint256 public rate; // output per 1e6 input units, scaled to output decimals

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external { rate = _rate; }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /*deadline*/
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rate) / 1e6;
        require(out >= amountOutMin, "MockV2Router: INSUFFICIENT_OUTPUT");
        IERC20(path[path.length - 1]).transfer(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}

contract BuyBackEngineTest is Test {
    TDIRAC internal dirac;
    MockUSDC internal usdc;
    MockV2Router internal router;
    BuyBackEngine internal engine;

    address internal treasury = address(0xCAFE);
    address internal admin = address(0xAD);
    address internal keeper = address(0x6EE9);
    address internal pool = address(0x9001); // stand-in recipient (the SBT pool)
    address internal alice = address(0xA11CE);

    uint256 internal constant USDC1 = 1e6;
    // 1 USDC -> 2 TDIRAC (rate = 2e18 output per 1e6 input)
    uint256 internal constant RATE = 2e18;

    function setUp() public {
        dirac = new TDIRAC(treasury);
        usdc = new MockUSDC();
        router = new MockV2Router(RATE);

        // Fund the router with TDIRAC so it can pay out swaps.
        vm.prank(treasury);
        dirac.transfer(address(router), 100_000_000 * 1e18);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dirac);

        engine = new BuyBackEngine(
            address(usdc), address(dirac), address(router), pool, admin, keeper, path
        );

        // Seed the engine with USDC revenue.
        usdc.mint(address(engine), 10_000 * USDC1);
    }

    // ============ Construction ============

    function test_wiring() public view {
        assertEq(address(engine.usdc()), address(usdc));
        assertEq(address(engine.tdirac()), address(dirac));
        assertEq(engine.router(), address(router));
        assertEq(engine.recipient(), pool);
        assertEq(engine.admin(), admin);
        assertEq(engine.keeper(), keeper);
        address[] memory p = engine.getPath();
        assertEq(p.length, 2);
        assertEq(p[0], address(usdc));
        assertEq(p[1], address(dirac));
    }

    function test_constructor_rejectsBadPath() public {
        address[] memory bad = new address[](2);
        bad[0] = address(dirac); // must start at USDC
        bad[1] = address(dirac);
        vm.expectRevert(BuyBackEngine.BB__BadPath.selector);
        new BuyBackEngine(address(usdc), address(dirac), address(router), pool, admin, keeper, bad);
    }

    // ============ Buyback ============

    function test_buyback_swapsAndForwardsToRecipient() public {
        uint256 amountIn = 1000 * USDC1;
        uint256 expectedOut = (amountIn * RATE) / 1e6; // 2000 TDIRAC

        vm.prank(keeper);
        uint256 out = engine.buyback(amountIn, expectedOut, block.timestamp + 1);

        assertEq(out, expectedOut);
        assertEq(dirac.balanceOf(pool), expectedOut);
        assertEq(engine.usdcBalance(), 9_000 * USDC1);
        // No residual allowance left to the router.
        assertEq(usdc.allowance(address(engine), address(router)), 0);
    }

    function test_buyback_respectsMinOut() public {
        uint256 amountIn = 1000 * USDC1;
        uint256 tooMuch = (amountIn * RATE) / 1e6 + 1; // 1 wei above achievable
        vm.prank(keeper);
        vm.expectRevert("MockV2Router: INSUFFICIENT_OUTPUT");
        engine.buyback(amountIn, tooMuch, block.timestamp + 1);
    }

    function test_buyback_onlyKeeper() public {
        vm.expectRevert(BuyBackEngine.BB__OnlyKeeper.selector);
        engine.buyback(1000 * USDC1, 0, block.timestamp + 1);
    }

    function test_buyback_zeroReverts() public {
        vm.prank(keeper);
        vm.expectRevert(BuyBackEngine.BB__ZeroAmount.selector);
        engine.buyback(0, 0, block.timestamp + 1);
    }

    function test_buyback_insufficientBalanceReverts() public {
        vm.prank(keeper);
        vm.expectRevert(BuyBackEngine.BB__InsufficientBalance.selector);
        engine.buyback(20_000 * USDC1, 0, block.timestamp + 1);
    }

    function test_buyback_toConfigurableRecipient() public {
        vm.prank(admin);
        engine.setRecipient(alice);
        vm.prank(keeper);
        engine.buyback(500 * USDC1, 0, block.timestamp + 1);
        assertEq(dirac.balanceOf(alice), (500 * USDC1 * RATE) / 1e6);
    }

    // ============ Admin ============

    function test_setRouter_path_recipient_keeper_onlyAdmin() public {
        vm.expectRevert(BuyBackEngine.BB__OnlyAdmin.selector);
        engine.setRouter(address(0xBEEF));
        vm.expectRevert(BuyBackEngine.BB__OnlyAdmin.selector);
        engine.setRecipient(alice);
        vm.expectRevert(BuyBackEngine.BB__OnlyAdmin.selector);
        engine.setKeeper(alice);
    }

    function test_setPath_validatesEndpoints() public {
        address[] memory bad = new address[](2);
        bad[0] = address(usdc);
        bad[1] = address(usdc); // must end at TDIRAC
        vm.prank(admin);
        vm.expectRevert(BuyBackEngine.BB__BadPath.selector);
        engine.setPath(bad);
    }

    function test_setPath_multiHopOk() public {
        address weth = address(0x9E74);
        address[] memory p = new address[](3);
        p[0] = address(usdc);
        p[1] = weth;
        p[2] = address(dirac);
        vm.prank(admin);
        engine.setPath(p);
        assertEq(engine.getPath().length, 3);
    }

    function test_setKeeper_rotates() public {
        vm.prank(admin);
        engine.setKeeper(alice);
        assertEq(engine.keeper(), alice);
        vm.prank(alice);
        engine.buyback(100 * USDC1, 0, block.timestamp + 1);
        assertGt(dirac.balanceOf(pool), 0);
    }

    function test_rescue_sweepsToken() public {
        vm.prank(admin);
        engine.rescue(address(usdc), treasury, 1_000 * USDC1);
        assertEq(usdc.balanceOf(treasury), 1_000 * USDC1);
        assertEq(engine.usdcBalance(), 9_000 * USDC1);
    }

    function test_rescue_onlyAdmin() public {
        vm.expectRevert(BuyBackEngine.BB__OnlyAdmin.selector);
        engine.rescue(address(usdc), alice, 1);
    }
}
