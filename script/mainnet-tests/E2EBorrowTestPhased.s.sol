// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Data} from "../../src/libraries/Data.sol";
import {DiracVaultFactory} from "../../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../../src/vault/DiracVault.sol";
import {DolomiteBeraModule} from "../../src/modules/lending/dolomite/DolomiteBeraModule.sol";
import {DolomiteLendingBase} from "../../src/modules/lending/dolomite/DolomiteLendingBase.sol";
import {KodiakModule} from "../../src/modules/swap/KodiakModule.sol";
import {OrderlyModule} from "../../src/modules/perps/OrderlyModule.sol";

/// @title E2EBorrowTestPhased
/// @notice Same flow as E2EBorrowTest but split into 4 phases to avoid simulation/broadcast
///         state drift that caused supplyCollateral (isolation mode) to fail on-chain.
///
/// Phase 1 — Deploy:
///   forge script script/mainnet-tests/E2EBorrowTestPhased.s.sol:E2EBorrowTestPhased \
///     --sig "phase1_deploy()" --rpc-url mainnet --broadcast --with-gas-price 10000000
///   (then copy E2E_VAULT_ADDR and E2E_DOLOMITE_MODULE_ADDR into .env)
///
/// Phase 2 — Setup:
///   forge script script/mainnet-tests/E2EBorrowTestPhased.s.sol:E2EBorrowTestPhased \
///     --sig "phase2_setup()" --rpc-url mainnet --broadcast --with-gas-price 10000000
///
/// Phase 3 — Supply + Borrow + RepayDebtWithCollateral:
///   forge script script/mainnet-tests/E2EBorrowTestPhased.s.sol:E2EBorrowTestPhased \
///     --sig "phase3_supplyBorrowRepay()" --rpc-url mainnet --broadcast --with-gas-price 10000000 --ffi
///
/// Phase 4 — Withdraw:
///   forge script script/mainnet-tests/E2EBorrowTestPhased.s.sol:E2EBorrowTestPhased \
///     --sig "phase4_withdraw()" --rpc-url mainnet --broadcast --with-gas-price 10000000
contract E2EBorrowTestPhased is Script {
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    address public constant DOLOMITE_OOGA_ADAPTER = 0x0CE205f7bCBa70E4c03f826918c8c21073386ED3;

    uint256 public constant DIBGT_MARKET_ID = 38;
    uint256 public constant USDC_MARKET_ID = 2;

    uint256 constant DEPOSIT_AMOUNT  = 50_000;                   // 0.05 USDC
    uint256 constant IBGT_TRANSFER   = 200_000_000_000_000_000;  // 0.2 iBGT
    uint256 constant BORROW_AMOUNT   = 10_000;                   // 0.01 USDC

    // =========================================================
    // PHASE 1: Deploy factory, modules, create vault
    // =========================================================
    function phase1_deploy() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== Phase 1: Deploy ===");
        console.log("Deployer:", deployer);
        console.log("USDC balance:", IERC20(USDC).balanceOf(deployer));
        console.log("iBGT balance:", IERC20(IBGT).balanceOf(deployer));

        vm.startBroadcast(pk);

        Data.ProtocolFees memory fees = Data.ProtocolFees({
            protocolFeeBps: 1000,
            daoFeeBps: 300,
            protocolFeeRecipient: deployer,
            daoFeeRecipient: deployer
        });

        DiracVaultFactory factory = new DiracVaultFactory(deployer, deployer);
        DolomiteBeraModule dolomiteModule = new DolomiteBeraModule();
        KodiakModule kodiakModule = new KodiakModule();
        OrderlyModule orderlyModule = new OrderlyModule();

        factory.registerModule(keccak256("lending.dolomite"), address(dolomiteModule));
        factory.registerModule(keccak256("swap.kodiak"),      address(kodiakModule));
        factory.registerModule(keccak256("perps.orderly"),    address(orderlyModule));
        factory.whitelistDepositToken(USDC);

        string[] memory ibgtPerps = new string[](1);
        ibgtPerps[0] = "BERA";
        factory.whitelistStrategyAsset(Data.AssetInfo({token: IBGT, allowedPerpsAssets: ibgtPerps}));
        factory.setModuleLendingConfig(keccak256("lending.dolomite"), IBGT, abi.encode(uint256(34)));
        factory.registerTemplate(keccak256("delta-neutral-v1"));

        address vaultAddr = factory.createVault(
            "Dirac Borrow Test", "dBRW", USDC, 1_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.VaultFees({ performanceFeeBps: 1000, managementFeeBps: 50, feeRecipient: deployer }),
            0, // rebalanceThresholdBps
            0  // fundingRateThresholdBps
        );

        vm.stopBroadcast();

        console.log("\n=== Copy these into .env ===");
        console.log("E2E_VAULT_ADDR=", vaultAddr);
        console.log("E2E_DOLOMITE_MODULE_ADDR=", address(dolomiteModule));
        console.log("\nNext: phase2_setup()");
    }

    // =========================================================
    // PHASE 2: openDeposits, deposit USDC, startTrading, initDolomite, transfer iBGT
    // =========================================================
    function phase2_setup() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddr = vm.envAddress("E2E_VAULT_ADDR");
        address dolomiteModuleAddr = vm.envAddress("E2E_DOLOMITE_MODULE_ADDR");
        DiracVault vault = DiracVault(payable(vaultAddr));

        console.log("=== Phase 2: Setup ===");
        console.log("Vault:", vaultAddr);

        vm.startBroadcast(pk);

        vault.openDeposits();

        IERC20(USDC).approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, deployer);
        console.log("Deposited USDC:", DEPOSIT_AMOUNT);

        vault.startTrading();

        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );
        console.log("Dolomite module initialized");

        IERC20(IBGT).transfer(vaultAddr, IBGT_TRANSFER);
        console.log("iBGT transferred to vault:", IBGT_TRANSFER);

        vm.stopBroadcast();

        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("\nNext: phase3_supplyBorrowRepay() --ffi");
    }

    // =========================================================
    // PHASE 3: Supply iBGT → Borrow → RepayDebt → Supply again →
    //          Borrow again → RepayDebtWithCollateral (OogaBooga zap)
    //
    // Supply is the FIRST operation in this phase so simulation is
    // tight to broadcast — fixes the diBGT ERC4626 underflow issue.
    // =========================================================
    function phase3_supplyBorrowRepay() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("E2E_VAULT_ADDR");
        address dolomiteModuleAddr = vm.envAddress("E2E_DOLOMITE_MODULE_ADDR");
        DiracVault vault = DiracVault(payable(vaultAddr));
        DolomiteBeraModule dolomiteModule = DolomiteBeraModule(dolomiteModuleAddr);

        console.log("=== Phase 3: Supply + Borrow + RepayWithCollateral ===");
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        vm.startBroadcast(pk);

        // --- Supply iBGT to Dolomite isolation mode (market 38) ---
        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.supplyCollateral, (IBGT, type(uint256).max, DIBGT_MARKET_ID))
        );
        console.log("Supplied iBGT. Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));

        // --- Borrow USDC ---
        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.borrow, (BORROW_AMOUNT, DIBGT_MARKET_ID, USDC_MARKET_ID))
        );
        console.log("Borrowed. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // --- RepayDebt (auto amount = 101% of debt) ---
        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.repayDebt, (USDC, 0, DIBGT_MARKET_ID, USDC_MARKET_ID))
        );
        console.log("Debt repaid. Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));

        // --- Supply iBGT again ---
        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.supplyCollateral, (IBGT, type(uint256).max, DIBGT_MARKET_ID))
        );
        console.log("Re-supplied. Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));

        // --- Borrow USDC again ---
        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.borrow, (BORROW_AMOUNT, DIBGT_MARKET_ID, USDC_MARKET_ID))
        );
        console.log("Re-borrowed. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        vm.stopBroadcast();

        // --- Fetch OogaBooga quote (FFI, outside broadcast so quote is fresh) ---
        (uint256 expectedOut, uint256 minOut, bytes memory pathDef) =
            _fetchOogaBoogaQuote(IBGT, USDC, IBGT_TRANSFER);
        console.log("OogaBooga quote - expectedOut:", expectedOut, "minOut:", minOut);

        vm.startBroadcast(pk);

        // --- RepayDebtWithCollateral (atomic diBGT → iBGT → USDC zap) ---
        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(
                DolomiteBeraModule.repayDebtWithCollateral,
                (IBGT, USDC, minOut, expectedOut, pathDef, DIBGT_MARKET_ID, USDC_MARKET_ID)
            )
        );
        console.log("RepayWithCollateral done.");
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        vm.stopBroadcast();

        console.log("\nNext: phase4_withdraw()");
    }

    // =========================================================
    // PHASE 4: openWithdrawals, redeem, closeCycle
    // =========================================================
    function phase4_withdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddr = vm.envAddress("E2E_VAULT_ADDR");
        DiracVault vault = DiracVault(payable(vaultAddr));

        console.log("=== Phase 4: Withdraw ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Shares:", vault.balanceOf(deployer));

        vm.startBroadcast(pk);

        vault.openWithdrawals();
        uint256 shares = vault.balanceOf(deployer);
        uint256 assetsOut = vault.redeem(shares, deployer, deployer);
        console.log("Redeemed. USDC received:", assetsOut);

        vault.closeCycle();
        console.log("Cycle closed.");

        vm.stopBroadcast();

        console.log("\n=== E2E BORROW TEST COMPLETE ===");
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));
        console.log("Deployer iBGT:", IERC20(IBGT).balanceOf(deployer));
    }

    // =========================================================
    // OogaBooga FFI helper
    // =========================================================
    function _fetchOogaBoogaQuote(
        address tokenIn,
        address tokenOut,
        uint256 amount
    )
        internal
        returns (uint256 expectedOut, uint256 minOut, bytes memory pathDefinition)
    {
        string memory apiKey = vm.envString("OOGABOOGA_API_KEY");
        string memory curlCmd = string.concat(
            "curl -s -H 'Authorization: Bearer ", apiKey, "' "
            "'https://mainnet.api.oogabooga.io/v1/swap"
            "?tokenIn=", vm.toString(tokenIn),
            "&tokenOut=", vm.toString(tokenOut),
            "&amount=", vm.toString(amount),
            "&to=", vm.toString(DOLOMITE_OOGA_ADAPTER),
            "&slippage=0.05'"
        );

        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = curlCmd;

        console.log("Fetching OogaBooga quote...");
        bytes memory result = vm.ffi(cmd);
        string memory json = string(result);

        expectedOut     = vm.parseJsonUint(json, ".assumedAmountOut");
        minOut          = (expectedOut * 95) / 100;
        pathDefinition  = vm.parseJsonBytes(json, ".routerParams.pathDefinition");
    }
}
