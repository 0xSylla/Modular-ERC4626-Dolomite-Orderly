import { type Address, encodeFunctionData, keccak256, stringToHex, encodeAbiParameters } from "viem";
import { config, getChainConfig } from "../config";
import { getWalletClient, getPublicClient, operatorAddress } from "./blockchain";
import { routerAbi } from "../abis/router";
import { orderlyModuleAbi } from "../abis/modules";
import { signMessage as signEd25519Message, generateOrderlyKeyPair, type OrderlyKeyPair } from "./orderly-signing";

// ============ State ============

const vaultCredentials = new Map<string, {
  accountId: string;
  keyPair: OrderlyKeyPair;
}>();

export function getVaultCredentials(vault: Address) {
  const creds = vaultCredentials.get(vault.toLowerCase());
  if (!creds) throw new Error(`Vault ${vault} not set up on Orderly. Call POST /vaults/initialize first.`);
  return creds;
}

export function setVaultCredentials(vault: Address, accountId: string, keyPair: OrderlyKeyPair) {
  vaultCredentials.set(vault.toLowerCase(), { accountId, keyPair });
}

/**
 * Lazy-initializing accessor: if the vault has trading creds in memory, return them;
 * otherwise transparently re-run the Orderly setup. The setup is idempotent: if the
 * vault is already registered on Orderly (which it is across API restarts), the
 * on-chain delegateSigner step is skipped and we just register a fresh trading key.
 *
 * Use this from every Orderly operation in the executor so a stale in-memory cache
 * (e.g. after an API restart) self-heals instead of forcing the user to re-click
 * "Initialize on Orderly".
 */
export async function ensureVaultSetup(chainId: number, vault: Address, leverage = 2) {
  const cached = vaultCredentials.get(vault.toLowerCase());
  if (cached) return cached;
  console.log(`[Orderly] no creds in memory for ${vault} — running lazy setup`);
  await setupVaultOrderly(chainId, vault, leverage);
  const creds = vaultCredentials.get(vault.toLowerCase());
  if (!creds) throw new Error(`Lazy Orderly setup failed for ${vault}`);
  return creds;
}

// ============ Account ID ============

export function computeAccountId(vaultAddress: Address): string {
  const brokerHash = keccak256(stringToHex(config.brokerId));
  const encoded = encodeAbiParameters(
    [{ type: "address" }, { type: "bytes32" }],
    [vaultAddress, brokerHash]
  );
  return keccak256(encoded);
}

// ============ Authenticated Fetch ============

async function orderlyFetch(
  vault: Address,
  path: string,
  method: "GET" | "POST" | "DELETE" = "GET",
  body?: unknown
): Promise<unknown> {
  const { accountId, keyPair } = getVaultCredentials(vault);
  const url = `${config.orderlyApiUrl}${path}`;
  const timestamp = Date.now().toString();

  const bodyStr = body ? JSON.stringify(body) : "";
  const messageToSign = `${timestamp}${method}${path}${bodyStr}`;
  const signature = signEd25519Message(messageToSign, keyPair.privateKey);

  const contentType = method === "GET" || method === "DELETE"
    ? "application/x-www-form-urlencoded"
    : "application/json";

  const headers: Record<string, string> = {
    "Content-Type": contentType,
    "orderly-account-id": accountId,
    "orderly-key": keyPair.publicKey,
    "orderly-signature": signature,
    "orderly-timestamp": timestamp,
  };

  const res = await fetch(url, {
    method,
    headers,
    body: bodyStr || undefined,
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Orderly API error (${res.status}): ${text}`);
  }

  return res.json();
}

// ============ Setup: Step 1 — Delegate Signer On-Chain ============

export async function delegateSignerOnChain(chainId: number, vault: Address): Promise<string> {
  const cfg = getChainConfig(chainId);
  const brokerHash = keccak256(stringToHex(config.brokerId));

  const perpsModuleType = keccak256(stringToHex("perps.orderly"));

  const calldata = encodeFunctionData({
    abi: orderlyModuleAbi,
    functionName: "delegateSigner",
    args: [{
      brokerHash,
      delegateSigner: operatorAddress,
    }],
  });

  const txData = encodeFunctionData({
    abi: routerAbi,
    functionName: "setupModule",
    args: [vault, perpsModuleType, calldata],
  });

  const hash = await getWalletClient(chainId).sendTransaction({
    to: cfg.routerAddr,
    data: txData,
  });

  await getPublicClient(chainId).waitForTransactionReceipt({ hash });
  return hash;
}

// ============ Setup: Step 2 — Confirm Delegate Signer Off-Chain ============

export async function confirmDelegateSigner(
  chainId: number,
  vault: Address,
  delegateSignerTxHash: string
): Promise<string> {
  const accountId = computeAccountId(vault);

  const nonceRes = await fetch(
    `${config.orderlyApiUrl}/v1/registration_nonce?address=${vault}&broker_id=${config.brokerId}&chain_id=${chainId}`
  );
  const nonceData = (await nonceRes.json()) as { data: { registration_nonce: number } };
  const registrationNonce = nonceData.data.registration_nonce;

  const timestamp = BigInt(Date.now());

  const signature = await getWalletClient(chainId).signTypedData({
    domain: {
      name: "Orderly",
      version: "1",
      chainId,
      verifyingContract: config.orderlyVerifyingContract,
    },
    types: {
      DelegateSigner: [
        { name: "delegateContract", type: "address" },
        { name: "brokerId", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "timestamp", type: "uint64" },
        { name: "registrationNonce", type: "uint256" },
        { name: "txHash", type: "bytes32" },
      ],
    },
    primaryType: "DelegateSigner",
    message: {
      delegateContract: vault,
      brokerId: config.brokerId,
      chainId: BigInt(chainId),
      timestamp,
      registrationNonce: BigInt(registrationNonce),
      txHash: delegateSignerTxHash as `0x${string}`,
    },
  });

  const response = await fetch(`${config.orderlyApiUrl}/v1/delegate_signer`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      message: {
        delegateContract: vault,
        brokerId: config.brokerId,
        chainId,
        timestamp: Number(timestamp),
        registrationNonce,
        txHash: delegateSignerTxHash,
      },
      signature,
      userAddress: operatorAddress,
    }),
  });

  const result = (await response.json()) as { success: boolean };
  if (!result.success) {
    throw new Error(`Failed to confirm delegate signer: ${JSON.stringify(result)}`);
  }

  return accountId;
}

// ============ Setup: Step 3 — Register Orderly Key ============

export async function registerOrderlyKey(
  chainId: number,
  vault: Address
): Promise<OrderlyKeyPair> {
  const keyPair = generateOrderlyKeyPair();

  const timestamp = BigInt(Date.now());
  const expiration = timestamp + BigInt(365 * 24 * 60 * 60 * 1000);

  const signature = await getWalletClient(chainId).signTypedData({
    domain: {
      name: "Orderly",
      version: "1",
      chainId,
      verifyingContract: config.orderlyVerifyingContract,
    },
    types: {
      DelegateAddOrderlyKey: [
        { name: "delegateContract", type: "address" },
        { name: "brokerId", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "orderlyKey", type: "string" },
        { name: "scope", type: "string" },
        { name: "timestamp", type: "uint64" },
        { name: "expiration", type: "uint64" },
      ],
    },
    primaryType: "DelegateAddOrderlyKey",
    message: {
      delegateContract: vault,
      brokerId: config.brokerId,
      chainId: BigInt(chainId),
      orderlyKey: keyPair.publicKey,
      scope: "read,trading",
      timestamp,
      expiration,
    },
  });

  const response = await fetch(`${config.orderlyApiUrl}/v1/delegate_orderly_key`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      message: {
        delegateContract: vault,
        brokerId: config.brokerId,
        chainId,
        orderlyKey: keyPair.publicKey,
        scope: "read,trading",
        timestamp: Number(timestamp),
        expiration: Number(expiration),
      },
      signature,
      userAddress: operatorAddress,
    }),
  });

  const result = (await response.json()) as { success: boolean };
  if (!result.success) {
    throw new Error(`Failed to register orderly key: ${JSON.stringify(result)}`);
  }

  return keyPair;
}

// ============ Full Setup Flow ============

/**
 * Check whether a vault is already registered on Orderly Network.
 * Uses the public `get_account` endpoint, so it works even after API restart
 * (no in-memory credentials needed).
 */
async function isAccountRegistered(vault: Address): Promise<boolean> {
  const url = `${config.orderlyApiUrl}/v1/get_account?address=${vault}&broker_id=${config.brokerId}`;
  const r = await fetch(url);
  if (!r.ok) return false;
  const body = (await r.json().catch(() => null)) as
    | { success?: boolean; data?: { account_id?: string } }
    | null;
  return Boolean(body?.success && body?.data?.account_id);
}

export async function setupVaultOrderly(
  chainId: number,
  vault: Address,
  leverage = 2
): Promise<{ accountId: string; orderlyPublicKey: string }> {
  console.log(`[Setup] Starting Orderly setup for vault ${vault} on chain ${chainId}`);

  // Idempotency: if the vault is already registered, skip on-chain delegateSigner +
  // confirm steps. Just (re-)register an Orderly key so trading creds live in memory.
  const alreadyRegistered = await isAccountRegistered(vault);
  if (alreadyRegistered) {
    console.log("[Setup] Vault already registered on Orderly — skipping on-chain delegateSigner");
    const accountId = computeAccountId(vault);

    console.log("[Setup] Registering fresh orderly key...");
    const keyPair = await registerOrderlyKey(chainId, vault);
    console.log(`[Setup] Orderly key: ${keyPair.publicKey}`);
    setVaultCredentials(vault, accountId, keyPair);

    console.log(`[Setup] Setting leverage to ${leverage}x...`);
    await orderlyFetch(vault, "/v1/client/leverage", "POST", { leverage });

    console.log(`[Setup] Vault ${vault} ready for trading (existing registration reused)`);
    return { accountId, orderlyPublicKey: keyPair.publicKey };
  }

  console.log("[Setup] Step 1: delegateSigner on-chain...");
  const txHash = await delegateSignerOnChain(chainId, vault);
  console.log(`[Setup] delegateSigner tx: ${txHash}`);

  console.log("[Setup] Step 2: Confirm delegate signer...");
  let accountId: string;
  try {
    accountId = await confirmDelegateSigner(chainId, vault, txHash);
  } catch (err: any) {
    if (err.message?.includes("in progress")) {
      console.log("[Setup] Delegate signer in progress — searching vault logs for earlier tx hash...");

      const logs = await getPublicClient(chainId).getLogs({
        address: vault,
        event: {
          type: "event",
          name: "DelegateSignerSet",
          inputs: [
            { type: "bytes32", name: "brokerHash", indexed: true },
            { type: "address", name: "delegateSigner", indexed: true },
          ],
        },
        fromBlock: BigInt(0),
        toBlock: "latest",
      });

      if (logs.length === 0) {
        throw new Error("No DelegateSignerSet events found on vault — cannot recover from 'in progress' state");
      }

      const earliestTxHash = logs[0].transactionHash!;
      console.log(`[Setup] Found earlier delegateSigner tx: ${earliestTxHash}, retrying confirm...`);
      await new Promise((r) => setTimeout(r, 2000));
      accountId = await confirmDelegateSigner(chainId, vault, earliestTxHash);
    } else {
      throw err;
    }
  }
  console.log(`[Setup] Account ID: ${accountId}`);

  console.log("[Setup] Step 3: Register orderly key...");
  const keyPair = await registerOrderlyKey(chainId, vault);
  console.log(`[Setup] Orderly key: ${keyPair.publicKey}`);

  setVaultCredentials(vault, accountId, keyPair);

  console.log(`[Setup] Step 4: Set leverage to ${leverage}x...`);
  await orderlyFetch(vault, "/v1/client/leverage", "POST", { leverage });

  console.log(`[Setup] Vault ${vault} is ready for trading on Orderly`);
  return { accountId, orderlyPublicKey: keyPair.publicKey };
}

// ============ Resume Setup ============

export async function resumeVaultOrderly(
  chainId: number,
  vault: Address,
  delegateSignerTxHash: string,
  leverage = 2
): Promise<{ accountId: string; orderlyPublicKey: string }> {
  console.log(`[Setup Resume] Resuming Orderly setup for vault ${vault} from step 2`);

  const accountId = await confirmDelegateSigner(chainId, vault, delegateSignerTxHash);
  console.log(`[Setup Resume] Account ID: ${accountId}`);

  const keyPair = await registerOrderlyKey(chainId, vault);
  console.log(`[Setup Resume] Orderly key: ${keyPair.publicKey}`);

  setVaultCredentials(vault, accountId, keyPair);

  await orderlyFetch(vault, "/v1/client/leverage", "POST", { leverage });

  console.log(`[Setup Resume] Vault ${vault} is ready for trading on Orderly`);
  return { accountId, orderlyPublicKey: keyPair.publicKey };
}

// ============ Market Info ============

/**
 * Returns the current mark price for a PERP symbol via Orderly's public futures endpoint.
 * Unauthenticated — uses /v1/public/futures/{symbol}.
 */
export async function getMarkPrice(perpsAsset: string): Promise<number> {
  const symbol = `PERP_${perpsAsset}_USDC`;
  const res = await fetch(`${config.orderlyApiUrl}/v1/public/futures/${symbol}`);
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Orderly market info failed (${res.status}): ${text}`);
  }
  const body = (await res.json()) as { success?: boolean; data?: { mark_price?: number; index_price?: number } };
  const price = body?.data?.mark_price ?? body?.data?.index_price;
  if (!price || price <= 0) throw new Error(`Could not read mark price for ${symbol}`);
  return price;
}

/**
 * Returns the symbol's lot size / min quantity / min notional so we can validate orders
 * against Orderly's binding constraints. Orderly rejects with code -1101 if either
 * `qty < base_min` or `qty * price < min_notional`. Uses /v1/public/info/{symbol}.
 */
export async function getSymbolInfo(perpsAsset: string): Promise<{ baseTick: number; minQty: number; minNotional: number; quoteTick: number }> {
  const symbol = `PERP_${perpsAsset}_USDC`;
  const res = await fetch(`${config.orderlyApiUrl}/v1/public/info/${symbol}`);
  if (!res.ok) {
    return { baseTick: 0.0001, minQty: 0.001, minNotional: 10, quoteTick: 0.01 };
  }
  const body = (await res.json()) as { success?: boolean; data?: { base_tick?: number; base_min?: number; min_notional?: number; quote_tick?: number } };
  return {
    baseTick: body?.data?.base_tick ?? 0.0001,
    minQty: body?.data?.base_min ?? 0.001,
    minNotional: body?.data?.min_notional ?? 10,
    quoteTick: body?.data?.quote_tick ?? 0.01,
  };
}

/**
 * Fetch the last N realized 8h funding rates for a symbol (newest first).
 * Public endpoint, no signing required.
 */
export async function getFundingHistory(perpsAsset: string, count = 9): Promise<number[]> {
  const symbol = `PERP_${perpsAsset}_USDC`;
  const url = `${config.orderlyApiUrl}/v1/public/funding_rate_history?symbol=${encodeURIComponent(symbol)}&page_size=${count}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Orderly funding history failed (${res.status})`);
  const body = (await res.json()) as { data?: { rows?: Array<{ funding_rate?: number | string }> } };
  return (body?.data?.rows ?? [])
    .map((r) => Number(r.funding_rate))
    .filter((n) => Number.isFinite(n));
}

// ============ TP/SL Algo Orders ============

/**
 * Place a positional TP/SL algo for a SHORT (current strategy is always shorting the perp
 * against wstETH collateral, so this is the only side we wire up here).
 *
 * For a short at entry E:
 *   TP triggers when price drops by tpPct% (E × (1 - tpPct/100)) — buy back lower → profit
 *   SL triggers when price rises by slPct% (E × (1 + slPct/100)) — buy back higher → cut loss
 *
 * Both children are CLOSE_POSITION reduce-only, triggered by MARK_PRICE.
 * Returns the algo_order_id (or 0 on failure).
 */
export async function placeTpSlShort(
  vault: Address,
  perpsAsset: string,
  entry: number,
  tpPct: number,
  slPct: number,
): Promise<number> {
  const symbol = `PERP_${perpsAsset}_USDC`;
  const info = await getSymbolInfo(perpsAsset);
  const decimals = Math.max(0, -Math.floor(Math.log10(info.quoteTick)));
  const round = (p: number) => Math.round(p / info.quoteTick) * info.quoteTick;

  const tpPrice = Number(round(entry * (1 - tpPct / 100)).toFixed(decimals));
  const slPrice = Number(round(entry * (1 + slPct / 100)).toFixed(decimals));

  const result = (await orderlyFetch(vault, "/v1/algo/order", "POST", {
    symbol,
    algo_type: "POSITIONAL_TP_SL",
    child_orders: [
      { algo_type: "TAKE_PROFIT", side: "BUY", type: "CLOSE_POSITION",
        trigger_price: tpPrice, trigger_price_type: "MARK_PRICE", reduce_only: true },
      { algo_type: "STOP_LOSS",   side: "BUY", type: "CLOSE_POSITION",
        trigger_price: slPrice, trigger_price_type: "MARK_PRICE", reduce_only: true },
    ],
  })) as { success?: boolean; data?: { rows?: Array<{ order_id?: number }> }; message?: string };

  if (!result?.success) {
    throw new Error(`placeTpSlShort failed: ${result?.message ?? "unknown"}`);
  }
  const id = result?.data?.rows?.[0]?.order_id ?? 0;
  console.log(`[Orderly] TP/SL placed: TP=${tpPrice} SL=${slPrice} algoId=${id}`);
  return id;
}

/** Cancel all algo orders for a symbol. No-op if none exist. */
export async function cancelAllAlgoOrders(vault: Address, perpsAsset: string): Promise<void> {
  const symbol = `PERP_${perpsAsset}_USDC`;
  try {
    await orderlyFetch(vault, `/v1/algo/orders?symbol=${symbol}`, "DELETE");
  } catch (e: any) {
    // If there's nothing to cancel Orderly returns an error; treat as success.
    if (!/no.*orders/i.test(e?.message ?? "")) throw e;
  }
}

/**
 * Returns the status of the symbol's positional TP/SL algo:
 *   "TAKE_PROFIT" — TP child triggered/filled (i.e. position was closed at profit)
 *   "STOP_LOSS"   — SL child triggered/filled
 *   "active:N"    — algo present with order id N, neither child triggered
 *   "none"        — no positional TP/SL active for this symbol
 */
export async function getAlgoStatus(vault: Address, perpsAsset: string): Promise<string> {
  const symbol = `PERP_${perpsAsset}_USDC`;
  const result = (await orderlyFetch(vault, `/v1/algo/orders?symbol=${symbol}`, "GET")) as {
    data?: { rows?: Array<{ algo_type?: string; algo_order_id?: number; child_orders?: Array<{ algo_type?: string; is_triggered?: boolean; status?: string }> }> };
  };
  const rows = result?.data?.rows ?? [];
  for (const o of rows) {
    if (o.algo_type !== "POSITIONAL_TP_SL") continue;
    for (const c of o.child_orders ?? []) {
      if (c.is_triggered || c.status === "FILLED") return c.algo_type ?? "none";
    }
    return `active:${o.algo_order_id ?? 0}`;
  }
  return "none";
}

/**
 * Returns the average open price of the current short for the symbol, or null if flat.
 * Used to seed the TP/SL prices when a position was opened but a fill price wasn't captured.
 */
export async function getOpenPositionEntry(vault: Address, perpsAsset: string): Promise<number | null> {
  const symbol = `PERP_${perpsAsset}_USDC`;
  const result = await orderlyFetch(vault, "/v1/positions") as {
    data?: { rows?: Array<{ symbol: string; position_qty: number; average_open_price: number }> };
  };
  const pos = result?.data?.rows?.find((r) => r.symbol === symbol);
  if (!pos || pos.position_qty === 0) return null;
  return pos.average_open_price;
}

// ============ Trading Operations ============

interface OrderlyOrderResponse {
  success: boolean;
  data: {
    order_id: number;
    client_order_id: string;
    order_type: string;
    status: string;
  };
}

export async function openShort(
  vault: Address,
  perpsAsset: string,
  quantity: string
): Promise<OrderlyOrderResponse> {
  const symbol = `PERP_${perpsAsset}_USDC`;
  return orderlyFetch(vault, "/v1/order", "POST", {
    symbol,
    order_type: "MARKET",
    side: "SELL",
    order_quantity: parseFloat(quantity),
    reduce_only: false,
  }) as Promise<OrderlyOrderResponse>;
}

export async function closeShort(
  vault: Address,
  perpsAsset: string,
  quantity: string
): Promise<OrderlyOrderResponse> {
  const symbol = `PERP_${perpsAsset}_USDC`;
  return orderlyFetch(vault, "/v1/order", "POST", {
    symbol,
    order_type: "MARKET",
    side: "BUY",
    order_quantity: parseFloat(quantity),
    reduce_only: true,
  }) as Promise<OrderlyOrderResponse>;
}

// ============ Settle PnL ============

export async function settlePnL(chainId: number, vault: Address): Promise<unknown> {
  const cfg = getChainConfig(chainId);
  const nonceResult = await orderlyFetch(vault, "/v1/settle_nonce") as { data: { settle_nonce: number } };
  const settleNonce = nonceResult.data.settle_nonce;

  const timestamp = BigInt(Date.now());

  const eip712Sig = await getWalletClient(chainId).signTypedData({
    domain: {
      name: "Orderly",
      version: "1",
      chainId,
      verifyingContract: cfg.orderlyLedgerContract,
    },
    types: {
      DelegateSettlePnl: [
        { name: "delegateContract", type: "address" },
        { name: "brokerId", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "settleNonce", type: "uint64" },
        { name: "timestamp", type: "uint64" },
      ],
    },
    primaryType: "DelegateSettlePnl",
    message: {
      delegateContract: vault,
      brokerId: config.brokerId,
      chainId: BigInt(chainId),
      settleNonce: BigInt(settleNonce),
      timestamp,
    },
  });

  const body = {
    message: {
      delegateContract: vault,
      brokerId: config.brokerId,
      chainId,
      settleNonce,
      timestamp: Number(timestamp),
    },
    signature: eip712Sig,
    userAddress: operatorAddress,
    verifyingContract: cfg.orderlyLedgerContract,
  };

  return orderlyFetch(vault, "/v1/delegate_settle_pnl", "POST", body);
}

// ============ Withdrawal ============

export async function withdrawFromOrderly(
  chainId: number,
  vault: Address,
  amount: string
): Promise<unknown> {
  const cfg = getChainConfig(chainId);
  const nonceResult = await orderlyFetch(vault, "/v1/withdraw_nonce") as { data: { withdraw_nonce: number } };
  const withdrawNonce = nonceResult.data.withdraw_nonce;

  const rawAmount = BigInt(Math.floor(parseFloat(amount) * 1e6));
  const timestamp = BigInt(Date.now());

  const eip712Sig = await getWalletClient(chainId).signTypedData({
    domain: {
      name: "Orderly",
      version: "1",
      chainId,
      verifyingContract: cfg.orderlyLedgerContract,
    },
    types: {
      DelegateWithdraw: [
        { name: "delegateContract", type: "address" },
        { name: "brokerId", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "receiver", type: "address" },
        { name: "token", type: "string" },
        { name: "amount", type: "uint256" },
        { name: "withdrawNonce", type: "uint64" },
        { name: "timestamp", type: "uint64" },
      ],
    },
    primaryType: "DelegateWithdraw",
    message: {
      delegateContract: vault,
      brokerId: config.brokerId,
      chainId: BigInt(chainId),
      receiver: vault,
      token: "USDC",
      amount: rawAmount,
      withdrawNonce: BigInt(withdrawNonce),
      timestamp,
    },
  });

  const body = {
    message: {
      delegateContract: vault,
      brokerId: config.brokerId,
      chainId,
      receiver: vault,
      token: "USDC",
      amount: rawAmount.toString(),
      withdrawNonce,
      timestamp: Number(timestamp),
    },
    signature: eip712Sig,
    userAddress: operatorAddress,
    verifyingContract: cfg.orderlyLedgerContract,
  };

  const result = await orderlyFetch(vault, "/v1/delegate_withdraw_request", "POST", body) as
    | { success: true; data: { withdraw_id: number } }
    | { success: false; code: number; message: string };
  // orderlyFetch only throws on HTTP-level failures; Orderly returns 200 + {success:false}
  // for application errors (e.g., "Margin is occupied by position or open orders"). Surface those
  // explicitly so the close job fails fast instead of polling for a withdrawal that never arrives.
  if (!result.success) {
    throw new Error(
      `Orderly withdraw rejected (code ${(result as any).code}): ${(result as any).message}`
    );
  }
  return result;
}

// ============ Balance / Position Queries ============

export async function getOrderlyBalance(vault: Address): Promise<unknown> {
  return orderlyFetch(vault, "/v1/client/holding");
}

/**
 * Returns the absolute open position size on Orderly for the given perp, snapped to the
 * symbol's base_tick precision so it can be passed directly to closeShort.
 * Returns "0" if there's no open position.
 *
 * Used by close paths to avoid the open/close qty drift bug: opening and closing use the
 * same margin-derived formula but mark price moves between calls, so the close qty can be
 * 1 base_tick smaller than the open qty, leaving a residual short that blocks withdrawal.
 */
export async function getOpenPositionQty(vault: Address, perpsAsset: string): Promise<string> {
  const symbol = `PERP_${perpsAsset}_USDC`;
  const result = await orderlyFetch(vault, "/v1/positions") as {
    data?: { rows?: Array<{ symbol: string; position_qty: number }> };
  };
  const pos = result?.data?.rows?.find((r) => r.symbol === symbol);
  if (!pos || pos.position_qty === 0) return "0";

  const info = await getSymbolInfo(perpsAsset);
  const qty = Math.abs(pos.position_qty);
  // Already at base_tick precision from Orderly, but format to be safe
  const decimals = Math.max(0, -Math.floor(Math.log10(info.baseTick)));
  return qty.toFixed(decimals);
}

export async function getOrderlyPositions(vault: Address): Promise<unknown> {
  return orderlyFetch(vault, "/v1/positions");
}
