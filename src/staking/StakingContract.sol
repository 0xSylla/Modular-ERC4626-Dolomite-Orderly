// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title StakingContract
/// @notice Phase 4 staking — stake TDIRAC, earn a share of protocol revenue
///         (USDC) streamed linearly over a reward window. Synthetix
///         `StakingRewards`-style accounting (rewardRate + rewardPerTokenStored
///         + periodFinish), which smooths lumpy revenue drops over the
///         `rewardsDuration` rather than paying them out instantly.
///
///         **Independent revenue sink.** This contract is funded separately
///         from the SoulboundReceiptPool. The revenue router (multisig now,
///         BuyBackEngine / governance later) decides how much USDC to send
///         here vs. to the pool by calling `notifyRewardAmount` here and
///         `distributeRevenue` on the pool — the split is a routing policy,
///         not hardcoded on-chain.
///
///         Distinct from SBT distribution: SBT rewards are attribution-based
///         (you earned them by acting); staking rewards are capital-locked
///         (you earned them by staking TDIRAC). The two streams don't overlap.
///
///         **Token note:** `stakingToken` (TDIRAC, 18dec) and `rewardsToken`
///         (USDC, 6dec) are different contracts, so the Synthetix
///         "reward balance" invariant in `notifyRewardAmount` is exact — the
///         contract's reward-token balance is never commingled with stakes.
contract StakingContract is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e18;

    // ============ Immutables ============

    /// @notice Token users stake (TDIRAC).
    IERC20 public immutable stakingToken;
    /// @notice Token rewards are paid in (USDC in v1).
    IERC20 public immutable rewardsToken;

    // ============ Roles ============

    /// @notice Tunes `rewardsDuration`, rotates roles. Multisig in Phase 4
    ///         start; handed to the DiracTimelock (governance) after.
    address public admin;
    /// @notice Authorized to fund rewards via `notifyRewardAmount`. Multisig /
    ///         treasury / BuyBackEngine / governance.
    address public rewardsDistributor;

    // ============ Reward state (Synthetix) ============

    /// @notice Length of each reward window, in seconds.
    uint256 public rewardsDuration;
    /// @notice Timestamp the current reward window ends.
    uint256 public periodFinish;
    /// @notice Reward tokens distributed per second during the window.
    uint256 public rewardRate;
    /// @notice Last time reward accounting was updated.
    uint256 public lastUpdateTime;
    /// @notice Accumulated reward per staked token, scaled by PRECISION.
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // ============ Stake bookkeeping ============

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // ============ Events ============

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward, uint256 periodFinish);
    event RewardsDurationUpdated(uint256 newDuration);
    event AdminChanged(address indexed prev, address indexed next);
    event RewardsDistributorChanged(address indexed prev, address indexed next);

    // ============ Errors ============

    error Staking__OnlyAdmin();
    error Staking__OnlyRewardsDistributor();
    error Staking__ZeroAddress();
    error Staking__ZeroAmount();
    error Staking__RewardTooHigh();
    error Staking__PeriodNotFinished();
    error Staking__ZeroDuration();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Staking__OnlyAdmin();
        _;
    }

    modifier onlyRewardsDistributor() {
        if (msg.sender != rewardsDistributor) revert Staking__OnlyRewardsDistributor();
        _;
    }

    /// @dev Settles global + per-account reward accounting before any state
    ///      change. Pass address(0) for global-only updates (e.g. notify).
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    constructor(
        address _stakingToken,
        address _rewardsToken,
        address _admin,
        address _rewardsDistributor,
        uint256 _rewardsDuration
    ) {
        if (
            _stakingToken == address(0) || _rewardsToken == address(0) || _admin == address(0)
                || _rewardsDistributor == address(0)
        ) revert Staking__ZeroAddress();
        if (_rewardsDuration == 0) revert Staking__ZeroDuration();

        stakingToken = IERC20(_stakingToken);
        rewardsToken = IERC20(_rewardsToken);
        admin = _admin;
        rewardsDistributor = _rewardsDistributor;
        rewardsDuration = _rewardsDuration;
    }

    // ============ Views ============

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / PRECISION
            + rewards[account];
    }

    /// @notice Total reward tokens that will be paid over the current window.
    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    // ============ Stake / withdraw / claim ============

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert Staking__ZeroAmount();
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert Staking__ZeroAmount();
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice Withdraw the full stake and claim rewards in one call.
    function exit() external {
        withdraw(balanceOf[msg.sender]);
        getReward();
    }

    // ============ Reward funding ============

    /// @notice Fund a new reward window with `reward` USDC, pulled from the
    ///         caller (the rewards distributor must `approve` first). If a
    ///         window is in progress, the unstreamed remainder is rolled into
    ///         the new rate. Streams over `rewardsDuration` from now.
    function notifyRewardAmount(uint256 reward)
        external
        onlyRewardsDistributor
        updateReward(address(0))
    {
        if (reward == 0) revert Staking__ZeroAmount();
        rewardsToken.safeTransferFrom(msg.sender, address(this), reward);

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        // Invariant: the contract actually holds enough reward tokens to cover
        // the rate for the full window. Exact here because stakingToken !=
        // rewardsToken (no stake commingling).
        if (rewardRate * rewardsDuration > rewardsToken.balanceOf(address(this))) {
            revert Staking__RewardTooHigh();
        }

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward, periodFinish);
    }

    // ============ Admin ============

    /// @notice Change the reward window length. Only between windows so it
    ///         can't retroactively rescale an in-flight stream.
    function setRewardsDuration(uint256 newDuration) external onlyAdmin {
        if (block.timestamp <= periodFinish) revert Staking__PeriodNotFinished();
        if (newDuration == 0) revert Staking__ZeroDuration();
        rewardsDuration = newDuration;
        emit RewardsDurationUpdated(newDuration);
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert Staking__ZeroAddress();
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    function setRewardsDistributor(address newDistributor) external onlyAdmin {
        if (newDistributor == address(0)) revert Staking__ZeroAddress();
        emit RewardsDistributorChanged(rewardsDistributor, newDistributor);
        rewardsDistributor = newDistributor;
    }
}
