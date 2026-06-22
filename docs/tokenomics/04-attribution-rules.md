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

Mint SBT to an LP when:
1. Their `userDeposit` was ≥ `MIN_LP_DEPOSIT` USDC at some point in a cycle, AND
2. They held their position through ≥ `MIN_CYCLES_FOR_LP_SBT` full cycle transitions
   (i.e., their balance was non-zero across at least one `TRADING → CLOSED` boundary).

**Weight per mint:** `weight = userDeposit_at_cycle_start × cyclesHeld`

> Rationale: "Risqué son argent durant au moins un cycle complet" maps cleanly
> to "held a balance across at least one TRADING window." A deposit made
> during DEPOSIT_OPEN and withdrawn before TRADING does NOT qualify — no risk
> was actually taken.

### DAO-tunable knobs

| Param | Default | Notes |
|---|---|---|
| `MIN_LP_DEPOSIT` | 100 USDC | Dust floor — prevents 1¢ deposit gaming |
| `MIN_CYCLES_FOR_LP_SBT` | 1 | Boss's wording = 1 full cycle |
| `LP_WEIGHT_FORMULA` | `deposit × cyclesHeld` | DAO can switch to `deposit × sqrt(cyclesHeld)` to soften long-tail rewards |

### On-chain enforceability

✅ **Fully on-chain.** The vault tracks `userDeposits[receiver]` (V3+ already does this) and emits `CycleStatusChanged` on every transition. The Attribution module subscribes to these signals and increments a per-user counter. SBT mint is automatic in `closeCycle()` for any LP whose `userDeposits[u] > 0` at that boundary.

### Edge cases

| Case | Ruling |
|---|---|
| LP deposits during DEPOSIT_OPEN, withdraws before TRADING starts | **No SBT** — never had skin in the game |
| LP deposits during DEPOSIT_OPEN, balance still > 0 when cycle closes | **SBT, weight = deposit × 1 cycle** |
| LP holds across 5 cycles without exit | **SBT, weight = avg_deposit × 5 cycles** (cumulative — minted once per cycle close, not as a single big mint at end) |
| LP partially withdraws mid-cycle | **No new SBT for the withdrawn portion**; the remaining balance continues to accrue if still ≥ `MIN_LP_DEPOSIT` |
| Two cycles back-to-back, LP holds through both | **2 SBT mints**, one per cycle close |
| Vault is closed (no new cycles) | LP's last cycle's SBT is the final attribution; no further mints |

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

⚠️ **Partial.** `totalAssets()` is on-chain. `uniqueDepositorCount` requires the vault (or a helper) to track distinct depositor addresses — V3+ tracks `totalUsers` already, but it increments and decrements naively (every full withdrawal decrements). A more correct implementation tracks **historical unique depositors** in a `mapping(address => bool) hasEverDeposited`. We'll add this to a V5 vault (or implement off-chain with an indexer if we don't want a new vault rev).

> **Decision needed:** add `hasEverDeposited` to a V5 vault (clean) or do it off-chain via an indexer (faster to ship, requires trusting the off-chain oracle)? My recommendation: **on-chain in V5**, since the attribution is permanent and should be censorship-resistant.

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

⚠️ **Hybrid.** The "template used by N vaults" check is on-chain (factory tracks templates). The "in line with backtest" check is the multisig calling `attestStrategistPerformance(templateId, vaultAddress)`. After attestation, the SBT mint is automatic.

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
| LP | Deposit ≥ `MIN_LP_DEPOSIT` AND held through ≥ `MIN_CYCLES_FOR_LP_SBT` cycle close(s) | At each cycle close, automatic | `deposit × cyclesHeld` | `MIN_LP_DEPOSIT`, `MIN_CYCLES_FOR_LP_SBT`, formula |
| Curator | Vault first hits `MIN_TVL` AND `MIN_UNIQUE_LPS` jointly | Once per vault, automatic | `BASE_WEIGHT + tier_bonus` | `MIN_TVL`, `MIN_UNIQUE_LPS`, base, tier bonuses |
| Strategist | Template used by ≥1 vault AND backtest-attested | After attestation by multisig | `BASE_WEIGHT × numVaults` (capped) | Attester address, base, max-vaults cap, tolerance |

## Pseudocode for the attribution module (Phase 3)

```solidity
contract AttributionRegistry {
    // DAO-tunable params (storage; set via governor)
    uint256 public minLpDeposit;
    uint256 public minCyclesForLpSbt;
    uint256 public minTvlForCuratorSbt;
    uint256 public minUniqueLps;
    address public strategistBacktestAttester;
    uint256 public maxStrategistVaultsCounted;
    // ... weights, tier bonuses, etc.

    // Mints called by hooks in vault / factory / router
    function onCycleClose(address vault) external onlyFactoryVault {
        // For every LP with userDeposits[u] >= minLpDeposit at this point,
        // mint SBT to u with weight = deposit × 1 (this cycle)
    }

    function onVaultThresholdHit(address vault) external onlyFactoryVault {
        // Called from vault.deposit() when TVL × uniqueLPs first crosses
        require(!curatorAttributed[vault], "already attributed");
        // Mint to vaultInfo.curator (= original creator)
    }

    function attestStrategistPerformance(bytes32 templateId, address vault) external {
        require(msg.sender == strategistBacktestAttester, "not attester");
        // Mint to template author with weight = base × min(vaultsUsingTemplate, maxCap)
    }
}
```

## Integration touchpoints (Phase 3 deliverables, not in this session)

| Existing contract | Hook needed | Why |
|---|---|---|
| V5 Vault (forked from V4) | `closeCycle()` — call `AttributionRegistry.onCycleClose(address(this))` before returning | LP attribution at cycle boundary |
| V5 Vault | `deposit()` — after the per-user state update, if `(totalAssets, uniqueLPs)` newly crosses gate, call `AttributionRegistry.onVaultThresholdHit(this)` | Curator attribution at TVL milestone |
| V5 Vault | Add `mapping(address => bool) hasEverDeposited` and `uint256 uniqueDepositorCount` (incremented only on first deposit, never decremented) | Needed for the curator gate (current `totalUsers` is bidirectional) |
| V5 Factory | Store `templateAuthor[templateId]` at `registerTemplate(templateId)` so we know who to credit | Strategist attribution |
| V6 Router (or new) | Emit `StrategyAdopted(templateId, vault)` on `definePosition` | Track template usage for strategist gate |
| `AttributionRegistry.sol` (new) | All the above hooks land here | Single source of truth for "who gets what SBT" |
