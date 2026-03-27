// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Data} from "../../src/libraries/Data.sol";
import {DiracVaultFactory} from "../../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../../src/vault/DiracVault.sol";
import {DolomiteBeraModule} from "../../src/modules/lending/dolomite/DolomiteBeraModule.sol";
import {KodiakModule} from "../../src/modules/swap/KodiakModule.sol";
import {OrderlyModule} from "../../src/modules/perps/OrderlyModule.sol";
import {UserRouter} from "../../src/routers/UserRouter.sol";
import {VaultCuratorRouter} from "../../src/routers/VaultCuratorRouter.sol";

/// @title E2ETest
/// @notice End-to-end mainnet test: Deploy → Create Vault → Deposit → Withdraw
/// @dev Run: forge script script/E2ETest.s.sol:E2ETest --rpc-url mainnet --broadcast
contract E2ETest is Script {
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== E2E Test on Berachain Mainnet ===");
        console.log("Deployer / Curator / User:", deployer);
        console.log("USDC balance:", IERC20(USDC).balanceOf(deployer));

        vm.startBroadcast(pk);

        // ========================================
        // STEP 1: Deploy Protocol
        // ========================================
        console.log("\n--- Step 1: Deploy Protocol ---");

        Data.ProtocolFees memory fees = Data.ProtocolFees({
            protocolFeeBps: 1000,
            daoFeeBps: 300,
            protocolFeeRecipient: deployer,
            daoFeeRecipient: deployer
        });

        DiracVaultFactory factory = new DiracVaultFactory(deployer, deployer);
        console.log("Factory:", address(factory));

        DolomiteBeraModule dolomiteModule = new DolomiteBeraModule();
        KodiakModule kodiakModule = new KodiakModule();
        OrderlyModule orderlyModule = new OrderlyModule();
        console.log("Modules deployed.");

        factory.registerModule(keccak256("lending.dolomite"), address(dolomiteModule));
        factory.registerModule(keccak256("swap.kodiak"), address(kodiakModule));
        factory.registerModule(keccak256("perps.orderly"), address(orderlyModule));
        console.log("Modules registered.");

        factory.whitelistDepositToken(USDC);
        console.log("USDC whitelisted as deposit token.");

        string[] memory ibgtPerps = new string[](1);
        ibgtPerps[0] = "BERA";
        factory.whitelistStrategyAsset(
            Data.AssetInfo({
                token: IBGT,
                allowedPerpsAssets: ibgtPerps
            })
        );
        factory.setModuleLendingConfig(keccak256("lending.dolomite"), IBGT, abi.encode(uint256(34)));
        console.log("iBGT whitelisted as strategy asset.");

        UserRouter userRouter = new UserRouter(address(factory));
        VaultCuratorRouter curatorRouter = new VaultCuratorRouter(address(factory));
        console.log("Routers deployed.");

        factory.registerTemplate(keccak256("delta-neutral-v1"));

        // ========================================
        // STEP 2: Curator Creates Vault
        // ========================================
        console.log("\n--- Step 2: Curator Creates Vault ---");

        address vaultAddr = factory.createVault(
            "Dirac E2E Test Vault",
            "dE2E",
            USDC,
            1_000_000e6, // 1M USDC max
            keccak256("delta-neutral-v1"),
            Data.VaultFees({ performanceFeeBps: 1000, managementFeeBps: 50, feeRecipient: deployer }),
            0, // rebalanceThresholdBps
            0  // fundingRateThresholdBps
        );
        DiracVault vault = DiracVault(payable(vaultAddr));
        console.log("Vault created:", vaultAddr);

        // deployer already has OPERATOR_ROLE (factory auto-grants to deployer)

        // ========================================
        // STEP 3: Curator Configures Cycle
        // ========================================
        console.log("\n--- Step 3: Configure Cycle ---");

        vault.openDeposits();
        console.log("Deposits OPEN.");

        // ========================================
        // STEP 4: User Deposits
        // ========================================
        console.log("\n--- Step 4: User Deposits ---");

        uint256 depositAmount = 500_000; // 0.5 USDC (6 decimals)
        uint256 usdcBefore = IERC20(USDC).balanceOf(deployer);
        console.log("USDC before deposit:", usdcBefore);

        IERC20(USDC).approve(vaultAddr, depositAmount);
        uint256 shares = vault.deposit(depositAmount, deployer);
        console.log("Deposited 0.5 USDC, shares received:", shares);
        console.log("USDC after deposit:", IERC20(USDC).balanceOf(deployer));
        console.log("Vault share balance:", vault.balanceOf(deployer));
        console.log("Vault totalAssets:", vault.totalAssets());

        // ========================================
        // STEP 5: Advance Cycle → Trading → Withdrawals
        // ========================================
        console.log("\n--- Step 5: Advance Cycle ---");

        vault.startTrading();
        console.log("Trading started (assets snapshot taken).");

        vault.openWithdrawals();
        console.log("Withdrawals OPEN (fees collected if profit).");

        // ========================================
        // STEP 6: User Withdraws
        // ========================================
        console.log("\n--- Step 6: User Withdraws ---");

        uint256 sharesBal = vault.balanceOf(deployer);
        uint256 assetsOut = vault.redeem(sharesBal, deployer, deployer);
        console.log("Redeemed all shares, USDC received:", assetsOut);
        console.log("USDC final balance:", IERC20(USDC).balanceOf(deployer));
        console.log("Vault share balance:", vault.balanceOf(deployer));

        // ========================================
        // STEP 7: Close Cycle
        // ========================================
        vault.closeCycle();
        console.log("\nCycle CLOSED.");

        vm.stopBroadcast();

        // ========================================
        // Summary
        // ========================================
        console.log("\n=======================================");
        console.log("  E2E TEST COMPLETE");
        console.log("=======================================");
        console.log("Factory:        ", address(factory));
        console.log("Vault:          ", vaultAddr);
        console.log("DolomiteBeraModule: ", address(dolomiteModule));
        console.log("KodiakModule:   ", address(kodiakModule));
        console.log("OrderlyModule:  ", address(orderlyModule));
        console.log("UserRouter:     ", address(userRouter));
        console.log("CuratorRouter:  ", address(curatorRouter));
        console.log("=======================================");
    }
}
