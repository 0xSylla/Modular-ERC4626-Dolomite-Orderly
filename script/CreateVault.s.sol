// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Data} from "../src/libraries/Data.sol";
import {DiracVaultFactory} from "../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../src/vault/DiracVault.sol";

/// @title CreateVault
/// @notice Curator Phase 1: Deploy a new vault via the factory
/// @dev Run: forge script script/CreateVault.s.sol:CreateVault --rpc-url mainnet --broadcast
///      Env: FACTORY_ADDR, PRIVATE_KEY, DEPOSIT_TOKEN (optional, defaults to USDC)
contract CreateVault is Script {
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;

    function run() external {
        uint256 curatorPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        require(curatorPrivateKey != 0, "PRIVATE_KEY not set");

        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        address depositToken = vm.envOr("DEPOSIT_TOKEN", USDC);
        uint256 maxDeposit = vm.envOr("MAX_DEPOSIT", uint256(1_000_000e6)); // 1M USDC default
        uint256 curatorFeeBps = vm.envOr("CURATOR_FEE_BPS", uint256(200)); // 2% default
        address curatorAddr = vm.addr(curatorPrivateKey);

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);

        vm.startBroadcast(curatorPrivateKey);

        console.log("--- Creating Vault ---");
        console.log("Curator:", curatorAddr);
        console.log("Deposit token:", depositToken);
        console.log("Max deposit:", maxDeposit);
        console.log("Curator fee (bps):", curatorFeeBps);

        bytes32 templateId = vm.envOr("TEMPLATE_ID", keccak256("delta-neutral-v1"));

        address vault = factory.createVault(
            "Dirac iBGT Delta-Neutral Vault",
            "diBGT-DN",
            depositToken,
            maxDeposit,
            templateId,
            Data.CuratorFeeConfig({
                curatorFeeBps: curatorFeeBps,
                curatorFeeRecipient: curatorAddr
            })
        );

        console.log("Vault deployed at:", vault);

        vm.stopBroadcast();

        console.log("=======================================");
        console.log("  VAULT CREATED SUCCESSFULLY");
        console.log("=======================================");
        console.log("Vault:          ", vault);
        console.log("Curator:        ", curatorAddr);
        console.log("Deposit Token:  ", depositToken);
        console.log("Max Deposit:    ", maxDeposit);
        console.log("=======================================");
        console.log("Next: Run CurateVault.s.sol to configure cycle and strategies.");
    }
}
