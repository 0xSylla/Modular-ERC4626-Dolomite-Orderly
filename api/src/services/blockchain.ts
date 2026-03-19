import {
  createPublicClient,
  createWalletClient,
  http,
  encodeFunctionData,
  type Address,
  type Chain,
  keccak256,
  toHex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { berachainMainnet } from "./chain";
import { config, getChainConfig, getOperatorPrivateKey, type ChainConfig } from "../config";
import { factoryAbi } from "../abis/factory";
import { routerAbi } from "../abis/router";
import { dolomiteModuleAbi, orderlyModuleAbi } from "../abis/modules";

// ============ Account (shared across chains) ============

const account = privateKeyToAccount(getOperatorPrivateKey());
export const operatorAddress = account.address;

// ============ Per-chain Client Cache ============

const CHAIN_DEFS: Record<number, Chain> = {
  80094: berachainMainnet,
  42161: arbitrum,
};

const publicClients = new Map<number, ReturnType<typeof createPublicClient>>();
const walletClients = new Map<number, ReturnType<typeof createWalletClient>>();

function getChainDef(chainId: number): Chain {
  const chain = CHAIN_DEFS[chainId];
  if (!chain) throw new Error(`No chain definition for chainId ${chainId}`);
  return chain;
}

export function getPublicClient(chainId: number) {
  let client = publicClients.get(chainId);
  if (!client) {
    const cfg = getChainConfig(chainId);
    client = createPublicClient({
      chain: getChainDef(chainId),
      transport: http(cfg.rpcUrl),
    });
    publicClients.set(chainId, client);
  }
  return client;
}

export function getWalletClient(chainId: number) {
  let client = walletClients.get(chainId);
  if (!client) {
    const cfg = getChainConfig(chainId);
    client = createWalletClient({
      account,
      chain: getChainDef(chainId),
      transport: http(cfg.rpcUrl),
    });
    walletClients.set(chainId, client);
  }
  return client;
}

// ============ Module Type Hashes ============

export const MODULE_TYPES = {
  SWAP_KODIAK: keccak256(toHex("swap.kodiak")),
  LENDING_DOLOMITE: keccak256(toHex("lending.dolomite")),
  PERPS_ORDERLY: keccak256(toHex("perps.orderly")),
} as const;

// ============ TX Helpers ============

const TX_TIMEOUT_MS = 60_000;

async function waitForReceipt(chainId: number, hash: `0x${string}`) {
  const client = getPublicClient(chainId);
  const receipt = await client.waitForTransactionReceipt({
    hash,
    timeout: TX_TIMEOUT_MS,
  });
  if (receipt.status === "reverted") {
    throw new Error(`Transaction reverted: ${hash}`);
  }
  return receipt;
}

// ============ Read Helpers ============

export interface VaultInfo {
  vault: Address;
  creator: Address;
  templateId: `0x${string}`;
  deployedAt: bigint;
}

export interface PositionRecord {
  id: bigint;
  vault: Address;
  collateralAsset: Address;
  perpsAsset: string;
  allocation: bigint;
  rebalanceThresholdBps: bigint;
  status: number;
  legs: {
    swapModule: Address;
    lendingModule: Address;
    perpsModule: Address;
  };
}

export async function getVaultInfo(chainId: number, vault: Address): Promise<VaultInfo> {
  const cfg = getChainConfig(chainId);
  const result = await getPublicClient(chainId).readContract({
    address: cfg.factoryAddr,
    abi: factoryAbi,
    functionName: "vaultInfo",
    args: [vault],
  });
  return result as unknown as VaultInfo;
}

export async function getPosition(
  chainId: number,
  vault: Address,
  positionId: bigint
): Promise<PositionRecord> {
  const cfg = getChainConfig(chainId);
  const result = await getPublicClient(chainId).readContract({
    address: cfg.routerAddr,
    abi: routerAbi,
    functionName: "getPosition",
    args: [vault, positionId],
  });
  return result as unknown as PositionRecord;
}

export async function getStrategyAssetInfo(chainId: number, token: Address) {
  const cfg = getChainConfig(chainId);
  return getPublicClient(chainId).readContract({
    address: cfg.factoryAddr,
    abi: factoryAbi,
    functionName: "whitelistedStrategyAssets",
    args: [token],
  });
}

export async function getModuleLendingConfig(chainId: number, moduleTypeHash: `0x${string}`, token: Address): Promise<`0x${string}`> {
  const cfg = getChainConfig(chainId);
  return getPublicClient(chainId).readContract({
    address: cfg.factoryAddr,
    abi: factoryAbi,
    functionName: "moduleLendingConfig",
    args: [moduleTypeHash, token],
  }) as Promise<`0x${string}`>;
}

// ============ Write Helpers ============

export async function executeOpeningRequest(
  chainId: number,
  vault: Address,
  positionId: bigint,
  modules: Address[],
  datas: `0x${string}`[],
  value = 0n
) {
  const cfg = getChainConfig(chainId);
  const hash = await getWalletClient(chainId).writeContract({
    address: cfg.routerAddr,
    abi: routerAbi,
    functionName: "executeOpeningRequest",
    args: [vault, positionId, modules, datas],
    value,
  });
  const receipt = await waitForReceipt(chainId, hash);
  return { hash, receipt };
}

export async function confirmOpen(chainId: number, vault: Address, positionId: bigint) {
  const cfg = getChainConfig(chainId);
  const hash = await getWalletClient(chainId).writeContract({
    address: cfg.routerAddr,
    abi: routerAbi,
    functionName: "confirmOpen",
    args: [vault, positionId],
  });
  const receipt = await waitForReceipt(chainId, hash);
  return { hash, receipt };
}

export async function executeClosingRequest(
  chainId: number,
  vault: Address,
  positionId: bigint,
  modules: Address[],
  datas: `0x${string}`[],
  value = 0n
) {
  const cfg = getChainConfig(chainId);
  const hash = await getWalletClient(chainId).writeContract({
    address: cfg.routerAddr,
    abi: routerAbi,
    functionName: "executeClosingRequest",
    args: [vault, positionId, modules, datas],
    value,
  });
  const receipt = await waitForReceipt(chainId, hash);
  return { hash, receipt };
}

export async function executeRebalanceClose(
  chainId: number,
  vault: Address,
  positionId: bigint,
  modules: Address[],
  datas: `0x${string}`[],
  value = 0n
) {
  const cfg = getChainConfig(chainId);
  const hash = await getWalletClient(chainId).writeContract({
    address: cfg.routerAddr,
    abi: routerAbi,
    functionName: "executeRebalanceClose",
    args: [vault, positionId, modules, datas],
    value,
  });
  const receipt = await waitForReceipt(chainId, hash);
  return { hash, receipt };
}

export async function executeRebalanceOpen(
  chainId: number,
  vault: Address,
  positionId: bigint,
  modules: Address[],
  datas: `0x${string}`[],
  value = 0n
) {
  const cfg = getChainConfig(chainId);
  const hash = await getWalletClient(chainId).writeContract({
    address: cfg.routerAddr,
    abi: routerAbi,
    functionName: "executeRebalanceOpen",
    args: [vault, positionId, modules, datas],
    value,
  });
  const receipt = await waitForReceipt(chainId, hash);
  return { hash, receipt };
}

// ============ Module Initialization ============

export async function getDolomiteModuleAddress(chainId: number): Promise<Address> {
  const cfg = getChainConfig(chainId);
  const addr = await getPublicClient(chainId).readContract({
    address: cfg.factoryAddr,
    abi: factoryAbi,
    functionName: "getModule",
    args: [MODULE_TYPES.LENDING_DOLOMITE],
  });
  return addr as Address;
}

export async function getOrderlyModuleAddress(chainId: number): Promise<Address> {
  const cfg = getChainConfig(chainId);
  const addr = await getPublicClient(chainId).readContract({
    address: cfg.factoryAddr,
    abi: factoryAbi,
    functionName: "getModule",
    args: [MODULE_TYPES.PERPS_ORDERLY],
  });
  return addr as Address;
}

export async function initializeDolomite(chainId: number, vault: Address): Promise<string> {
  const cfg = getChainConfig(chainId);
  const dolomiteModule = await getDolomiteModuleAddress(chainId);

  const calldata = encodeFunctionData({
    abi: dolomiteModuleAbi,
    functionName: "initializeModule",
  });

  const hash = await getWalletClient(chainId).writeContract({
    address: cfg.routerAddr,
    abi: routerAbi,
    functionName: "setupModule",
    args: [vault, dolomiteModule, calldata],
  });

  await waitForReceipt(chainId, hash);
  return hash;
}

export async function initializeOrderlyModule(chainId: number, vault: Address): Promise<string> {
  const cfg = getChainConfig(chainId);
  const orderlyModule = await getOrderlyModuleAddress(chainId);

  const calldata = encodeFunctionData({
    abi: orderlyModuleAbi,
    functionName: "initializeModule",
    args: [cfg.orderlyVaultAddr],
  });

  const hash = await getWalletClient(chainId).writeContract({
    address: cfg.routerAddr,
    abi: routerAbi,
    functionName: "setupModule",
    args: [vault, orderlyModule, calldata],
  });

  await waitForReceipt(chainId, hash);
  return hash;
}
