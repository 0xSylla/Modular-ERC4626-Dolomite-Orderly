// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Test, console} from "forge-std/Test.sol";
import {DiracHoneyPotV1} from "../src/contracts/DiracHoneyPotV1.sol";
import {IDolomiteMargin} from "../src/interfaces/IDolomite.sol";
import {IVault, VaultTypes} from "../src/interfaces/IOrderly.sol";
import {IKXRouter} from "../src/interfaces/IKXRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DiracHoneyPotV1 Full Flow Test
 * @notice Tests the complete leveraged perpetual trading strategy:
 * 1. Users deposit USDC
 * 2. Operator swaps USDC → iBGT via Kodiak
 * 3. Supply iBGT to Dolomite as collateral
 * 4. Borrow USDC from Dolomite (leverage)
 * 5. Deposit borrowed USDC to Orderly for perps trading
 */
contract DiracHoneyPotV1Test is Test {
    DiracHoneyPotV1 public vault;
    DiracHoneyPotV1 public implementation;
    
    address public constant DOLOMITE_MARGIN = 0x003Ca23Fd5F0ca87D01F6eC6CD14A8AE60c2b97D;
    address public constant KODIAK_ROUTER = 0x43Dac637c4383f91B4368041E7A8687da3806Cae;
    
    // Token addresses (will be fetched from Dolomite)
    address public iBGT;      // Infrared BGT (collateral)
    address public diBGT;     // Dolomite wrapped iBGT
    address public USDC;      // User deposit + borrow asset
    address public dUSDC;     // Dolomite wrapped USDC
    
    // Mock Orderly vault (in production this would be the real vault)
    address public orderlyVault;
    
    address public admin = address(0x1);
    address public operator = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    
    // Events to test
    event CollateralSupplied(uint256 amount);
    event AssetBorrowed(uint256 amount);
    event DebtRepaid(uint256 amount);
    event CollateralWithdrawn(uint256 amount);
    
    function setUp() public {
        // Fork Berachain mainnet
        string memory rpcUrl = vm.envOr("BERA_RPC_URL", string("https://rpc.berachain.com/"));
        vm.createSelectFork(rpcUrl);
        
        console.log("===========================================");
        console.log("Forked Berachain at block:", block.number);
        console.log("===========================================");
        
        // Fetch market tokens from Dolomite
        _fetchMarketAddresses();
        
        require(iBGT != address(0), "iBGT address is zero");
        require(USDC != address(0), "USDC address is zero");
        
        console.log("Token Addresses:");
        console.log("iBGT (collateral):", iBGT);
        console.log("diBGT (Dolomite):", diBGT);
        console.log("USDC (deposit/borrow):", USDC);
        console.log("dUSDC (Dolomite):", dUSDC);
        
        // Deploy mock Orderly vault
        orderlyVault = address(new MockOrderlyVault());
        console.log("Orderly Vault (mock):", orderlyVault);
        
        // Deploy vault with transparent proxy
        vm.startPrank(admin);
        
        implementation = new DiracHoneyPotV1();
        
        bytes memory initData = abi.encodeWithSelector(
            DiracHoneyPotV1.initialize.selector,
            orderlyVault,     // Orderly vault address
            iBGT,             // Collateral asset (iBGT)
            USDC,             // Borrow asset (USDC)
            IERC20(USDC)      // Deposit asset (USDC) - what users deposit!
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = DiracHoneyPotV1(payable(address(proxy)));
        
        // Grant operator role
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        
        // Initialize trade cycle (status = INIT, allows deposits)
        vault.initializeCycle();
        
        vm.stopPrank();
        
        console.log("Vault Setup Complete:");
        console.log("Vault Proxy:", address(vault));
        console.log("Implementation:", address(implementation));
        console.log("Admin:", admin);
        console.log("Operator:", operator);
        console.log("===========================================\n");
    }
    
    function _fetchMarketAddresses() internal {
        // Market 38 = diBGT
        (bool success, bytes memory data) = DOLOMITE_MARGIN.call(
            abi.encodeWithSignature("getMarketTokenAddress(uint256)", 38)
        );
        require(success, "Failed to fetch diBGT");
        diBGT = abi.decode(data, (address));
        
        // Get underlying iBGT
        (success, data) = diBGT.call(abi.encodeWithSignature("UNDERLYING_TOKEN()"));
        require(success, "Failed to fetch underlying iBGT");
        iBGT = abi.decode(data, (address));
        
        // Market 2 = USDC
        (success, data) = DOLOMITE_MARGIN.call(
            abi.encodeWithSignature("getMarketTokenAddress(uint256)", 2)
        );
        require(success, "Failed to fetch USDC");
        USDC = abi.decode(data, (address));
        console.log("Fetched USDC Address:", USDC);
        
        // Get underlying USDC
        //(success, data) = dUSDC.call(abi.encodeWithSignature("UNDERLYING_TOKEN()"));
        //if (!success) {
       //     console.log("Failed calling UNDERLYING_TOKEN() on dUSDC");
            // Try lower case just in case
        //     (success, data) = dUSDC.call(abi.encodeWithSignature("underlyingToken()"));
        //     if (success) console.log("Success with underlyingToken()");
        //}
        //require(success, "Failed to fetch underlying USDC");
        //USDC = abi.decode(data, (address));
        //console.log("Fetched USDC Address:", USDC);
    }
    
    // ============================================
    // Basic ERC4626 Tests (USDC as deposit asset)
    // ============================================
    
    function test_Initialization() public view {
        assertEq(address(vault.asset()), USDC, "Deposit asset should be USDC");
        assertEq(address(vault.collateralAsset()), iBGT, "Collateral should be iBGT");
        assertEq(address(vault.borrowAsset()), USDC, "Borrow asset should be USDC");
        assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), true);
        assertEq(vault.hasRole(vault.OPERATOR_ROLE(), operator), true);
        assertEq(vault.name(), "Dirac Honeypot Perpetual Vault");
        assertEq(vault.symbol(), "DHPV");
    }
    
    function test_UserDepositUSDC() public {
        uint256 depositAmount = 1000e6; // 1000 USDC (6 decimals)
        
        // Deal USDC to user
        deal(USDC, user1, depositAmount);
        
        vm.startPrank(user1);
        
        uint256 balanceBefore = IERC20(USDC).balanceOf(user1);
        
        IERC20(USDC).approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user1);
        
        console.log("User Deposit:");
        console.log("Amount:", depositAmount);
        console.log("Shares received:", shares);
        
        // Assertions
        assertEq(shares, depositAmount, "Shares should be 1:1 initially");
        assertEq(vault.balanceOf(user1), shares);
        assertEq(vault.totalAssets(), depositAmount);
        assertEq(vault.userDeposits(user1), depositAmount);
        assertEq(vault.totalTVL(), depositAmount);
        assertEq(IERC20(USDC).balanceOf(user1), balanceBefore - depositAmount);
        
        vm.stopPrank();
    }
    
    function test_MultipleUsersDeposit() public {
        uint256 amount1 = 1000e6; // 1000 USDC
        uint256 amount2 = 2000e6; // 2000 USDC
        
        // User 1 deposits
        deal(USDC, user1, amount1);
        vm.startPrank(user1);
        IERC20(USDC).approve(address(vault), amount1);
        vault.deposit(amount1, user1);
        vm.stopPrank();
        
        // User 2 deposits
        deal(USDC, user2, amount2);
        vm.startPrank(user2);
        IERC20(USDC).approve(address(vault), amount2);
        vault.deposit(amount2, user2);
        vm.stopPrank();
        
        assertEq(vault.totalUsers(), 2);
        assertEq(vault.totalTVL(), amount1 + amount2);
        assertEq(vault.totalAssets(), amount1 + amount2);
    }
    
    function test_WithdrawUSDC() public {
        uint256 depositAmount = 1000e6;
        uint256 withdrawAmount = 500e6;
        
        // Setup: user deposits
        deal(USDC, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user1);
        
        uint256 balanceBefore = IERC20(USDC).balanceOf(user1);
        
        // Withdraw
        vault.withdraw(withdrawAmount, user1, user1);
        
        assertEq(IERC20(USDC).balanceOf(user1), balanceBefore + withdrawAmount);
        assertEq(vault.totalAssets(), depositAmount - withdrawAmount);
        
        vm.stopPrank();
    }
    
    // ============================================
    // Full Strategy Flow Test
    // ============================================
    
    /**
     * @notice Tests the complete leveraged strategy flow:
     * 1. Users deposit USDC
     * 2. Swap USDC → iBGT
     * 3. Supply iBGT to Dolomite
     * 4. Borrow USDC from Dolomite
     * 5. Deposit to Orderly
     */
    function test_FullLeverageStrategy() public {
        console.log("Starting Full Leverage Strategy Test");
        console.log("===========================================");
        
        // ========== STEP 1: Users Deposit USDC ==========
        uint256 userDepositAmount = 10000e6; // 10,000 USDC
        
        deal(USDC, user1, userDepositAmount);
        vm.startPrank(user1);
        IERC20(USDC).approve(address(vault), userDepositAmount);
        vault.deposit(userDepositAmount, user1);
        vm.stopPrank();
        
        console.log("Step 1: User deposited", userDepositAmount / 1e6, "USDC");
        assertEq(vault.totalAssets(), userDepositAmount);
        
        // ========== STEP 2: Start Trade Cycle ==========
        vm.prank(admin);
        vault.startTradeCycle(7 days);
        console.log("Step 2: Trade cycle started");
        
        vm.startPrank(operator);
        
        // ========== STEP 3: Swap USDC → iBGT via Kodiak ==========
        uint256 usdcToSwap = userDepositAmount; // Swap all deposited USDC
        uint256 minIbgtOut = 9000 ether; // Expect ~9000 iBGT (assuming some slippage)
        
        // Mock swap data (in production, this would be real Kodiak path)
        IKXRouter.SwapData memory swapData = IKXRouter.SwapData({
            router: KODIAK_ROUTER,
            data: ""
        });
        
        IKXRouter.FeeData memory feeData = IKXRouter.FeeData({
            feeQuote: 0,
            surplusFeeBps: 0,
            refCode: 0,
            referrerFeeBps: 0
        });
        
        // Mock the swap result by dealing iBGT
        uint256 ibgtReceived = 9500 ether; // Simulated swap output
        deal(iBGT, address(vault), ibgtReceived);
        
        console.log("Step 3: Swapped USDC to iBGT");
        console.log("USDC amount:", usdcToSwap / 1e6);
        console.log("iBGT received:", ibgtReceived / 1e18);
        
        // ========== STEP 4: Supply iBGT to Dolomite ==========
        uint256 vaultIbgtBalance = IERC20(iBGT).balanceOf(address(vault));
        
        vm.expectEmit(true, true, true, true);
        emit CollateralSupplied(ibgtReceived);
        
        vault.supplyCollateralToDolomite(ibgtReceived);
        
        console.log("Step 4: Supplied", ibgtReceived / 1e18, "iBGT to Dolomite");
        assertEq(vault.totalCollateralDeposited(), ibgtReceived);
        
        // ========== STEP 5: Borrow USDC from Dolomite ==========
        // Assuming 75% LTV, borrow ~7500 USDC worth
        uint256 borrowAmount = 7000 * 1e18; // 7000 USDC in 18 decimals (Dolomite format)
        
        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(address(vault));
        
        vm.expectEmit(true, true, true, true);
        emit AssetBorrowed(borrowAmount);
        
        vault.borrowAssetFromDolomite(borrowAmount);
        
        console.log("Step 5: Borrowed", borrowAmount / 1e18, "USDC from Dolomite");
        assertEq(vault.totalAssetBorrowed(), borrowAmount);
        assertGt(IERC20(USDC).balanceOf(address(vault)), vaultUsdcBefore);
        
        // ========== STEP 6: Deposit to Orderly ==========
        uint256 orderlyDepositAmount = borrowAmount / 1e12; // Convert to 6 decimals
        
        VaultTypes.VaultDepositFE memory depositData = VaultTypes.VaultDepositFE({
            accountId: keccak256(abi.encodePacked(address(vault))),
            brokerHash: keccak256("DIRAC"),
            tokenHash: keccak256("USDC"),
            tokenAmount: uint128(orderlyDepositAmount)
        });
        
        // Mock orderly deposit (no actual transfer in mock)
        // vault.depositToOrderly(depositData, 0);
        
        console.log("Step 6: Would deposit", orderlyDepositAmount / 1e6, "USDC to Orderly");
        
        // ========== Verify Final State ==========
        console.log("Final Strategy State:");
        console.log("===========================================");
        
        uint256 leverageRatio = vault.getLeverageRatio();
        console.log("Leverage Ratio:", leverageRatio / 1e16, "x"); // Convert to readable format
        
        (uint256 collateral, uint256 borrowed) = vault.getDolomitePosition();
        console.log("Collateral in Dolomite:", collateral / 1e18, "iBGT");
        console.log("Debt in Dolomite:", borrowed / 1e18, "USDC");
        
        (int256 collateralInBorrow, int256 debtInBorrow) = vault.getDebtAccountBalanceFromDolomite();
        console.log("Borrow Account Collateral:", uint256(collateralInBorrow) / 1e18);
        console.log("Borrow Account Debt:", uint256(-debtInBorrow) / 1e18);
        
        // Assertions
        assertGt(leverageRatio, 1e18, "Should be leveraged (>1x)");
        assertEq(collateral, ibgtReceived, "Collateral mismatch");
        assertEq(borrowed, borrowAmount, "Debt mismatch");
        
        console.log("===========================================");
        console.log("Full Strategy Test Complete!");
        
        vm.stopPrank();
    }
    
    // ============================================
    // Unwind Position Test
    // ============================================
    
    function test_UnwindPosition() public {
        console.log("Testing Position Unwind");
        console.log("===========================================");
        
        // Setup: Create leveraged position first
        uint256 userDeposit = 10000e6; // 10k USDC
        deal(USDC, user1, userDeposit);
        
        vm.startPrank(user1);
        IERC20(USDC).approve(address(vault), userDeposit);
        vault.deposit(userDeposit, user1);
        vm.stopPrank();
        
        vm.prank(admin);
        vault.startTradeCycle(7 days);
        
        vm.startPrank(operator);
        
        // Simulate strategy: swap, supply, borrow
        uint256 ibgtAmount = 9500 ether;
        deal(iBGT, address(vault), ibgtAmount);
        vault.supplyCollateralToDolomite(ibgtAmount);
        
        uint256 borrowAmount = 7000 * 1e18;
        vault.borrowAssetFromDolomite(borrowAmount);
        
        console.log("Position opened with", borrowAmount / 1e18, "USDC debt");
        
        // ========== Unwind Process ==========
        
        // Step 1: Ensure vault has USDC to repay (simulate profit or funding)
        uint256 repayAmount = (borrowAmount * 110) / 100; // 10% buffer for interest
        deal(USDC, address(vault), repayAmount / 1e12); // Convert to 6 decimals
        
        // Step 2: Repay debt
        vault.repayDebtToDolomite(0); // 0 = auto-calculate with buffer
        
        console.log("Debt repaid");
        assertEq(vault.totalAssetBorrowed(), 0);
        
        // Step 3: Withdraw collateral from Dolomite
        vault.withdrawCollateralFromDolomite(0); // 0 = withdraw all
        
        console.log("Collateral withdrawn");
        assertEq(vault.totalCollateralDeposited(), 0);
        assertEq(IERC20(iBGT).balanceOf(address(vault)), ibgtAmount);
        
        // Step 4: Swap iBGT back to USDC (simulate)
        uint256 usdcReceived = 9000e6; // Simulate swap output
        deal(USDC, address(vault), usdcReceived);
        
        console.log("Swapped iBGT back to", usdcReceived / 1e6, "USDC");
        
        vm.stopPrank();
        
        // Step 5: Close trade cycle
        vm.prank(admin);
        vault.requestToEndTradeCycle();
        vault.endTradeCycle();
        
        console.log("Trade cycle closed");
        
        // Step 6: User can now withdraw
        vm.startPrank(user1);
        uint256 userShares = vault.balanceOf(user1);
        vault.redeem(userShares, user1, user1);
        
        console.log("User withdrew all shares");
        console.log("===========================================\n");
        
        vm.stopPrank();
    }
    
    // ============================================
    // Dolomite Integration Tests
    // ============================================
    
    function test_SupplyCollateralToDolomite() public {
        uint256 ibgtAmount = 100 ether;
        
        // Get iBGT to vault
        deal(iBGT, address(vault), ibgtAmount);
        
        vm.prank(admin);
        vault.startTradeCycle(1 days);
        
        vm.startPrank(operator);
        
        uint256 balanceBefore = IERC20(iBGT).balanceOf(address(vault));
        
        vault.supplyCollateralToDolomite(ibgtAmount);
        
        assertEq(vault.totalCollateralDeposited(), ibgtAmount);
        assertEq(IERC20(iBGT).balanceOf(address(vault)), 0);
        
        // Verify Dolomite account balance
        (int256 collateral, ) = vault.getMainAccountBalanceFromDolomite();
        assertGt(collateral, 0, "No collateral in Dolomite");
        
        vm.stopPrank();
    }
    
    function test_BorrowAssetFromDolomite() public {
        uint256 collateralAmount = 100 ether; // 100 iBGT
        uint256 borrowAmount = 30 * 1e18;     // 30 USDC in 18 decimals
        
        deal(iBGT, address(vault), collateralAmount);
        
        vm.prank(admin);
        vault.startTradeCycle(1 days);
        
        vm.startPrank(operator);
        
        vault.supplyCollateralToDolomite(collateralAmount);
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(vault));
        
        vault.borrowAssetFromDolomite(borrowAmount);
        
        assertEq(vault.totalAssetBorrowed(), borrowAmount);
        assertGt(IERC20(USDC).balanceOf(address(vault)), usdcBefore);
        
        // Check borrow account has debt
        (, int256 debt) = vault.getDebtAccountBalanceFromDolomite();
        assertLt(debt, 0, "Should have debt in borrow account");
        
        vm.stopPrank();
    }
    
    function test_RepayDebtToDolomite() public {
        uint256 collateralAmount = 100 ether;
        uint256 borrowAmount = 30 * 1e18;
        
        // Setup position
        deal(iBGT, address(vault), collateralAmount);
        
        vm.prank(admin);
        vault.startTradeCycle(1 days);
        
        vm.startPrank(operator);
        
        vault.supplyCollateralToDolomite(collateralAmount);
        vault.borrowAssetFromDolomite(borrowAmount);
        
        // Get USDC to repay
        uint256 repayAmount = borrowAmount + (borrowAmount * 110) / 100;
        deal(USDC, address(vault), repayAmount / 1e12); // 6 decimals
        
        vault.repayDebtToDolomite(0);
        
        assertEq(vault.totalAssetBorrowed(), 0);
        
        // Verify collateral returned to main account
        (int256 collateralInMain, ) = vault.getMainAccountBalanceFromDolomite();
        assertGt(collateralInMain, 0);
        
        vm.stopPrank();
    }
    
    function test_GetLeverageRatio() public {
        assertEq(vault.getLeverageRatio(), 1e18, "No leverage initially");
        
        uint256 collateral = 10000 ether;
        uint256 borrowed = 5000 * 1e18;
        
        deal(iBGT, address(vault), collateral);
        
        vm.prank(admin);
        vault.startTradeCycle(1 days);
        
        vm.startPrank(operator);
        vault.supplyCollateralToDolomite(collateral);
        vault.borrowAssetFromDolomite(borrowed);
        vm.stopPrank();
        
        // Leverage = (collateral + borrowed) / collateral
        uint256 expected = ((collateral + borrowed) * 1e18) / collateral;
        assertEq(vault.getLeverageRatio(), expected);
    }
    
    // ============================================
    // Error Cases
    // ============================================
    
    function test_RevertWhen_WithdrawCollateralWithDebt() public {
        deal(iBGT, address(vault), 1000 ether);
        
        vm.prank(admin);
        vault.startTradeCycle(1 days);
        
        vm.startPrank(operator);
        vault.supplyCollateralToDolomite(1000 ether);
        vault.borrowAssetFromDolomite(500 * 1e18);
        
        vm.expectRevert(DiracHoneyPotV1.DebtExists.selector);
        vault.withdrawCollateralFromDolomite(1000 ether);
        
        vm.stopPrank();
    }
    
    function test_RevertWhen_NonOperatorSuppliesCollateral() public {
        deal(iBGT, address(vault), 100 ether);
        
        vm.prank(admin);
        vault.startTradeCycle(1 days);
        
        vm.prank(user1);
        vm.expectRevert();
        vault.supplyCollateralToDolomite(100 ether);
    }
    
    function test_RevertWhen_SupplyZeroCollateral() public {
        vm.prank(admin);
        vault.startTradeCycle(1 days);
        
        vm.prank(operator);
        vm.expectRevert(DiracHoneyPotV1.ZeroAmount.selector);
        vault.supplyCollateralToDolomite(0);
    }
    
    // ============================================
    // View Function Tests
    // ============================================
    
    function test_GetContractBalances() public {
        deal(iBGT, address(vault), 100 ether);
        deal(USDC, address(vault), 1000e6);
        
        (uint256 ibgtBal, uint256 usdcBal, uint256 assetBal) = vault.getContractBalances();
        
        assertEq(ibgtBal, 100 ether);
        assertEq(usdcBal, 1000e6);
    }
    
    function test_GetDolomitePosition() public {
        deal(iBGT, address(vault), 1000 ether);
        
        vm.prank(admin);
        vault.startTradeCycle(1 days);
        
        vm.startPrank(operator);
        vault.supplyCollateralToDolomite(1000 ether);
        vault.borrowAssetFromDolomite(500 * 1e18);
        vm.stopPrank();
        
        (uint256 collateral, uint256 borrowed) = vault.getDolomitePosition();
        
        assertEq(collateral, 1000 ether);
        assertEq(borrowed, 500 * 1e18);
    }
    
    // ============================================
    // Fuzz Tests
    // ============================================
    
    function testFuzz_UserDeposit(uint256 amount) public {
        amount = bound(amount, 100e6, 1000000e6); // 100 - 1M USDC
        
        deal(USDC, user1, amount);
        
        vm.startPrank(user1);
        IERC20(USDC).approve(address(vault), amount);
        
        uint256 shares = vault.deposit(amount, user1);
        
        assertEq(shares, amount);
        assertEq(vault.totalAssets(), amount);
        
        vm.stopPrank();
    }
    
    function testFuzz_MultiUserDeposits(uint8 numUsers, uint96 amountPerUser) public {
        numUsers = uint8(bound(numUsers, 1, 20));
        amountPerUser = uint96(bound(amountPerUser, 100e6, 10000e6));
        
        uint256 totalDeposited = 0;
        
        for (uint8 i = 0; i < numUsers; i++) {
            address user = address(uint160(1000 + i));
            uint256 amount = uint256(amountPerUser);
            
            deal(USDC, user, amount);
            
            vm.startPrank(user);
            IERC20(USDC).approve(address(vault), amount);
            vault.deposit(amount, user);
            vm.stopPrank();
            
            totalDeposited += amount;
        }
        
        assertEq(vault.totalUsers(), numUsers);
        assertEq(vault.totalTVL(), totalDeposited);
    }
}

// ============================================
// Mock Contracts
// ============================================

contract MockOrderlyVault {
    event Deposit(bytes32 accountId, bytes32 tokenHash, uint256 amount);
    event DelegateSigner(bytes32 brokerHash, address delegateSigner);
    
    mapping(bytes32 => mapping(bytes32 => uint256)) public balances;
    
    function deposit(VaultTypes.VaultDepositFE calldata data) external payable {
        balances[data.accountId][data.tokenHash] += data.tokenAmount;
        emit Deposit(data.accountId, data.tokenHash, data.tokenAmount);
    }
    
    function delegateSigner(VaultTypes.VaultDelegate calldata data) external {
        emit DelegateSigner(data.brokerHash, data.delegateSigner);
    }
    
    function getBalance(bytes32 accountId, bytes32 tokenHash) external view returns (uint256) {
        return balances[accountId][tokenHash];
    }
}