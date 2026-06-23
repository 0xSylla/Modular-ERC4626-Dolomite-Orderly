// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestUSDC
/// @notice 6-decimal, openly-mintable test stand-in for USDC. Used ONLY for the
///         first tokenomics test deployment to simulate protocol revenue from
///         an arbitrary wallet (mint to it, then call distributeRevenue /
///         notifyRewardAmount). Has NO value and NO access control on mint by
///         design — do not use for anything real.
contract TestUSDC is ERC20 {
    constructor() ERC20("Test USDC", "tUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Anyone can mint test USDC to any address.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
