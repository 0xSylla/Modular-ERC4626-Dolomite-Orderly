# Tokenomics deployment runbook

**Status:** nothing is deployed. This is the ordered, mechanical procedure to
deploy the full stack. Branch: `tokenomics-v1` (standalone, never merged).

> ⚠️ **Per-tx confirmation required.** Do not broadcast any of these without
> explicit sign-off. All scripts run in dry-run (no `--broadcast`) first.

## Inputs you must decide before starting

| Input | Used by | Notes |
|---|---|---|
| Target chain(s) | all | Arbitrum first (curator framework lives there). Berachain TBD. |
| `ADMIN` (multisig) | all | Holds every admin/attester/keeper/distributor role until governance takes over. |
| `REVENUE_TOKEN` (USDC) | pool, staking, buyback | Per-chain USDC address. |
| `DEX_ROUTER` + path | buyback | V2-style router (Kodiak on Bera; Camelot/Sushi on Arbitrum) + a liquid USDC→TDIRAC path. |
| `KEEPER` | buyback | Bot/multisig allowed to trigger buybacks. |
| Voting params **in BLOCKS** | governor | See the block-clock gotcha below. |

## Block-clock gotcha (read this)

TDIRAC uses the **default `ERC20Votes` clock = block number** (it does not
override `clock()`/`CLOCK_MODE`, and Phase 1 is frozen). So `DiracGovernor`'s
`votingDelay` / `votingPeriod` are denominated in **BLOCKS, not seconds**.

- Script defaults assume a ~12s cadence: `VOTING_DELAY_BLOCKS=7200` (~1 day),
  `VOTING_PERIOD_BLOCKS=50400` (~7 days).
- **On Arbitrum `block.number` follows the L1 block** (~12s), so the defaults
  are roughly right there — but confirm the current cadence before deploy.
- The timelock `minDelay` is in **seconds** (uses `block.timestamp`) — default
  `172800` (2 days).
- Both voting params are `GovernorSettings`-tunable later via a governance
  proposal, so they're not permanent — but get them sane at launch.

## Order

TDIRAC must exist first; everything else references it. Pool must exist before
the registry (registry is the pool's sole minter) and before staking/buyback
(they reference the pool as a revenue sink / recipient).

```
1. TDIRAC            script/DeployTDIRAC.s.sol
2. Soulbound layer   script/DeploySoulboundLayer.s.sol   (needs DIRAC_ADDR)
3. AttributionReg.   script/DeployAttributionRegistry.s.sol (needs POOL_ADDR, FACTORY_ADDR=live V4 factory)
4. Governance        script/DeployGovernance.s.sol       (needs TDIRAC_ADDR)
5. Staking           script/DeployStaking.s.sol          (needs TDIRAC_ADDR, REVENUE_TOKEN)
6. BuyBack           script/DeployBuyBack.s.sol          (needs TDIRAC_ADDR, REVENUE_TOKEN, DEX_ROUTER, BUYBACK_RECIPIENT=pool, KEEPER)
```

### Per-step env + command

```bash
# 1. TDIRAC (mints full supply to ADMIN/treasury)
ADMIN=0x... forge script script/DeployTDIRAC.s.sol --rpc-url $RPC            # add --broadcast when confirmed

# 2. Soulbound layer (SBT + Pool)
ADMIN=0x... DIRAC_ADDR=0x... REVENUE_TOKEN=0x... \
  forge script script/DeploySoulboundLayer.s.sol --rpc-url $RPC
#   then (multisig): TDIRAC.transfer(Pool, <burn reserve>)

# 3. AttributionRegistry (auto-wires pool.setAttributor if broadcaster is pool admin)
ADMIN=0x... POOL_ADDR=0x... FACTORY_ADDR=0x<live V4 factory> \
  forge script script/DeployAttributionRegistry.s.sol --rpc-url $RPC

# 4. Governance (timelock + governor; deployer renounces timelock admin)
TDIRAC_ADDR=0x... \
  [TIMELOCK_MIN_DELAY=172800] [VOTING_DELAY_BLOCKS=7200] [VOTING_PERIOD_BLOCKS=50400] \
  [PROPOSAL_THRESHOLD=...] [QUORUM_PERCENT=4] \
  forge script script/DeployGovernance.s.sol --rpc-url $RPC

# 5. Staking
ADMIN=0x... TDIRAC_ADDR=0x... REVENUE_TOKEN=0x... [REWARDS_DURATION=604800] \
  forge script script/DeployStaking.s.sol --rpc-url $RPC

# 6. BuyBack
ADMIN=0x... TDIRAC_ADDR=0x... REVENUE_TOKEN=0x... DEX_ROUTER=0x... \
  BUYBACK_RECIPIENT=0x<pool> KEEPER=0x... [PATH_MID=0x<hop token>] \
  forge script script/DeployBuyBack.s.sol --rpc-url $RPC
```

## Post-deploy wiring (multisig)

1. **Pool minter** (if step 3 didn't auto-wire): `pool.setAttributor(registry)`.
2. **Burn reserve**: `TDIRAC.transfer(pool, <reserve>)` — sized to cover expected
   SBT mints (burn is 1:1 by default, `pool.burnRatio`).
3. **Strategist authorship** (as strategists are confirmed):
   `registry.setTemplateAuthor(templateId, strategist)` — any time, re-pointable.
4. **Fund staking rewards** (per window): `USDC.approve(staking, amt)` then
   `staking.notifyRewardAmount(amt)` (distributor role).
5. **Fund buyback**: transfer USDC to the engine; `keeper` calls
   `engine.buyback(amountIn, minOut, deadline)`.

## Governance handoff (when ready to go trustless)

Hand the module admin roles to the timelock (current admin/multisig calls). The
full-stack integration test (`test/FullStackIntegration.t.sol`) exercises this
exact sequence + a real proposal afterward, so it's proven to work:

```
registry.setAdmin(timelock)
pool.setAdmin(timelock)
staking.setAdmin(timelock)
engine.setAdmin(timelock)
```

Keep these as multisig OR move to the timelock per how fast you need them:
- `registry.attester` / `registry.strategistAttester` (LP/curator/strategist attestations)
- `staking.rewardsDistributor` (funds reward windows)
- `engine.keeper` (triggers buybacks)
- `pool.attributor` stays the **AttributionRegistry** (do NOT hand to timelock).

Holders must `delegate()` (to self or another) for voting power to count.

## Known gap — revenue routing is not wired

The sinks exist (`pool.distributeRevenue`, `staking.notifyRewardAmount`, buyback
feeds the pool) but **nothing currently routes protocol revenue into them**.
Deciding where revenue comes from (vault performance fees / curator router skim)
and wiring a router/keeper to split it across pool + staking + buyback is the
main integration left. Until then, funding is manual multisig transfers.
