// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {DolomiteVault} from "./DolomiteIBGT.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title TestDolomiteIBGT
/// @notice Test script for DolomiteIBGT.sol standalone contract
///
/// Run phases:
///   forge script example/TestDolomiteIBGT.s.sol:TestDolomiteIBGT \
///     --sig "phase1_deploy()" --rpc-url mainnet --broadcast --with-gas-price 10000000
///
///   forge script example/TestDolomiteIBGT.s.sol:TestDolomiteIBGT \
///     --sig "phase2_supplyAndBorrow()" --rpc-url mainnet --broadcast --with-gas-price 10000000
///
///   forge script example/TestDolomiteIBGT.s.sol:TestDolomiteIBGT \
///     --sig "phase3_repayAndWithdraw()" --rpc-url mainnet --broadcast --with-gas-price 10000000
contract TestDolomiteIBGT is Script {
    address constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    address constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;

    uint256 constant SUPPLY_AMOUNT = 100000000000000000; // 0.1 iBGT (18 decimals)
    uint256 constant BORROW_AMOUNT = 30000; // 0.03 USDC (6 decimals) — conservative LTV

    // ============================================================
    // PHASE 1: Deploy DolomiteVault contract
    // ============================================================
    function phase1_deploy() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== Phase 1: Deploy DolomiteVault ===");
        console.log("Deployer:", deployer);
        console.log("Deployer iBGT:", IERC20(IBGT).balanceOf(deployer));
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));

        vm.startBroadcast(pk);

        DolomiteVault vault = new DolomiteVault(IBGT, USDC);

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  DolomiteVault deployed:", address(vault));
        console.log("=======================================");
        console.log("\nSet DOLOMITE_VAULT_ADDR in .env or pass via env:");
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
        DolomiteVault vault = DolomiteVault(vaultAddr);

        console.log("=== Phase 2: Fund + Supply + Borrow ===");
        console.log("Vault:", vaultAddr);
        console.log("Deployer iBGT:", IERC20(IBGT).balanceOf(deployer));

        vm.startBroadcast(pk);

        // Step 1: Approve and fund contract with iBGT
        IERC20(IBGT).approve(vaultAddr, SUPPLY_AMOUNT);
        vault.fundContract(SUPPLY_AMOUNT);
        console.log("Funded vault with iBGT:", SUPPLY_AMOUNT);

        // Step 2: Supply iBGT to Dolomite (isolation mode — diBGT market 38)
        vault.supplyiBGT(SUPPLY_AMOUNT);
        console.log("Supplied iBGT to Dolomite");

        // Step 3: Borrow USDC
        vault.borrowUSDC(BORROW_AMOUNT);
        console.log("Borrowed USDC:", BORROW_AMOUNT);

        vm.stopBroadcast();

        (uint256 coll, uint256 debt, uint256 contractIBGT, uint256 contractUSDC) = vault.getPosition();
        console.log("\n--- Position ---");
        console.log("Collateral (iBGT):", coll);
        console.log("Debt (USDC):", debt);
        console.log("Contract iBGT:", contractIBGT);
        console.log("Contract USDC:", contractUSDC);
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));
        console.log("\nNext: phase3_repayAndWithdraw()");
    }

    // ============================================================
    // PHASE 3: Repay USDC + Withdraw iBGT
    // ============================================================
    function phase3_repayAndWithdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddr = vm.envAddress("DOLOMITE_VAULT_ADDR");
        DolomiteVault vault = DolomiteVault(vaultAddr);

        console.log("=== Phase 3: Repay + Withdraw ===");
        (uint256 coll, uint256 debt, , ) = vault.getPosition();
        console.log("Current collateral:", coll);
        console.log("Current debt:", debt);
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));

        // Repay with 10% buffer for interest
        uint256 repayAmount = (debt * 110) / 100;
        if (repayAmount == 0) repayAmount = BORROW_AMOUNT;
        console.log("Repay amount (with buffer):", repayAmount);

        vm.startBroadcast(pk);

        // Step 1: Approve USDC and repay debt
        IERC20(USDC).approve(vaultAddr, repayAmount);
        vault.repayUSDC(repayAmount);
        console.log("Debt repaid");

        // Step 2: Withdraw iBGT from Dolomite
        vault.withdrawiBGT(0); // 0 = withdraw all
        console.log("iBGT withdrawn from Dolomite");

        // Step 3: Withdraw iBGT from contract to deployer
        uint256 contractIBGT = IERC20(IBGT).balanceOf(vaultAddr);
        if (contractIBGT > 0) {
            vault.withdrawFromContract(0); // 0 = withdraw all
            console.log("iBGT withdrawn from contract:", contractIBGT);
        }

        // Step 4: Withdraw any leftover USDC from contract
        uint256 contractUSDC = IERC20(USDC).balanceOf(vaultAddr);
        if (contractUSDC > 0) {
            vault.emergencyWithdraw(USDC, contractUSDC);
            console.log("Leftover USDC withdrawn:", contractUSDC);
        }

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  TEST COMPLETE");
        console.log("=======================================");
        console.log("Deployer iBGT:", IERC20(IBGT).balanceOf(deployer));
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));
    }

    // ============================================================
    // HELPER: Check balances
    // ============================================================
    function checkBalances() external view {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        address vaultAddr = vm.envAddress("DOLOMITE_VAULT_ADDR");

        console.log("=== Balance Check ===");
        console.log("Deployer iBGT:", IERC20(IBGT).balanceOf(deployer));
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        (uint256 coll, uint256 debt, uint256 cIBGT, uint256 cUSDC) = DolomiteVault(vaultAddr).getPosition();
        console.log("Position collateral:", coll);
        console.log("Position debt:", debt);
        console.log("Contract iBGT:", cIBGT);
        console.log("Contract USDC:", cUSDC);
    }
}
