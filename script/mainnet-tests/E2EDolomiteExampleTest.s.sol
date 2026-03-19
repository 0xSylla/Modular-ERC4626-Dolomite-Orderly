// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DolomiteVault} from "../../example/DolomiteIBGTWETH.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDolomiteVault {
    // iBGT (isolation mode)
    function fundContractiBGT(uint256 amount) external;
    function supplyiBGT(uint256 amount) external;
    function borrowUSDCFromiBGT(uint256 borrowAmount) external;
    function repayiBGTDebtWithCollateral(
        uint256 minAmountOut,
        uint256 expectedAmountOut,
        bytes calldata pathDefinition
    ) external;
    function withdrawiBGT(uint256 amount) external;

    // WETH (non-isolation mode)
    function fundContractWETH(uint256 amount) external;
    function supplyWETH(uint256 amount) external;
    function borrowUSDCFromWETH(uint256 borrowAmount) external;
    function repayWETHDebtWithCollateral(
        uint256 minAmountOut,
        uint256 expectedAmountOut,
        bytes calldata pathDefinition
    ) external;
    function withdrawWETH(uint256 amount) external;

    // View
    function getiBGTPosition() external view returns (uint256, uint256, uint256, uint256);
    function getWETHPosition() external view returns (uint256, uint256, uint256, uint256);
    function totaliBGTDeposited() external view returns (uint256);
    function totalWETHDeposited() external view returns (uint256);
    function totalUSDCBorrowedFromiBGT() external view returns (uint256);
    function totalUSDCBorrowedFromWETH() external view returns (uint256);
    function owner() external view returns (address);

    // Fund/withdraw contract tokens
    function withdrawFromContractiBGT(uint256 amount) external;
    function withdrawFromContractWETH(uint256 amount) external;
    function withdrawFromContractUSDC(uint256 amount) external;
}

/// @title E2EDolomiteExampleTest
/// @notice Tests the DolomiteVault example contract (DolomiteIBGTWETH.sol)
///         with both iBGT (isolation mode) and WETH (non-isolation mode) using GenericTrader.
///
/// Prerequisites: Deploy DolomiteVault first, set DOLOMITE_VAULT_ADDR in .env
///   Or use phase1_deploy() to deploy it.
///
/// Run phases:
///   forge script script/mainnet-tests/E2EDolomiteExampleTest.s.sol:E2EDolomiteExampleTest \
///     --sig "phase1_deploy()" --rpc-url mainnet --broadcast --with-gas-price 10000000
///
///   forge script ... --sig "phase2_supplyAndBorrow()" --rpc-url mainnet --broadcast --with-gas-price 10000000
///
///   forge script ... --sig "phase3_repayWithCollateral()" --rpc-url mainnet --broadcast --ffi --with-gas-price 10000000
///
///   forge script ... --sig "checkBalances()" --rpc-url mainnet
contract E2EDolomiteExampleTest is Script {
    // ============ Berachain Mainnet Addresses ============
    address public constant USDC_ADDR = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT_ADDR = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    address public constant WETH_ADDR = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;

    address public constant OOGABOOGA_EXECUTOR = 0x27F66bA3fDa600239F48526Bb26A1F8D5700ccf7;
    address public constant DOLOMITE_OOGA_ADAPTER = 0x0CE205f7bCBa70E4c03f826918c8c21073386ED3;

    // ============================================================
    // PHASE 1: Deploy DolomiteVault
    // ============================================================
    function phase1_deploy() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== Phase 1: Deploy DolomiteVault ===");
        console.log("Deployer:", deployer);
        console.log("Deployer iBGT:", IERC20(IBGT_ADDR).balanceOf(deployer));
        console.log("Deployer WETH:", IERC20(WETH_ADDR).balanceOf(deployer));
        console.log("Deployer USDC:", IERC20(USDC_ADDR).balanceOf(deployer));

        vm.startBroadcast(pk);

        // Deploy using the compiled artifact from example/
        address vault = _deployVault();

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  PHASE 1 COMPLETE");
        console.log("=======================================");
        console.log("Set in .env:");
        console.log("  DOLOMITE_VAULT_ADDR=", vault);
        console.log("\nNext: phase2_supplyAndBorrow()");
    }

    function _deployVault() internal returns (address) {
        DolomiteVault vault = new DolomiteVault();
        console.log("DolomiteVault deployed:", address(vault));
        return address(vault);
    }

    // ============================================================
    // PHASE 2: Fund + Supply + Borrow (both iBGT and WETH)
    // ============================================================
    function phase2_supplyAndBorrow() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddr = vm.envAddress("DOLOMITE_VAULT_ADDR");
        IDolomiteVault vault = IDolomiteVault(vaultAddr);

        uint256 ibgtAmount = vm.envOr("IBGT_SUPPLY_AMOUNT", uint256(1e15)); // default 0.001 iBGT
        uint256 wethAmount = vm.envOr("WETH_SUPPLY_AMOUNT", uint256(1e14)); // default 0.0001 WETH
        uint256 ibgtBorrowUsdc = vm.envOr("IBGT_BORROW_USDC", uint256(100_000)); // 0.1 USDC
        uint256 wethBorrowUsdc = vm.envOr("WETH_BORROW_USDC", uint256(100_000)); // 0.1 USDC

        console.log("=== Phase 2: Supply + Borrow ===");
        console.log("Vault:", vaultAddr);
        console.log("iBGT supply:", ibgtAmount);
        console.log("WETH supply:", wethAmount);
        console.log("iBGT borrow USDC:", ibgtBorrowUsdc);
        console.log("WETH borrow USDC:", wethBorrowUsdc);

        vm.startBroadcast(pk);

        // --- iBGT path (isolation mode) ---
        IERC20(IBGT_ADDR).approve(vaultAddr, ibgtAmount);
        vault.fundContractiBGT(ibgtAmount);
        console.log("iBGT funded to contract.");

        vault.supplyiBGT(ibgtAmount);
        console.log("iBGT supplied to Dolomite.");

        vault.borrowUSDCFromiBGT(ibgtBorrowUsdc);
        console.log("USDC borrowed from iBGT position:", ibgtBorrowUsdc);

        // --- WETH path (non-isolation mode) ---
        IERC20(WETH_ADDR).approve(vaultAddr, wethAmount);
        vault.fundContractWETH(wethAmount);
        console.log("WETH funded to contract.");

        vault.supplyWETH(wethAmount);
        console.log("WETH supplied to Dolomite.");

        vault.borrowUSDCFromWETH(wethBorrowUsdc);
        console.log("USDC borrowed from WETH position:", wethBorrowUsdc);

        vm.stopBroadcast();

        _logPositions(vault);
        console.log("\nNext: phase3_repayWithCollateral() --ffi");
    }

    // ============================================================
    // PHASE 3: Repay both positions using GenericTrader
    // ============================================================
    function phase3_repayWithCollateral() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("DOLOMITE_VAULT_ADDR");
        IDolomiteVault vault = IDolomiteVault(vaultAddr);

        console.log("=== Phase 3: Repay With Collateral (GenericTrader) ===");
        _logPositions(vault);

        uint256 ibgtDeposited = vault.totaliBGTDeposited();
        uint256 wethDeposited = vault.totalWETHDeposited();

        // --- Fetch OogaBooga quotes via FFI ---
        console.log("\n--- Fetching iBGT -> USDC quote ---");
        (uint256 ibgtExpected, uint256 ibgtMin, bytes memory ibgtPath) =
            _fetchOogaBoogaQuote(IBGT_ADDR, USDC_ADDR, ibgtDeposited, vaultAddr);
        console.log("iBGT quote: expected=", ibgtExpected, "min=", ibgtMin);

        console.log("\n--- Fetching WETH -> USDC quote ---");
        (uint256 wethExpected, uint256 wethMin, bytes memory wethPath) =
            _fetchOogaBoogaQuote(WETH_ADDR, USDC_ADDR, wethDeposited, vaultAddr);
        console.log("WETH quote: expected=", wethExpected, "min=", wethMin);

        vm.startBroadcast(pk);

        // --- Repay iBGT position (isolation mode: 2-step GenericTrader) ---
        console.log("\n--- Repaying iBGT debt with collateral ---");
        vault.repayiBGTDebtWithCollateral(ibgtMin, ibgtExpected, ibgtPath);
        console.log("iBGT debt repaid with collateral!");

        // --- Repay WETH position (non-isolation: 1-step GenericTrader) ---
        console.log("\n--- Repaying WETH debt with collateral ---");
        vault.repayWETHDebtWithCollateral(wethMin, wethExpected, wethPath);
        console.log("WETH debt repaid with collateral!");

        vm.stopBroadcast();

        _logPositions(vault);
        console.log("\n=======================================");
        console.log("  PHASE 3 COMPLETE - All debt repaid!");
        console.log("=======================================");
    }

    // ============================================================
    // PHASE 3A: Repay iBGT only
    // ============================================================
    function phase3a_repayIBGT() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("DOLOMITE_VAULT_ADDR");
        IDolomiteVault vault = IDolomiteVault(vaultAddr);

        uint256 ibgtDeposited = vault.totaliBGTDeposited();
        require(ibgtDeposited > 0, "No iBGT position to repay");

        console.log("=== Phase 3A: Repay iBGT With Collateral ===");
        console.log("iBGT deposited:", ibgtDeposited);

        (uint256 expected, uint256 min, bytes memory path) =
            _fetchOogaBoogaQuote(IBGT_ADDR, USDC_ADDR, ibgtDeposited, vaultAddr);

        vm.startBroadcast(pk);
        vault.repayiBGTDebtWithCollateral(min, expected, path);
        vm.stopBroadcast();

        console.log("iBGT debt repaid! USDC balance:", IERC20(USDC_ADDR).balanceOf(vaultAddr));
    }

    // ============================================================
    // PHASE 3B: Repay WETH only
    // ============================================================
    function phase3b_repayWETH() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("DOLOMITE_VAULT_ADDR");
        IDolomiteVault vault = IDolomiteVault(vaultAddr);

        uint256 wethDeposited = vault.totalWETHDeposited();
        require(wethDeposited > 0, "No WETH position to repay");

        console.log("=== Phase 3B: Repay WETH With Collateral ===");
        console.log("WETH deposited:", wethDeposited);

        (uint256 expected, uint256 min, bytes memory path) =
            _fetchOogaBoogaQuote(WETH_ADDR, USDC_ADDR, wethDeposited, vaultAddr);

        vm.startBroadcast(pk);
        vault.repayWETHDebtWithCollateral(min, expected, path);
        vm.stopBroadcast();

        console.log("WETH debt repaid! USDC balance:", IERC20(USDC_ADDR).balanceOf(vaultAddr));
    }

    // ============================================================
    // HELPER: Check Balances
    // ============================================================
    function checkBalances() external view {
        address vaultAddr = vm.envAddress("DOLOMITE_VAULT_ADDR");
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        IDolomiteVault vault = IDolomiteVault(vaultAddr);

        console.log("=== Balance Check ===");
        console.log("Deployer:", deployer);
        console.log("Vault:", vaultAddr);
        console.log("");
        console.log("Deployer iBGT:", IERC20(IBGT_ADDR).balanceOf(deployer));
        console.log("Deployer WETH:", IERC20(WETH_ADDR).balanceOf(deployer));
        console.log("Deployer USDC:", IERC20(USDC_ADDR).balanceOf(deployer));
        console.log("");
        _logPositions(vault);
    }

    // ============================================================
    // HELPER: Withdraw all remaining tokens from vault contract
    // ============================================================
    function withdrawAll() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("DOLOMITE_VAULT_ADDR");
        IDolomiteVault vault = IDolomiteVault(vaultAddr);

        console.log("=== Withdraw All From Vault ===");

        vm.startBroadcast(pk);

        uint256 ibgt = IERC20(IBGT_ADDR).balanceOf(vaultAddr);
        uint256 weth = IERC20(WETH_ADDR).balanceOf(vaultAddr);
        uint256 usdc = IERC20(USDC_ADDR).balanceOf(vaultAddr);

        if (ibgt > 0) {
            vault.withdrawFromContractiBGT(ibgt);
            console.log("Withdrew iBGT:", ibgt);
        }
        if (weth > 0) {
            vault.withdrawFromContractWETH(weth);
            console.log("Withdrew WETH:", weth);
        }
        if (usdc > 0) {
            vault.withdrawFromContractUSDC(usdc);
            console.log("Withdrew USDC:", usdc);
        }

        vm.stopBroadcast();
        console.log("Done.");
    }

    // ============================================================
    // INTERNAL: Log positions
    // ============================================================
    function _logPositions(IDolomiteVault vault) internal view {
        (uint256 ibgtCol, uint256 ibgtDebt, uint256 contractIBGT, uint256 contractUSDC_ibgt) =
            vault.getiBGTPosition();
        (uint256 wethCol, uint256 wethDebt, uint256 contractWETH, uint256 contractUSDC_weth) =
            vault.getWETHPosition();

        console.log("--- iBGT Position ---");
        console.log("  Collateral:", ibgtCol);
        console.log("  USDC Debt:", ibgtDebt);
        console.log("  Contract iBGT:", contractIBGT);
        console.log("--- WETH Position ---");
        console.log("  Collateral:", wethCol);
        console.log("  USDC Debt:", wethDebt);
        console.log("  Contract WETH:", contractWETH);
        console.log("--- Contract USDC:", contractUSDC_ibgt);
    }

    // ============================================================
    // INTERNAL: Fetch OogaBooga quote via FFI (GET format)
    // ============================================================
    function _fetchOogaBoogaQuote(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        address /* to - unused, adapter is receiver */
    ) internal returns (uint256 expectedOut, uint256 minOut, bytes memory pathDefinition) {
        string memory apiKey = vm.envString("OOGABOOGA_API_KEY");

        string memory curlCmd = string.concat(
            "curl -s -H 'Authorization: Bearer ", apiKey, "' ",
            "'https://mainnet.api.oogabooga.io/v1/swap",
            "?tokenIn=", vm.toString(tokenIn),
            "&tokenOut=", vm.toString(tokenOut),
            "&amount=", vm.toString(amount),
            "&to=", vm.toString(DOLOMITE_OOGA_ADAPTER),
            "&slippage=0.10'"
        );

        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = curlCmd;

        console.log("Fetching OogaBooga quote...");
        bytes memory result = vm.ffi(cmd);
        string memory json = string(result);

        // Parse the response
        expectedOut = vm.parseJsonUint(json, ".assumedAmountOut");
        minOut = vm.parseJsonUint(json, ".routerParams.swapTokenInfo.outputMin");
        pathDefinition = vm.parseJsonBytes(json, ".routerParams.pathDefinition");

        console.log("  expectedOut:", expectedOut);
        console.log("  minOut:", minOut);
        console.log("  pathDefinition length:", pathDefinition.length);
    }
}
