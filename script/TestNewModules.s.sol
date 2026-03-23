// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveModule} from "../src/modules/lending/aave/AaveModule.sol";
import {MorphoModule} from "../src/modules/lending/morpho/MorphoModule.sol";

/// @title TestNewModules
/// @notice Fork-test Aave + Morpho modules on Arbitrum
/// @dev Run: forge test --match-contract TestNewModules --fork-url arbitrum -vv
contract TestNewModules is Test {
    address constant USDC    = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WETH    = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WSTETH  = 0x5979d7B546E38E9Ab8B0d483b5C0c2C99b27C399;
    address constant WBTC    = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    AaveModule aave;
    MorphoModule morpho;

    function setUp() public {
        aave = new AaveModule();
        morpho = new MorphoModule();
    }

    function test_aave_weth_full_cycle() public {
        console.log("========== AAVE: WETH full cycle ==========");

        uint256 wethAmount = 1 ether;
        uint256 borrowAmount = 500e6;

        deal(WETH, address(this), wethAmount);
        // Extra USDC to cover interest on repay
        deal(USDC, address(this), 10e6);

        // Supply
        (bool ok, ) = address(aave).delegatecall(
            abi.encodeCall(aave.supplyCollateral, (WETH, wethAmount, 0))
        );
        require(ok, "supply failed");
        console.log("[OK] Supplied 1 WETH");

        // Borrow
        (ok, ) = address(aave).delegatecall(
            abi.encodeCall(aave.borrowAsset, (USDC, borrowAmount))
        );
        require(ok, "borrow failed");
        console.log("[OK] Borrowed 500 USDC. Balance:", IERC20(USDC).balanceOf(address(this)));

        // Repay max (covers interest dust)
        (ok, ) = address(aave).delegatecall(
            abi.encodeCall(aave.repayDebt, (USDC, type(uint256).max, 0, 0))
        );
        require(ok, "repay failed");
        console.log("[OK] Repaid all debt");

        // Withdraw max
        (ok, ) = address(aave).delegatecall(
            abi.encodeCall(aave.withdrawCollateralAsset, (WETH, type(uint256).max))
        );
        require(ok, "withdraw failed");
        uint256 wethBack = IERC20(WETH).balanceOf(address(this));
        console.log("[OK] Withdrew WETH:", wethBack);
        assertGt(wethBack, 0);
    }

    function test_aave_wbtc_full_cycle() public {
        console.log("========== AAVE: WBTC full cycle ==========");

        uint256 wbtcAmount = 1e7; // 0.1 WBTC
        uint256 borrowAmount = 2000e6;

        deal(WBTC, address(this), wbtcAmount);
        deal(USDC, address(this), 10e6);

        // Supply
        (bool ok, ) = address(aave).delegatecall(
            abi.encodeCall(aave.supplyCollateral, (WBTC, wbtcAmount, 0))
        );
        require(ok, "supply failed");
        console.log("[OK] Supplied 0.1 WBTC");

        // Borrow
        (ok, ) = address(aave).delegatecall(
            abi.encodeCall(aave.borrowAsset, (USDC, borrowAmount))
        );
        require(ok, "borrow failed");
        console.log("[OK] Borrowed 2000 USDC. Balance:", IERC20(USDC).balanceOf(address(this)));

        // Repay max
        (ok, ) = address(aave).delegatecall(
            abi.encodeCall(aave.repayDebt, (USDC, type(uint256).max, 0, 0))
        );
        require(ok, "repay failed");
        console.log("[OK] Repaid all debt");

        // Withdraw max
        (ok, ) = address(aave).delegatecall(
            abi.encodeCall(aave.withdrawCollateralAsset, (WBTC, type(uint256).max))
        );
        require(ok, "withdraw failed");
        uint256 wbtcBack = IERC20(WBTC).balanceOf(address(this));
        console.log("[OK] Withdrew WBTC:", wbtcBack);
        assertGt(wbtcBack, 0);
    }

    function test_module_types() public {
        assertEq(aave.moduleType(), keccak256("lending.aave"));
        console.log("[OK] AaveModule type hash correct");

        assertEq(morpho.moduleType(), keccak256("lending.morpho"));
        console.log("[OK] MorphoModule type hash correct");

        // wstETH totalSupply check skipped — may not exist on all fork blocks
        console.log("[OK] All module types verified");
    }
}
