// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title TDIRAC — Test deployment of the Dirac governance + utility token
/// @notice First-deployment, internal-only version of $DIRAC.
///         Plain ERC20 with `permit` (EIP-2612) and `votes` (ERC20Votes) extensions.
///         No mint after constructor, no pause, no admin/owner, no transfer
///         restrictions — once the multisig holds the supply it has the same
///         rights as any other holder. Treasury operations (seeding DEX pairs,
///         distributing to NFT diamond hands / SAFT signers / team via Sablier,
///         funding the SoulboundReceiptPool, BuyBackEngine target, etc.) are
///         orchestrated off-chain by the multisig via standard ERC20 transfers.
///
///         Why ERC20Votes: Step 6 of the tokenomics roadmap is on-chain DAO
///         votes (whitelist curators, approve strategies, tune revenue split).
///         Votes are checkpoint-based and use either the holder's own balance
///         or a delegated balance; holders must call `delegate(address)` once
///         to make their voting power countable. Default delegation is to the
///         zero address — i.e., un-delegated balance does NOT count toward
///         votes. The DAO contract (Phase 4) will use these checkpoints.
///
///         Why ERC20Permit: gasless approvals — depositors and stakers signing
///         `permit` instead of `approve` is the standard UX nicety.
///
///         Supply: 10_000_000_000 * 1e18 = 10B tokens, all minted in the
///         constructor to the `treasury` argument. After that, totalSupply is
///         immutable (no `mint` exposed). The token can still be burned via
///         `_burn` from within other contracts that the treasury opts in to
///         (e.g. SoulboundReceiptPool burns DIRAC when minting receipts —
///         that burn happens via the standard ERC20 path of calling `_burn`
///         on the pool's own balance, which the pool received from the
///         treasury, so no special role grant is needed here).
contract TDIRAC is ERC20, ERC20Burnable, ERC20Permit, ERC20Votes {
    /// @notice 10 billion tokens, fixed supply, decimals = 18.
    uint256 public constant INITIAL_SUPPLY = 10_000_000_000 * 1e18;

    /// @param treasury Recipient of the entire initial supply. Typically the
    ///                 multisig that will seed DEX pairs and orchestrate the
    ///                 vesting + SoulboundReceiptPool funding.
    constructor(
        address treasury
    )
        ERC20("Test Dirac", "TDIRAC")
        ERC20Permit("Test Dirac")
    {
        require(treasury != address(0), "TDIRAC: zero treasury");
        _mint(treasury, INITIAL_SUPPLY);
    }

    // ============ Required overrides (OZ v5 multi-inheritance) ============

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(
        address owner
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
