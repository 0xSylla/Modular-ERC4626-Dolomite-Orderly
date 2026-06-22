// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title SoulboundReceiptToken
/// @notice Non-transferable receipt token issued by `SoulboundReceiptPool` to
///         contributors of the Dirac protocol (LPs, curators, strategists —
///         per Phase 3 AttributionRegistry rules).
///
///         Standard ERC20 surface for balanceOf / totalSupply visibility (so
///         block explorers, dashboards, and the curator UI can show the
///         "contribution score" cleanly), but ALL transfer paths revert. The
///         token exists only via `mint` (called by the pool) and optionally
///         `burn` (also pool-only — used if the DAO ever votes to slash a
///         contributor).
///
///         Governance: inherits OZ `ERC20Votes` for checkpoint-based voting.
///         On first mint, the contract auto-delegates the recipient to
///         themselves so their voting power counts immediately without a
///         separate `delegate()` tx — same UX rationale as making the token
///         soulbound: the holder has no choice over who holds it, so they
///         shouldn't have to manage delegation either.
///
///         Authorization model: mint/burn are restricted to the immutable
///         `pool` address set in the constructor. There is intentionally no
///         admin / role-based access on this contract — its only role is to
///         be the dumb balance + votes ledger that the pool drives. Any
///         policy lives in the pool.
contract SoulboundReceiptToken is ERC20, ERC20Votes {
    error SoulboundReceiptToken__OnlyPool();
    error SoulboundReceiptToken__NonTransferable();
    error SoulboundReceiptToken__ZeroAddress();

    /// @notice The `SoulboundReceiptPool` contract authorized to mint + burn.
    address public immutable pool;

    modifier onlyPool() {
        if (msg.sender != pool) revert SoulboundReceiptToken__OnlyPool();
        _;
    }

    constructor(
        address _pool
    )
        ERC20("Dirac Soulbound Receipt", "DSR")
        EIP712("Dirac Soulbound Receipt", "1")
    {
        if (_pool == address(0)) revert SoulboundReceiptToken__ZeroAddress();
        pool = _pool;
    }

    // ============ Pool-driven mint / burn ============

    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }

    // ============ Soulbound enforcement + auto-delegation ============

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) {
        // Soulbound: only mint (from == 0) and burn (to == 0) allowed; reject
        // user-to-user transfers. This catches `transfer` and `transferFrom`
        // at the lowest level so neither has to be individually overridden.
        if (from != address(0) && to != address(0)) {
            revert SoulboundReceiptToken__NonTransferable();
        }

        // Auto-delegate to self on first receipt. Without this, ERC20Votes
        // treats a holder who never called `delegate()` as having 0 voting
        // power — which is fine for a tradeable token (user opted in) but
        // is the wrong default for a soulbound token (user has no agency).
        if (from == address(0) && to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }

        super._update(from, to, value);
    }
}
