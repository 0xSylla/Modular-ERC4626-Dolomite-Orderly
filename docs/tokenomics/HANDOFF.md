# Tokenomics workstream — session handoff

**Purpose:** continue this work in a fresh Claude session without losing context.

## State summary

| Phase | Status | Where |
|---|---|---|
| 1 — `$TDIRAC` ERC20 token | ✅ Done, **tested**, **not deployed** | `src/token/TDIRAC.sol`, `script/DeployTDIRAC.s.sol`, `test/TDIRAC.t.sol`. 11/11 tests pass. |
| 2 — Soulbound layer (`SoulboundReceiptToken` + `SoulboundReceiptPool`) | ✅ Done, **tested**, **not deployed** | `src/token/SoulboundReceiptToken.sol`, `src/token/SoulboundReceiptPool.sol`, `script/DeploySoulboundLayer.s.sol`, `test/SoulboundLayer.t.sol`. 26/26 tests pass. |
| 3 — Attribution engine | ✅ **Done, tested, not deployed** (V4 + multisig path). `src/registry/AttributionRegistry.sol`, `src/interfaces/IAttributionRegistry.sol`, `script/DeployAttributionRegistry.s.sol`, `test/AttributionRegistry.t.sol`. 31/31 tests pass. **V5 vault + factory deleted.** | See "Decision resolved" below. |
| 4 — Buyback + Staking + Governance | ✅ **Done, tested, not deployed** | `src/governance/DiracGovernor.sol` + `DiracTimelock.sol`, `src/staking/StakingContract.sol`, `src/buyback/BuyBackEngine.sol`. Deploy scripts + tests for each. 38/38 Phase 4 tests pass. |

Total contracts shipped + tested: **8** (TDIRAC, SoulboundReceiptToken, SoulboundReceiptPool, AttributionRegistry, DiracGovernor, DiracTimelock, StakingContract, BuyBackEngine).
Total tests passing: **106** (P1: 11, P2: 26, P3: 31, P4: 38 = Governance 7 + Staking 17 + BuyBack 14).

## Phase 4 — what shipped + decisions (2026-06-23)

All three Phase 4 pieces built in sequence, V4+multisig-compatible, none deployed.

| Contract | Design | Key decisions |
|---|---|---|
| `DiracGovernor` + `DiracTimelock` | OZ v5 Governor (Settings + CountingSimple + Votes + QuorumFraction + TimelockControl) over TDIRAC. | **Vote clock = block number** (TDIRAC uses default ERC20Votes clock, and it's frozen Phase 1), so voting delay/period are in BLOCKS. Deploy defaults assume ~12s blocks; tunable by governance. Timelock minDelay is in seconds. Executor open (`address(0)`), proposer/canceller = governor, deployer renounces admin. |
| `StakingContract` | **Synthetix duration-based** (rewardRate + periodFinish + rewardPerTokenStored). Stake TDIRAC, earn USDC streamed over `rewardsDuration`. | User chose Synthetix over MasterChef accumulator. staking token (TDIRAC) != reward token (USDC), so the reward-balance invariant is exact. `notifyRewardAmount` pulls USDC from the distributor (approve first). |
| `BuyBackEngine` | **Uniswap V2-style** router (`swapExactTokensForTokens` + path). | User chose V2 over aggregator/V3. **Keeper role** triggers `buyback(amountIn, minOut, deadline)`; bought TDIRAC sent to a **governance-configurable recipient** (pool by default). Path validated USDC->...->TDIRAC. admin can rescue stuck tokens. |

**Revenue split = independent sinks** (user choice): no on-chain splitter. The revenue router calls `pool.distributeRevenue` and `staking.notifyRewardAmount` with whatever split it wants; the buyback feeds the pool's TDIRAC reserve.

**Role handoff to governance (post-deploy, current admin/multisig calls):** `registry.setAdmin(timelock)`, `pool.setAdmin(timelock)`, `staking.setAdmin(timelock)`, `engine.setAdmin(timelock)`. Attester/keeper/distributor roles can stay multisig for speed or move to the timelock. See each deploy script's printed steps.

## Branch + git state

- **Branch:** `tokenomics-v1` (in `DiracHoneypot` repo)
- **Cut from:** `main`
- **Not merged. Will NOT be merged.** User explicitly said this branch lives standalone.
- **Phase 1+2+3 WIP** committed in this branch — see `git log` for the breakdown.

To resume in a new session:
```bash
cd c:/Users/DELL02/Desktop/DiracHoneypot
git checkout tokenomics-v1
git log --oneline -5     # see the commits
```

## ✅ Decision resolved (2026-06-22) — V4 + multisig attestation

**The "V5 vault hooks" approach was discarded.** Phase 3 ships as a single
multisig-attested `AttributionRegistry` against the **live V4 vaults** — no new
vault tier, no new factory, no router redeploy, no user migration. Works with
`0x333970F3524F04759C5e9833b4Caa82b05617c05` (the test vault) today.

`DiracVaultV5.sol` and `DiracVaultFactoryV5.sol` were **deleted** (`git rm`),
which also retires the V5 factory EIP-170 overflow problem entirely.

### What shipped

`src/registry/AttributionRegistry.sol` holds the pool's sole `attributor` role
and exposes 3 attestation functions. It reads only `isVault` + `vaultInfo` from
the live V4 factory (`IDiracFactory`).

| Function | Caller role | On-chain checks |
|---|---|---|
| `attestLpsForCycle(vault, cycleId, lps[], deposits[])` | `attester` | isVault; length match; per-LP `deposit ≥ minLpDeposit`; per-`(vault,cycleId,lp)` de-dup |
| `attestCuratorGate(vault, tvl, uniqueLps)` | `attester` | isVault; one-time latch; attested `tvl ≥ minTvlForCurator` AND `uniqueLps ≥ minUniqueLps` |
| `attestStrategistPerformance(templateId, vault, vaultsUsingTemplate)` | `strategistAttester` | isVault; `vault.templateId` matches; author set; per-`(template,vault)` de-dup; count capped at `maxStrategistVaultsCounted` |

Roles: `admin` (DAO knobs + `setTemplateAuthor` + `burnReceipt` via pool),
`attester` (LP + curator), `strategistAttester` (performance judgment). All
three default to the multisig; admin can rotate each. Phase 4 DAO replaces them.

### Two design choices made this session

1. **LP cycle-hold requirement removed.** LP weight is now purely
   `deposit × lpWeightPerDeposit / 1e6` at the attested snapshot — no
   diamond-hands multiplier. Reintroducible later via attester snapshot timing
   or a DAO knob, no contract change. (User's call.)
2. **Strategist authorship is wired manually in the registry.** The V4 factory
   doesn't track template authors, so `templateAuthor[templateId]` lives in the
   registry, set by admin via `setTemplateAuthor(templateId, author)` — callable
   any time (before/after attestation) and re-pointable. (User asked for the
   ability to connect strategy→strategist later.)

### Phase 3 files (final state)

| File | Status |
|---|---|
| `src/registry/AttributionRegistry.sol` | ✅ rewritten for V4 + multisig |
| `src/interfaces/IAttributionRegistry.sol` | ✅ rewritten to the attestation surface |
| `script/DeployAttributionRegistry.s.sol` | ✅ new — deploys registry + wires `pool.setAttributor` |
| `test/AttributionRegistry.t.sol` | ✅ new — 31 tests, all passing |
| `src/vault/DiracVaultV5.sol` | 🗑️ deleted |
| `src/factory/DiracVaultFactoryV5.sol` | 🗑️ deleted |

### Deploy (when ready)

`DeploySoulboundLayer.s.sol` first (TDIRAC must already exist), then:
```
ADMIN=<multisig> POOL_ADDR=<pool> FACTORY_ADDR=<live V4 factory> \
  forge script script/DeployAttributionRegistry.s.sol --rpc-url $RPC --broadcast
```
Then multisig: `pool.setAttributor(registry)` (the script auto-wires this if the
broadcaster is the pool admin), and `registry.setTemplateAuthor(...)` per
strategist. **Not deployed yet — awaiting go-ahead.**

## Outside the tokenomics scope — other state from this session

Same Claude session also did unrelated production work that the new session may need to know about:

| Workstream | Status |
|---|---|
| **V4 vault + router + factory + user router** deployed to Arbitrum (in `DiracHoneypot/main` branch) | ✅ Done, **deployed**. Addresses:
- V4 Factory: `0xfB1dD48e7b353690938c7c2aBf213e67e4CF8ed2`
- V6 Router (V4 instance): `0x5fdC41244708fA625850989aB8093ad6b0382280`
- User Router (V4): `0x94803489321d719bc3f9e51bcfca142726b8f6ea` |
| **api-v2 Heroku app** pointed at V4 + 4 patches (`v8` gas, `v9` 429-retry, `v10` unknown-reason regex, `v12` extended retry budget) | ✅ Live (release v12) |
| **User's Vercel update** to V4 frontend addresses | ⚠️ Pending user action — see DiracHoneypot/docs/tokenomics/HANDOFF.md or the V4 deploy summary |
| **Test V4 vault `0x333970F3524F04759C5e9833b4Caa82b05617c05`** | Active, ACTIVE position, used to validate v12 retry-budget patch |

## Prompt to use in the new session

```
Continue from the previous session's tokenomics workstream.

Read docs/tokenomics/HANDOFF.md first for full context. We're on the
`tokenomics-v1` branch in DiracHoneypot. Phases 1-4 are ALL done, tested,
NOT deployed (106 tests passing). Nothing is blocked. The whole 8-step
tokenomics stack exists as contracts + deploy scripts + tests: TDIRAC,
Soulbound layer, AttributionRegistry (V4+multisig), DiracGovernor+Timelock,
StakingContract (Synthetix), BuyBackEngine (V2 router).

Remaining work is OPERATIONAL, not new contracts:
- Deployment (chain order, ADMIN/multisig address, revenue token per chain,
  DEX router + path, voting-period block counts) — nothing deployed yet.
- Role handoff wiring to the timelock (see the deploy scripts' printed steps).
- Possible integrations: where protocol revenue actually gets routed from
  (vault perf fees / curator router skim) into pool + staking + buyback.
- Open team questions in 01-overview.md (SBT shape, burn ratio, supply
  allocation) remain.
Ask the user which of these to do before writing code.
```

## Open questions for the team (from `01-overview.md`)

Still open, carried forward from Phase 1:

1. SBT shape — ERC20-like (current default) vs ERC1155 vs ERC721
2. Burn ratio TDIRAC:SBT at launch (1:1 default, 10:1 alternative)
3. Revenue token per chain (USDC on Arbitrum; Berachain TBD)
4. LP diamond-hand bonus weighting — **resolved (2026-06-22): cycle-hold gate removed; weight = deposit only.** Reintroducible later.
5. Strategist backtest attestation mechanism — **resolved (2026-06-22): multisig `strategistAttester` for v1**; on-chain oracle deferred to a later rev
6. Initial supply allocation breakdown across cohorts
