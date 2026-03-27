// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Data} from "../../src/libraries/Data.sol";
import {DiracVaultFactory} from "../../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../../src/vault/DiracVault.sol";
import {OrderlyModule} from "../../src/modules/perps/OrderlyModule.sol";
import {DolomiteBeraModule} from "../../src/modules/lending/dolomite/DolomiteBeraModule.sol";
import {KodiakModule} from "../../src/modules/swap/KodiakModule.sol";
import {IVault, VaultTypes} from "../../src/interfaces/IOrderly.sol";

/// @title E2EOrderlyTest
/// @notice E2E: Deploy → Deposit → Init Orderly → Delegate Signer → Deposit to Orderly
/// @dev On-chain portion only. Off-chain steps (set leverage, open short) require the orderly-bot script.
///      Run: forge script script/mainnet-tests/E2EOrderlyTest.s.sol:E2EOrderlyTest --rpc-url mainnet --broadcast --ffi
contract E2EOrderlyTest is Script {
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    address public constant ORDERLY_VAULT = 0x816f722424B49Cf1275cc86DA9840Fbd5a6167e9;

    string public constant BROKER_ID = "honeypot";

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== E2E Orderly Test ===");
        console.log("Deployer:", deployer);
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

        DiracVaultFactory factory = new DiracVaultFactory(deployer, deployer, fees);
        DolomiteBeraModule dolomiteModule = new DolomiteBeraModule();
        KodiakModule kodiakModule = new KodiakModule();
        OrderlyModule orderlyModule = new OrderlyModule();

        factory.registerModule(keccak256("lending.dolomite"), address(dolomiteModule));
        factory.registerModule(keccak256("swap.kodiak"), address(kodiakModule));
        factory.registerModule(keccak256("perps.orderly"), address(orderlyModule));
        factory.whitelistDepositToken(USDC);
        string[] memory ibgtPerps = new string[](1);
        ibgtPerps[0] = "BERA";
        factory.whitelistStrategyAsset(
            Data.AssetInfo({token: IBGT, allowedPerpsAssets: ibgtPerps})
        );
        factory.setModuleLendingConfig(keccak256("lending.dolomite"), IBGT, abi.encode(uint256(34)));
        console.log("Factory:", address(factory));

        factory.registerTemplate(keccak256("delta-neutral-v1"));

        // ========================================
        // STEP 2: Create Vault + Deposit
        // ========================================
        console.log("\n--- Step 2: Create Vault + Deposit ---");

        address vaultAddr = factory.createVault(
            "Dirac Orderly Test", "dORD", USDC, 1_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.VaultFees({ performanceFeeBps: 1000, managementFeeBps: 50, feeRecipient: deployer }),
            0, // rebalanceThresholdBps
            0  // fundingRateThresholdBps
        );
        DiracVault vault = DiracVault(payable(vaultAddr));
        // deployer already has OPERATOR_ROLE (factory auto-grants to deployer)
        console.log("Vault:", vaultAddr);

        vault.openDeposits();

        uint256 depositAmount = 50_000; // 0.05 USDC
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount, deployer);
        console.log("Deposited:", depositAmount);

        // ========================================
        // STEP 3: Start Trading + Init Orderly
        // ========================================
        console.log("\n--- Step 3: Start Trading + Init Orderly ---");
        vault.startTrading();

        vault.executeModule(
            keccak256("perps.orderly"),
            abi.encodeCall(OrderlyModule.initializeModule, (ORDERLY_VAULT))
        );
        console.log("Orderly module initialized with vault:", ORDERLY_VAULT);

        // ========================================
        // STEP 4: Delegate Signer
        // ========================================
        console.log("\n--- Step 4: Delegate Signer ---");

        bytes32 brokerHash = keccak256(abi.encodePacked(BROKER_ID));

        VaultTypes.VaultDelegate memory delegateData = VaultTypes.VaultDelegate({
            brokerHash: brokerHash,
            delegateSigner: deployer // EOA that will sign orders off-chain
        });

        vault.executeModule(
            keccak256("perps.orderly"),
            abi.encodeCall(OrderlyModule.delegateSigner, (delegateData))
        );
        console.log("Delegate signer set to:", deployer);

        // ========================================
        // STEP 5: Deposit USDC to Orderly
        // ========================================
        console.log("\n--- Step 5: Deposit USDC to Orderly ---");

        // Compute accountId: keccak256(abi.encode(userAddress, brokerHash)) per Orderly's Utils.sol
        bytes32 accountId = keccak256(abi.encode(vaultAddr, brokerHash));
        bytes32 tokenHash = keccak256(abi.encodePacked("USDC"));

        console.log("Account ID:");
        console.logBytes32(accountId);
        console.log("Broker Hash:");
        console.logBytes32(brokerHash);
        console.log("Token Hash:");
        console.logBytes32(tokenHash);

        uint256 orderlyDeposit = IERC20(USDC).balanceOf(vaultAddr);
        console.log("Depositing to Orderly:", orderlyDeposit);

        VaultTypes.VaultDepositFE memory depositData = VaultTypes.VaultDepositFE({
            accountId: accountId,
            brokerHash: brokerHash,
            tokenHash: tokenHash,
            tokenAmount: uint128(orderlyDeposit)
        });

        // Deposit fee for Orderly cross-chain messaging (~0.02 BERA)
        // Queried on-chain via: cast call ORDERLY_VAULT "getDepositFee(...)" => ~20063118218682404 wei
        uint256 depositFee = 0.025 ether; // Slight overpay to cover fee fluctuations
        console.log("Deposit fee (BERA):", depositFee);

        vault.executeModule{value: depositFee}(
            keccak256("perps.orderly"),
            abi.encodeCall(
                OrderlyModule.deposit,
                (USDC, depositData, depositFee)
            )
        );

        console.log("Deposited to Orderly successfully!");
        console.log("Vault USDC remaining:", IERC20(USDC).balanceOf(vaultAddr));

        vm.stopBroadcast();

        // ========================================
        // OUTPUT: Info needed for off-chain steps
        // ========================================
        console.log("\n=======================================");
        console.log("  ON-CHAIN STEPS COMPLETE");
        console.log("=======================================");
        console.log("\nNext: Run off-chain steps with orderly-bot:");
        console.log("  1. Confirm delegate signer via REST API");
        console.log("  2. Register orderly key (ed25519)");
        console.log("  3. Set leverage to 100x");
        console.log("  4. Open short on PERP_ETH_USDC");
        console.log("\nVault address:", vaultAddr);
        console.log("Deployer (delegate signer):", deployer);
        console.log("Factory:", address(factory));
    }
}
