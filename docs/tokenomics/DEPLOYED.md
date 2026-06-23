# Tokenomics — first-test deployment (Arbitrum mainnet)

**Deployed:** 2026-06-23 · chain 42161 (Arbitrum One) · branch `tokenomics-v1`
**Status:** FIRST TEST. Test-economic tokens (TDIRAC is the test-labeled token,
revenue is a mock `TestUSDC`, buyback uses a mock router). Real chain, real gas.

> ⚠️ All admin/attester/keeper/distributor roles + the full 10B TDIRAC supply
> are held by the **deployer EOA** `0xdF2F0C8c58Ade470c780c73e2a3c71b5EB787E9B`
> (the API operator key). No multisig, no governance handoff yet — that's the
> first-test setup. The DiracTimelock exists but is NOT yet admin of the
> modules.

## Addresses

| Contract | Address |
|---|---|
| TestUSDC (mock revenue) | `0x91110db0D77ee769f76de78dE1Ae33E059fb8441` |
| TDIRAC | `0xe378c52f50da2E1B6491CcE0FCFC58f829DA01aE` |
| SoulboundReceiptToken (SBT) | `0xA24BE63a52C3173fA43C0f4E112fe821A1BA05cE` |
| SoulboundReceiptPool | `0xd944F0F4bb283d63CfEed114BBAFA580Ec4243ED` |
| AttributionRegistry | `0x6C4eA9e53C1E69B149a9375E378015AC69fbd175` (bound to **V1** factory `0xb161fac4…`; supersedes `0x671B83…` which was wrongly bound to the V4 factory) |
| DiracTimelock | `0x1DE82CB54Ae7b4Fdb8a07D742E1cA9D36c30394d` |
| DiracGovernor | `0x6cB615564b4630C74FcaADC28BAF2aE79E8351f1` |
| StakingContract | `0x3eacE1F6618b52665399c1F6d3dF63E1d9161385` |
| MockV2Router | `0xA9CC5e0d400DD668ED8d55B5FCe24e4700eef24A` |
| BuyBackEngine | `0x53490C0AC75D2E3A65096d5F928b8eD94337A0A6` |
| V1 factory (registry binds to, pre-existing) | `0xb161fac415c733c05c1308ec437cd7f9a870ec78` |

Deployer / all roles / treasury: `0xdF2F0C8c58Ade470c780c73e2a3c71b5EB787E9B`

## Live config (verified on-chain)

- `pool.attributor` = AttributionRegistry ✅ (registry is the sole SBT minter)
- `pool.diracReserve` = 100,000,000 TDIRAC (burn reserve)
- MockV2Router seeded with 100,000,000 TDIRAC; rate = 1:1 (1 tUSDC → 1 TDIRAC)
- deployer TDIRAC balance = 9.8B (10B − 100M reserve − 100M router), self-delegated
- Governor: votingDelay 1 block, votingPeriod 300 blocks, threshold 1000 TDIRAC,
  quorum 4%; timelock minDelay 300s. **Vote clock = block number.**

## How to drive the test (deployer holds every role)

Simulate revenue from any wallet by minting TestUSDC to it, then:

```bash
R=https://arb1.arbitrum.io/rpc
USDC=0x91110db0D77ee769f76de78dE1Ae33E059fb8441
POOL=0xd944F0F4bb283d63CfEed114BBAFA580Ec4243ED
STAKING=0x3eacE1F6618b52665399c1F6d3dF63E1d9161385
BUYBACK=0x53490C0AC75D2E3A65096d5F928b8eD94337A0A6
REG=0x6C4eA9e53C1E69B149a9375E378015AC69fbd175

# mint mock revenue to a wallet
cast send $USDC "mint(address,uint256)" <WALLET> 1000000000 --rpc-url $R --private-key <PK>

# attribution (deployer = attester): mint SBT to LPs / curator for a real V4 vault
cast send $REG "attestLpsForCycle(address,uint256,address[],uint256[])" <VAULT> 1 "[<lp>]" "[500000000]" --rpc-url $R --private-key <PK>
cast send $REG "attestCuratorGate(address,uint256,uint256)" <VAULT> 20000000000 12 --rpc-url $R --private-key <PK>

# revenue -> SBT holders
cast send $USDC "approve(address,uint256)" $POOL 1000000000 --rpc-url $R --private-key <PK>
cast send $POOL "distributeRevenue(uint256)" 1000000000 --rpc-url $R --private-key <PK>

# revenue -> stakers (deployer = rewardsDistributor)
cast send $USDC "approve(address,uint256)" $STAKING 700000000 --rpc-url $R --private-key <PK>
cast send $STAKING "notifyRewardAmount(uint256)" 700000000 --rpc-url $R --private-key <PK>

# buyback (deployer = keeper): tUSDC -> TDIRAC -> pool reserve
cast send $USDC "mint(address,uint256)" $BUYBACK 1000000000 --rpc-url $R --private-key <PK>
cast send $BUYBACK "buyback(uint256,uint256,uint256)" 1000000000 0 <deadline> --rpc-url $R --private-key <PK>
```

## To go trustless later (governance handoff)

```
registry.setAdmin(DiracTimelock)
pool.setAdmin(DiracTimelock)
staking.setAdmin(DiracTimelock)
engine.setAdmin(DiracTimelock)
```
Then all tuning flows through DiracGovernor proposals. See `DEPLOY.md`.

Tx record: `broadcast/DeployTokenomicsFirstTest.s.sol/42161/run-latest.json`.
