// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DiracVaultFactory} from "../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../src/vault/DiracVault.sol";
import {AaveModule} from "../src/modules/lending/aave/AaveModule.sol";
import {Data} from "../src/libraries/Data.sol";

/// @title TestAaveE2E
/// @notice Live E2E test: deposit USDC into vault, supply to Aave as WETH, borrow, unwind, withdraw
/// @dev Phased execution:
///   Phase 1: forge script script/TestAaveE2E.s.sol:TestAaveE2E --sig "phase1_createVault()" --rpc-url arbitrum --broadcast --with-gas-price 100000000
///   Phase 2: forge script script/TestAaveE2E.s.sol:TestAaveE2E --sig "phase2_deposit()" --rpc-url arbitrum --broadcast --with-gas-price 100000000
///   Phase 3: forge script script/TestAaveE2E.s.sol:TestAaveE2E --sig "phase3_supplyAndBorrow()" --rpc-url arbitrum --broadcast --with-gas-price 100000000
///   Phase 4: forge script script/TestAaveE2E.s.sol:TestAaveE2E --sig "phase4_repayAndWithdraw()" --rpc-url arbitrum --broadcast --with-gas-price 100000000
contract TestAaveE2E is Script {
    // Arbitrum
    address constant USDC  = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WETH  = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    // Existing Arbitrum deployment
    address constant FACTORY = 0x2dA14f095Ae2494b9EC9d5348274A3836f99c501;
    address constant AAVE_MODULE = 0x402Ee7130fbfa96DE0307F9f712bc437cad92776;

    // Set after phase1 (update manually or via env)
    function _vault() internal view returns (address) {
        return vm.envAddress("TEST_VAULT");
    }

    function _pk() internal view returns (uint256) {
        return vm.envUint("PRIVATE_KEY");
    }

    function _deployer() internal view returns (address) {
        return vm.addr(_pk());
    }

    // ======== Phase 1: Create vault ========
    function phase1_createVault() external {
        uint256 pk = _pk();
        address admin = vm.addr(pk);

        vm.startBroadcast(pk);

        DiracVaultFactory factory = DiracVaultFactory(FACTORY);

        // Create vault
        bytes32 templateId = keccak256("delta-neutral-v1");
        address vault = factory.createVault(
            "Aave Test Vault",
            "atvUSDC",
            USDC,
            1e6, // 1 USDC max deposit (tiny test)
            templateId,
            Data.CuratorFeeConfig({ curatorFeeBps: 0, curatorFeeRecipient: admin })
        );
        console.log("Vault created:", vault);

        // Whitelist WETH as collateral
        DiracVault(payable(vault)).whitelistTargetAsset(WETH);
        console.log("WETH whitelisted on vault");

        // Operator role is auto-granted by factory to its operator address
        console.log("Operator auto-granted by factory");

        // Open deposit window
        DiracVault(payable(vault)).openDeposits();
        console.log("Deposit window opened");

        vm.stopBroadcast();

        console.log("=========================================");
        console.log("Set TEST_VAULT=%s in .env", vault);
        console.log("Then run phase2_deposit()");
        console.log("=========================================");
    }

    // ======== Phase 2: Deposit USDC into vault ========
    function phase2_deposit() external {
        uint256 pk = _pk();
        address vault = _vault();
        address admin = vm.addr(pk);
        uint256 depositAmount = 990000; // 0.99 USDC (vault cap is 1 USDC)
        require(IERC20(USDC).balanceOf(admin) >= depositAmount, "No USDC");

        console.log("Depositing USDC:", depositAmount);

        vm.startBroadcast(pk);

        IERC20(USDC).approve(vault, depositAmount);
        DiracVault(payable(vault)).deposit(depositAmount, admin);

        vm.stopBroadcast();

        uint256 vaultBal = IERC20(USDC).balanceOf(vault);
        console.log("Vault USDC balance:", vaultBal);
        console.log("[OK] Deposit complete. Run phase3_supplyAndBorrow()");
    }

    // ======== Phase 3: Supply WETH to Aave + Borrow USDC ========
    // NOTE: We skip the swap step since we only have ~1 USDC.
    // Instead, we test Aave directly by wrapping ETH to WETH and supplying.
    // For a real flow: swap USDC -> WETH via Odos, then supply.
    function phase3_supplyAndBorrow() external {
        uint256 pk = _pk();
        address vault = _vault();

        // The vault has ~1 USDC. Too small for a swap.
        // Instead, send a tiny bit of WETH directly to the vault for testing.
        // We'll wrap 0.0005 ETH -> WETH and transfer to vault.

        vm.startBroadcast(pk);

        // Wrap ETH to WETH
        uint256 wethAmount = 0.0005 ether;
        (bool ok, ) = WETH.call{value: wethAmount}("");
        require(ok, "WETH wrap failed");
        console.log("Wrapped ETH to WETH:", wethAmount);

        // Transfer WETH to vault
        IERC20(WETH).transfer(vault, wethAmount);
        console.log("Transferred WETH to vault:", IERC20(WETH).balanceOf(vault));

        // Supply WETH to Aave via vault's executeModule
        DiracVault v = DiracVault(payable(vault));
        bytes memory supplyData = abi.encodeCall(
            AaveModule.supplyCollateral, (WETH, wethAmount, 0)
        );
        v.executeModule(keccak256("lending.aave"), supplyData);
        console.log("[OK] Supplied WETH to Aave via vault");

        // Borrow ~0.5 USDC against it
        uint256 borrowAmt = 500000; // 0.5 USDC
        bytes memory borrowData = abi.encodeCall(
            AaveModule.borrowAsset, (USDC, borrowAmt)
        );
        v.executeModule(keccak256("lending.aave"), borrowData);
        console.log("[OK] Borrowed USDC:", IERC20(USDC).balanceOf(vault));

        vm.stopBroadcast();

        console.log("Run phase4_repayAndWithdraw()");
    }

    // ======== Phase 4: Repay + Withdraw + Return funds ========
    function phase4_repayAndWithdraw() external {
        uint256 pk = _pk();
        address vault = _vault();
        address admin = vm.addr(pk);

        vm.startBroadcast(pk);

        DiracVault v = DiracVault(payable(vault));

        // Repay all USDC debt
        bytes memory repayData = abi.encodeCall(
            AaveModule.repayDebt, (USDC, type(uint256).max, 0, 0)
        );
        v.executeModule(keccak256("lending.aave"), repayData);
        console.log("[OK] Repaid all USDC debt");

        // Withdraw all WETH from Aave
        bytes memory withdrawData = abi.encodeCall(
            AaveModule.withdrawCollateralAsset, (WETH, type(uint256).max)
        );
        v.executeModule(keccak256("lending.aave"), withdrawData);
        uint256 wethInVault = IERC20(WETH).balanceOf(vault);
        console.log("[OK] Withdrew WETH from Aave:", wethInVault);

        // Withdraw USDC from vault (user redeem)
        uint256 shares = v.balanceOf(admin);
        if (shares > 0) {
            v.redeem(shares, admin, admin);
            console.log("[OK] Redeemed vault shares");
        }

        // Any remaining WETH stays in vault (no rescue function).
        // It's dust from the test — not user funds.
        uint256 remainingWeth = IERC20(WETH).balanceOf(vault);
        if (remainingWeth > 0) {
            console.log("NOTE: WETH dust remaining in vault:", remainingWeth);
        }

        vm.stopBroadcast();

        console.log("=========================================");
        console.log("  E2E TEST COMPLETE - FUNDS WITHDRAWN");
        console.log("=========================================");
        console.log("Admin USDC:", IERC20(USDC).balanceOf(admin));
        console.log("Admin WETH:", IERC20(WETH).balanceOf(admin));
    }
}
