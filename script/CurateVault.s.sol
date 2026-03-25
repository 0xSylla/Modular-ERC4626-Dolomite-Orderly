// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Data} from "../src/libraries/Data.sol";
import {DiracVault} from "../src/vault/DiracVault.sol";
import {DiracVaultFactory} from "../src/factory/DiracVaultFactory.sol";
import {VaultCuratorRouter} from "../src/routers/VaultCuratorRouter.sol";

/// @title CurateVault
/// @notice Curator Phase 2: Configure trade cycle, whitelist target assets, define strategies, grant operator
/// @dev Run: forge script script/CurateVault.s.sol:CurateVault --sig "run()" --rpc-url mainnet --broadcast
///      Env: VAULT_ADDR, FACTORY_ADDR, PRIVATE_KEY, OPERATOR_ADDR
///      Individual functions can be called via --sig, e.g.:
///        forge script script/CurateVault.s.sol:CurateVault --sig "setCycle()" --rpc-url mainnet --broadcast
contract CurateVault is Script {
    // ============ Berachain Addresses ============
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;

    function run() external {
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address routerAddr = vm.envAddress("ROUTER_ADDR");
        address operatorAddr = vm.envOr("OPERATOR_ADDR", address(0));

        DiracVault vault = DiracVault(payable(vaultAddr));
        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);

        _startBroadcast();

        // --- 1. Whitelist Target Assets ---
        console.log("--- Step 1: Whitelist Target Assets ---");
        vault.whitelistTargetAsset(IBGT);
        console.log("iBGT whitelisted as target asset.");

        // --- 3. Define Position (on router) ---
        console.log("--- Step 3: Define Position ---");

        // Get module addresses from factory
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");
        bytes32 orderlyModule = keccak256("perps.orderly");

        uint256 positionId = router.definePosition(
            vaultAddr,
            IBGT,
            "BERA",                 // perpsAsset: short BERA
            600_000e6               // allocation: 600k USDC
        );
        console.log("Position defined, ID:", positionId);

        // --- 4. Grant Operator Role ---
        if (operatorAddr != address(0)) {
            console.log("--- Step 4: Grant Operator Role ---");
            factory.grantVaultOperator(address(vault), operatorAddr);
            console.log("OPERATOR_ROLE granted to:", operatorAddr);
        }

        vm.stopBroadcast();

        console.log("=======================================");
        console.log("  VAULT CURATED SUCCESSFULLY");
        console.log("=======================================");
        console.log("Next: Open deposits with openDeposits(), then use OperateVault.s.sol");
    }

    // ============ Individual Functions ============

    function openDeposits() external {
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        _startBroadcast();
        DiracVault(payable(vaultAddr)).openDeposits();
        vm.stopBroadcast();
        console.log("Deposits opened.");
    }

    function startTrading() external {
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        _startBroadcast();
        DiracVault(payable(vaultAddr)).startTrading();
        vm.stopBroadcast();
        console.log("Trading started. Assets snapshot taken for P&L.");
    }

    function openWithdrawals() external {
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        _startBroadcast();
        DiracVault(payable(vaultAddr)).openWithdrawals();
        vm.stopBroadcast();
        console.log("Withdrawals opened. Performance fees collected.");
    }

    function closeCycle() external {
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        _startBroadcast();
        DiracVault(payable(vaultAddr)).closeCycle();
        vm.stopBroadcast();
        console.log("Cycle closed.");
    }

    function grantOperator() external {
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address operatorAddr = vm.envAddress("OPERATOR_ADDR");
        _startBroadcast();
        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        factory.grantVaultOperator(vaultAddr, operatorAddr);
        vm.stopBroadcast();
        console.log("OPERATOR_ROLE granted to:", operatorAddr);
    }

    function _startBroadcast() internal {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        require(pk != 0, "PRIVATE_KEY not set");
        vm.startBroadcast(pk);
    }
}
