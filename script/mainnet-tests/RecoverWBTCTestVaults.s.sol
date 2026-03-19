// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DiracVault} from "../../src/vault/DiracVault.sol";

/// @title RecoverWBTCTestVaults
/// @notice Recover USDC from abandoned WBTC test vaults (3 deployments that got redeployed).
///         Cycles each vault: openWithdrawals → redeem all shares → closeCycle.
///
/// @dev Vaults 2 & 3 also have ~$0.60 each stuck in Dolomite borrow positions (1400 WBTC sats
///      collateral, ~400k USDC debt). Those positions are healthy and can't be recovered without
///      the fixed module code. They'll eventually be liquidated or can be abandoned.
///
/// Run: forge script script/mainnet-tests/RecoverWBTCTestVaults.s.sol:RecoverWBTCTestVaults \
///        --rpc-url mainnet --broadcast --with-gas-price 10000000
contract RecoverWBTCTestVaults is Script {
    address constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;

    // Deploy 1: phase3 borrow failed (old openBorrowPosition). Vault has full 1 USDC.
    address constant VAULT_1 = 0xE99373fbc924387ca5A7F5Edc67dD181F11658d0;
    // Deploy 2: phase4 repayDebt auth failed. Vault has 0.4 USDC (borrowed amount).
    address constant VAULT_2 = 0x4a2d7C8dfc7504334Badd98F5298CAe8f81f351D;
    // Deploy 3: phase4 _positionOwner failed. Vault has 0.4 USDC (borrowed amount).
    address constant VAULT_3 = 0x8C3Fc0CbCD8c97D3F754Ec1F011f15D3f7E3B534;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);

        console.log("=== Recover Abandoned WBTC Test Vaults ===");
        console.log("User:", user);
        console.log("User USDC before:", IERC20(USDC).balanceOf(user));

        vm.startBroadcast(pk);

        _recoverVault(VAULT_1, user, "Vault 1 (full 1 USDC)");
        _recoverVault(VAULT_2, user, "Vault 2 (0.4 USDC)");
        _recoverVault(VAULT_3, user, "Vault 3 (0.4 USDC)");

        vm.stopBroadcast();

        console.log("\nUser USDC after:", IERC20(USDC).balanceOf(user));
        console.log("Recovery complete.");
    }

    function _recoverVault(address vaultAddr, address user, string memory label) internal {
        DiracVault vault = DiracVault(payable(vaultAddr));
        uint256 shares = vault.balanceOf(user);
        uint256 vaultUSDC = IERC20(USDC).balanceOf(vaultAddr);

        console.log("\n---", label, "---");
        console.log("Vault USDC:", vaultUSDC);
        console.log("User shares:", shares);

        if (shares == 0) {
            console.log("No shares to redeem, skipping.");
            return;
        }

        vault.openWithdrawals();
        uint256 received = vault.redeem(shares, user, user);
        vault.closeCycle();

        console.log("Redeemed:", received, "USDC");
    }
}
