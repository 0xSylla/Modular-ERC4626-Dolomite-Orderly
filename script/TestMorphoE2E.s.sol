// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DiracVaultFactory} from "../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../src/vault/DiracVault.sol";
import {MorphoModule} from "../src/modules/lending/morpho/MorphoModule.sol";
import {Data} from "../src/libraries/Data.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams} from "../src/interfaces/IMorpho.sol";

/// @title TestMorphoE2E
/// @notice End-to-end test: deploy Morpho module → create vault → deposit → supply → borrow → repay → withdraw
/// @dev Run phases individually:
///   Phase 1 (deploy+setup): forge script script/TestMorphoE2E.s.sol:TestMorphoE2E --sig "phase1_setup()" --rpc-url arbitrum --broadcast
///   Phase 2 (deposit+supply+borrow): forge script script/TestMorphoE2E.s.sol:TestMorphoE2E --sig "phase2_supplyBorrow()" --rpc-url arbitrum --broadcast
///   Phase 3 (repay+withdraw+redeem): forge script script/TestMorphoE2E.s.sol:TestMorphoE2E --sig "phase3_repayWithdraw()" --rpc-url arbitrum --broadcast
contract TestMorphoE2E is Script {
    // ============ Arbitrum Addresses ============
    address constant FACTORY = 0x2dA14f095Ae2494b9EC9d5348274A3836f99c501;
    address constant ROUTER  = 0x8f1B5Fb2604FF2ac9f218394d35CC22c064Bb0a3;

    address constant USDC    = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WSTETH  = 0x5979D7b546E38E414F7E9822514be443A4800529;

    // Morpho wstETH/USDC market params
    address constant MORPHO_BLUE   = 0x6c247b1F6182318877311737BaC0844bAa518F5e;
    address constant MORPHO_ORACLE = 0x8e02a9b9Cc29d783b2fCB71C3a72651B591cae31;
    address constant MORPHO_IRM    = 0x66F30587FB8D4206918deb78ecA7d5eBbafD06DA;
    uint256 constant MORPHO_LLTV   = 860000000000000000;

    // Odos Router V2
    address constant ODOS_ROUTER = 0xa669e7A0d4b3e4Fa48af2dE86BD4CD7126Be4e13;

    // ============ State (set by phase1, read by phase2/3 via env) ============

    function _pk() internal view returns (uint256) {
        return vm.envUint("PRIVATE_KEY");
    }

    function _vault() internal view returns (address) {
        return vm.envAddress("TEST_MORPHO_VAULT");
    }

    function _morphoModule() internal view returns (address) {
        return vm.envAddress("TEST_MORPHO_MODULE");
    }

    // ============ Phase 1: Deploy module, whitelist, create vault ============

    function phase1_setup() external {
        uint256 pk = _pk();
        address deployer = vm.addr(pk);
        DiracVaultFactory factory = DiracVaultFactory(FACTORY);

        vm.startBroadcast(pk);

        // 1. Deploy fresh MorphoModule (with correct Arbitrum Morpho address)
        MorphoModule morphoModule = new MorphoModule();
        console.log("MorphoModule deployed at:", address(morphoModule));

        // 2. Re-register on factory (overwrites old one)
        bytes32 morphoTypeHash = keccak256("lending.morpho");
        factory.registerModule(morphoTypeHash, address(morphoModule));
        console.log("MorphoModule registered on factory");

        // 3. Whitelist wstETH if not already
        bytes32 orderlyTypeHash = keccak256("perps.orderly");
        try factory.whitelistStrategyAsset(Data.AssetInfo({
            token: WSTETH,
            allowedPerpsAssets: _ethPerps()
        })) {
            console.log("wstETH whitelisted");
        } catch {
            console.log("wstETH already whitelisted (skipping)");
        }

        // 4. Set Morpho lending config
        factory.setModuleLendingConfig(morphoTypeHash, WSTETH, abi.encode(
            USDC,
            WSTETH,
            MORPHO_ORACLE,
            MORPHO_IRM,
            MORPHO_LLTV
        ));
        console.log("Morpho lending config set for wstETH");

        factory.setPerpsModuleSymbol(WSTETH, orderlyTypeHash, bytes("PERP_ETH_USDC"));

        // 5. Create vault
        address vault = factory.createVault(
            "Morpho Test Vault",
            "mtVAULT",
            USDC,
            type(uint256).max,
            keccak256("delta-neutral-v1"),
            Data.VaultFees({ performanceFeeBps: 1000, managementFeeBps: 50, feeRecipient: deployer }),
            0, // rebalanceThresholdBps
            0  // fundingRateThresholdBps
        );
        console.log("Vault created at:", vault);

        // 6. Whitelist wstETH on vault
        DiracVault(payable(vault)).whitelistTargetAsset(WSTETH);
        console.log("wstETH whitelisted on vault");

        // 7. Open deposits
        DiracVault(payable(vault)).openDeposits();
        console.log("Deposits opened");

        vm.stopBroadcast();

        console.log("=======================================");
        console.log("  PHASE 1 COMPLETE");
        console.log("=======================================");
        console.log("MorphoModule:", address(morphoModule));
        console.log("Vault:", vault);
        console.log("");
        console.log("Set env vars for next phases:");
        console.log("  TEST_MORPHO_VAULT=<vault address>");
        console.log("  TEST_MORPHO_MODULE=<module address>");
        console.log("=======================================");
    }

    // ============ Phase 2: Deposit USDC, swap to wstETH, supply to Morpho, borrow USDC ============

    function phase2_supplyBorrow() external {
        uint256 pk = _pk();
        address deployer = vm.addr(pk);
        DiracVault vault = DiracVault(payable(_vault()));
        address morphoModule = _morphoModule();

        uint256 depositAmount = IERC20(USDC).balanceOf(deployer);
        require(depositAmount > 0, "No USDC to deposit");
        console.log("Depositing USDC:", depositAmount);

        vm.startBroadcast(pk);

        // 1. Approve + deposit USDC into vault
        IERC20(USDC).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, deployer);
        console.log("[OK] Deposited USDC into vault");

        // 2. Start trading
        vault.startTrading();
        console.log("[OK] Trading started");

        // 3. Swap USDC → wstETH via Odos
        //    We need Odos quote calldata. For testing, use a small swap.
        //    TODO: Get Odos quote calldata off-chain and pass via env var
        bytes memory swapData = vm.envOr("ODOS_SWAP_DATA", bytes(""));
        if (swapData.length > 0) {
            // Approve Odos router
            bytes memory approveData = abi.encodeWithSelector(
                IERC20.approve.selector, ODOS_ROUTER, depositAmount
            );
            vault.executeModule(keccak256("swap.odos"), approveData);

            // Execute swap via low-level call to Odos
            // This would be done via OdosModule in production
            console.log("Swap via Odos (custom calldata)");
        } else {
            console.log("SKIP: No ODOS_SWAP_DATA env var - manually swap USDC to wstETH");
            console.log("After swapping, run phase2b_morphoOps()");
            vm.stopBroadcast();
            return;
        }

        vm.stopBroadcast();
    }

    /// @notice Phase 2b: After wstETH is in the vault, supply to Morpho and borrow
    function phase2b_morphoOps() external {
        uint256 pk = _pk();
        DiracVault vault = DiracVault(payable(_vault()));
        address morphoModule = _morphoModule();

        uint256 wstethBalance = IERC20(WSTETH).balanceOf(address(vault));
        require(wstethBalance > 0, "No wstETH in vault - run swap first");
        console.log("wstETH in vault:", wstethBalance);

        // Borrow ~50% of collateral value in USDC
        // wstETH ~$3500, 86% LLTV, so borrow conservatively
        uint256 borrowAmount = 400000; // 0.40 USDC (conservative test)

        vm.startBroadcast(pk);

        // 1. Supply wstETH as collateral to Morpho
        bytes memory supplyData = abi.encodeWithSelector(
            MorphoModule.supplyCollateral.selector,
            WSTETH,
            wstethBalance,
            USDC,
            MORPHO_ORACLE,
            MORPHO_IRM,
            MORPHO_LLTV
        );
        vault.executeModule(keccak256("lending.morpho"), supplyData);
        console.log("[OK] Supplied wstETH to Morpho:", wstethBalance);

        // 2. Borrow USDC
        bytes memory borrowData = abi.encodeWithSelector(
            MorphoModule.borrowAsset.selector,
            USDC,
            borrowAmount,
            WSTETH,
            MORPHO_ORACLE,
            MORPHO_IRM,
            MORPHO_LLTV
        );
        vault.executeModule(keccak256("lending.morpho"), borrowData);
        console.log("[OK] Borrowed USDC from Morpho:", borrowAmount);

        vm.stopBroadcast();

        console.log("=======================================");
        console.log("  PHASE 2 COMPLETE - Morpho position open");
        console.log("=======================================");
    }

    // ============ Phase 3: Repay, withdraw, redeem ============

    function phase3_repayWithdraw() external {
        uint256 pk = _pk();
        address deployer = vm.addr(pk);
        DiracVault vault = DiracVault(payable(_vault()));
        address morphoModule = _morphoModule();

        vm.startBroadcast(pk);

        // 1. Repay all USDC debt
        bytes memory repayData = abi.encodeWithSelector(
            MorphoModule.repayDebt.selector,
            USDC,
            type(uint256).max,
            WSTETH,
            MORPHO_ORACLE,
            MORPHO_IRM,
            MORPHO_LLTV
        );
        vault.executeModule(keccak256("lending.morpho"), repayData);
        console.log("[OK] Repaid USDC debt to Morpho");

        // 2. Withdraw all wstETH collateral
        uint256 wstethInMorpho = IERC20(WSTETH).balanceOf(address(vault));
        // Read from Morpho directly
        MarketParams memory params = MarketParams({
            loanToken: USDC,
            collateralToken: WSTETH,
            oracle: MORPHO_ORACLE,
            irm: MORPHO_IRM,
            lltv: MORPHO_LLTV
        });
        bytes32 marketId = keccak256(abi.encode(params));
        (, , uint128 collateral) = IMorpho(MORPHO_BLUE).position(marketId, address(vault));
        console.log("Collateral in Morpho:", collateral);

        if (collateral > 0) {
            bytes memory withdrawData = abi.encodeWithSelector(
                MorphoModule.withdrawCollateral.selector,
                WSTETH,
                collateral,
                USDC,
                MORPHO_ORACLE,
                MORPHO_IRM,
                MORPHO_LLTV
            );
            vault.executeModule(keccak256("lending.morpho"), withdrawData);
            console.log("[OK] Withdrew wstETH from Morpho:", collateral);
        }

        // 3. TODO: Swap wstETH → USDC (via Odos) before withdrawing
        console.log("NOTE: Swap wstETH back to USDC before opening withdrawals");

        // 4. Open withdrawals + redeem
        vault.openWithdrawals();
        console.log("[OK] Withdrawals opened");

        uint256 shares = vault.balanceOf(deployer);
        if (shares > 0) {
            vault.redeem(shares, deployer, deployer);
            console.log("[OK] Redeemed shares:", shares);
        }

        // 5. Close cycle
        vault.closeCycle();
        console.log("[OK] Cycle closed");

        vm.stopBroadcast();

        uint256 finalUsdc = IERC20(USDC).balanceOf(deployer);
        console.log("=======================================");
        console.log("  PHASE 3 COMPLETE - Funds recovered");
        console.log("=======================================");
        console.log("Final USDC balance:", finalUsdc);
    }

    // ============ Helpers ============

    function _ethPerps() internal pure returns (string[] memory) {
        string[] memory perps = new string[](1);
        perps[0] = "ETH";
        return perps;
    }
}
