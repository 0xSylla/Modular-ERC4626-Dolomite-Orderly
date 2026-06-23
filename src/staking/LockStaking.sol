// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LockStaking
/// @notice Lock-boosted $DIRAC staking (Phase 4, tokenomics first-test). Lock
///         TDIRAC for a whole-year term and earn a share of protocol revenue
///         (USDC) proportional to your LOCK WEIGHT:
///
///             weight = amount × years
///
///         Weight is denominated in the same 1e18 unit as a soulbound receipt,
///         so `1 DIRAC locked 2 years = 2 SBT` of revenue share, `3 years = 3`,
///         etc. The actual split between SBT holders and lockers is enforced by
///         the RevenueRouter (it funds this contract and the SoulboundReceiptPool
///         in proportion to total weight : total SBT supply).
///
///         Rewards: Synthetix-style accumulator over `totalWeight`, streamed
///         over `rewardsDuration` per `notifyRewardAmount`. Claimable anytime.
///
///         Locks: principal is locked until `end`. Early `withdraw` IS allowed
///         but burns `earlyPenaltyBps` of the principal (default 30%) — the
///         burned TDIRAC permanently reduces supply. Accrued USDC rewards are
///         always claimable regardless.
contract LockStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant BPS = 10_000;

    // ============ Immutables ============
    /// @notice Staked + burnable token (TDIRAC).
    ERC20Burnable public immutable stakingToken;
    /// @notice Reward token (USDC).
    IERC20 public immutable rewardsToken;

    // ============ Roles ============
    address public admin;
    address public rewardsDistributor;

    // ============ Params (DAO-tunable) ============
    uint256 public maxLockYears;       // longest allowed term
    uint256 public earlyPenaltyBps;    // burned on early withdraw (default 3000 = 30%)
    uint256 public rewardsDuration;    // reward window length (seconds)

    // ============ Reward state (Synthetix, per-weight) ============
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerWeightStored;
    mapping(address => uint256) public userRewardPerWeightPaid;
    mapping(address => uint256) public rewards;

    // ============ Lock bookkeeping ============
    struct Lock {
        uint256 amount;   // principal (TDIRAC wei)
        uint256 weight;   // amount × years
        uint64 start;
        uint64 end;
        bool withdrawn;
    }
    mapping(address => Lock[]) public locks;
    mapping(address => uint256) public weightOf;
    uint256 public totalWeight;

    // ============ Events ============
    event Locked(address indexed user, uint256 indexed lockId, uint256 amount, uint256 years_, uint256 weight, uint64 end);
    event Withdrawn(address indexed user, uint256 indexed lockId, uint256 returned, uint256 burned);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward, uint256 periodFinish);
    event RewardsDurationUpdated(uint256 newDuration);
    event MaxLockYearsUpdated(uint256 newMax);
    event EarlyPenaltyUpdated(uint256 newBps);
    event AdminChanged(address indexed prev, address indexed next);
    event RewardsDistributorChanged(address indexed prev, address indexed next);

    // ============ Errors ============
    error LS__OnlyAdmin();
    error LS__OnlyRewardsDistributor();
    error LS__ZeroAddress();
    error LS__ZeroAmount();
    error LS__BadTerm();
    error LS__BadLockId();
    error LS__AlreadyWithdrawn();
    error LS__RewardTooHigh();
    error LS__PeriodNotFinished();
    error LS__BadParam();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert LS__OnlyAdmin();
        _;
    }
    modifier onlyRewardsDistributor() {
        if (msg.sender != rewardsDistributor) revert LS__OnlyRewardsDistributor();
        _;
    }
    modifier updateReward(address account) {
        rewardPerWeightStored = rewardPerWeight();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerWeightPaid[account] = rewardPerWeightStored;
        }
        _;
    }

    constructor(
        address _stakingToken,
        address _rewardsToken,
        address _admin,
        address _rewardsDistributor,
        uint256 _rewardsDuration,
        uint256 _maxLockYears
    ) {
        if (
            _stakingToken == address(0) || _rewardsToken == address(0) || _admin == address(0)
                || _rewardsDistributor == address(0)
        ) revert LS__ZeroAddress();
        if (_rewardsDuration == 0 || _maxLockYears == 0) revert LS__BadParam();
        stakingToken = ERC20Burnable(_stakingToken);
        rewardsToken = IERC20(_rewardsToken);
        admin = _admin;
        rewardsDistributor = _rewardsDistributor;
        rewardsDuration = _rewardsDuration;
        maxLockYears = _maxLockYears;
        earlyPenaltyBps = 3000; // 30% default
    }

    // ============ Views ============
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerWeight() public view returns (uint256) {
        if (totalWeight == 0) return rewardPerWeightStored;
        return rewardPerWeightStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / totalWeight;
    }

    function earned(address account) public view returns (uint256) {
        return (weightOf[account] * (rewardPerWeight() - userRewardPerWeightPaid[account])) / PRECISION
            + rewards[account];
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    function lockCount(address user) external view returns (uint256) {
        return locks[user].length;
    }

    function getLocks(address user) external view returns (Lock[] memory) {
        return locks[user];
    }

    // ============ Lock / withdraw / claim ============

    /// @notice Lock `amount` TDIRAC for `years_` whole years. Weight = amount × years_.
    function lock(uint256 amount, uint256 years_) external nonReentrant updateReward(msg.sender) returns (uint256 lockId) {
        if (amount == 0) revert LS__ZeroAmount();
        if (years_ == 0 || years_ > maxLockYears) revert LS__BadTerm();

        uint256 w = amount * years_;
        totalWeight += w;
        weightOf[msg.sender] += w;

        uint64 nowTs = uint64(block.timestamp);
        uint64 end = uint64(block.timestamp + years_ * SECONDS_PER_YEAR);
        locks[msg.sender].push(Lock({amount: amount, weight: w, start: nowTs, end: end, withdrawn: false}));
        lockId = locks[msg.sender].length - 1;

        IERC20(address(stakingToken)).safeTransferFrom(msg.sender, address(this), amount);
        emit Locked(msg.sender, lockId, amount, years_, w, end);
    }

    /// @notice Withdraw a lock. After `end`: full principal. Before `end`: burns
    ///         `earlyPenaltyBps` of principal, returns the rest. Rewards are
    ///         unaffected (claim separately).
    function withdraw(uint256 lockId) external nonReentrant updateReward(msg.sender) {
        Lock[] storage userLocks = locks[msg.sender];
        if (lockId >= userLocks.length) revert LS__BadLockId();
        Lock storage l = userLocks[lockId];
        if (l.withdrawn) revert LS__AlreadyWithdrawn();

        l.withdrawn = true;
        totalWeight -= l.weight;
        weightOf[msg.sender] -= l.weight;

        uint256 amount = l.amount;
        uint256 burned = 0;
        if (block.timestamp < l.end) {
            burned = (amount * earlyPenaltyBps) / BPS;
        }
        uint256 returned = amount - burned;

        if (burned > 0) stakingToken.burn(burned);
        if (returned > 0) IERC20(address(stakingToken)).safeTransfer(msg.sender, returned);
        emit Withdrawn(msg.sender, lockId, returned, burned);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    // ============ Reward funding ============

    /// @notice Fund a reward window with `reward` USDC (pulled from caller).
    ///         Called by the RevenueRouter (rewards distributor).
    function notifyRewardAmount(uint256 reward)
        external
        onlyRewardsDistributor
        updateReward(address(0))
    {
        if (reward == 0) revert LS__ZeroAmount();
        rewardsToken.safeTransferFrom(msg.sender, address(this), reward);

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }
        // staking token (TDIRAC) != reward token (USDC), so balance is purely rewards.
        if (rewardRate * rewardsDuration > rewardsToken.balanceOf(address(this))) revert LS__RewardTooHigh();

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward, periodFinish);
    }

    // ============ Admin ============
    function setRewardsDuration(uint256 d) external onlyAdmin {
        if (block.timestamp <= periodFinish) revert LS__PeriodNotFinished();
        if (d == 0) revert LS__BadParam();
        rewardsDuration = d;
        emit RewardsDurationUpdated(d);
    }

    function setMaxLockYears(uint256 y) external onlyAdmin {
        if (y == 0) revert LS__BadParam();
        maxLockYears = y;
        emit MaxLockYearsUpdated(y);
    }

    function setEarlyPenaltyBps(uint256 bps) external onlyAdmin {
        if (bps > BPS) revert LS__BadParam();
        earlyPenaltyBps = bps;
        emit EarlyPenaltyUpdated(bps);
    }

    function setAdmin(address a) external onlyAdmin {
        if (a == address(0)) revert LS__ZeroAddress();
        emit AdminChanged(admin, a);
        admin = a;
    }

    function setRewardsDistributor(address d) external onlyAdmin {
        if (d == address(0)) revert LS__ZeroAddress();
        emit RewardsDistributorChanged(rewardsDistributor, d);
        rewardsDistributor = d;
    }
}
