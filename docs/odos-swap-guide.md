# Odos Swap Integration Guide — DiracVault + OdosModule

## Architecture

The vault calls `executeModule(bytes32 moduleType, bytes calldata)` which resolves the module address from the factory and delegatecalls into it. The OdosModule's `swap` function handles approval, calls the Odos router, and verifies output.

## OdosModule.swap Signature

```solidity
function swap(
    address tokenIn,
    uint256 amountIn,    // use type(uint256).max for entire balance
    address tokenOut,
    uint256 minAmountOut,
    bytes calldata odosCalldata  // raw calldata from Odos assemble API
) external payable onlyDelegatecall
```

**Critical**: The param order is `(tokenIn, amountIn, tokenOut, minAmountOut, bytes)` — NOT `(tokenIn, tokenOut, amountIn, minAmountOut, bytes)`.

## Odos Quote + Assemble Flow

### Step 1: Quote

```
POST https://api.odos.xyz/sor/quote/v2
{
  "chainId": 42161,
  "inputTokens": [{ "tokenAddress": "<tokenIn>", "amount": "<amountIn as string>" }],
  "outputTokens": [{ "tokenAddress": "<tokenOut>", "proportion": 1 }],
  "userAddr": "<VAULT_ADDRESS>",     // MUST be the vault, not the deployer/EOA
  "slippageLimitPercent": 2
}
```

### Step 2: Assemble (immediately after quote — quotes expire in ~30 seconds)

```
POST https://api.odos.xyz/sor/assemble
{
  "userAddr": "<VAULT_ADDRESS>",     // same vault address
  "pathId": "<from quote response>",
  "simulate": false
}
```

The `transaction.data` from the assemble response is the raw calldata to pass as `odosCalldata`.

## Common Failure Points

### 1. `userAddr` must be the vault address

Odos builds calldata that references `msg.sender` for token transfers. Since the module runs via delegatecall from the vault, `address(this)` = vault. If you pass the deployer/operator EOA as `userAddr`, the calldata will reference the wrong address and the swap will fail.

### 2. Quote expiry

The quote + assemble must happen in quick succession. If you quote, wait, then assemble, the `pathId` expires. Do both in one script/function call.

### 3. Approval inside the module

The OdosModule must `forceApprove(ODOS_ROUTER, amount)` before calling the router. After the swap, it should `forceApprove(ODOS_ROUTER, 0)` to clear approval. Example from OdosModule:

```solidity
IERC20(tokenIn).forceApprove(ODOS_ROUTER, amount);
(bool success, ) = ODOS_ROUTER.call(odosCalldata);
if (!success) revert Events.OperationFailed();
IERC20(tokenIn).forceApprove(ODOS_ROUTER, 0);
```

### 4. Odos Router address

- **Arbitrum**: `0xa669e7A0d4b3e4Fa48af2dE86BD4CD7126Be4e13`

### 5. The vault must hold tokenIn

The swap happens inside the vault's context (delegatecall). The vault must actually have the tokens. If you deposited USDC to the vault but the vault's `balanceOf(USDC)` is 0 (e.g., still in a lending protocol), the swap will fail.

### 6. Module must be whitelisted

The vault checks `whitelistedModuleTypes[moduleType]`. If the `swap.odos` hash isn't registered, `executeModule` reverts with `ModuleNotWhitelisted`.

### 7. Vault must be in TRADING state

`executeModule` requires `currentCycle.status == TRADING`. Call `openDeposits()` → `deposit()` → `startTrading()` before executing modules.

## Working Example (Proven on Arbitrum Mainnet)

```bash
VAULT=0x74F63715d694e9bdaBa6DD1cAb95D167564e2880
USDC=0xaf88d065e77c8cC2239327C5EDb3A432268e5831
WSTETH=0x5979D7b546E38E414F7E9822514be443A4800529
SWAP_MODULE=$(cast keccak "swap.odos")

# Quote + assemble in one shot (prevents expiry)
SWAP_DATA=$(python3 -c "
import requests
q=requests.post('https://api.odos.xyz/sor/quote/v2',json={
  'chainId':42161,
  'inputTokens':[{'tokenAddress':'$USDC','amount':'300000'}],
  'outputTokens':[{'tokenAddress':'$WSTETH','proportion':1}],
  'userAddr':'$VAULT',
  'slippageLimitPercent':2
}).json()
a=requests.post('https://api.odos.xyz/sor/assemble',json={
  'userAddr':'$VAULT',
  'pathId':q['pathId'],
  'simulate':False
}).json()
print(a['transaction']['data'])
")

# Encode the module calldata
SWAP_CALLDATA=$(cast calldata "swap(address,uint256,address,uint256,bytes)" \
  $USDC 300000 $WSTETH 0 $SWAP_DATA)

# Execute via vault
cast send $VAULT "executeModule(bytes32,bytes)" \
  $SWAP_MODULE $SWAP_CALLDATA \
  --private-key $PRIVKEY --rpc-url arbitrum --gas-price 100000000
```

## Reverse Swap (wstETH → USDC)

Same flow, swap the token addresses:

```bash
WSTETH_BAL=$(cast call $WSTETH 'balanceOf(address)(uint256)' $VAULT --rpc-url arbitrum | awk '{print $1}')

SWAP_DATA=$(python3 -c "
import requests
q=requests.post('https://api.odos.xyz/sor/quote/v2',json={
  'chainId':42161,
  'inputTokens':[{'tokenAddress':'$WSTETH','amount':'$WSTETH_BAL'}],
  'outputTokens':[{'tokenAddress':'$USDC','proportion':1}],
  'userAddr':'$VAULT',
  'slippageLimitPercent':2
}).json()
a=requests.post('https://api.odos.xyz/sor/assemble',json={
  'userAddr':'$VAULT',
  'pathId':q['pathId'],
  'simulate':False
}).json()
print(a['transaction']['data'])
")

SWAP_CALLDATA=$(cast calldata "swap(address,uint256,address,uint256,bytes)" \
  $WSTETH $WSTETH_BAL $USDC 0 $SWAP_DATA)

cast send $VAULT "executeModule(bytes32,bytes)" \
  $SWAP_MODULE $SWAP_CALLDATA \
  --private-key $PRIVKEY --rpc-url arbitrum --gas-price 100000000
```

## Debugging Checklist

If swaps are failing with `ModuleExecutionFailed`:

- [ ] Is `userAddr` in the Odos quote the **vault** address (not deployer)?
- [ ] Is the quote + assemble done in quick succession (< 30 seconds)?
- [ ] Does the vault hold enough `tokenIn`?
- [ ] Is the vault in `TRADING` cycle state?
- [ ] Is `swap.odos` module type whitelisted on the vault?
- [ ] Is the OdosModule registered on the factory? (`factory.getModule(keccak256("swap.odos"))` returns non-zero)
- [ ] Is the param order correct: `(tokenIn, amountIn, tokenOut, minAmountOut, bytes)`?
- [ ] Is the Odos router address correct for the chain?
- [ ] Is `executeModule` using `bytes32 moduleType` (not `address module`)?

## Key Addresses (Arbitrum)

| Contract | Address |
|---|---|
| Odos Router V2 | `0xa669e7A0d4b3e4Fa48af2dE86BD4CD7126Be4e13` |
| USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| wstETH | `0x5979D7b546E38E414F7E9822514be443A4800529` |
| WETH | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` |
| WBTC | `0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f` |
