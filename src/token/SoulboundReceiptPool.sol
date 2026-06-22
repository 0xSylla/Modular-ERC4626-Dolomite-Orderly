// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SoulboundReceiptToken} from "./SoulboundReceiptToken.sol";

/// @title SoulboundReceiptPool
/// @notice Burns TDIRAC ↔ mints SBT. Distributes protocol revenue (single
///         token, USDC in v1) pro-rata to SBT holders using a Synthetix-style
///         accumulator.
///
///         Lifecycle:
///         1. Multisig deploys SBT + Pool, transfers TDIRAC reserve to Pool.
///         2. `attributor` (Phase 2 = multisig; Phase 3 = AttributionRegistry)
///            calls `mintReceipt(user, amount)` → Pool burns `amount * burnRatio`
///            TDIRAC from its own balance and mints `amount` SBT to `user`.
///         3. Revenue source calls `distributeRevenue(amount)` after approving
///            USDC. Updates `accRevenuePerShare` for all current SBT holders.
///         4. Holder calls `claim()` whenever to pull accrued USDC.
///
///         Accounting (Synthetix `MasterChef`-style):
///         - `accRevenuePerShare`: scaled by PRECISION (1e18), running sum
///           of revenue divided by `sbt.totalSupply()` at each distribution.
///         - `userRewardDebt[u]`: shares × accRevenuePerShare at the last
///           moment the user's share count changed (mint or claim).
///         - pendingRewards(u) = shares × accRevenuePerShare - userRewardDebt[u].
///         - On every `mintReceipt`, the user's accrued-but-unclaimed revenue
///           is settled into `claimable[u]` BEFORE the share change, then
///           `userRewardDebt[u]` is recomputed.
///
///         No special role to distribute revenue — anyone can deposit USDC
///         on behalf of SBT holders (treasury, BuyBackEngine, individual
///         donor). Mint is gated to `attributor` because each mint burns
///         TDIRAC reserve (a privileged action). Admin can rotate roles +
///         tune burn ratio.
contract SoulboundReceiptPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e18;

    // ============ Immutables ============

    /// @notice Dirac governance token (TDIRAC). Pool burns from its own balance
    ///         each time a receipt is minted.
    ERC20Burnable public immutable dirac;

    /// @notice Soulbound receipt token. Pool is the sole mint/burn authority.
    SoulboundReceiptToken public immutable sbt;

    /// @notice Token in which protocol revenue is denominated (USDC in v1).
    IERC20 public immutable revenueToken;

    // ============ Roles ============

    /// @notice Authorized to call `mintReceipt`. Phase 2 = multisig.
    ///         Phase 3 = AttributionRegistry. Phase 4 = DAO governor.
    address public attributor;

    /// @notice Authorized to rotate `attributor` + `admin` + tune `burnRatio`.
    ///         Phase 2-3 = multisig; Phase 4 = DAO governor.
    address public admin;

    // ============ Burn policy ============

    /// @notice TDIRAC burned per 1 unit of SBT minted, scaled by PRECISION.
    ///         Default 1e18 = 1:1 burn-to-mint. DAO can tune via `setBurnRatio`.
    uint256 public burnRatio;

    // ============ Revenue accounting ============

    /// @notice Running sum of (revenue / sbt.totalSupply()) scaled by PRECISION.
    uint256 public accRevenuePerShare;

    /// @notice User's `shares × accRevenuePerShare` at the last share-changing
    ///         operation (mint or claim). Used to compute pending rewards.
    mapping(address => uint256) public userRewardDebt;

    /// @notice Settled-but-unclaimed rewards. Populated when a user's share
    ///         count changes (mint adds shares; the prior-period pending is
    ///         booked here before the share count update so the user doesn't
    ///         lose past rewards).
    mapping(address => uint256) public claimable;

    // ============ Events ============

    event ReceiptMinted(address indexed user, uint256 sbtAmount, uint256 diracBurned);
    event ReceiptBurned(address indexed user, uint256 sbtAmount);
    event RevenueDistributed(address indexed from, uint256 amount, uint256 newAccPerShare);
    event RewardClaimed(address indexed user, uint256 amount);
    event AttributorChanged(address indexed oldAttributor, address indexed newAttributor);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event BurnRatioChanged(uint256 oldRatio, uint256 newRatio);

    // ============ Errors ============

    error Pool__OnlyAttributor();
    error Pool__OnlyAdmin();
    error Pool__ZeroAddress();
    error Pool__ZeroAmount();
    error Pool__NoSharesYet();
    error Pool__NothingToClaim();
    error Pool__InsufficientReserve();

    modifier onlyAttributor() {
        if (msg.sender != attributor) revert Pool__OnlyAttributor();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Pool__OnlyAdmin();
        _;
    }

    constructor(
        address _dirac,
        address _sbt,
        address _revenueToken,
        address _attributor,
        address _admin
    ) {
        if (_dirac == address(0) || _sbt == address(0) || _revenueToken == address(0))
            revert Pool__ZeroAddress();
        if (_attributor == address(0) || _admin == address(0))
            revert Pool__ZeroAddress();

        dirac = ERC20Burnable(_dirac);
        sbt = SoulboundReceiptToken(_sbt);
        revenueToken = IERC20(_revenueToken);
        attributor = _attributor;
        admin = _admin;
        burnRatio = PRECISION; // 1:1 default
    }

    // ============ Receipt mint / burn ============

    /// @notice Mints SBT to `user`. Burns `amount × burnRatio` TDIRAC from the
    ///         pool's reserve. Settles the user's existing pending rewards into
    ///         `claimable[user]` first so the share-count change doesn't strand
    ///         past entitlement.
    /// @param user      Recipient of the SBT.
    /// @param amount    SBT shares to mint (NOT a TDIRAC amount).
    function mintReceipt(address user, uint256 amount) external onlyAttributor nonReentrant {
        if (user == address(0)) revert Pool__ZeroAddress();
        if (amount == 0) revert Pool__ZeroAmount();

        // 1. Settle pending into claimable[user] BEFORE shares change.
        _bookPending(user);

        // 2. Burn TDIRAC reserve.
        uint256 burnAmount = (amount * burnRatio) / PRECISION;
        if (burnAmount > 0) {
            if (dirac.balanceOf(address(this)) < burnAmount) revert Pool__InsufficientReserve();
            dirac.burn(burnAmount);
        }

        // 3. Mint SBT.
        sbt.mint(user, amount);

        // 4. Reset rewardDebt to new balance × accRevenuePerShare.
        userRewardDebt[user] = (sbt.balanceOf(user) * accRevenuePerShare) / PRECISION;

        emit ReceiptMinted(user, amount, burnAmount);
    }

    /// @notice DAO/admin escape hatch — slash a contributor's SBT.
    ///         (Boss noted DAO will vote attribution rules; if a contributor
    ///         is later found to have gamed the rules, the DAO can revoke.)
    function burnReceipt(address user, uint256 amount) external onlyAdmin nonReentrant {
        if (user == address(0)) revert Pool__ZeroAddress();
        if (amount == 0) revert Pool__ZeroAmount();

        _bookPending(user);
        sbt.burn(user, amount);
        userRewardDebt[user] = (sbt.balanceOf(user) * accRevenuePerShare) / PRECISION;

        emit ReceiptBurned(user, amount);
    }

    // ============ Revenue distribution + claim ============

    /// @notice Permissionless — anyone can deposit USDC for the SBT holder
    ///         pool. Requires prior `revenueToken.approve(pool, amount)`.
    function distributeRevenue(uint256 amount) external nonReentrant {
        if (amount == 0) revert Pool__ZeroAmount();
        uint256 totalShares = sbt.totalSupply();
        if (totalShares == 0) revert Pool__NoSharesYet();

        revenueToken.safeTransferFrom(msg.sender, address(this), amount);
        accRevenuePerShare += (amount * PRECISION) / totalShares;

        emit RevenueDistributed(msg.sender, amount, accRevenuePerShare);
    }

    /// @notice Caller claims their accumulated revenue.
    function claim() external nonReentrant returns (uint256 amount) {
        amount = pendingRewards(msg.sender);
        if (amount == 0) revert Pool__NothingToClaim();

        claimable[msg.sender] = 0;
        userRewardDebt[msg.sender] = (sbt.balanceOf(msg.sender) * accRevenuePerShare) / PRECISION;

        revenueToken.safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }

    /// @notice Total pending = claimable bucket + freshly-accrued since last
    ///         share change.
    function pendingRewards(address user) public view returns (uint256) {
        uint256 entitled = (sbt.balanceOf(user) * accRevenuePerShare) / PRECISION;
        uint256 fresh = entitled > userRewardDebt[user] ? entitled - userRewardDebt[user] : 0;
        return claimable[user] + fresh;
    }

    // ============ Internal ============

    /// @dev Books the user's currently-accrued-but-unsettled rewards into the
    ///      `claimable` bucket. Called before any share-count change.
    function _bookPending(address user) internal {
        uint256 entitled = (sbt.balanceOf(user) * accRevenuePerShare) / PRECISION;
        if (entitled > userRewardDebt[user]) {
            claimable[user] += entitled - userRewardDebt[user];
        }
    }

    // ============ Admin ============

    function setAttributor(address newAttributor) external onlyAdmin {
        if (newAttributor == address(0)) revert Pool__ZeroAddress();
        emit AttributorChanged(attributor, newAttributor);
        attributor = newAttributor;
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert Pool__ZeroAddress();
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    function setBurnRatio(uint256 newRatio) external onlyAdmin {
        emit BurnRatioChanged(burnRatio, newRatio);
        burnRatio = newRatio;
    }

    // ============ Views ============

    function diracReserve() external view returns (uint256) {
        return dirac.balanceOf(address(this));
    }

    function sbtTotalSupply() external view returns (uint256) {
        return sbt.totalSupply();
    }
}
