// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVault, VaultTypes} from "./IOrderly.sol";
import {IKXRouter} from "./IKXRouter.sol";
import {Data} from "../data/Data.sol";

/**
 * @title IDiracHoneyPotV1
 * @notice Interface for the Dirac Honeypot Perpetual Vault
 * @dev Combines ERC4626 vault with leveraged trading on Dolomite and Orderly
 */
interface IDiracHoneyPotV1 is IERC4626 {
    // ============================================
    // Events
    // ============================================

    event DelegateSignerSet(
        bytes32 indexed brokerHash,
        address indexed delegateSigner
    );
    event TradeCycleStarted(
        uint256 indexed tradeCycleId,
        uint256 honeyDeposit,
        uint256 startedAt,
        uint256 expiresAt
    );
    event TradeCyclePendingEnd(uint256 indexed tradeCycleId);
    event TradeCycleInit(uint256 indexed tradeCycleId);
    event TradeCycleEnded(uint256 indexed tradeCycleId, uint256 endedAt);
    event Deposit(uint256 indexed tradeCycleId, uint256 amount);
    event CollateralSupplied(uint256 amount);
    event AssetBorrowed(uint256 amount);
    event DebtRepaid(uint256 amount);
    event CollateralWithdrawn(uint256 amount);
    event ContractFunded(uint256 amount);
    event ContractWithdrawn(uint256 amount);
    event ClaimedRewards();
    event OperatorsSet(address[] operators, bool[] trusted);
    event BorrowPositionOpened(uint256 collateralAmount, uint256 borrowAmount);

    // ============================================
    // Errors
    // ============================================

    error InsufficientFunds();
    error OperationFailed();
    error TradeNotMatured();
    error UserExceedMaxDepositAmount();
    error UserNotWhitelisted();
    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error InsufficientBalance();
    error TransferFailed();
    error DebtExists();

    // ============================================
    // Initialization
    // ============================================

    /**
     * @notice Initializes the vault with the specified parameters
     * @param _ivault The address of the Orderly vault contract
     * @param _collateralAsset The collateral token address (iBGT)
     * @param _borrowAsset The borrow token address (USDC)
     * @param _assetDeposit The ERC20 token used for deposits (USDC)
     */
    function initialize(
        address _ivault,
        address _collateralAsset,
        address _borrowAsset,
        IERC20 _assetDeposit
    ) external;

    // ============================================
    // ERC4626 Vault Functions (Overridden)
    // ============================================

    /**
     * @notice Deposits assets and mints corresponding shares
     * @dev Only allowed when trade cycle is CLOSED/INIT
     * @param _assets The amount of assets to deposit
     * @param _receiver The address receiving the minted shares
     * @return shares The number of shares minted
     */
    function deposit(
        uint256 _assets,
        address _receiver
    ) external returns (uint256 shares);

    /**
     * @notice Mints shares corresponding to the specified amount of assets
     * @dev Only allowed when trade cycle is CLOSED/INIT
     * @param _shares The number of shares to mint
     * @param _receiver The address receiving the minted shares
     * @return assets The amount of assets corresponding to the minted shares
     */
    function mint(
        uint256 _shares,
        address _receiver
    ) external returns (uint256 assets);

    /**
     * @notice Withdraws assets by burning shares
     * @dev Only allowed when trade cycle is CLOSED/INIT
     * @param _assets The amount of assets to withdraw
     * @param _receiver The address receiving the withdrawn assets
     * @param _owner The owner of the shares being burned
     * @return shares The number of shares burned
     */
    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner
    ) external returns (uint256 shares);

    /**
     * @notice Redeems shares for assets
     * @dev Only allowed when trade cycle is CLOSED/INIT
     * @param _shares The number of shares to redeem
     * @param _receiver The address receiving the redeemed assets
     * @param _owner The owner of the shares being redeemed
     * @return assets The amount of assets received
     */
    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    ) external returns (uint256 assets);

    // ============================================
    // Swap Functions (Kodiak DEX)
    // ============================================

    /**
     * @notice Executes a token swap using the Kodiak Router
     * @dev Only callable by OPERATOR_ROLE
     * @param tokenIn The address of the input token
     * @param wrapIn Whether to wrap the input token
     * @param amountIn The amount of the input token to swap
     * @param tokenOut The address of the output token
     * @param unwrapOut Whether to unwrap the output token
     * @param minAmountOut The minimum acceptable amount of output token
     * @param swapDatas The swap data containing router and encoded instructions
     * @param feeDatas The fee data including fee quote and referral info
     * @param _spender The address to approve the input token for
     */
    function swapKodiak(
        address tokenIn,
        bool wrapIn,
        uint256 amountIn,
        address tokenOut,
        bool unwrapOut,
        uint256 minAmountOut,
        IKXRouter.SwapData calldata swapDatas,
        IKXRouter.FeeData calldata feeDatas,
        address _spender
    ) external;

    // ============================================
    // Orderly Functions
    // ============================================

    /**
     * @notice Delegates signer for Orderly
     * @dev Only callable by OPERATOR_ROLE
     * @param data The data for the delegate signer
     */
    function delegateSigner(VaultTypes.VaultDelegate calldata data) external;

    /**
     * @notice Deposits to Orderly for perpetuals trading
     * @dev Only callable by OPERATOR_ROLE
     * @param data The data for the deposit
     * @param fee The fee for the deposit
     */
    function depositToOrderly(
        VaultTypes.VaultDepositFE calldata data,
        uint256 fee
    ) external;

    // ============================================
    // Dolomite Functions
    // ============================================

    /**
     * @notice Sets operators for Dolomite
     * @dev Only callable by OPERATOR_ROLE
     */
    function setOperators() external;

    /**
     * @notice Supply iBGT to Dolomite as collateral
     * @dev Only callable by OPERATOR_ROLE during OPEN trade cycle
     * @param _amount Amount of iBGT to supply
     */
    function supplyCollateralToDolomite(uint256 _amount) external;

    /**
     * @notice Borrow USDC against iBGT collateral
     * @dev Only callable by OPERATOR_ROLE during OPEN trade cycle
     * @param _borrowAmount Amount of USDC to borrow (in 18 decimals)
     */
    function borrowAssetFromDolomite(uint256 _borrowAmount) external;

    /**
     * @notice Repay USDC debt and close borrow position
     * @dev Only callable by OPERATOR_ROLE during OPEN trade cycle
     * @param _amount Amount to repay (0 = auto-calculate with 10% buffer)
     */
    function repayDebtToDolomite(uint256 _amount) external;

    /**
     * @notice Withdraw iBGT from Dolomite
     * @dev Only callable by OPERATOR_ROLE during OPEN trade cycle
     * @dev Requires all debt to be repaid first
     * @param _amount Amount of iBGT to withdraw (0 = withdraw all)
     */
    function withdrawCollateralFromDolomite(uint256 _amount) external;

    /**
     * @notice Claims rewards from the underlying staking protocol
     * @param _add Address of Dolomite IsolationModeUpgradeableProxy
     */
    function claimRewardsFromDolomite(address _add) external;

    // ============================================
    // Trade Cycle Control Functions
    // ============================================

    function initializeCycle() external;

    function startTradeCycle(uint256 _duration) external;

    function updateTradeCycleDuration(uint40 _newTradeCycleEndDate) external;

    function requestToEndTradeCycle() external;

    function endTradeCycle() external;

    // ============================================
    // Emergency Functions
    // ============================================

    function emergencyPause() external;

    function emergencyUnpause() external;

    // ============================================
    // View Functions - Dolomite Positions
    // ============================================

    /**
     * @notice Get balances for BORROW_ACCOUNT
     * @return collateralBalance iBGT collateral (positive) or debt (negative)
     * @return borrowBalance USDC balance (positive) or debt (negative)
     */
    function getDebtAccountBalanceFromDolomite()
        external
        view
        returns (int256 collateralBalance, int256 borrowBalance);

    /**
     * @notice Get balances for MAIN_ACCOUNT (account 0)
     * @return collateralBalance iBGT balance (positive) or debt (negative)
     * @return borrowBalance USDC balance (positive) or debt (negative)
     */
    function getMainAccountBalanceFromDolomite()
        external
        view
        returns (int256 collateralBalance, int256 borrowBalance);

    /**
     * @notice Get Dolomite position summary
     * @return collateral Total iBGT in Dolomite
     * @return borrowed Total USDC debt
     */
    function getDolomitePosition()
        external
        view
        returns (uint256 collateral, uint256 borrowed);

    /**
     * @notice Get contract token balances
     * @return iBGT balance
     * @return USDC balance
     * @return Deposit asset balance
     */
    function getContractBalances()
        external
        view
        returns (uint256, uint256, uint256);

    /**
     * @notice Get leverage ratio
     * @return Leverage (1e18 scale, 1e18 = 1x)
     */
    function getLeverageRatio() external view returns (uint256);

    /**
     * @notice Get total BERA received (gas refunds)
     * @return Total BERA received
     */
    function getTotalReceived() external view returns (uint256);

    // ============================================
    // View Functions - State Variables
    // ============================================

    /**
     * @notice Total BERA received (gas refunds)
     */
    function totalReceived() external view returns (uint256);

    /**
     * @notice Collateral token (iBGT)
     */
    function collateralAsset() external view returns (IERC20);

    /**
     * @notice Borrow token (USDC)
     */
    function borrowAsset() external view returns (IERC20);

    /**
     * @notice Total iBGT deposited to Dolomite
     */
    function totalCollateralDeposited() external view returns (uint256);

    /**
     * @notice Total USDC borrowed from Dolomite
     */
    function totalAssetBorrowed() external view returns (uint256);

    /**
     * @notice User deposit amounts
     */
    function userDeposits(address user) external view returns (uint256);

    /**
     * @notice Total number of users
     */
    function totalUsers() external view returns (uint256);

    /**
     * @notice Total value locked
     */
    function totalTVL() external view returns (uint256);

    /**
     * @notice Orderly vault address
     */
    function ivault() external view returns (address);

    /**
     * @notice Deposit asset token
     */
    function assetDeposit() external view returns (IERC20);

    /**
     * @notice Max user deposit limit
     */
    function maxUserDeposit() external view returns (uint256);

    /**
     * @notice Whitelist status of users
     */
    function whitelisted(address user) external view returns (bool);

    /**
     * @notice Trade cycle information
     */
    function tradeCycles(
        uint256 tradeCycleId
    ) external view returns (Data.TradeCycle memory);

    /**
     * @notice Current trade cycle ID
     */
    function currentTradeCycleId() external view returns (uint256);

    // ============================================
    // Constants
    // ============================================

    function MAIN_ACCOUNT() external view returns (uint256);

    function BORROW_ACCOUNT() external view returns (uint256);

    function DIBGT_MARKET_ID() external view returns (uint256);

    function USDC_MARKET_ID() external view returns (uint256);

    function OPERATOR_ROLE() external view returns (bytes32);

    function MANAGER_ROLE() external view returns (bytes32);

    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
}
