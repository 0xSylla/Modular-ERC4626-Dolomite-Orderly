# Tokenomics workstream — session handoff

**Purpose:** continue this work in a fresh Claude session without losing context.

## State summary

| Phase | Status | Where |
|---|---|---|
| 1 — `$TDIRAC` ERC20 token | ✅ Done, **tested**, **not deployed** | `src/token/TDIRAC.sol`, `script/DeployTDIRAC.s.sol`, `test/TDIRAC.t.sol`. 11/11 tests pass. |
| 2 — Soulbound layer (`SoulboundReceiptToken` + `SoulboundReceiptPool`) | ✅ Done, **tested**, **not deployed** | `src/token/SoulboundReceiptToken.sol`, `src/token/SoulboundReceiptPool.sol`, `script/DeploySoulboundLayer.s.sol`, `test/SoulboundLayer.t.sol`. 26/26 tests pass. |
| 3 — Attribution engine | ⚠️ **In progress, blocked on design decision** | See below. Files exist on disk and are committed but do **not currently compile** (intentional WIP). |
| 4 — Buyback + Staking + Governance | Not started | — |

Total contracts shipped + tested: **3** (TDIRAC, SoulboundReceiptToken, SoulboundReceiptPool).
Total tests passing: **37** (Phase 1 + 2 combined).

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

## 🔴 Open decision — read before continuing

**Phase 3's "V5 vault hooks" approach is in question.** The user raised this at the end of the previous session and we didn't resolve it.

### What I started building (and committed as WIP)

A new vault tier — `DiracVaultV5` — with attribution hooks built in. This means:
- New `DiracVaultV5.sol` (V4 + ~50 lines of hook code)
- New `DiracVaultFactoryV5.sol` (V4 factory + author tracking)
- Fresh V6 router instance bound to V5 factory
- Migration: users would have to close their V4 vault + redeploy a V5 vault to benefit

### Why the user pushed back

V5 vaults are **only required if you want attribution to be 100% on-chain enforceable**. For a draft/internal phase, that's overkill.

### The cheaper alternative

**V4 + multisig-attested `AttributionRegistry` — no V5 needed.**

Registry adds 3 multisig-callable attestation functions:
- `attestLpsForCycle(vault, cycleId, address[] lps, uint256[] deposits)` — multisig provides the LP list per cycle
- `attestCuratorGate(vault)` — multisig confirms TVL × LP count milestone
- `attestStrategistPerformance(templateId, vault, vaultsCount)` — already off-chain attestation

Registry verifies what it can on-chain (`factory.isVault`, template exists) and trusts the multisig for the rest. The DAO can replace the multisig in Phase 4.

| | V5 (what's WIP) | V4 + multisig attestation |
|---|---|---|
| LP attribution | Fully on-chain at every `closeCycle` | Multisig pushes per-cycle list |
| Curator attribution | Fully on-chain at `deposit` | Multisig pushes confirmation |
| Strategist attribution | Off-chain attested (same) | Off-chain attested (same) |
| Trust model | Code is law | Multisig until DAO replaces |
| Migration burden | New factory, users migrate from V4 → V5 | **None — V4 vaults work today including 0x333970 (your test vault)** |
| Code surface | ~600 LOC of new vault + factory | ~150 LOC of new registry |

### Compile blocker on the V5 path

`DiracVaultFactoryV5` is ~1,200 bytes OVER the EIP-170 limit (`24,576`). I tried trimming by removing the legacy `registerTemplate(bytes32)` overload + `setTemplateAuthor` + `updateOperator`, but `updateOperator` is part of the `IDiracVaultFactory` interface — removing it made the contract abstract. **The WIP commit is in this broken state intentionally.**

If we decide to keep V5, the fix is either:
- Update `IDiracVaultFactory` to remove `updateOperator` (breaks V1-V4 factories if anything imports the interface — check first)
- Or stub `updateOperator` to `revert("removed")` (~50 bytes)
- Or trim something else (e.g., move a chunk to a helper library)

If we switch to V4+multisig attestation, **`DiracVaultV5.sol` and `DiracVaultFactoryV5.sol` get deleted**, and the only Phase 3 contract is `AttributionRegistry.sol` (already written, already compiles, just needs minor adjustments to add the multisig-attestation functions).

## Files written in Phase 3 WIP

| File | Compiles | Action if V5 path | Action if V4+multisig path |
|---|---|---|---|
| `src/interfaces/IAttributionRegistry.sol` | ✅ | Keep, no changes | Keep, no changes (hooks become attestation calls) |
| `src/registry/AttributionRegistry.sol` | ✅ | Keep — already V5-compatible | Adapt: replace `onCycleClose` (vault-callable) with `attestLpsForCycle` (multisig-callable); same for `onCuratorGateHit` → `attestCuratorGate` |
| `src/vault/DiracVaultV5.sol` | ✅ | Keep | **Delete** |
| `src/factory/DiracVaultFactoryV5.sol` | ❌ (1.2k bytes over) | Fix size — either drop `updateOperator` (and update interface) or stub it | **Delete** |

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
`tokenomics-v1` branch in DiracHoneypot. Phases 1+2 are done (TDIRAC +
Soulbound layer, 37 tests passing). Phase 3 is WIP and blocked on a
design decision: V5 vault with on-chain hooks vs V4 + multisig-attested
AttributionRegistry. The user is leaning toward V4 + multisig attestation
to avoid a new vault deploy + migration. The V5 factory also doesn't
compile (~1.2k over EIP-170 limit). My WIP Phase 3 files (V5 vault, V5
factory, AttributionRegistry, interface) are committed but the factory
is broken.

Proposed next step: switch to the V4 + multisig attestation path. Delete
DiracVaultV5.sol and DiracVaultFactoryV5.sol. Adapt AttributionRegistry
to expose attestation functions for the multisig instead of vault hooks.
Write tests + design doc. Ask the user to confirm before proceeding.
```

## Open questions for the team (from `01-overview.md`)

Still open, carried forward from Phase 1:

1. SBT shape — ERC20-like (current default) vs ERC1155 vs ERC721
2. Burn ratio TDIRAC:SBT at launch (1:1 default, 10:1 alternative)
3. Revenue token per chain (USDC on Arbitrum; Berachain TBD)
4. LP diamond-hand bonus weighting (linear in cycle count default)
5. Strategist backtest attestation mechanism (multisig vote v1, on-chain oracle v2)
6. Initial supply allocation breakdown across cohorts
