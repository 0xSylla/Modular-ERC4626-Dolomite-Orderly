// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal Uniswap-V2-style router surface used for the buyback swap
///      (Kodiak on Berachain, Camelot/Sushi on Arbitrum, etc.).
interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @title BuyBackEngine
/// @notice Phase 4 buyback — spends accumulated protocol revenue (USDC) to
///         market-buy TDIRAC on a Uniswap-V2-style DEX and forward it to a
///         configured recipient (the SoulboundReceiptPool by default, to
///         replenish its burn reserve and create buy pressure — Step 7 of the
///         tokenomics roadmap).
///
///         **Funding:** the engine simply holds USDC. Anyone (treasury, the
///         revenue router, governance) can `transfer` USDC in. The keeper then
///         triggers a buyback for some/all of the balance.
///
///         **Execution:** a `keeper` role calls `buyback(amountIn, minOut,
///         deadline)`. The engine approves USDC to the configured V2 `router`
///         and calls `swapExactTokensForTokens` along the configured `path`
///         (must start at USDC, end at TDIRAC), sending the output directly to
///         `recipient`. Slippage is bounded by the keeper-supplied `minOut`.
///
///         **Governance:** `admin` (multisig now, DiracTimelock later) sets the
///         router, path, recipient, and keeper, and can rescue stuck tokens.
contract BuyBackEngine is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Immutables ============

    /// @notice Revenue token spent on buybacks (USDC in v1).
    IERC20 public immutable usdc;
    /// @notice Token bought back (TDIRAC).
    IERC20 public immutable tdirac;

    // ============ Config (governance) ============

    address public admin;
    address public keeper;
    /// @notice Where bought TDIRAC is sent (SoulboundReceiptPool by default).
    address public recipient;
    /// @notice V2-style router used for the swap.
    address public router;
    /// @notice Swap path; `path[0]` must be USDC and `path[last]` TDIRAC.
    address[] public path;

    // ============ Events ============

    event BuyBack(uint256 amountIn, uint256 amountOut, address indexed recipient);
    event RouterChanged(address indexed prev, address indexed next);
    event PathChanged(address[] path);
    event RecipientChanged(address indexed prev, address indexed next);
    event KeeperChanged(address indexed prev, address indexed next);
    event AdminChanged(address indexed prev, address indexed next);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ============ Errors ============

    error BB__OnlyAdmin();
    error BB__OnlyKeeper();
    error BB__ZeroAddress();
    error BB__ZeroAmount();
    error BB__InsufficientBalance();
    error BB__BadPath();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert BB__OnlyAdmin();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert BB__OnlyKeeper();
        _;
    }

    constructor(
        address _usdc,
        address _tdirac,
        address _router,
        address _recipient,
        address _admin,
        address _keeper,
        address[] memory _path
    ) {
        if (
            _usdc == address(0) || _tdirac == address(0) || _router == address(0)
                || _recipient == address(0) || _admin == address(0) || _keeper == address(0)
        ) revert BB__ZeroAddress();
        usdc = IERC20(_usdc);
        tdirac = IERC20(_tdirac);
        router = _router;
        recipient = _recipient;
        admin = _admin;
        keeper = _keeper;
        _setPath(_path);
    }

    // ============ Buyback ============

    /// @notice Spend `amountIn` USDC to buy TDIRAC and forward it to `recipient`.
    /// @param amountIn USDC to spend (must be ≤ this contract's USDC balance).
    /// @param minOut   Minimum TDIRAC out (slippage guard, from the keeper's quote).
    /// @param deadline Swap deadline passed to the router.
    function buyback(uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert BB__ZeroAmount();
        if (usdc.balanceOf(address(this)) < amountIn) revert BB__InsufficientBalance();

        // Approve exactly amountIn (reset-to-zero pattern via forceApprove).
        usdc.forceApprove(router, amountIn);

        uint256[] memory amounts = IUniswapV2Router(router).swapExactTokensForTokens(
            amountIn, minOut, path, recipient, deadline
        );
        amountOut = amounts[amounts.length - 1];

        // Defensive: clear any residual allowance if the router under-spent.
        if (usdc.allowance(address(this), router) != 0) usdc.forceApprove(router, 0);

        emit BuyBack(amountIn, amountOut, recipient);
    }

    // ============ Views ============

    function usdcBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function getPath() external view returns (address[] memory) {
        return path;
    }

    // ============ Admin / governance ============

    function setRouter(address newRouter) external onlyAdmin {
        if (newRouter == address(0)) revert BB__ZeroAddress();
        emit RouterChanged(router, newRouter);
        router = newRouter;
    }

    function setPath(address[] calldata newPath) external onlyAdmin {
        _setPath(newPath);
    }

    function setRecipient(address newRecipient) external onlyAdmin {
        if (newRecipient == address(0)) revert BB__ZeroAddress();
        emit RecipientChanged(recipient, newRecipient);
        recipient = newRecipient;
    }

    function setKeeper(address newKeeper) external onlyAdmin {
        if (newKeeper == address(0)) revert BB__ZeroAddress();
        emit KeeperChanged(keeper, newKeeper);
        keeper = newKeeper;
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert BB__ZeroAddress();
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Sweep stuck tokens (e.g., dust, a mistakenly-sent token, or to
    ///         reclaim USDC if buybacks are paused). Governance-only.
    function rescue(address token, address to, uint256 amount) external onlyAdmin {
        if (to == address(0)) revert BB__ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ============ Internal ============

    function _setPath(address[] memory newPath) internal {
        if (newPath.length < 2) revert BB__BadPath();
        if (newPath[0] != address(usdc) || newPath[newPath.length - 1] != address(tdirac)) {
            revert BB__BadPath();
        }
        path = newPath;
        emit PathChanged(newPath);
    }
}
