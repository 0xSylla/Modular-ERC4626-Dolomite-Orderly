// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DiracFaucet
/// @notice Test-only faucet that dispenses a fixed amount of $DIRAC (TDIRAC) per
///         address on a cooldown. TDIRAC is fixed-supply with no public mint, so
///         this faucet hands out from a balance the admin pre-funds it with (a
///         plain ERC20 transfer to this contract). For the tokenomics first
///         test only — no value, abuse-bounded by the cooldown.
contract DiracFaucet {
    using SafeERC20 for IERC20;

    IERC20 public immutable token; // TDIRAC
    address public admin;
    uint256 public dripAmount;     // tokens per claim (wei)
    uint256 public cooldown;       // seconds between claims per address

    mapping(address => uint256) public lastClaim;

    event Dripped(address indexed to, uint256 amount);
    event DripAmountUpdated(uint256 amount);
    event CooldownUpdated(uint256 cooldown);
    event AdminChanged(address indexed prev, address indexed next);
    event Withdrawn(address indexed to, uint256 amount);

    error Faucet__OnlyAdmin();
    error Faucet__ZeroAddress();
    error Faucet__CooldownActive(uint256 readyAt);
    error Faucet__Empty();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Faucet__OnlyAdmin();
        _;
    }

    constructor(address _token, address _admin, uint256 _dripAmount, uint256 _cooldown) {
        if (_token == address(0) || _admin == address(0)) revert Faucet__ZeroAddress();
        token = IERC20(_token);
        admin = _admin;
        dripAmount = _dripAmount;
        cooldown = _cooldown;
    }

    /// @notice Claim `dripAmount` TDIRAC. Reverts if still on cooldown or the
    ///         faucet is out of funds.
    function drip() external {
        uint256 ready = lastClaim[msg.sender] + cooldown;
        if (block.timestamp < ready) revert Faucet__CooldownActive(ready);
        if (token.balanceOf(address(this)) < dripAmount) revert Faucet__Empty();
        lastClaim[msg.sender] = block.timestamp;
        token.safeTransfer(msg.sender, dripAmount);
        emit Dripped(msg.sender, dripAmount);
    }

    /// @notice Seconds until `user` can claim again (0 = ready now).
    function timeUntilNextClaim(address user) external view returns (uint256) {
        uint256 ready = lastClaim[user] + cooldown;
        return block.timestamp >= ready ? 0 : ready - block.timestamp;
    }

    function balance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    // ============ Admin ============
    function setDripAmount(uint256 a) external onlyAdmin { dripAmount = a; emit DripAmountUpdated(a); }
    function setCooldown(uint256 c) external onlyAdmin { cooldown = c; emit CooldownUpdated(c); }

    function setAdmin(address a) external onlyAdmin {
        if (a == address(0)) revert Faucet__ZeroAddress();
        emit AdminChanged(admin, a);
        admin = a;
    }

    /// @notice Reclaim unused faucet funds.
    function withdraw(address to, uint256 amount) external onlyAdmin {
        if (to == address(0)) revert Faucet__ZeroAddress();
        token.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }
}
