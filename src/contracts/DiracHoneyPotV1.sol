// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Controller} from "../controls/Controller.sol";
import {IVault, VaultTypes} from "../interfaces/IOrderly.sol";
import {IDolomiteMargin, IDepositWithdrawalRouter, AccountBalanceLib, IBorrowPositionRouter} from "../interfaces/IDolomite.sol";
import {Data} from "../data/Data.sol";
import {IKXRouter} from "../interfaces/IKXRouter.sol";
import {Events} from "../events/Events.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

contract DiracHoneyPotV1 is Controller, ERC4626Upgradeable{

    // ============ State Variables ============
    
    /// @notice Total BERA received (gas refunds)
    uint256 public totalReceived;
    /// @notice Collateral token (iBGT)
    IERC20 public collateralAsset;
    /// @notice Borrow token (USDC)
    IERC20 public borrowAsset;
    /// @notice Total iBGT deposited to Dolomite
    uint256 public totalCollateralDeposited;
    /// @notice Total USDC borrowed from Dolomite
    uint256 public totalAssetBorrowed;

    // ============ Constants ============
    
    /// @notice Main vault account (0)
    uint256 public constant MAIN_ACCOUNT = 0;
    /// @notice Borrow account (123) - isolates borrow risk
    uint256 public constant BORROW_ACCOUNT = 123;
    /// @notice diBGT market ID
    uint256 public constant DIBGT_MARKET_ID = 38;
    /// @notice USDC market ID
    uint256 public constant USDC_MARKET_ID = 2;

    /// @notice Dolomite main contract
    IDolomiteMargin public constant DOLOMITE_MARGIN = 
        IDolomiteMargin(0x003Ca23Fd5F0ca87D01F6eC6CD14A8AE60c2b97D);
    /// @notice Dolomite deposit/withdrawal router
    IDepositWithdrawalRouter public constant DEPOSIT_WITHDRAWAL_ROUTER = 
        IDepositWithdrawalRouter(0xf8b2c637A68cF6A17b1DF9F8992EeBeFf63d2dFf);
    /// @notice Dolomite borrow position router
    IBorrowPositionRouter public constant BORROW_POSITION_ROUTER = 
        IBorrowPositionRouter(0xF579b345cdA0860668b857De10ABD62442133D0F);
    /// @notice Kodiak DEX router
    IKXRouter public constant KXRouter = 
        IKXRouter(0x43Dac637c4383f91B4368041E7A8687da3806Cae);

    // Events
    event CollateralSupplied(uint256 amount);
    event AssetBorrowed(uint256 amount);
    event DebtRepaid(uint256 amount);
    event CollateralWithdrawn(uint256 amount);
    event ContractFunded(uint256 amount);
    event ContractWithdrawn(uint256 amount);
    event OperatorsSet(address[] operators, bool[] trusted);
    event BorrowPositionOpened(uint256 collateralAmount, uint256 borrowAmount);
    // Errors
    error Unauthorized();
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();
    error DebtExists();


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the vault with the specified parameters.
     * @param _ivault The address of the associated vault contract.
     * @param _assetDeposit The ERC20 token used for deposits.
     */

    function initialize(
        address _ivault,
        address _collateralAsset,
        address _borrowAsset,
        IERC20 _assetDeposit
    ) external initializer {

        if (address(_assetDeposit) == address(0) || address(_ivault) == address(0)) {
            revert Events.ZeroAddress();
        }

        __ERC20_init("Dirac Honeypot Perpetual Vault", "DHPV");
        __ERC4626_init(_assetDeposit);
        __Controller_init(_ivault, _assetDeposit);

        collateralAsset = IERC20(_collateralAsset);
        borrowAsset = IERC20(_borrowAsset);

        _setOperators();
    }


    /**
     * @notice Deposits assets and mints corresponding shares.
     * @dev Only allowed when the trade cycle status is INIT and the caller is whitelisted.
     * @param _assets The amount of assets to deposit.
     * @param _receiver The address receiving the minted shares.
     * @return shares The number of shares minted.
     */
    function deposit(
        uint256 _assets,
        address _receiver
    )
    public
    override
    whenTradeClosed
    whenNotPaused
    nonReentrant
    returns (uint256 shares)
    {
        if (_assets == 0) {
            revert Events.ZeroAmount();
        }
        if (_receiver == address(0)) {
            revert Events.ZeroAddress();
        }

        if (userDeposits[msg.sender] == 0 && _assets > 0) {
            totalUsers++;
        }
        userDeposits[msg.sender] += _assets;
        totalTVL = totalTVL + _assets;
        shares = super.deposit(_assets, _receiver);
    }

    /**
     * @notice Mints shares corresponding to the specified amount of assets.
     * @dev Only allowed when the trade cycle status is INIT and the caller is whitelisted.
     * @param _shares The number of shares to mint.
     * @param _receiver The address receiving the minted shares.
     * @return assets The amount of assets corresponding to the minted shares.
     */
    function mint(
        uint256 _shares,
        address _receiver
    )
    public
    override
    whenTradeClosed
    whenNotPaused
    nonReentrant
    returns (uint256 assets)
    {
        assets = convertToAssets(_shares);
        if (assets == 0) {
            revert Events.ZeroAmount();
        }

        if (userDeposits[msg.sender] == 0 && assets > 0) {
            totalUsers++;
        }
        userDeposits[msg.sender] += assets;
        assets = super.mint(_shares, _receiver);
    }

    /**
     * @notice Withdraws assets by burning shares.
     * @dev Only allowed when the trade cycle status is INIT and the caller is whitelisted.
     * @param _assets The amount of assets to withdraw.
     * @param _receiver The address receiving the withdrawn assets.
     * @param _owner The owner of the shares being burned.
     * @return shares The number of shares burned.
     */
    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner
    )
    public
    override
    whenTradeClosed
    whenNotPaused
    nonReentrant
    returns (uint256 shares)
    {
        if (_assets == 0) {
            revert Events.ZeroAmount();
        }

        if (userDeposits[msg.sender] > _assets) {
            userDeposits[msg.sender] -= _assets;
        } else {
            delete userDeposits[msg.sender];
            if(totalUsers > 0) {
                totalUsers--;
            }
        }
        totalTVL = totalTVL - _assets;
        shares = super.withdraw(_assets, _receiver, _owner);
    }

    /**
     * @notice Redeems shares for assets.
     * @dev Only allowed when the trade cycle status is INIT and the caller is whitelisted.
     * @param _shares The number of shares to redeem.
     * @param _receiver The address receiving the redeemed assets.
     * @param _owner The owner of the shares being redeemed.
     * @return assets The amount of assets received.
     */

    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    )
    public
    override
    whenTradeClosed
    whenNotPaused
    nonReentrant
    returns (uint256 assets)
    {
        assets = super.redeem(_shares, _receiver, _owner);

        if (assets == 0) {
            revert Events.ZeroAmount();
        }

        if (userDeposits[msg.sender] > assets) {
            userDeposits[msg.sender] -= assets;
        } else {
            delete userDeposits[msg.sender];
            if (totalUsers > 0) {
                totalUsers--;
            }
        }
    }
    ////////////////////////////////////////////////////////////////////////////
    //////////////////////////// SWAP FUNCTIONS ////////////////////////////////    
    ////////////////////////////////////////////////////////////////////////////
    /*
   *
   *
   * @notice Executes a token swap using the KXRouter.
     * @dev Approves the input token for the router, constructs input and output parameters,
     * and calls the swap function on the KXRouter.
     * @param tokenIn The address of the input token.
     * @param wrapIn Whether to wrap the input token (e.g., ETH to WETH).
     * @param amountIn The amount of the input token to swap.
     * @param tokenOut The address of the output token.
     * @param unwrapOut Whether to unwrap the output token (e.g., WETH to ETH).
     * @param minAmountOut The minimum acceptable amount of the output token to receive.
     * @param swapDatas The swap data containing router address and encoded swap instructions.
     * @param feeDatas The fee data including fee quote, surplus fee, referral code, and referral fee.
     * @param _spender The address to approve the input token for (typically the KXRouter).
     */
    function swapKodiak(address tokenIn, bool wrapIn, uint256 amountIn, address tokenOut, bool unwrapOut, uint256 minAmountOut, IKXRouter.SwapData calldata swapDatas, IKXRouter.FeeData calldata feeDatas, address _spender) external  nonReentrant onlyRole(OPERATOR_ROLE)  {

        IKXRouter.InputAmount memory input = IKXRouter.InputAmount({
            token : tokenIn,
            wrap : wrapIn,
            amount :amountIn
        });

        IKXRouter.OutputAmount memory output =  IKXRouter.OutputAmount({
            token : tokenOut,
            unwrap :unwrapOut,
            minAmountOut : minAmountOut,
            receiver : address(this)

        });

        TransferHelper.safeApprove(
            tokenIn,
            _spender,
            amountIn
        );

        KXRouter.swap(
            input,
            output,
            swapDatas,
            feeDatas
        );
    }
    ////////////////////////////////////////////////////////////////////////////
    //////////////////////// ORDERLY FUNCTIONS /////////////////////////////////    
    ////////////////////////////////////////////////////////////////////////////
    
    /**
     * @notice Delegates signer for Orderly
     * @param data The data for the delegate signer
     * @dev Only allowed when the trade cycle status is INIT and the caller is whitelisted.
     */
    function delegateSigner( VaultTypes.VaultDelegate calldata data) external     nonReentrant onlyRole(OPERATOR_ROLE)  whenNotPaused {
        IVault(address(ivault)).delegateSigner(data);
        emit Events.DelegateSignerSet( data.brokerHash,  data.delegateSigner);

    }

    /**
     * @notice Deposits to Orderly/HoneyPot for perpetuals
     * @param data The data for the deposit
     * @param fee The fee for the deposit
     */
    function depositToOrderly(VaultTypes.VaultDepositFE calldata data, uint256  fee) external nonReentrant  onlyRole(OPERATOR_ROLE)  whenNotPaused {
        IERC20(assetDeposit).approve(ivault, data.tokenAmount);
        IVault(ivault).deposit{value: fee }(data);
    }

    ////////////////////////////////////////////////////////////////////////////
    //////////////////////// DOLOMITE FUNCTIONS ////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Internal function to authorize Dolomite routers
     * @dev Must be called to allow routers to manipulate this contract's accounts
     */
    function _setOperators() internal {
        IDolomiteMargin.OperatorArg[] memory args = new IDolomiteMargin.OperatorArg[](1);
        
        args[0] = IDolomiteMargin.OperatorArg({
            operator: address(DEPOSIT_WITHDRAWAL_ROUTER),
            trusted: true
        });
        
        DOLOMITE_MARGIN.setOperators(args);
    }

    /**
     * @notice Supply iBGT to Dolomite as collateral
     * @param _amount Amount of iBGT to supply
     */
    function supplyCollateralToDolomite(uint256 _amount) external nonReentrant  onlyRole(OPERATOR_ROLE)  whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        
        uint256 contractBalance = collateralAsset.balanceOf(address(this));
        if (_amount > contractBalance) revert InsufficientBalance();
        
        // Approve Dolomite router
        collateralAsset.approve(address(DEPOSIT_WITHDRAWAL_ROUTER), _amount);
        
        // Deposit to Dolomite account 0
        DEPOSIT_WITHDRAWAL_ROUTER.depositWei(
            DIBGT_MARKET_ID,
            MAIN_ACCOUNT,
            DIBGT_MARKET_ID,
            _amount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        totalCollateralDeposited += _amount;
        
        emit CollateralSupplied(_amount);
    }

    /**
     * @notice Borrow USDC against iBGT collateral
     * @param _borrowAmount Amount of ETH to borrow (in wei, 18 decimals)
     */
    function borrowAssetFromDolomite(uint256 _borrowAmount) external nonReentrant  onlyRole(OPERATOR_ROLE)  whenNotPaused {
        if (_borrowAmount == 0) revert ZeroAmount();
        
        // Open borrow position and transfer collateral from vault account to borrow account
        BORROW_POSITION_ROUTER.openBorrowPosition(
            MAIN_ACCOUNT,  // fromAccountNumber
            BORROW_ACCOUNT,  // toAccountNumber
            DIBGT_MARKET_ID,   // collteralMarketId
            totalCollateralDeposited,      // collateralAmount
            IBorrowPositionRouter.BalanceCheckFlag.From
        );

        //Transfering borrowed USD back to account 0
        BORROW_POSITION_ROUTER.transferBetweenAccounts(
            DIBGT_MARKET_ID,
            BORROW_ACCOUNT,
            MAIN_ACCOUNT,
            USDC_MARKET_ID,
            _borrowAmount,
            IBorrowPositionRouter.BalanceCheckFlag.To
        );
        
        totalAssetBorrowed += _borrowAmount;

        // Withdraw USDC borrowed from Dolomite
        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            0,
            MAIN_ACCOUNT,
            USDC_MARKET_ID,
            _borrowAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        emit AssetBorrowed(_borrowAmount);
    }

    /**
     * @notice Repay USDC debt and close borrow position
     * @param _amount Amount to repay (0 = repay with 10% buffer for interest)
     * @dev After this, collateral will be back in account 0 (still in Dolomite)
     */
    function repayDebtToDolomite(uint256 _amount) external nonReentrant  onlyRole(OPERATOR_ROLE)  whenNotPaused {
        uint256 repayAmount = _amount;

        if (repayAmount == 0) {
            // Add 10% buffer for accrued interest
            repayAmount = (totalAssetBorrowed * 110) / 100;
        }

        if (repayAmount == 0) revert ZeroAmount();

        // Approve and deposit USDC to account 0
        borrowAsset.approve(address(DEPOSIT_WITHDRAWAL_ROUTER), repayAmount);
        
        DEPOSIT_WITHDRAWAL_ROUTER.depositWei(
            0,
            MAIN_ACCOUNT,
            USDC_MARKET_ID,
            repayAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        // Repay all debt in borrow account using funds from main account
        BORROW_POSITION_ROUTER.repayAllForBorrowPosition(
            DIBGT_MARKET_ID,
            MAIN_ACCOUNT,
            BORROW_ACCOUNT,
            USDC_MARKET_ID,
            AccountBalanceLib.BalanceCheckFlag.From
        );

        // Transfer collateral back to main account
        BORROW_POSITION_ROUTER.transferBetweenAccounts(
            DIBGT_MARKET_ID,
            BORROW_ACCOUNT,
            MAIN_ACCOUNT,
            DIBGT_MARKET_ID,
            totalCollateralDeposited,
            IBorrowPositionRouter.BalanceCheckFlag.None
        );

        // Reset debt tracking
        totalAssetBorrowed = 0;

        emit DebtRepaid(repayAmount);
        //emit BorrowPositionClosed(repayAmount);
    }

    /**
     * @notice Withdraw iBGT from Dolomite
     * @param _amount Amount of iBGT to withdraw (0 = withdraw all)
     * @dev Requires all debt to be repaid first
     */
    function withdrawCollateralFromDolomite(uint256 _amount) external nonReentrant  onlyRole(OPERATOR_ROLE)  whenNotPaused {
        if (totalAssetBorrowed > 0) revert DebtExists();
        
        uint256 withdrawAmount = _amount;
        
        // If amount is 0, withdraw all
        if (withdrawAmount == 0) {
            withdrawAmount = totalCollateralDeposited;
        }
        
        if (withdrawAmount == 0) revert ZeroAmount();
        if (withdrawAmount > totalCollateralDeposited) revert InsufficientBalance();
        
        // Withdraw iBGT from Dolomite
        DEPOSIT_WITHDRAWAL_ROUTER.withdrawWei(
            DIBGT_MARKET_ID,
            MAIN_ACCOUNT,
            DIBGT_MARKET_ID,
            withdrawAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );
        
        totalCollateralDeposited -= withdrawAmount;
        
        emit CollateralWithdrawn(withdrawAmount);
    }

    ////////////////////////////////////////////////////////////////////////////
    /////////////////////////// VIEW FUNCTIONS /////////////////////////////////    
    ////////////////////////////////////////////////////////////////////////////

    /
     * @notice Get balances for BORROW_ACCOUNT 
     * @return collateralBalance iBGT collateral (positive) or debt (negative)
     * @return borrowBalance USDC balance (positive) or debt (negative)
     */
    function getDebtAccountBalanceFromDolomite() public view returns (
        int256 collateralBalance,
        int256 borrowBalance
    ) {
        // Get iBGT collateral balance
        IDolomiteMargin.Wei memory collateralWei = DOLOMITE_MARGIN.getAccountWei(
            address(this),
            BORROW_ACCOUNT,
            DIBGT_MARKET_ID
        );
        
        // Get USDC debt balance
        IDolomiteMargin.Wei memory borrowWei = DOLOMITE_MARGIN.getAccountWei(
            address(this),
            BORROW_ACCOUNT,
            USDC_MARKET_ID
        );
        
        // Convert Wei to signed int256
        collateralBalance = collateralWei.sign 
            ? int256(collateralWei.value) 
            : -int256(collateralWei.value);
        
        borrowBalance = borrowWei.sign 
            ? int256(borrowWei.value) 
            : -int256(borrowWei.value);
    }
    
    /
     * @notice Get balances for MAIN_ACCOUNT (account 0)
     * @return collateralBalance iBGT balance (positive) or debt (negative)
     * @return borrowBalance USDC balance (positive) or debt (negative)
     */
    function getMainAccountBalanceFromDolomite() public view returns (
        int256 collateralBalance,
        int256 borrowBalance
    ) {
        // Get iBGT balance
        IDolomiteMargin.Wei memory collateralWei = DOLOMITE_MARGIN.getAccountWei(
            address(this),
            MAIN_ACCOUNT,
            DIBGT_MARKET_ID
        );
        
        // Get USDC balance
        IDolomiteMargin.Wei memory borrowWei = DOLOMITE_MARGIN.getAccountWei(
            address(this),
            MAIN_ACCOUNT,
            USDC_MARKET_ID
        );
        
        // Convert Wei to signed int256
        collateralBalance = collateralWei.sign 
            ? int256(collateralWei.value) 
            : -int256(collateralWei.value);
        
        borrowBalance = borrowWei.sign 
            ? int256(borrowWei.value) 
            : -int256(borrowWei.value);
    }

    /**
     * @notice Dolomite position
     * @return collateral Total iBGT in Dolomite
     * @return borrowed Total USDC debt
     */
    function getDolomitePosition() external view
        returns (uint256 collateral, uint256 borrowed)
    {
        return (totalCollateralDeposited, totalAssetBorrowed);
    }

    /**
     * @notice Contract token balances
     * @return iBGT balance
     * @return USDC balance
     * @return Deposit asset balance
     */
    function getContractBalances() external view
        returns (uint256, uint256, uint256)
    {
        return (
            collateralAsset.balanceOf(address(this)),
            borrowAsset.balanceOf(address(this)),
            IERC20(asset()).balanceOf(address(this))
        );
    }

    /**
     * @notice Leverage ratio
     * @return Leverage (1e18 scale, 1e18 = 1x)
     */
    function getLeverageRatio() external view returns (uint256) {
        if (totalCollateralDeposited == 0) return 1e18;
        return ((totalCollateralDeposited + totalAssetBorrowed) * 1e18) / totalCollateralDeposited;
    }

    /**
     * @notice Receives ETH from the caller
     * @dev Increments the total received amount
     */
    receive() external payable {
        totalReceived += msg.value;
    }


    fallback() external payable {
        totalReceived += msg.value;
    }

    // Une fonction pour récupérer le solde total reçu, juste pour vérification
    function getTotalReceived() external view returns (uint256) {
        return totalReceived;
    }
}
