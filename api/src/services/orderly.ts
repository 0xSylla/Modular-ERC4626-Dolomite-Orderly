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

export async function setupVaultOrderly(
  chainId: number,
  vault: Address,
  leverage = 2
): Promise<{ accountId: string; orderlyPublicKey: string }> {
  console.log(`[Setup] Starting Orderly setup for vault ${vault} on chain ${chainId}`);

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

  return orderlyFetch(vault, "/v1/delegate_withdraw_request", "POST", body);
}

// ============ Balance / Position Queries ============

export async function getOrderlyBalance(vault: Address): Promise<unknown> {
  return orderlyFetch(vault, "/v1/client/holding");
}

export async function getOrderlyPositions(vault: Address): Promise<unknown> {
  return orderlyFetch(vault, "/v1/positions");
}
