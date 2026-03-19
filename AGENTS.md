# AGENTS.md

## Project Overview

DiracHoneypot is a modular DeFi vault protocol on **Berachain** (chain ID 80094). Users deploy vaults via a factory, deposit USDC, and a centralized operator bot manages delta-neutral hedging positions through Orderly Network perps.

**Architecture**: On-chain vaults (Solidity/Foundry) + off-chain operator API (Node.js/TypeScript) + frontend (planned, Next.js).

### Key Contracts
- `src/vault/DiracVault.sol` — Main vault, uses delegatecall to modules via `executeModule`/`executeBatch`
- `src/factory/DiracVaultFactory.sol` — Deploys vault instances (near EIP-170 limit at ~24.5KB)
- `src/routers/VaultCuratorRouter.sol` — Position lifecycle orchestration
- `src/modules/perps/OrderlyModule.sol` — Orderly Network integration (deposit, delegateSigner)
- `src/modules/lending/DolomiteModule.sol` — Dolomite lending
- `src/modules/swap/KodiakModule.sol` — Kodiak DEX swaps
- `api/` — Express.js operator API service

## Setup Commands

### Contracts (Foundry)
```bash
forge install
forge build
forge test
```

### API
```bash
cd api
npm install
npm start
```

### Environment
Create `.env` with:
- `MAINNET_RPC_URL` — Berachain QuickNode RPC
- `PRIVATE_KEY` — Deployer key
- `OPERATOR_PRIVATE_KEY` — Operator EOA key
- `BERASCAN_API_KEY` — For verification
- Orderly keys (ed25519 private key, account ID)

## Build & Test

```bash
forge build                    # Compile contracts
forge test -vvv                # Run tests with traces
forge test --match-test testX  # Run specific test
```

**Compiler settings**: Solidity 0.8.28, optimizer ON with 10 runs, via_ir=true, EVM cancun. These settings are required to keep factory under EIP-170 size limit.

## Code Style

### Solidity
- All module functions MUST be `payable` (delegatecall preserves msg.value — nonpayable reverts)
- Diamond-style storage patterns (OrderlyStorage, VaultStorage) with dedicated storage slots
- Modules inherit `ModuleBase.sol` and implement `IModule`
- Use `executeModule(target, data)` and `executeBatch(targets[], datas[])` for module calls

### TypeScript (API)
- Express.js with route/service separation (`api/src/routes/`, `api/src/services/`)
- Secrets accessed via getter functions, never on config objects (prevents accidental logging)
- Ed25519 signing via `@noble/ed25519`, EIP-712 via ethers.js

## Deployment

```bash
# Deploy full protocol
forge script script/DeployDirac.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --with-gas-price 10000000

# Create a vault
forge script script/CreateVault.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --with-gas-price 10000000
```

**Gas**: Always use `--with-gas-price 10000000` (10 gwei) on Berachain. Lower values fail for some txs.

## Critical Architecture Notes

1. **delegatecall + msg.value**: All module functions are payable because `executeBatch` delegates with original msg.value. Solidity's nonpayable check reverts if msg.value > 0.
2. **Factory size**: `optimizer_runs = 10` is required to stay under EIP-170. Don't increase it.
3. **Orderly integration**: Two different EIP-712 domains — off-chain (registration/keys, verifyingContract=0xCcCC...ccC) and on-chain (withdraw/settle, verifyingContract=0x6F7a...3203).
4. **Orderly accountId**: `keccak256(abi.encode(userAddress, brokerHash))` — order matters, address first.
5. **Broker ID**: `"honeypot"`, brokerHash = `keccak256("honeypot")`

## Security

- Operator key can `executeModule` on granted vaults but CANNOT withdraw user funds directly
- Secrets must use getter functions, not config objects
- API requires API key auth on all routes except `/health`
- Health endpoint exposes no sensitive data
- See `.claude/projects/.../memory/production-security.md` for full production hardening checklist

## Tools & Resources

- **Foundry** — Solidity development framework (forge, cast, anvil)
- **Orderly Network** — Perpetuals DEX (API: https://api.orderly.org, underscores in paths)
- **The Black Box Network** (https://theblackbox.network) — CLI/MCP tooling used by team
- **Dolomite** — Lending protocol on Berachain
- **Kodiak** — DEX on Berachain

## Frontend (Planned)

Design reference available in `.claude/projects/.../memory/dirac-curator-frontend-reference.md`.
Stack: Next.js 16 + Tailwind v4 + wagmi v3 + viem v2. Dark theme with orange accent.
