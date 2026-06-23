// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DiracFaucet} from "../src/mocks/DiracFaucet.sol";

/// @title DeployFaucet
/// @notice Deploy + fund the test $DIRAC faucet for the staking tab.
///
/// @dev Required env:
///   PRIVATE_KEY    deployer (also admin + funding source; must hold TDIRAC)
///   TDIRAC_ADDR    token to dispense
///
///   Optional:
///   ADMIN            faucet admin (default deployer)
///   DRIP_AMOUNT      tokens per claim wei (default 1000e18)
///   FAUCET_COOLDOWN  seconds between claims (default 3600 = 1h)
///   FAUCET_FUNDING   TDIRAC to seed the faucet wei (default 10_000_000e18)
contract DeployFaucet is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address admin = vm.envOr("ADMIN", deployer);
        address tdirac = vm.envAddress("TDIRAC_ADDR");
        require(tdirac != address(0), "TDIRAC_ADDR required");
        uint256 drip = vm.envOr("DRIP_AMOUNT", uint256(1000 * 1e18));
        uint256 cooldown = vm.envOr("FAUCET_COOLDOWN", uint256(1 hours));
        uint256 funding = vm.envOr("FAUCET_FUNDING", uint256(10_000_000 * 1e18));

        vm.startBroadcast(pk);
        DiracFaucet faucet = new DiracFaucet(tdirac, admin, drip, cooldown);
        IERC20(tdirac).transfer(address(faucet), funding);
        vm.stopBroadcast();

        require(faucet.balance() == funding, "funding mismatch");

        console.log("");
        console.log("=== DiracFaucet deployed ===");
        console.log("  Faucet:     ", address(faucet));
        console.log("  Token:      ", tdirac);
        console.log("  Admin:      ", admin);
        console.log("  Drip amount:", drip);
        console.log("  Cooldown(s):", cooldown);
        console.log("  Funded:     ", funding);
    }
}
