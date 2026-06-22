# Soulbound layer — internal draft design

**Status:** draft, internal-only. Code lives, tests pass. Not deployed.
**Phase:** 2 of 4.

## Two contracts

```
                        ┌─────────────────────────────────────────┐
                        │  SoulboundReceiptPool                   │
                        │   - holds TDIRAC reserve                │
                        │   - mintReceipt(user, amount) only-attr │
                        │   - distributeRevenue(amount) anyone    │
                        │   - claim() for caller                  │
                        │   - burnReceipt(user, amt) only-admin   │
                        │   - acc/debt accounting (Synthetix)     │
                        └────────────┬───────────────────┬────────┘
                              burns  │                   │ mints
                          TDIRAC     ▼                   ▼ SBT
                ┌────────────────────────┐    ┌─────────────────────────┐
                │  TDIRAC                │    │  SoulboundReceiptToken  │
                │  (ERC20 + Burnable     │    │  (ERC20 + Votes,        │
                │   + Permit + Votes)    │    │   non-transferable,     │
                │                        │    │   pool-only mint/burn,  │
                │  10B fixed supply      │    │   auto-delegate on mint)│
                └────────────────────────┘    └─────────────────────────┘
```

## Soulbound enforcement

`SoulboundReceiptToken._update` is the single chokepoint:

```solidity
function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
    if (from != address(0) && to != address(0)) revert NonTransferable();
    if (from == address(0) && to != address(0) && delegates(to) == address(0)) {
        _delegate(to, to);  // auto self-delegate on first mint
    }
    super._update(from, to, value);
}
```

This catches `transfer`, `transferFrom`, and any future ERC20 transfer path
at the lowest level — no need to override each one individually. `approve`
still works (approve-without-transfer is harmless), but any subsequent
`transferFrom` reverts.

Why auto-delegate on first mint: holders never opt in (the token is soulbound),
so requiring a manual `delegate()` call would mean default voting power = 0
for everyone — defeats the purpose of step 6 of the tokenomics plan. Note
that holders CAN re-delegate later (delegating to someone else is fine; the
auto-delegate only fires on FIRST mint, when `delegates(to) == address(0)`).

## Burn-on-mint flow

When `pool.mintReceipt(user, sbtAmount)` is called:

1. Settle the user's accrued-but-unclaimed revenue into `claimable[user]` before
   their share count changes (the Synthetix accumulator math assumes shares
   are stable between checkpoints; we book pending into a separate bucket so
   nothing is lost).
2. Compute `burnAmount = sbtAmount × burnRatio / 1e18`. Default `burnRatio` is
   1e18 (1:1). The DAO can change this via `setBurnRatio`.
3. If `burnAmount > 0`, `dirac.burn(burnAmount)` — burns from the pool's own
   TDIRAC balance, decreasing TDIRAC total supply.
4. `sbt.mint(user, sbtAmount)` — increases SBT supply, gives user voting power.
5. Reset `userRewardDebt[user] = sbt.balanceOf(user) × accRevenuePerShare / 1e18`
   so future revenue distributions count proportionally for the new balance.

Why TDIRAC `ERC20Burnable` rather than a dead-address transfer: cleaner total
supply accounting on block explorers and analytics tooling (the burned amount
disappears from `totalSupply()` rather than accumulating at `0xdead`). It's
also the standard OZ pattern.

## Revenue distribution math (Synthetix MasterChef-style)

| Var | Type | Meaning |
|---|---|---|
| `accRevenuePerShare` | uint256 (×1e18) | Running sum of revenue/totalShares at each distribution |
| `userRewardDebt[u]` | uint256 (×1e18) | `shares[u] × accRevenuePerShare` at the user's last share-changing op |
| `claimable[u]` | uint256 | Settled-but-unclaimed bucket, populated when shares change mid-cycle |

Pending at any moment:

```
pendingRewards(u) = claimable[u] + max(0, shares[u] × accRevenuePerShare - userRewardDebt[u])
                                   └──────── "fresh" since last touch ────────────┘
```

Invariants the tests verify:
- A late joiner doesn't get past revenue (`test_lateJoiner_doesNotGetPastRevenue`).
- A user gaining more shares mid-cycle keeps their prior earnings (`test_mintAfterRevenue_settlesPriorPending`).
- A slashed user keeps their prior earnings (`test_burnReceipt_preservesPriorRewards`).
- Two holders split a single distribution exactly pro-rata (`test_twoHolders_proRataSplit`).

## Role model

| Role | Who (Phase 2) | Who (Phase 3) | Who (Phase 4) | Powers |
|---|---|---|---|---|
| `attributor` | multisig | `AttributionRegistry` | DAO governor | Call `mintReceipt(user, amount)` |
| `admin` | multisig | multisig | DAO governor | Rotate `attributor`/`admin`, tune `burnRatio`, slash via `burnReceipt` |
| Revenue depositor | anyone | anyone | anyone | Call `distributeRevenue(amount)` (permissionless — donations welcome from treasury, BuyBackEngine, individual donors) |
| Claimer | the holder | the holder | the holder | Call `claim()` |

Mint is gated because each mint burns TDIRAC reserve (a privileged action that
affects the supply curve). Distribution is permissionless because depositing
revenue into the pool can only ever benefit existing holders — there's no
reason to gate it.

## Chicken-and-egg deploy

`SoulboundReceiptToken` needs the Pool address in its constructor (so it can
gate mint/burn to pool-only). The Pool needs the SBT address in its
constructor. Resolved by precomputing the Pool's deterministic address using
the deployer's next nonce:

```solidity
uint256 nonce = vm.getNonce(deployer);
address futurePool = vm.computeCreateAddress(deployer, nonce + 1);

SoulboundReceiptToken sbt = new SoulboundReceiptToken(futurePool); // nonce = N
SoulboundReceiptPool pool = new SoulboundReceiptPool(             // nonce = N+1
    diracAddr, address(sbt), revenueToken, admin, admin
);
require(address(pool) == futurePool, "address drift");
```

Same pattern used in `DeploySoulboundLayer.s.sol` + `setUp()` in the test.

## Files shipped

| File | Bytes | Purpose |
|---|---|---|
| `src/token/TDIRAC.sol` | (amended) +1 line `ERC20Burnable` import + mixin | Lets the pool destroy TDIRAC via `dirac.burn(...)` |
| `src/token/SoulboundReceiptToken.sol` | 2.6 KB | Non-transferable ERC20 + ERC20Votes, pool-only mint/burn, auto-delegate on first mint |
| `src/token/SoulboundReceiptPool.sol` | 7.8 KB | Burn↔mint orchestrator + revenue accumulator + claim |
| `script/DeploySoulboundLayer.s.sol` | 3.6 KB | Two-step deploy with precomputed Pool address |
| `test/SoulboundLayer.t.sol` | 11 KB | 26 tests covering wiring, soulbound enforcement, auto-delegate, burn-on-mint, revenue distribution + claim, late-joiner, mid-cycle mint, slash, admin rotation |

## Test coverage matrix (26 tests, all passing)

| Category | Tests |
|---|---|
| Deployment wiring | `test_wiring` |
| Soulbound enforcement | `transferRevertsAfterMint`, `transferFromRevertsAfterMint`, `directMintFromNonPoolReverts`, `directBurnFromNonPoolReverts` |
| Auto-delegation | `autoDelegate_onFirstMint`, `autoDelegate_secondMintDoesNotResetCustomDelegate` |
| Burn semantics | `burnsExactDiracAtDefaultRatio`, `respectsBurnRatio`, `zeroBurnRatioStillMints`, `revertsIfReserveInsufficient`, `revertsFromNonAttributor`, `revertsOnZeroAmount`, `revertsOnZeroAddress` |
| Revenue + claim | `singleHolder_claimsFullRevenue`, `twoHolders_proRataSplit`, `lateJoiner_doesNotGetPastRevenue`, `mintAfterRevenue_settlesPriorPending`, `claim_revertsWhenNothingToClaim`, `distributeRevenue_revertsBeforeAnyMint` |
| Slash / burn | `burnReceipt_revertsFromNonAdmin`, `burnReceipt_zerosVotes`, `burnReceipt_preservesPriorRewards` |
| Admin rotation | `setAttributor`, `setAdmin_handover`, `setBurnRatio_emits` |

## Known gaps / Phase 3 dependencies

| Gap | Resolved by |
|---|---|
| Manual minting only — multisig has to call `mintReceipt(user, amount)` for each contributor | Phase 3 `AttributionRegistry` becomes the `attributor` and mints automatically on qualifying actions |
| Single revenue token (USDC) | Phase 4 multi-token revenue (route per-vault performance fees + native token rebates) |
| No on-chain DAO yet — `admin` is the multisig | Phase 4 `DiracGovernor` (OZ Governor) takes `admin` role; tallies votes via `sbt.getPastVotes(user, block)` |
| No buyback flow yet | Phase 4 `BuyBackEngine` deposits market-bought TDIRAC into the pool (replenishes reserve) and/or calls `distributeRevenue` |

## Open questions before deploy

1. **Burn ratio at launch.** 1:1 means 1 TDIRAC burned per 1 SBT minted. With
   ~10B TDIRAC and an expected ~1M SBT minted in the first year (rough order
   of magnitude), that's 1M TDIRAC burned. Is that the intended deflation
   pressure, or should we start at 10:1 (or 100:1) to leave more TDIRAC supply
   for staking + DEX liquidity? Easy to tune via `setBurnRatio` post-deploy.

2. **Pool TDIRAC reserve size.** How many TDIRAC does the multisig pre-fund
   the pool with at launch? Has to cover all expected SBT mints until the
   BuyBackEngine starts replenishing. Recommend: 10-20% of total supply
   (1-2B TDIRAC) for the first year, top up as needed.

3. **Revenue token = USDC** is the natural choice for Arbitrum, but Berachain
   deployment will need to decide between USDC.e, HONEY, or native BERA. Pool
   is single-token in v1, so we'd deploy a separate Pool instance per chain
   anyway.
