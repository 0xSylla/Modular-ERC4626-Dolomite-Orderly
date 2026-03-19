// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;
import {Script, console} from "forge-std/Script.sol";
import {DiracVaultFactory} from "../../../src/factory/DiracVaultFactory.sol";
import {VaultCuratorRouter} from "../../../src/routers/VaultCuratorRouter.sol";
import {DolomiteArbModule} from "../../../src/modules/lending/dolomite/DolomiteArbModule.sol";
import {DolomiteLendingBase} from "../../../src/modules/lending/dolomite/DolomiteLendingBase.sol";

/// @dev One-shot: redeploy DolomiteArbModule + re-register + re-init (both routers authorized)
contract RedeployArbModule is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factoryAddr = vm.envAddress("ARB_FACTORY_ADDR");
        address routerAddr = vm.envAddress("ARB_ROUTER_ADDR");
        address vaultAddr = vm.envAddress("ARB_VAULT_ADDR");

        vm.startBroadcast(pk);

        DolomiteArbModule newModule = new DolomiteArbModule();
        DiracVaultFactory(factoryAddr).registerModule(keccak256("lending.dolomite"), address(newModule));
        VaultCuratorRouter(routerAddr).executeModule(
            vaultAddr,
            address(newModule),
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );

        vm.stopBroadcast();

        console.log("New DolomiteArbModule:", address(newModule));
        console.log("Both DepositWithdrawalRouter + BorrowPositionRouter authorized.");
    }
}
