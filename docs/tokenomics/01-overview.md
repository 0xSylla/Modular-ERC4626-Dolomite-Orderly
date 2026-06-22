# Dirac tokenomics — internal draft overview

**Status:** draft, internal-only. Not announced. Live code where indicated.

## 8-step flow

```
┌────────────────────────────────────────────────────────────────────────┐
│ Step 1 (LIVE - Phase 1)                                                │
│   Multisig deploys TDIRAC (10B fixed supply, ERC20 + Permit + Votes).  │
│   Multisig seeds DEX pairs (TDIRAC / USDC) and holds DAO treasury.     │
└────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Step 2 (off-chain orchestration)                                       │
│   Multisig sets up Sablier streams for:                                │
│     - NFT "diamond hands" cohort (cliff + vesting)                     │
│     - SAFT signers (cliff + vesting)                                   │
│     - Team / advisors (cliff + vesting)                                │
└────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Step 3 (Phase 2 — TBD)                                                 │
│   SoulboundReceiptPool deployed. Multisig transfers a reserve of       │
│   TDIRAC into it. Each time the pool mints a SoulboundReceiptToken     │
│   (SBT), it burns 1:1 (or DAO-tuned ratio) of its TDIRAC reserve.      │
│   SBT is non-transferable.                                             │
└────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Step 4 (Phase 3 — boss's main concern)                                 │
│   Attribution: incentivized actions automatically trigger SBT mint.   │
│   Three actor types: LP, Curator, Strategist. Rules in [04-attribution-│
│   rules.md].                                                           │
└────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Step 5 (Phase 4)                                                       │
│   Revenue routing: a DAO-tunable % of protocol revenue (vault fees,    │
│   curator router fees, anything else) flows to the SoulboundReceipt-   │
│   Pool. Pool distributes pro-rata to SBT holders.                      │
└────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Step 6 (Phase 4)                                                       │
│   On-chain DAO governance using TDIRAC's ERC20Votes checkpoints:       │
│     - Whitelist new curators                                           │
│     - Approve new strategy templates                                   │
│     - Tune revenue split %                                             │
│     - Tune attribution thresholds                                      │
└────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Step 7 (Phase 4)                                                       │
│   BuyBackEngine: drains a portion of protocol revenue, market-buys     │
│   TDIRAC on the DEX, transfers the bought TDIRAC to SoulboundReceipt-  │
│   Pool. Creates buy pressure + replenishes the pool's burn reserve.    │
└────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Step 8 (Phase 4)                                                       │
│   StakingContract: stake TDIRAC to receive a tunable % of revenue.    │
│   Likely a Synthetix-style rewards distributor. Distinct from SBT     │
│   distribution (SBT = attribution-based, Staking = capital-locked).   │
└────────────────────────────────────────────────────────────────────────┘
```

## Phase plan

| Phase | Status | Scope | Contracts |
|---|---|---|---|
| **1** | ✅ this session | Token + deploy | `TDIRAC.sol` |
| 2 | TBD | Soulbound layer | `SoulboundReceiptToken.sol`, `SoulboundReceiptPool.sol` |
| 3 | TBD | Attribution engine (boss's main ask) | `AttributionRegistry.sol`, hooks into V4 factory + V6 router + vault |
| 4 | TBD | Revenue + governance | `BuyBackEngine.sol`, `StakingContract.sol`, `DiracGovernor.sol` (OZ Governor) |

## Phase 1 deliverables (this session)

| File | Purpose |
|---|---|
| `src/token/TDIRAC.sol` | ERC20 + Permit + Votes, 10B fixed supply, mints to `treasury` arg. No mint after constructor. |
| `script/DeployTDIRAC.s.sol` | Reads `ADMIN` env var, deploys, mints. Same script for Arbitrum + Berachain. |
| `test/TDIRAC.t.sol` | 11 tests — supply, metadata, transfer, permit, votes (delegation + checkpoints), no-mint-after-deploy guard. All passing. |
| `docs/tokenomics/01-overview.md` | This file. |
| `docs/tokenomics/04-attribution-rules.md` | Concrete proposals for boss's Point 4 concern. |

## Key design decisions made in Phase 1

1. **Single token, both chains, different addresses.** No CREATE2 / cross-chain salting. Bridging deferred to a later phase. Arbitrum-first since the curator framework lives there.

2. **Plain ERC20 — no admin, no pause, no mint, no transfer hooks.** Anything fancier is a footgun for a token that will trade on DEXes. Treasury operations are off-chain multisig actions.

3. **ERC20Votes is opt-in via `delegate()`.** Holders must call `delegate(self)` or `delegate(other)` once to make their voting power countable. Default is zero. This is the OZ standard and matches Compound / Uniswap conventions.

4. **Burn-on-mint flow uses standard ERC20 `_burn`.** No special role grants needed — the SoulboundReceiptPool will burn from its own balance, which the multisig pre-funded it with. Keeps TDIRAC dumb.

5. **"TDIRAC" symbol** signals internal/test status. Renaming for prod launch is a separate (and expensive) decision — would require a new deploy + migration / wrapper.

## Open questions (for team discussion)

| # | Question | Default if no answer |
|---|---|---|
| 1 | Should Phase 2's SoulboundReceiptToken be ERC721 (one NFT per attribution event, with `weight` field) or ERC1155 (multiple "shares" per user) or ERC20-like non-transferable? | **ERC1155 with `weight` per id** — flexible for revenue math, gas-cheap on batch claim |
| 2 | What's the TDIRAC:SBT mint ratio? Fixed 1:1, or weighted by action value? | **1:1 for v1**; DAO can change |
| 3 | Where does protocol revenue come from? Vault performance fee? Curator router skim? Both? | Both — defaults: 10% of vault perf fees, 0% of curator skim |
| 4 | LP attribution: do "diamond hands" (held through multiple cycles) get bonus weight? | **Yes, linear in cycle count** — see [04-attribution-rules.md](04-attribution-rules.md) |
| 5 | Strategist "in line with backtest" — who attests? Off-chain oracle, DAO multisig vote, or auto-computed from realized vs. backtest delta? | **DAO multisig** for v1 (simplest); upgrade to auto-computed later |
| 6 | Initial supply allocation breakdown across cohorts? | TBD — needs separate doc once boss confirms percentages |

## Deployment status (Phase 1)

- ❌ Not deployed yet (waiting for explicit go-ahead + `ADMIN` address from multisig)
- ✅ Compiles
- ✅ 11/11 tests pass
- ✅ Script ready: `ADMIN=0x... forge script script/DeployTDIRAC.s.sol --rpc-url $RPC --broadcast`
