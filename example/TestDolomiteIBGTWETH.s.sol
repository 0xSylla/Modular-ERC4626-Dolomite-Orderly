// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {DolomiteVault} from "./DolomiteIBGTWETH.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title TestDolomiteIBGTWETH
/// @notice Tests the full repayiBGTDebtWithCollateral cycle on DolomiteIBGTWETH.sol
///
/// Run phases:
///   forge script example/TestDolomiteIBGTWETH.s.sol:TestDolomiteIBGTWETH \
///     --sig "phase1_deploy()" --rpc-url mainnet --broadcast --with-gas-price 10000000 --ffi
///
///   forge script example/TestDolomiteIBGTWETH.s.sol:TestDolomiteIBGTWETH \
///     --sig "phase2_supplyAndBorrow()" --rpc-url mainnet --broadcast --with-gas-price 10000000
///
///   forge script example/TestDolomiteIBGTWETH.s.sol:TestDolomiteIBGTWETH \
///     --sig "phase3_repayWithCollateral()" --rpc-url mainnet --broadcast --with-gas-price 10000000 --ffi
contract TestDolomiteIBGTWETH is Script {
    address constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    address constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;

    address constant DOLOMITE_OOGA_ADAPTER = 0x0CE205f7bCBa70E4c03f826918c8c21073386ED3;

    uint256 constant SUPPLY_AMOUNT = 100_000_000_000_000_000; // 0.1 iBGT
    uint256 constant BORROW_AMOUNT = 30_000;                  // 0.03 USDC (6 decimals)

    // ============================================================
    // PHASE 1: Deploy DolomiteVault (DolomiteIBGTWETH)
    // ============================================================
    function phase1_deploy() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== Phase 1: Deploy DolomiteVault (IBGTWETH) ===");
        console.log("Deployer:", deployer);
        console.log("Deployer iBGT:", IERC20(IBGT).balanceOf(deployer));
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));

        vm.startBroadcast(pk);
        DolomiteVault vault = new DolomiteVault();
        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  DolomiteVault deployed:", address(vault));
        console.log("=======================================");
        console.log("Set DOLOMITE_VAULT_ADDR in .env:");
        console.log("  DOLOMITE_VAULT_ADDR=", address(vault));
        console.log("\nNext: phase2_supplyAndBorrow()");
    }

    // ============================================================
    // PHASE 2: Fund + Supply iBGT + Borrow USDC
    // ============================================================
    function phase2_supplyAndBorrow() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddr = vm.envAddress("DOLOMITE_VAULT_ADDR");
        DolomiteVault vault = DolomiteVault(payable(vaultAddr));

        console.log("=== Phase 2: Fund + Supply iBGT + Borrow USDC ===");
        console.log("Vault:", vaultAddr);
        console.log("Deployer iBGT:", IERC20(IBGT).balanceOf(deployer));

        vm.startBroadcast(pk);

        // Step 1: Approve + fund vault with iBGT
        IERC20(IBGT).approve(vaultAddr, SUPPLY_AMOUNT);
        vault.fundContractiBGT(SUPPLY_AMOUNT);
        console.log("Funded vault with iBGT:", SUPPLY_AMOUNT);

        // Step 2: Supply iBGT to Dolomite isolation mode (market 38)
        vault.supplyiBGT(SUPPLY_AMOUNT);
        console.log("Supplied iBGT to Dolomite (isolation mode market 38)");
        console.log("Isolation proxy:", vault.isolationProxy());

        // Step 3: Borrow USDC against iBGT collateral
        vault.borrowUSDCFromiBGT(BORROW_AMOUNT);
        console.log("Borrowed USDC:", BORROW_AMOUNT);

        vm.stopBroadcast();

        (uint256 coll, uint256 debt, uint256 cIBGT, uint256 cUSDC) = vault.getiBGTPosition();
        console.log("\n--- iBGT Position ---");
        console.log("Collateral (iBGT tracked):", coll);
        console.log("Debt (USDC):", debt);
        console.log("Contract iBGT:", cIBGT);
        console.log("Contract USDC:", cUSDC);
        console.log("\nNext: phase3_repayWithCollateral()");
    }

    // ============================================================
    // PHASE 3: Repay USDC debt by swapping iBGT collateral
    // ============================================================
    function phase3_repayWithCollateral() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddr = vm.envAddress("DOLOMITE_VAULT_ADDR");
        DolomiteVault vault = DolomiteVault(payable(vaultAddr));

        console.log("=== Phase 3: repayiBGTDebtWithCollateral ===");
        (uint256 coll, uint256 debt, , ) = vault.getiBGTPosition();
        console.log("Collateral (iBGT):", coll);
        console.log("Debt (USDC):", debt);

        // Fetch OogaBooga quote for iBGT -> USDC
        (uint256 expectedOut, uint256 minOut, bytes memory pathDefinition) =
            _fetchOogaBoogaQuote(IBGT, USDC, coll);
        console.log("OogaBooga quote - expectedOut:", expectedOut, "minOut:", minOut);

        vm.startBroadcast(pk);

        vault.repayiBGTDebtWithCollateral(minOut, expectedOut, pathDefinition);

        vm.stopBroadcast();

        (uint256 collAfter, uint256 debtAfter, uint256 cIBGT, uint256 cUSDC) = vault.getiBGTPosition();
        console.log("\n--- Position After ---");
        console.log("Collateral:", collAfter);
        console.log("Debt:", debtAfter);
        console.log("Contract iBGT:", cIBGT);
        console.log("Contract USDC (surplus):", cUSDC);
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));

        console.log("\n=======================================");
        console.log("  REPAY-WITH-COLLATERAL TEST COMPLETE");
        console.log("=======================================");
    }

    // ============================================================
    // PHASE 4 (optional): Emergency withdraw any remaining tokens
    // ============================================================
    function phase4_emergencyWithdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("DOLOMITE_VAULT_ADDR");
        DolomiteVault vault = DolomiteVault(payable(vaultAddr));

        console.log("=== Phase 4: Emergency Withdraw ===");

        vm.startBroadcast(pk);

        uint256 ibgtBal = IERC20(IBGT).balanceOf(vaultAddr);
        if (ibgtBal > 0) {
            vault.emergencyWithdraw(IBGT);
            console.log("Withdrawn iBGT:", ibgtBal);
        }

        uint256 usdcBal = IERC20(USDC).balanceOf(vaultAddr);
        if (usdcBal > 0) {
            vault.emergencyWithdraw(USDC);
            console.log("Withdrawn USDC:", usdcBal);
        }

        vm.stopBroadcast();
    }

    // ============================================================
    // HELPER: OogaBooga quote via FFI
    // ============================================================
    function _fetchOogaBoogaQuote(
        address tokenIn,
        address tokenOut,
        uint256 amount
    )
        internal
        returns (
            uint256 expectedOut,
            uint256 minOut,
            bytes memory pathDefinition
        )
    {
        string memory apiKey = vm.envString("OOGABOOGA_API_KEY");
        string memory curlCmd = string.concat(
            "curl -s -H 'Authorization: Bearer ", apiKey, "' "
            "'https://mainnet.api.oogabooga.io/v1/swap"
            "?tokenIn=", vm.toString(tokenIn),
            "&tokenOut=", vm.toString(tokenOut),
            "&amount=", vm.toString(amount),
            "&to=", vm.toString(DOLOMITE_OOGA_ADAPTER),
            "&slippage=0.05'"
        );

        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = curlCmd;

        console.log("Fetching OogaBooga quote...");
        bytes memory result = vm.ffi(cmd);
        string memory json = string(result);

        expectedOut = vm.parseJsonUint(json, ".assumedAmountOut");
        minOut = (expectedOut * 95) / 100;
        pathDefinition = vm.parseJsonBytes(json, ".routerParams.pathDefinition");
    }
}
