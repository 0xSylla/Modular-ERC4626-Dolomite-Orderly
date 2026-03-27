// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Data} from "../../src/libraries/Data.sol";
import {DiracVaultFactory} from "../../src/factory/DiracVaultFactory.sol";
import {DiracVault} from "../../src/vault/DiracVault.sol";
import {DolomiteLendingBase} from "../../src/modules/lending/dolomite/DolomiteLendingBase.sol";
import {KodiakModule} from "../../src/modules/swap/KodiakModule.sol";
import {IKXRouter} from "../../src/interfaces/IKXRouter.sol";

/// @title E2EDualVaultTest
/// @notice Creates 2 vaults on Berachain using the same factory:
///         Vault A: iBGT collateral (isolation mode, diBGT market 38)
///         Vault B: WETH collateral (regular mode, market 0)
///
///         Both go through: Deposit USDC -> Swap -> Supply -> Borrow -> Repay -> Withdraw
///
/// Factory: 0xa056E2DECBb3aCA01ef4C0cC5b3fC2b7126D086d
///
/// Run phases individually:
///   forge script script/mainnet-tests/E2EDualVaultTest.s.sol:E2EDualVaultTest \
///     --sig "phase1_createVaults()" --rpc-url mainnet --broadcast --with-gas-price 10000000
contract E2EDualVaultTest is Script {
    // ============ Berachain Addresses ============
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
    address public constant WETH = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;

    // Dolomite market IDs
    uint256 public constant DIBGT_MARKET_ID = 38;
    uint256 public constant WETH_MARKET_ID  = 0;
    uint256 public constant USDC_MARKET_ID  = 2;

    uint256 public constant DEPOSIT_AMOUNT = 1_000_000; // 1 USDC

    // ============================================================
    // PHASE 1: Create both vaults
    // ============================================================
    function phase1_createVaults() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        bytes32 dolomiteModule = keccak256("lending.dolomite");

        console.log("=== Phase 1: Create 2 Vaults ===");
        console.log("Deployer:", deployer);
        console.log("USDC balance:", IERC20(USDC).balanceOf(deployer));

        vm.startBroadcast(pk);

        // --- Vault A: iBGT (isolation mode) ---
        address vaultA = factory.createVault(
            "Dirac iBGT Dual Test",
            "diBGT-DUAL",
            USDC,
            10_000_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.VaultFees({ performanceFeeBps: 1000, managementFeeBps: 50, feeRecipient: deployer }),
            0, // rebalanceThresholdBps
            0  // fundingRateThresholdBps
        );
        DiracVault vA = DiracVault(payable(vaultA));
        vA.openDeposits();
        IERC20(USDC).approve(vaultA, 1);
        vA.deposit(1, deployer);
        vA.startTrading();
        vA.executeModule(keccak256("lending.dolomite"), abi.encodeCall(DolomiteLendingBase.initializeModule, ()));
        vA.whitelistTargetAsset(IBGT);
        vA.openWithdrawals();
        vA.closeCycle();
        console.log("Vault A (iBGT):", vaultA);

        // --- Vault B: WETH (regular mode) ---
        address vaultB = factory.createVault(
            "Dirac WETH Dual Test",
            "dWETH-DUAL",
            USDC,
            10_000_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.VaultFees({ performanceFeeBps: 1000, managementFeeBps: 50, feeRecipient: deployer }),
            0, // rebalanceThresholdBps
            0  // fundingRateThresholdBps
        );
        DiracVault vB = DiracVault(payable(vaultB));
        vB.openDeposits();
        IERC20(USDC).approve(vaultB, 1);
        vB.deposit(1, deployer);
        vB.startTrading();
        vB.executeModule(keccak256("lending.dolomite"), abi.encodeCall(DolomiteLendingBase.initializeModule, ()));
        vB.whitelistTargetAsset(WETH);
        vB.openWithdrawals();
        vB.closeCycle();
        console.log("Vault B (WETH):", vaultB);

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  PHASE 1 COMPLETE - 2 vaults created");
        console.log("=======================================");
        console.log("Set in .env:");
        console.log("  VAULT_A=", vaultA);
        console.log("  VAULT_B=", vaultB);
    }

    // ============================================================
    // PHASE 2A: Deposit to Vault A (iBGT)
    // ============================================================
    function phase2a_deposit() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address depositor = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_A");
        DiracVault vault = DiracVault(payable(vaultAddr));

        console.log("=== Phase 2A: Deposit to iBGT Vault ===");
        vm.startBroadcast(pk);
        vault.openDeposits();
        IERC20(USDC).approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, depositor);
        vault.startTrading();
        vm.stopBroadcast();

        console.log("Deposited:", DEPOSIT_AMOUNT);
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Shares:", vault.balanceOf(depositor));
    }

    // ============================================================
    // PHASE 2B: Deposit to Vault B (WETH)
    // ============================================================
    function phase2b_deposit() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address depositor = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_B");
        DiracVault vault = DiracVault(payable(vaultAddr));

        console.log("=== Phase 2B: Deposit to WETH Vault ===");
        vm.startBroadcast(pk);
        vault.openDeposits();
        IERC20(USDC).approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, depositor);
        vault.startTrading();
        vm.stopBroadcast();

        console.log("Deposited:", DEPOSIT_AMOUNT);
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Shares:", vault.balanceOf(depositor));
    }

    // ============================================================
    // PHASE 3A: Swap + Supply + Borrow on Vault A (iBGT - isolation mode)
    // ============================================================
    function phase3a_swapSupplyBorrow() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_A");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");

        uint256 swapAmount   = IERC20(USDC).balanceOf(vaultAddr);
        uint256 borrowAmount = vm.envOr("BORROW_A", uint256(400_000));

        console.log("=== Phase 3A: iBGT Vault - Swap + Supply + Borrow ===");
        console.log("Vault USDC:", swapAmount);
        console.log("Borrow:", borrowAmount);

        (IKXRouter.SwapData memory sd, IKXRouter.FeeData memory fd, uint256 minOut) =
            _fetchKodiakQuote(USDC, IBGT, swapAmount, vaultAddr);
        console.log("minIBGTOut:", minOut);

        vm.startBroadcast(pk);

        vault.executeModule(kodiakModule,
            abi.encodeCall(KodiakModule.swap, (USDC, false, swapAmount, IBGT, false, minOut, sd, fd)));
        console.log("Vault iBGT:", IERC20(IBGT).balanceOf(vaultAddr));

        vault.executeModule(dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.supplyCollateral, (IBGT, type(uint256).max, DIBGT_MARKET_ID)));
        console.log("iBGT supplied (isolation mode diBGT market 38)");

        vault.executeModule(dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.borrow, (borrowAmount, DIBGT_MARKET_ID, USDC_MARKET_ID)));

        vm.stopBroadcast();

        console.log("Borrowed:", borrowAmount);
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
    }

    // ============================================================
    // PHASE 3B: Swap + Supply + Borrow on Vault B (WETH - regular mode)
    // ============================================================
    function phase3b_swapSupplyBorrow() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_B");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");

        uint256 swapAmount   = IERC20(USDC).balanceOf(vaultAddr);
        uint256 borrowAmount = vm.envOr("BORROW_B", uint256(350_000));

        console.log("=== Phase 3B: WETH Vault - Swap + Supply + Borrow ===");
        console.log("Vault USDC:", swapAmount);
        console.log("Borrow:", borrowAmount);

        (IKXRouter.SwapData memory sd, IKXRouter.FeeData memory fd, uint256 minOut) =
            _fetchKodiakQuote(USDC, WETH, swapAmount, vaultAddr);
        console.log("minWETHOut:", minOut);

        vm.startBroadcast(pk);

        vault.executeModule(kodiakModule,
            abi.encodeCall(KodiakModule.swap, (USDC, false, swapAmount, WETH, false, minOut, sd, fd)));
        console.log("Vault WETH:", IERC20(WETH).balanceOf(vaultAddr));

        // Supply WETH - regular mode (isolationModeMarketId=0 internally)
        vault.executeModule(dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.supplyCollateral, (WETH, type(uint256).max, WETH_MARKET_ID)));
        console.log("WETH supplied (regular mode, market 0)");

        // Borrow - uses operate() internally (regular mode detected)
        vault.executeModule(dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.borrow, (borrowAmount, WETH_MARKET_ID, USDC_MARKET_ID)));

        vm.stopBroadcast();

        console.log("Borrowed:", borrowAmount);
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
    }

    // ============================================================
    // PHASE 4A: Repay + Withdraw on Vault A (iBGT - isolation mode)
    // ============================================================
    function phase4a_repayAndWithdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_A");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");

        uint256 repayAmount = IERC20(USDC).balanceOf(vaultAddr);
        uint256 ibgtEstimate = vm.envUint("COLLATERAL_A");

        console.log("=== Phase 4A: iBGT Vault - Repay + Withdraw ===");
        console.log("Vault USDC:", repayAmount);
        console.log("iBGT estimate:", ibgtEstimate);

        (IKXRouter.SwapData memory sd, IKXRouter.FeeData memory fd, uint256 minUSDC) =
            _fetchKodiakQuote(IBGT, USDC, ibgtEstimate, vaultAddr);

        vm.startBroadcast(pk);

        vault.executeModule(dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.repayDebt, (USDC, repayAmount, DIBGT_MARKET_ID, USDC_MARKET_ID)));
        uint256 ibgtBack = IERC20(IBGT).balanceOf(vaultAddr);
        console.log("Debt repaid. iBGT back:", ibgtBack);

        vault.executeModule(kodiakModule,
            abi.encodeCall(KodiakModule.swap, (IBGT, false, ibgtBack, USDC, false, minUSDC * 95 / 100, sd, fd)));
        console.log("Vault USDC after swap:", IERC20(USDC).balanceOf(vaultAddr));

        vault.openWithdrawals();
        uint256 shares = vault.balanceOf(user);
        uint256 received = vault.redeem(shares, user, user);
        vault.closeCycle();

        vm.stopBroadcast();

        console.log("iBGT Vault: shares redeemed:", shares);
        console.log("iBGT Vault: USDC received:", received);
    }

    // ============================================================
    // PHASE 4B: Repay + Withdraw on Vault B (WETH - regular mode)
    // ============================================================
    function phase4b_repayAndWithdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_B");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");

        uint256 repayAmount = IERC20(USDC).balanceOf(vaultAddr);
        uint256 wethEstimate = vm.envUint("COLLATERAL_B");

        console.log("=== Phase 4B: WETH Vault - Repay + Withdraw ===");
        console.log("Vault USDC:", repayAmount);
        console.log("WETH estimate:", wethEstimate);

        (IKXRouter.SwapData memory sd, IKXRouter.FeeData memory fd, uint256 minUSDC) =
            _fetchKodiakQuote(WETH, USDC, wethEstimate, vaultAddr);

        vm.startBroadcast(pk);

        vault.executeModule(dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.repayDebt, (USDC, repayAmount, WETH_MARKET_ID, USDC_MARKET_ID)));
        uint256 wethBack = IERC20(WETH).balanceOf(vaultAddr);
        console.log("Debt repaid. WETH back:", wethBack);

        vault.executeModule(kodiakModule,
            abi.encodeCall(KodiakModule.swap, (WETH, false, wethBack, USDC, false, minUSDC * 95 / 100, sd, fd)));
        console.log("Vault USDC after swap:", IERC20(USDC).balanceOf(vaultAddr));

        vault.openWithdrawals();
        uint256 shares = vault.balanceOf(user);
        uint256 received = vault.redeem(shares, user, user);
        vault.closeCycle();

        vm.stopBroadcast();

        console.log("WETH Vault: shares redeemed:", shares);
        console.log("WETH Vault: USDC received:", received);
    }

    // ============================================================
    // HELPER: Balance Check
    // ============================================================
    function checkBalances() external view {
        address user = vm.addr(vm.envUint("PRIVATE_KEY"));
        address vA = vm.envAddress("VAULT_A");
        address vB = vm.envAddress("VAULT_B");

        console.log("=== Balance Check ===");
        console.log("User USDC:", IERC20(USDC).balanceOf(user));
        console.log("--- Vault A (iBGT) ---");
        console.log("  USDC:", IERC20(USDC).balanceOf(vA));
        console.log("  iBGT:", IERC20(IBGT).balanceOf(vA));
        console.log("  Shares:", DiracVault(payable(vA)).balanceOf(user));
        console.log("--- Vault B (WETH) ---");
        console.log("  USDC:", IERC20(USDC).balanceOf(vB));
        console.log("  WETH:", IERC20(WETH).balanceOf(vB));
        console.log("  Shares:", DiracVault(payable(vB)).balanceOf(user));
    }

    // ============================================================
    // HELPER: Kodiak Quote (FFI)
    // ============================================================
    function _fetchKodiakQuote(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        address recipient
    ) internal returns (
        IKXRouter.SwapData memory swapData,
        IKXRouter.FeeData memory feeData,
        uint256 minAmountOut
    ) {
        string memory curlCmd = string.concat(
            "curl -s 'https://backend.kodiak.finance/quote"
            "?tokenInAddress=", vm.toString(tokenIn),
            "&tokenInChainId=80094"
            "&tokenOutAddress=", vm.toString(tokenOut),
            "&tokenOutChainId=80094"
            "&amount=", vm.toString(amount),
            "&type=exactIn"
            "&recipient=", vm.toString(recipient),
            "&slippageTolerance=5'"
        );

        string[] memory cmd = new string[](3);
        cmd[0] = "bash"; cmd[1] = "-c"; cmd[2] = curlCmd;

        console.log("Fetching Kodiak quote...");
        bytes memory result = vm.ffi(cmd);
        string memory json = string(result);

        bytes memory fullCalldata = vm.parseJsonBytes(json, ".methodParameters.calldata");
        bytes memory encoded = _stripSelector(fullCalldata);

        IKXRouter.InputAmount memory _input;
        IKXRouter.OutputAmount memory _output;

        (_input, _output, swapData, feeData) = abi.decode(
            encoded,
            (IKXRouter.InputAmount, IKXRouter.OutputAmount, IKXRouter.SwapData, IKXRouter.FeeData)
        );

        minAmountOut = _output.minAmountOut;
        console.log("Quote minAmountOut:", minAmountOut);
    }

    function _stripSelector(bytes memory data) internal pure returns (bytes memory) {
        require(data.length >= 4, "calldata too short");
        bytes memory r = new bytes(data.length - 4);
        for (uint256 i = 0; i < r.length; i++) {
            r[i] = data[i + 4];
        }
        return r;
    }
}
