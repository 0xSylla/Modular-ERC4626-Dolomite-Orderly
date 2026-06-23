// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IRevenuePool {
    function distributeRevenue(uint256 amount) external;
    function sbtTotalSupply() external view returns (uint256);
}

interface ILockStaking {
    function notifyRewardAmount(uint256 reward) external;
    function totalWeight() external view returns (uint256);
}

/// @title RevenueRouter
/// @notice Splits protocol revenue (USDC) between SBT holders and $DIRAC lockers
///         in proportion to their shares, enforcing the unified weighting:
///
///             toStaking = amount × W / (S + W)
///             toPool    = amount − toStaking
///
///         where S = SoulboundReceiptPool.sbtTotalSupply() and
///         W = LockStaking.totalWeight() (lock weight = amount × years, same
///         1e18 unit as an SBT). This makes "1 DIRAC locked 2 years earns 2×
///         what 1 SBT earns" hold on-chain: a locker with weight w nets
///         `R·w/(S+W)` and an SBT holder with s nets `R·s/(S+W)`.
///
///         Permissionless: anyone (treasury, buyback, keeper) approves USDC to
///         this router and calls `route(amount)`. The router must hold the
///         LockStaking `rewardsDistributor` role (the pool's distribute is
///         already permissionless).
contract RevenueRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable revenueToken; // USDC
    IRevenuePool public immutable pool;
    ILockStaking public immutable staking;
    address public admin;

    event Routed(uint256 amount, uint256 toPool, uint256 toStaking, uint256 sbtShares, uint256 lockWeight);
    event AdminChanged(address indexed prev, address indexed next);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error RR__ZeroAddress();
    error RR__ZeroAmount();
    error RR__NoShares();
    error RR__OnlyAdmin();

    constructor(address _revenueToken, address _pool, address _staking, address _admin) {
        if (_revenueToken == address(0) || _pool == address(0) || _staking == address(0) || _admin == address(0)) {
            revert RR__ZeroAddress();
        }
        revenueToken = IERC20(_revenueToken);
        pool = IRevenuePool(_pool);
        staking = ILockStaking(_staking);
        admin = _admin;
    }

    /// @notice Pull `amount` USDC from the caller and split it S:W between the
    ///         SBT pool and the lockers. Caller must `approve` first.
    function route(uint256 amount) external nonReentrant returns (uint256 toPool, uint256 toStaking) {
        if (amount == 0) revert RR__ZeroAmount();
        uint256 s = pool.sbtTotalSupply();
        uint256 w = staking.totalWeight();
        if (s + w == 0) revert RR__NoShares();

        revenueToken.safeTransferFrom(msg.sender, address(this), amount);

        toStaking = (amount * w) / (s + w);
        toPool = amount - toStaking;

        if (toPool > 0) {
            revenueToken.forceApprove(address(pool), toPool);
            pool.distributeRevenue(toPool);
        }
        if (toStaking > 0) {
            revenueToken.forceApprove(address(staking), toStaking);
            staking.notifyRewardAmount(toStaking);
        }
        emit Routed(amount, toPool, toStaking, s, w);
    }

    // ============ Admin ============
    function setAdmin(address a) external {
        if (msg.sender != admin) revert RR__OnlyAdmin();
        if (a == address(0)) revert RR__ZeroAddress();
        emit AdminChanged(admin, a);
        admin = a;
    }

    /// @notice Sweep stray tokens (e.g. dust from rounding or a mistaken send).
    function rescue(address token, address to, uint256 amount) external {
        if (msg.sender != admin) revert RR__OnlyAdmin();
        if (to == address(0)) revert RR__ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
