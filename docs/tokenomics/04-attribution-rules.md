# Attribution rules — concrete proposals

**Status:** draft. Numbers are DAO-tunable starting points, not final.
**Boss's framing (verbatim from chat):**

> On doit être un peu plus spécifique sur les règles d'attribution, qui seront dans tous les cas votées par DAO avant d'être mises en place.
>
> - LP touche des SPT s'il risque son argent durant au moins un cycle complet
> - Curator s'il déploie un vault qui atteint au moins 10k TVL avec 10 LPs différents
> - Stratégist si la stratégie a été déployée au moins une fois et a répondu conformément au backtest

Below: a concrete on-chain enforceable version of each, with edge-case rulings and the DAO-tunable knobs called out.

---

## Actor 1 — LP (depositor)

### Rule

Mint SBT to an LP when their `deposit` for the attested cycle was ≥ `MIN_LP_DEPOSIT` USDC.

**Weight per mint:** `weight = deposit × LP_WEIGHT_PER_DEPOSIT / 1e6` (USDC scale). Default
`LP_WEIGHT_PER_DEPOSIT = 1e18` → 1 SBT per 1 USDC of deposit.

> **Cycle-hold requirement removed (2026-06-22 decision).** The earlier rule
> required holding across a full `TRADING → CLOSED` boundary and weighted by
> `cyclesHeld`. For the draft phase we attribute purely on deposit size at the
> attested snapshot. The diamond-hands multiplier can be reintroduced later as
> a DAO knob without a contract change (the attester simply chooses the
> snapshot timing).

### DAO-tunable knobs

| Param | Default | Notes |
|---|---|---|
| `minLpDeposit` | 100 USDC | Dust floor — prevents 1¢ deposit gaming |
| `lpWeightPerDeposit` | 1e18 | 1 SBT per 1 USDC of deposit (at USDC 6dec) |

### On-chain enforceability

⚠️ **Multisig-attested (V4 path).** No vault changes. The multisig (`attester`
role) reads the per-cycle LP list off-chain and calls
`attestLpsForCycle(vault, cycleId, lps[], deposits[])`. The registry verifies
the caller, that `vault` is a factory vault, the per-LP deposit floor, and
de-dups per `(vault, cycleId, lp)` — then mints. In Phase 4 the DAO can move
this to on-chain enforcement if desired.

### Edge cases

| Case | Ruling |
|---|---|
| LP below `minLpDeposit` for the cycle | **No SBT** — silently skipped, not reverted |
| Same LP attested twice in one cycle | **One mint** — `(vault, cycleId, lp)` de-dup latch |
| LP attested across cycles 1 and 2 | **2 mints**, one per cycle (different de-dup keys) |
| Attester supplies zero address / zero-weight entry | **Skipped** — no mint |
| `lps.length != deposits.length` | **Reverts** `AR__LengthMismatch` |
| `vault` not from the factory | **Reverts** `AR__NotFactoryVault` |

---

## Actor 2 — Curator (vault deployer)

### Rule

Mint SBT to a Curator when their deployed vault FIRST simultaneously satisfies:
1. `totalAssets() ≥ MIN_TVL_FOR_CURATOR_SBT` (in deposit-token units), AND
2. `uniqueDepositorCount ≥ MIN_UNIQUE_LPS`

This is a **one-time mint per vault** — hitting the threshold a second time after a dip does not re-mint. Crossing the threshold is the rare milestone we're rewarding.

**Weight per mint:** flat `CURATOR_SBT_BASE_WEIGHT`, plus optional bonus tier above 100k TVL.

> Rationale: deploying empty vaults is free; the curator's value is in
> attracting capital + community. The TVL × LP-count joint condition stops
> a single whale from "fake-curating" by self-depositing 10k from one wallet.

### DAO-tunable knobs

| Param | Default | Notes |
|---|---|---|
| `MIN_TVL_FOR_CURATOR_SBT` | 10_000 USDC | Boss's number |
| `MIN_UNIQUE_LPS` | 10 | Boss's number |
| `CURATOR_SBT_BASE_WEIGHT` | 1000 (units of SBT) | Base for hitting the gate |
| `CURATOR_SBT_TIER_BONUS` | +500 per 10x TVL above base | Optional; capped at 4 tiers |
| `UNIQUE_LP_LOOKBACK_WINDOW` | infinite (all-time) | DAO could constrain to last 90 days |

### On-chain enforceability

⚠️ **Multisig-attested (V4 path).** `totalAssets()` is on-chain but
`uniqueDepositorCount` is not (V3+ `totalUsers` decrements on withdrawal, so it
isn't a historical-unique count). Rather than ship a V5 vault with
`hasEverDeposited`, the multisig (`attester` role) calls
`attestCuratorGate(vault, tvl, uniqueLps)`. The registry **re-checks the
attested `tvl ≥ minTvlForCurator` AND `uniqueLps ≥ minUniqueLps`** against the
on-chain thresholds (so the attester can't mint for a sub-threshold vault
without explicitly lying, and both numbers are logged in the event), confirms
`vault` is a factory vault, enforces the one-time latch, and mints to
`vaultInfo.creator`.

> **Decision resolved (2026-06-22):** V4 + multisig attestation, no V5 vault.
> See `HANDOFF.md`. A future rev can add `hasEverDeposited` on-chain if the DAO
> wants the curator gate to be trustless.

### Edge cases

| Case | Ruling |
|---|---|
| Vault hits 10k TVL + 10 LPs, then drops to 9k. Does dropping back un-attribute? | **No.** SBT mint is one-time on first crossing. Already-minted SBT stays. |
| 11 LPs but 1 of them is the curator self-depositing | **Counts as 11.** We don't gate self-deposits — the curator is also a risk-taker. Whale-gaming protection comes from the TVL × LP-count joint requirement, not from disqualifying the curator. |
| Multiple co-curators (multisig deploys) | **The deployer address (`msg.sender` on `factory.createVault`) gets the SBT.** Co-curators split offline. |
| Curator deploys 5 vaults | **5 separate SBTs, one per vault that hits the gate.** |
| Curator deploys 5 vaults, only 1 hits the gate | **1 SBT.** No "best-of" or stacking. |

---

## Actor 3 — Strategist (template author)

### Rule

Mint SBT to a Strategist when their `templateId` (the strategy recipe registered in the factory) has:
1. Been used by at least 1 deployed vault, AND
2. That vault's realized performance has been **attested as "in line with backtest"** by the `STRATEGIST_BACKTEST_ATTESTER` (a multisig or oracle).

**Weight per mint:** `STRATEGIST_SBT_BASE_WEIGHT × numVaultsUsingTemplate` (capped at `MAX_STRATEGIST_VAULTS_COUNTED` to prevent runaway dilution).

> Rationale: "A répondu conformément au backtest" is by far the hardest of
> the three rules to verify on-chain, because "in line with backtest" is
> not a single number — it's a comparison of realized P&L vs simulated
> P&L across volatile market conditions. For v1, we delegate that judgment
> to a multisig (the DAO can vote on attestations). v2 can move to an
> on-chain oracle that compares realized APY ± tolerance band to the
> backtested APY.

### DAO-tunable knobs

| Param | Default | Notes |
|---|---|---|
| `STRATEGIST_BACKTEST_ATTESTER` | Dirac multisig | Will become DAO governor in Phase 4 |
| `STRATEGIST_SBT_BASE_WEIGHT` | 2000 (units) | Higher than curator base because authoring a strategy is rarer |
| `MAX_STRATEGIST_VAULTS_COUNTED` | 5 | One template adopted by 100 vaults shouldn't 100x the strategist |
| `BACKTEST_TOLERANCE_BPS` | n/a in v1 (manual attestation) | In v2: realized APY must be within ±X bps of backtested APY across the window |

### On-chain enforceability

⚠️ **Multisig-attested (V4 path).** The strategist attester (multisig) calls
`attestStrategistPerformance(templateId, vault, vaultsUsingTemplate)`. The
registry verifies `vault` is a factory vault, that `vault.templateId` matches,
and that a `templateAuthor` is set, then mints `strategistBaseSbt ×
min(vaultsUsingTemplate, maxStrategistVaultsCounted)` to the author.

> **Authorship is wired manually.** The live V4 factory does NOT record template
> authors, so authorship lives in the registry: admin/multisig calls
> `setTemplateAuthor(templateId, strategist)` whenever convenient — before or
> after the performance attestation, and re-pointable. `vaultsUsingTemplate` is
> supplied by the attester (trusted, governance-correctable) since the V4
> factory doesn't enumerate per-template vault counts.

### Edge cases

| Case | Ruling |
|---|---|
| Strategist's template is registered but never used | **No SBT.** Deployment of the template alone doesn't qualify. |
| Template used, vault loses money but stays within backtest bounds | **SBT.** "In line with backtest" includes drawdowns that the backtest also showed. The standard is the backtest's risk profile, not "positive APY." |
| Template used, vault way outperforms backtest | **SBT** — outperformance is still "consistent with backtest" in the loose sense. (DAO can decide to require ±tolerance both ways.) |
| Template used, vault way underperforms backtest | **No SBT** — fails the "in line with backtest" gate. |
| Strategist is also the curator that deployed the vault using their template | **Both SBTs** — distinct attribution events, no double-counting concern. |
| Multiple strategists collaborate on a template | **Single SBT to the address that registered the template.** Splits off-chain. |
| Backtest itself is fraudulent / cherry-picked | This is a curation problem upstream — the multisig should reject registering bad templates. Once registered, this rule trusts the backtest. |

---

## Summary table

| Actor | Gate | Mint timing | Weight formula | DAO knobs |
|---|---|---|---|---|
| LP | `deposit ≥ minLpDeposit` for the attested cycle | When multisig attests the cycle | `deposit × lpWeightPerDeposit / 1e6` | `minLpDeposit`, `lpWeightPerDeposit` |
| Curator | Vault first hits `minTvlForCurator` AND `minUniqueLps` jointly | Once per vault, when multisig attests | `curatorBaseSbt` | `minTvlForCurator`, `minUniqueLps`, `curatorBaseSbt` |
| Strategist | Template used by ≥1 vault AND backtest-attested AND author wired | When multisig attests | `strategistBaseSbt × min(numVaults, cap)` | attester, base, `maxStrategistVaultsCounted` |

## Implementation (Phase 3 — shipped, V4 + multisig path)

`src/registry/AttributionRegistry.sol` (tested in `test/AttributionRegistry.t.sol`,
31 tests). Multisig-attested — no vault/factory/router changes; works with the
live V4 vaults including `0x333970…`.

```solidity
contract AttributionRegistry is IAttributionRegistry {
    // Roles: admin (DAO knobs), attester (LP+curator), strategistAttester
    // DAO-tunable: minLpDeposit, lpWeightPerDeposit, minTvlForCurator,
    //              minUniqueLps, curatorBaseSbt, strategistBaseSbt,
    //              maxStrategistVaultsCounted
    // Authorship wired manually: templateAuthor[templateId] via setTemplateAuthor

    function attestLpsForCycle(address vault, uint256 cycleId,
        address[] calldata lps, uint256[] calldata deposits) external onlyAttester;
    function attestCuratorGate(address vault, uint256 tvl, uint256 uniqueLps) external onlyAttester;
    function attestStrategistPerformance(bytes32 templateId, address vault,
        uint256 vaultsUsingTemplate) external onlyStrategistAttester;
}
```

The registry holds the pool's sole `attributor` role — nobody mints receipts
except through here. It reads only `factory.isVault` + `factory.vaultInfo` from
the live V4 factory.

## What V4 + multisig trades away vs. the (discarded) V5 path

| | V5 hooks (discarded) | V4 + multisig (shipped) |
|---|---|---|
| LP attribution | vault calls registry at `closeCycle` | multisig pushes per-cycle list |
| Curator attribution | vault calls registry at `deposit` | multisig confirms milestone |
| Strategist | identical (multisig-attested either way) | identical |
| Migration | users close V4 → redeploy V5 | none |
| Trust | code-is-law | multisig until Phase 4 DAO |

The DAO can replace the `attester`/`strategistAttester` (and `burnReceipt`
gamed mints via the pool) in Phase 4, converging both paths on the same trust
model. See `HANDOFF.md` for the full decision record.
