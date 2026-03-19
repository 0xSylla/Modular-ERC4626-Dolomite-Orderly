// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Data} from "../src/libraries/Data.sol";
import {DiracVault} from "../src/vault/DiracVault.sol";
import {DiracVaultFactory} from "../src/factory/DiracVaultFactory.sol";
import {VaultCuratorRouter} from "../src/routers/VaultCuratorRouter.sol";
import {DolomiteBeraModule} from "../src/modules/lending/dolomite/DolomiteBeraModule.sol";
import {DolomiteLendingBase} from "../src/modules/lending/dolomite/DolomiteLendingBase.sol";
import {KodiakModule} from "../src/modules/swap/KodiakModule.sol";
import {OrderlyModule} from "../src/modules/perps/OrderlyModule.sol";
import {IKXRouter} from "../src/interfaces/IKXRouter.sol";
import {IVault, VaultTypes} from "../src/interfaces/IOrderly.sol";

/// @title OperateVault
/// @notice Curator Phase 3 / Operator: Launch, rebalance, and close strategies via module execution
/// @dev Run individual functions via --sig:
///      forge script script/OperateVault.s.sol:OperateVault --sig "launchStrategy()" --rpc-url mainnet --broadcast
///      Env: VAULT_ADDR, FACTORY_ADDR, PRIVATE_KEY
contract OperateVault is Script {
    // ============ Berachain Addresses ============
    address public constant USDC = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address public constant IBGT = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;

    // Dolomite market IDs
    uint256 public constant DIBGT_MARKET_ID = 38;
    uint256 public constant USDC_MARKET_ID = 2;

    /// @notice Initialize Dolomite module (one-time setup after vault creation)
    function initializeDolomite() external {
        (DiracVault vault, DiracVaultFactory factory) = _loadVault();

        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));

        _startBroadcast();
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteLendingBase.initializeModule, ())
        );
        vm.stopBroadcast();
        console.log("Dolomite module initialized (operators set).");
    }

    /// @notice Set Dolomite isolation proxy address
    function setIsolationProxy() external {
        (DiracVault vault, DiracVaultFactory factory) = _loadVault();

        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));
        address proxy = vm.envAddress("ISOLATION_PROXY");
        uint256 marketId = vm.envUint("COLLATERAL_MARKET_ID");

        _startBroadcast();
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteBeraModule.setIsolationProxy, (marketId, proxy))
        );
        vm.stopBroadcast();
        console.log("Isolation proxy set to:", proxy);
    }

    /// @notice Initialize Orderly module (one-time setup)
    function initializeOrderly() external {
        (DiracVault vault, DiracVaultFactory factory) = _loadVault();

        address orderlyModule = factory.getModule(keccak256("perps.orderly"));
        address orderlyVault = vm.envAddress("ORDERLY_VAULT");

        _startBroadcast();
        vault.executeModule(
            orderlyModule,
            abi.encodeCall(OrderlyModule.initializeModule, (orderlyVault))
        );
        vm.stopBroadcast();
        console.log("Orderly module initialized with vault:", orderlyVault);
    }

    /// @notice Delegate signer on Orderly
    function delegateSigner() external {
        (DiracVault vault, DiracVaultFactory factory) = _loadVault();

        address orderlyModule = factory.getModule(keccak256("perps.orderly"));
        bytes32 brokerHash = vm.envBytes32("BROKER_HASH");
        address delegateSigner_ = vm.envAddress("DELEGATE_SIGNER");

        VaultTypes.VaultDelegate memory data = VaultTypes.VaultDelegate({
            brokerHash: brokerHash,
            delegateSigner: delegateSigner_
        });

        _startBroadcast();
        vault.executeModule(
            orderlyModule,
            abi.encodeCall(OrderlyModule.delegateSigner, (data))
        );
        vm.stopBroadcast();
        console.log("Delegate signer set.");
    }

    /// @notice Full strategy launch: Swap USDC → iBGT → Supply → Borrow → Deposit to Orderly
    /// @dev This demonstrates a full batch execution of all 3 legs
    function launchStrategy() external {
        (DiracVault vault, DiracVaultFactory factory) = _loadVault();

        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));
        address kodiakModule = factory.getModule(keccak256("swap.kodiak"));

        // Read strategy 0 allocation from router
        address routerAddr = vm.envAddress("ROUTER_ADDR");
        VaultCuratorRouter router = VaultCuratorRouter(routerAddr);
        VaultCuratorRouter.PositionRecord memory pos = router.getPosition(address(vault), 0);
        uint256 swapAmount = pos.allocation;

        console.log("--- Launching Strategy ---");
        console.log("Allocation:", swapAmount);

        // Build batch: Swap → Supply → Borrow
        // Note: In production, swap data would come from the Kodiak API quote
        //       and borrow amount would be calculated from the collateral received

        uint256 collateralAmount = vm.envOr("COLLATERAL_AMOUNT", uint256(0));
        uint256 borrowAmount = vm.envOr("BORROW_AMOUNT", uint256(0));
        require(collateralAmount > 0 && borrowAmount > 0, "Set COLLATERAL_AMOUNT and BORROW_AMOUNT");

        address[] memory modules = new address[](2);
        bytes[] memory datas = new bytes[](2);

        // Step 1: Supply collateral
        modules[0] = dolomiteModule;
        datas[0] = abi.encodeCall(
            DolomiteLendingBase.supplyCollateral,
            (IBGT, collateralAmount, DIBGT_MARKET_ID)
        );

        // Step 2: Borrow USDC
        modules[1] = dolomiteModule;
        datas[1] = abi.encodeCall(
            DolomiteLendingBase.borrow,
            (borrowAmount, DIBGT_MARKET_ID, USDC_MARKET_ID)
        );

        _startBroadcast();
        vault.executeBatch(modules, datas);
        vm.stopBroadcast();

        console.log("Strategy launched: Supply + Borrow executed.");
        console.log("Next: Deposit borrowed USDC to Orderly for shorting.");
    }

    /// @notice Close strategy: Repay debt → Withdraw collateral → Swap back
    function closeStrategy() external {
        (DiracVault vault, DiracVaultFactory factory) = _loadVault();

        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));

        uint256 repayAmount = vm.envOr("REPAY_AMOUNT", uint256(0));

        address[] memory modules = new address[](1);
        bytes[] memory datas = new bytes[](1);

        // Repay and close (automatically withdraws collateral)
        modules[0] = dolomiteModule;
        datas[0] = abi.encodeCall(
            DolomiteLendingBase.repayDebt,
            (USDC, repayAmount, DIBGT_MARKET_ID, USDC_MARKET_ID)
        );

        _startBroadcast();
        vault.executeBatch(modules, datas);
        vm.stopBroadcast();

        console.log("Strategy closed: Debt repaid, collateral withdrawn.");
    }

    /// @notice Repay debt with collateral (zap)
    function repayWithCollateral() external {
        (DiracVault vault, DiracVaultFactory factory) = _loadVault();

        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));
        uint256 minUSDCOut = vm.envUint("MIN_USDC_OUT");
        uint256 expectedUSDCOut = vm.envUint("EXPECTED_USDC_OUT");
        bytes memory pathDefinition = vm.envBytes("PATH_DEFINITION");

        _startBroadcast();
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(
                DolomiteBeraModule.repayDebtWithCollateral,
                (IBGT, USDC, minUSDCOut, expectedUSDCOut, pathDefinition, DIBGT_MARKET_ID, USDC_MARKET_ID)
            )
        );
        vm.stopBroadcast();

        console.log("Debt repaid with collateral zap.");
    }

    /// @notice Execute a single Kodiak swap
    function swapKodiak() external {
        (DiracVault vault, DiracVaultFactory factory) = _loadVault();

        address kodiakModule = factory.getModule(keccak256("swap.kodiak"));

        address tokenIn = vm.envOr("TOKEN_IN", USDC);
        address tokenOut = vm.envOr("TOKEN_OUT", IBGT);
        uint256 amountIn = vm.envUint("SWAP_AMOUNT");
        uint256 minAmountOut = vm.envUint("MIN_AMOUNT_OUT");

        // Swap data must be provided as env vars (from Kodiak API)
        address swapRouter = vm.envAddress("SWAP_ROUTER");
        bytes memory swapBytes = vm.envBytes("SWAP_DATA");
        uint256 feeQuote = vm.envOr("FEE_QUOTE", uint256(0));

        IKXRouter.SwapData memory swapData = IKXRouter.SwapData({
            router: swapRouter,
            data: swapBytes
        });

        IKXRouter.FeeData memory feeData = IKXRouter.FeeData({
            feeQuote: feeQuote,
            surplusFeeBps: 0,
            refCode: 0,
            referrerFeeBps: 0
        });

        _startBroadcast();
        vault.executeModule(
            kodiakModule,
            abi.encodeCall(
                KodiakModule.swap,
                (tokenIn, false, amountIn, tokenOut, false, minAmountOut, swapData, feeData)
            )
        );
        vm.stopBroadcast();

        console.log("Kodiak swap executed.");
    }

    /// @notice Supply collateral to Dolomite (single step)
    function supplyCollateral() external {
        (DiracVault vault, DiracVaultFactory factory) = _loadVault();

        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));
        uint256 amount = vm.envUint("SUPPLY_AMOUNT");

        _startBroadcast();
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(
                DolomiteLendingBase.supplyCollateral,
                (IBGT, amount, DIBGT_MARKET_ID)
            )
        );
        vm.stopBroadcast();

        console.log("Collateral supplied:", amount);
    }

    /// @notice Borrow asset from Dolomite (single step)
    function borrowAsset() external {
        (DiracVault vault, DiracVaultFactory factory) = _loadVault();

        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));
        uint256 amount = vm.envUint("BORROW_AMOUNT");

        _startBroadcast();
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(
                DolomiteLendingBase.borrow,
                (amount, DIBGT_MARKET_ID, USDC_MARKET_ID)
            )
        );
        vm.stopBroadcast();

        console.log("Borrowed:", amount);
    }

    /// @notice Withdraw collateral from Dolomite
    function withdrawCollateral() external {
        (DiracVault vault, DiracVaultFactory factory) = _loadVault();

        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));
        uint256 amount = vm.envOr("WITHDRAW_AMOUNT", uint256(0)); // 0 = withdraw all

        _startBroadcast();
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(
                DolomiteLendingBase.withdrawCollateral,
                (amount, DIBGT_MARKET_ID)
            )
        );
        vm.stopBroadcast();

        console.log("Collateral withdrawn.");
    }

    /// @notice Claim staking rewards from Dolomite
    function claimRewards() external {
        (DiracVault vault, DiracVaultFactory factory) = _loadVault();

        address dolomiteModule = factory.getModule(keccak256("lending.dolomite"));
        uint256 marketId = vm.envUint("COLLATERAL_MARKET_ID");

        _startBroadcast();
        vault.executeModule(
            dolomiteModule,
            abi.encodeCall(DolomiteBeraModule.claimRewards, (marketId))
        );
        vm.stopBroadcast();

        console.log("Rewards claimed.");
    }

    /// @notice Deposit to Orderly for perpetuals
    function depositToOrderly() external {
        (DiracVault vault, DiracVaultFactory factory) = _loadVault();

        address orderlyModule = factory.getModule(keccak256("perps.orderly"));
        uint256 amount = vm.envUint("ORDERLY_DEPOSIT_AMOUNT");
        bytes32 accountId = vm.envBytes32("ORDERLY_ACCOUNT_ID");
        bytes32 brokerHash = vm.envBytes32("BROKER_HASH");
        bytes32 tokenHash = vm.envBytes32("TOKEN_HASH");

        VaultTypes.VaultDepositFE memory depositData = VaultTypes.VaultDepositFE({
            accountId: accountId,
            brokerHash: brokerHash,
            tokenHash: tokenHash,
            tokenAmount: uint128(amount)
        });

        _startBroadcast();
        vault.executeModule(
            orderlyModule,
            abi.encodeCall(
                OrderlyModule.deposit,
                (USDC, depositData, 0)
            )
        );
        vm.stopBroadcast();

        console.log("Deposited to Orderly:", amount);
    }

    // ============ Emergency ============

    function emergencyPause() external {
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        _startBroadcast();
        DiracVault(payable(vaultAddr)).pause();
        vm.stopBroadcast();
        console.log("Vault paused.");
    }

    function emergencyUnpause() external {
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        _startBroadcast();
        DiracVault(payable(vaultAddr)).unpause();
        vm.stopBroadcast();
        console.log("Vault unpaused.");
    }

    // ============ Internal ============

    function _loadVault()
        internal
        view
        returns (DiracVault vault, DiracVaultFactory factory)
    {
        address vaultAddr = vm.envAddress("VAULT_ADDR");
        address factoryAddr = vm.envAddress("FACTORY_ADDR");
        vault = DiracVault(payable(vaultAddr));
        factory = DiracVaultFactory(factoryAddr);
    }

    function _startBroadcast() internal {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        require(pk != 0, "PRIVATE_KEY not set");
        vm.startBroadcast(pk);
    }
}
