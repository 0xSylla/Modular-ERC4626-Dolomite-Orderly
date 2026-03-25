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
import {IKXRouter} from "../../src/interfaces/IKXRouter.sol";

/// @title E2EBeraWBTCTest
/// @notice Berachain E2E: Deploy → Deposit $1 USDC → Swap to WBTC → Supply to Dolomite
///         (regular market, no isolation mode) → Borrow USDC back → Repay → Swap back → Withdraw
///
/// @dev Validates DolomiteBeraModule regular-market path (5-param borrow router).
///      WBTC is a regular (non-isolation-mode) market on Berachain Dolomite.
///
/// Run phases individually:
///   forge script script/mainnet-tests/E2EBeraWBTCTest.s.sol:E2EBeraWBTCTest \
///     --sig "phase1_deploy()" --rpc-url mainnet --broadcast --ffi
///
///   forge script ... --sig "phase2_deposit()" --rpc-url mainnet --broadcast
///
///   forge script ... --sig "phase3_swapSupplyBorrow()" --rpc-url mainnet --broadcast --ffi
///
///   forge script ... --sig "phase4_repayAndWithdraw()" --rpc-url mainnet --broadcast --ffi
///
/// Env vars:
///   PRIVATE_KEY
///   Phase 2+: FACTORY_ADDR, VAULT_ADDR
///   Phase 3:  BORROW_AMOUNT (optional, default 400_000 = 0.4 USDC)
///   Phase 4:  REPAY_AMOUNT  (optional, default = BORROW_AMOUNT, adjust if interest accrued)
///             WBTC_ESTIMATE (optional, WBTC wei in Dolomite — set if vault holds no WBTC)
contract E2EBeraWBTCTest is Script {
    // ============ Berachain Mainnet Addresses ============
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    // Dolomite market IDs on Berachain
    uint256 public constant WBTC_MARKET_ID = 4;
    uint256 public constant USDC_MARKET_ID = 2;

    uint256 public constant DEPOSIT_AMOUNT = 1_000_000; // 1 USDC (6 decimals)

    // ============================================================
    // PHASE 1: Deploy
    // ============================================================
    function phase1_deploy() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== Phase 1: Deploy Berachain WBTC Protocol ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        require(block.chainid == 80094, "Must run on Berachain (--rpc-url mainnet)");
        console.log("Deployer BERA:", deployer.balance);
        console.log("Deployer USDC:", IERC20(USDC).balanceOf(deployer));

        vm.startBroadcast(pk);

        Data.ProtocolFees memory fees = Data.ProtocolFees({
            protocolFeeBps: 1000,
            daoFeeBps: 300,
            protocolFeeRecipient: deployer,
            daoFeeRecipient: deployer
        });

        DiracVaultFactory factory = new DiracVaultFactory(deployer, deployer, fees);
        console.log("Factory:", address(factory));

        DolomiteBeraModule dolomiteModule = new DolomiteBeraModule();
        KodiakModule kodiakModule = new KodiakModule();
        OrderlyModule orderlyModule = new OrderlyModule();
        console.log("DolomiteBeraModule:", address(dolomiteModule));
        console.log("KodiakModule:  ", address(kodiakModule));

        factory.registerModule(keccak256("lending.dolomite"), address(dolomiteModule));
        factory.registerModule(keccak256("swap.kodiak"),      address(kodiakModule));
        factory.registerModule(keccak256("perps.orderly"),    address(orderlyModule));

        factory.registerTemplate(keccak256("delta-neutral-v1"));
        factory.whitelistDepositToken(USDC);

        // Whitelist WBTC as strategy asset
        string[] memory wbtcPerps = new string[](1);
        wbtcPerps[0] = "BTC";
        factory.whitelistStrategyAsset(Data.AssetInfo({ token: WBTC, allowedPerpsAssets: wbtcPerps }));
        factory.setModuleLendingConfig(keccak256("lending.dolomite"), WBTC, abi.encode(WBTC_MARKET_ID));
        console.log("WBTC whitelisted as strategy asset (Dolomite market ID: 4).");

        address vaultAddr = factory.createVault(
            "Dirac WBTC Delta-Neutral Berachain",
            "dWBTC-BERA",
            USDC,
            10_000_000_000e6,
            keccak256("delta-neutral-v1"),
            Data.CuratorFeeConfig({ curatorFeeBps: 200, curatorFeeRecipient: deployer })
        );
        DiracVault vault = DiracVault(payable(vaultAddr));
        console.log("Vault:", vaultAddr);

        // Bootstrap: open → 1 wei deposit → start trading → init Dolomite → whitelist WBTC → reset
        vault.openDeposits();
        IERC20(USDC).approve(vaultAddr, 1);
        vault.deposit(1, deployer);
        vault.startTrading();

        vault.executeModule(
            keccak256("lending.dolomite"),
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );
        console.log("Dolomite module initialized (routers authorized as operators).");

        vault.whitelistTargetAsset(WBTC);
        console.log("WBTC whitelisted as target asset on vault.");

        // Reset cycle
        vault.openWithdrawals();
        vault.closeCycle();

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  PHASE 1 COMPLETE");
        console.log("=======================================");
        console.log("Set in .env:");
        console.log("  FACTORY_ADDR=", address(factory));
        console.log("  VAULT_ADDR=", vaultAddr);
        console.log("\nNext: phase2_deposit()");
    }

    // ============================================================
    // PHASE 2: Deposit $1 USDC
    // ============================================================
    function phase2_deposit() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address depositor = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        DiracVault vault = DiracVault(payable(vaultAddr));

        console.log("=== Phase 2: Deposit $1 USDC ===");
        console.log("Depositor:", depositor);
        console.log("USDC balance:", IERC20(USDC).balanceOf(depositor));

        vm.startBroadcast(pk);

        vault.openDeposits();
        IERC20(USDC).approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, depositor);
        vault.startTrading();

        vm.stopBroadcast();

        console.log("Deposited:", DEPOSIT_AMOUNT, "(1 USDC)");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("User shares:", vault.balanceOf(depositor));
        console.log("\nNext: phase3_swapSupplyBorrow() --ffi");
    }

    // ============================================================
    // PHASE 3: Swap USDC → WBTC → Supply → Borrow
    // ============================================================
    function phase3_swapSupplyBorrow() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");

        uint256 swapAmount   = IERC20(USDC).balanceOf(vaultAddr);
        uint256 borrowAmount = vm.envOr("BORROW_AMOUNT", uint256(400_000));

        console.log("=== Phase 3: Swap USDC -> WBTC -> Supply -> Borrow ===");
        console.log("Vault USDC (swap in):", swapAmount);
        console.log("Borrow amount (USDC):", borrowAmount);

        (
            IKXRouter.SwapData memory swapData,
            IKXRouter.FeeData memory feeData,
            uint256 minWBTCOut
        ) = _fetchKodiakQuote(USDC, WBTC, swapAmount, vaultAddr);
        console.log("Kodiak minWBTCOut (8 decimals):", minWBTCOut);

        vm.startBroadcast(pk);

        // Step 1: Swap USDC → WBTC
        vault.executeModule(
            kodiakModule,
            abi.encodeCall(KodiakModule.swap, (USDC, false, swapAmount, WBTC, false, minWBTCOut, swapData, feeData))
        );
        uint256 wbtcBalance = IERC20(WBTC).balanceOf(vaultAddr);
        console.log("Vault WBTC after swap:", wbtcBalance);

        // Step 2: Supply all WBTC to Dolomite (regular market — no isolation mode)
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.supplyCollateral, (WBTC, type(uint256).max, WBTC_MARKET_ID))
        );
        console.log("WBTC supplied to Dolomite (market 4). Vault WBTC:", IERC20(WBTC).balanceOf(vaultAddr));

        // Step 3: Borrow USDC against WBTC collateral (uses 5-param openBorrowPosition)
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.borrow, (borrowAmount, WBTC_MARKET_ID, USDC_MARKET_ID))
        );

        vm.stopBroadcast();

        console.log("Borrowed:", borrowAmount, "USDC.");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault WBTC:", IERC20(WBTC).balanceOf(vaultAddr));
        console.log("\nNext: phase4_repayAndWithdraw() --ffi");
    }

    // ============================================================
    // PHASE 4: Repay → Swap WBTC back → Withdraw
    // ============================================================
    function phase4_repayAndWithdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");

        DiracVaultFactory factory = DiracVaultFactory(factoryAddr);
        DiracVault vault = DiracVault(payable(vaultAddr));
        bytes32 dolomiteModule = keccak256("lending.dolomite");
        bytes32 kodiakModule = keccak256("swap.kodiak");

        // repayAmount = 0 → auto-calculate (107% of debt). Requires vault to have enough USDC.
        // For a short test set REPAY_AMOUNT = BORROW_AMOUNT (no interest accrued in seconds).
        uint256 borrowAmount = vm.envOr("BORROW_AMOUNT", uint256(400_000));
        uint256 repayAmount  = vm.envOr("REPAY_AMOUNT",  borrowAmount);

        uint256 wbtcEstimate = vm.envOr("WBTC_ESTIMATE", IERC20(WBTC).balanceOf(vaultAddr));
        require(wbtcEstimate > 0, "Set WBTC_ESTIMATE env var (WBTC amount Dolomite will return)");

        console.log("=== Phase 4: Repay + Swap WBTC -> USDC + Withdraw ===");
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault WBTC:", IERC20(WBTC).balanceOf(vaultAddr));
        console.log("Repay amount:", repayAmount);
        console.log("WBTC estimate for swap quote:", wbtcEstimate);
        console.log("User shares:", vault.balanceOf(user));

        // Fetch Odos/Kodiak WBTC→USDC quote before broadcast (read-only)
        (
            IKXRouter.SwapData memory swapData,
            IKXRouter.FeeData memory feeData,
            uint256 minUSDCOut
        ) = _fetchKodiakQuote(WBTC, USDC, wbtcEstimate, vaultAddr);
        console.log("Kodiak WBTC->USDC minUSDCOut:", minUSDCOut);

        vm.startBroadcast(pk);

        // Step 1: Repay USDC debt → WBTC collateral returned to vault
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.repayDebt, (USDC, repayAmount, WBTC_MARKET_ID, USDC_MARKET_ID))
        );
        uint256 wbtcBack = IERC20(WBTC).balanceOf(vaultAddr);
        console.log("Debt repaid. Vault WBTC:", wbtcBack);
        console.log("           Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // Step 2: Swap all WBTC → USDC
        vault.executeModule(
            kodiakModule,
            abi.encodeCall(KodiakModule.swap, (WBTC, false, wbtcBack, USDC, false, minUSDCOut, swapData, feeData))
        );
        console.log("WBTC swapped to USDC. Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));

        // Step 3: Open withdrawals → user redeems → close cycle
        vault.openWithdrawals();
        uint256 shares = vault.balanceOf(user);
        uint256 usdcReceived = vault.redeem(shares, user, user);
        vault.closeCycle();

        vm.stopBroadcast();

        console.log("\n=======================================");
        console.log("  BERACHAIN WBTC TEST COMPLETE");
        console.log("=======================================");
        console.log("Shares redeemed:", shares);
        console.log("USDC returned to user:", usdcReceived);
        console.log("User USDC balance:", IERC20(USDC).balanceOf(user));
        console.log("(Net loss = Dolomite borrow interest + swap fees)");
    }

    // ============================================================
    // HELPER: Balance Check
    // ============================================================
    function checkBalances() external view {
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address user = vm.addr(vm.envUint("PRIVATE_KEY"));

        console.log("=== Balance Check ===");
        console.log("User  USDC:", IERC20(USDC).balanceOf(user));
        console.log("User  WBTC:", IERC20(WBTC).balanceOf(user));
        console.log("Vault USDC:", IERC20(USDC).balanceOf(vaultAddr));
        console.log("Vault WBTC:", IERC20(WBTC).balanceOf(vaultAddr));
        console.log("User shares:", DiracVault(payable(vaultAddr)).balanceOf(user));
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
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = curlCmd;

        console.log("Fetching Kodiak quote...");
        bytes memory result = vm.ffi(cmd);
        string memory json = string(result);

        bytes memory fullCalldata = vm.parseJsonBytes(json, ".methodParameters.calldata");
        console.log("Calldata length:", fullCalldata.length);

        bytes memory encoded = _stripSelector(fullCalldata);

        IKXRouter.InputAmount memory _input;
        IKXRouter.OutputAmount memory _output;

        (_input, _output, swapData, feeData) = abi.decode(
            encoded,
            (IKXRouter.InputAmount, IKXRouter.OutputAmount, IKXRouter.SwapData, IKXRouter.FeeData)
        );

        minAmountOut = _output.minAmountOut;
    }

    function _stripSelector(bytes memory data) internal pure returns (bytes memory) {
        require(data.length >= 4, "calldata too short");
        bytes memory result = new bytes(data.length - 4);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[i + 4];
        }
        return result;
    }
}
