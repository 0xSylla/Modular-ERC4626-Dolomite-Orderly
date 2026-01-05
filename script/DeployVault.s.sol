// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Script, console} from "forge-std/Script.sol";
import {DiracHoneyPotV1} from "../src/contracts/DiracHoneyPotV1.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployVault is Script {
    // Berachain Addresses (Example for Mainnet/Bartio)
    address public constant mainnetOrderlyVault =
        0x816f722424B49Cf1275cc86DA9840Fbd5a6167e9; // Correctly provided by user
    address public constant mainnetIBGT =
        0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b; // Correctly provided by user
    address public constant mainnetUSDC =
        0x549943e04f40284185054145c6E4e9568C1D3241; // Correctly provided by user

    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPrivateKey == 0) {
            console.log(
                "WARNING: PRIVATE_KEY not set, using default anvil key"
            );
            deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }

        address orderlyVault = vm.envOr("ORDERLY_VAULT", mainnetOrderlyVault);
        address iBGT = vm.envOr("IBGT_COLLATERAL", mainnetIBGT);
        address USDC = vm.envOr("USDC_ASSET", mainnetUSDC);

        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying DiracHoneyPotV1 implementation...");
        DiracHoneyPotV1 implementation = new DiracHoneyPotV1();
        console.log("Implementation deployed at:", address(implementation));

        console.log("Deploying ERC1967Proxy...");
        bytes memory initData = abi.encodeWithSelector(
            DiracHoneyPotV1.initialize.selector,
            orderlyVault,
            iBGT,
            USDC,
            IERC20(USDC)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        console.log("Proxy deployed at:", address(proxy));

        vm.stopBroadcast();

        console.log("---------------------------------------");
        console.log("Successful Deployment!");
        console.log("Vault (Proxy):", address(proxy));
        console.log("Implementation:", address(implementation));
        console.log("---------------------------------------");
    }
}
