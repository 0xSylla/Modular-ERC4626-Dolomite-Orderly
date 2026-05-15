import {
  createPublicClient,
  createWalletClient,
  http,
  encodeFunctionData,
  decodeAbiParameters,
  type Address,
  type Hex,
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

// The cache types are derived from the create*-functions below so that the bound
// account + chain stay encoded in the type. Without this, viem can't tell the
// account is pre-set and demands `account` on every per-call invocation.
function createBoundPublicClient(chainId: number) {
  const cfg = getChainConfig(chainId);
  return createPublicClient({
    chain: getChainDef(chainId),
    transport: http(cfg.rpcUrl),
  });
}
function createBoundWalletClient(chainId: number) {
  const cfg = getChainConfig(chainId);
  return createWalletClient({
    account,
    chain: getChainDef(chainId),
    transport: http(cfg.rpcUrl),
  });
}

type BoundPublicClient = ReturnType<typeof createBoundPublicClient>;
type BoundWalletClient = ReturnType<typeof createBoundWalletClient>;

const publicClients = new Map<number, BoundPublicClient>();
const walletClients = new Map<number, BoundWalletClient>();

function getChainDef(chainId: number): Chain {
  const chain = CHAIN_DEFS[chainId];
  if (!chain) throw new Error(`No chain definition for chainId ${chainId}`);
  return chain;
}

export function getPublicClient(chainId: number): BoundPublicClient {
  let client = publicClients.get(chainId);
  if (!client) {
    client = createBoundPublicClient(chainId);
    publicClients.set(chainId, client);
  }
  return client;
}

export function getWalletClient(chainId: number): BoundWalletClient {
  let client = walletClients.get(chainId);
  if (!client) {
    client = createBoundWalletClient(chainId);
    walletClients.set(chainId, client);
  }
  return client;
}

// ============ Module Type Hashes ============

export const MODULE_TYPES = {
  SWAP_KODIAK: keccak256(toHex("swap.kodiak")),
  SWAP_ODOS: keccak256(toHex("swap.odos")),
  SWAP_UNISWAP: keccak256(toHex("swap.uniswap")),
  LENDING_DOLOMITE: keccak256(toHex("lending.dolomite")),
  LENDING_AAVE: keccak256(toHex("lending.aave")),
  LENDING_MORPHO: keccak256(toHex("lending.morpho")),
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
  status: number;
}

export async function getVaultInfo(chainId: number, vault: Address): Promise<VaultInfo> {
  const cfg = getChainConfig(chainId);
  const result = await getPublicClient(chainId).readContract({
    address: cfg.factoryAddr,
    abi: factoryAbi,
    functionName: "vaultInfo",
    args: [vault],
  }) as any;
  // Auto-getter returns flat array [vault, creator, templateId, deployedAt]
  return {
    vault: result[0] ?? result.vault,
    creator: result[1] ?? result.creator,
    templateId: result[2] ?? result.templateId,
    deployedAt: result[3] ?? result.deployedAt,
  } as VaultInfo;
}

export async function getPosition(
  chainId: number,
  vault: Address,
  positionId: bigint
): Promise<PositionRecord> {
  const cfg = getChainConfig(chainId);
  const client = getPublicClient(chainId);

  // Use raw eth_call + manual decode to avoid viem tuple decoding issues with string fields
  const calldata = encodeFunctionData({
    abi: routerAbi,
    functionName: "getPosition",
    args: [vault, positionId],
  });

  const rawResult = await client.call({
    to: cfg.routerAddr,
    data: calldata,
  });

  if (!rawResult.data) throw new Error("getPosition returned empty data");

  // Manual decode: skip first 32-byte offset pointer, then decode flat fields
  const hex = rawResult.data.slice(2); // remove 0x
  const word = (i: number) => hex.slice(i * 64, (i + 1) * 64);
  const toNum = (w: string) => BigInt("0x" + w);
  const toAddr = (w: string) => ("0x" + w.slice(24)) as Address;

  // Word 0: offset (0x20 = 32, skip)
  // Word 1: id
  const id = toNum(word(1));
  // Word 2: vault
  const posVault = toAddr(word(2));
  // Word 3: collateralAsset
  const collateralAsset = toAddr(word(3));
  // Word 4: offset to string data (relative to start of tuple = word 1)
  const strOffset = Number(toNum(word(4))) / 32; // in words, relative to tuple start
  // Word 5: allocation
  const allocation = toNum(word(5));
  // Word 6: status
  const status = Number(toNum(word(6)));
  // String: at word (1 + strOffset) = length, then data
  const strLenWord = 1 + strOffset;
  const strLen = Number(toNum(word(strLenWord)));
  const strData = hex.slice((strLenWord + 1) * 64, (strLenWord + 1) * 64 + strLen * 2);
  const perpsAsset = Buffer.from(strData, "hex").toString("utf8");

  return { id, vault: posVault, collateralAsset, perpsAsset, allocation, status };
}

export interface VaultLegs {
  swapModuleType: Hex;
  lendingModuleType: Hex;
  perpsModuleType: Hex;
}

export async function getVaultLegs(chainId: number, vault: Address): Promise<VaultLegs> {
  const cfg = getChainConfig(chainId);
  const [swapModuleType, lendingModuleType, perpsModuleType] = await getPublicClient(chainId).readContract({
    address: cfg.routerAddr,
    abi: routerAbi,
    functionName: "vaultLegs",
    args: [vault],
  }) as [Hex, Hex, Hex];
  return { swapModuleType, lendingModuleType, perpsModuleType };
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

/**
 * Read the live collateral amount the vault has supplied to a Morpho Blue market.
 * Computes marketId from MarketParams, then queries Morpho.position(id, vault).
 */
const MORPHO_BLUE_ARB = "0x6c247b1F6182318877311737BaC0844bAa518F5e" as `0x${string}`;
const morphoBlueAbi = [{
  type: "function", name: "position",
  inputs: [{ name: "id", type: "bytes32" }, { name: "user", type: "address" }],
  outputs: [
    { name: "supplyShares", type: "uint256" },
    { name: "borrowShares", type: "uint128" },
    { name: "collateral", type: "uint128" },
  ],
  stateMutability: "view",
}] as const;

export async function getMorphoCollateral(
  chainId: number,
  vault: Address,
  marketParams: {
    loanToken: Address; collateralToken: Address; oracle: Address; irm: Address; lltv: bigint;
  },
): Promise<bigint> {
  const { keccak256, encodeAbiParameters } = await import("viem");
  const marketId = keccak256(encodeAbiParameters(
    [{ type: "tuple", components: [
      { name: "loanToken", type: "address" }, { name: "collateralToken", type: "address" },
      { name: "oracle", type: "address" }, { name: "irm", type: "address" },
      { name: "lltv", type: "uint256" },
    ]}],
    [marketParams as any]
  ));
  const pos = await getPublicClient(chainId).readContract({
    address: MORPHO_BLUE_ARB,
    abi: morphoBlueAbi,
    functionName: "position",
    args: [marketId, vault],
  }) as readonly [bigint, bigint, bigint];
  return BigInt(pos[2]); // collateral
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

/**
 * Calls `vault.executeBatch(moduleTypes, datas)` directly, bypassing the curator router's
 * position-state machine. Used by the funding monitor's pause/resume flows — they need to
 * run module sequences while the position is in ACTIVE state, which the curator router
 * doesn't allow (its execute* functions all require specific transition states).
 *
 * Operator wallet has OPERATOR_ROLE on the vault, and `executeBatch` only requires
 * `cycle.status == TRADING` — so this works as long as the vault is in trading mode.
 */
const vaultBatchAbi = [{
  type: "function", name: "executeBatch",
  inputs: [{ name: "moduleTypes", type: "bytes32[]" }, { name: "datas", type: "bytes[]" }],
  outputs: [{ name: "results", type: "bytes[]" }],
  stateMutability: "payable",
}] as const;

export async function vaultExecuteBatch(
  chainId: number,
  vault: Address,
  modules: Hex[],
  datas: `0x${string}`[],
  value = 0n,
) {
  const txData = encodeFunctionData({
    abi: vaultBatchAbi,
    functionName: "executeBatch",
    args: [modules, datas],
  });
  const hash = await getWalletClient(chainId).sendTransaction({
    to: vault,
    data: txData,
    value,
  });
  const receipt = await waitForReceipt(chainId, hash);
  return { hash, receipt };
}

export async function executeOpeningRequest(
  chainId: number,
  vault: Address,
  positionId: bigint,
  modules: Hex[],
  datas: `0x${string}`[],
  value = 0n
) {
  const cfg = getChainConfig(chainId);
  const txData = encodeFunctionData({
    abi: routerAbi,
    functionName: "executeOpeningRequest",
    args: [vault, positionId, modules, datas],
  });
  const hash = await getWalletClient(chainId).sendTransaction({
    to: cfg.routerAddr,
    data: txData,
    value,
  });
  const receipt = await waitForReceipt(chainId, hash);
  return { hash, receipt };
}

export async function confirmOpen(chainId: number, vault: Address, positionId: bigint) {
  const cfg = getChainConfig(chainId);
  const txData = encodeFunctionData({
    abi: routerAbi,
    functionName: "confirmOpen",
    args: [vault, positionId],
  });
  const hash = await getWalletClient(chainId).sendTransaction({
    to: cfg.routerAddr,
    data: txData,
  });
  const receipt = await waitForReceipt(chainId, hash);
  return { hash, receipt };
}

export async function executeClosingRequest(
  chainId: number,
  vault: Address,
  positionId: bigint,
  modules: Hex[],
  datas: `0x${string}`[],
  value = 0n
) {
  const cfg = getChainConfig(chainId);
  const txData = encodeFunctionData({
    abi: routerAbi,
    functionName: "executeClosingRequest",
    args: [vault, positionId, modules, datas],
  });
  const hash = await getWalletClient(chainId).sendTransaction({
    to: cfg.routerAddr,
    data: txData,
    value,
  });
  const receipt = await waitForReceipt(chainId, hash);
  return { hash, receipt };
}

export async function executeRebalanceClose(
  chainId: number,
  vault: Address,
  positionId: bigint,
  modules: Hex[],
  datas: `0x${string}`[],
  value = 0n
) {
  const cfg = getChainConfig(chainId);
  const txData = encodeFunctionData({
    abi: routerAbi,
    functionName: "executeRebalanceClose",
    args: [vault, positionId, modules, datas],
  });
  const hash = await getWalletClient(chainId).sendTransaction({
    to: cfg.routerAddr,
    data: txData,
    value,
  });
  const receipt = await waitForReceipt(chainId, hash);
  return { hash, receipt };
}

export async function executeRebalanceOpen(
  chainId: number,
  vault: Address,
  positionId: bigint,
  modules: Hex[],
  datas: `0x${string}`[],
  value = 0n
) {
  const cfg = getChainConfig(chainId);
  const txData = encodeFunctionData({
    abi: routerAbi,
    functionName: "executeRebalanceOpen",
    args: [vault, positionId, modules, datas],
  });
  const hash = await getWalletClient(chainId).sendTransaction({
    to: cfg.routerAddr,
    data: txData,
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
  console.log("[DEBUG] LENDING_DOLOMITE hash:", MODULE_TYPES.LENDING_DOLOMITE);
  console.log("[DEBUG] Router:", cfg.routerAddr);

  const moduleCalldata = encodeFunctionData({
    abi: dolomiteModuleAbi,
    functionName: "initializeModule",
  });

  const txData = encodeFunctionData({
    abi: routerAbi,
    functionName: "setupModule",
    args: [vault, MODULE_TYPES.LENDING_DOLOMITE, moduleCalldata],
  });

  const hash = await getWalletClient(chainId).sendTransaction({
    to: cfg.routerAddr,
    data: txData,
  });

  await waitForReceipt(chainId, hash);
  return hash;
}

export async function initializeOrderlyModule(chainId: number, vault: Address): Promise<string> {
  const cfg = getChainConfig(chainId);

  const moduleCalldata = encodeFunctionData({
    abi: orderlyModuleAbi,
    functionName: "initializeModule",
    args: [cfg.orderlyVaultAddr],
  });

  const txData = encodeFunctionData({
    abi: routerAbi,
    functionName: "setupModule",
    args: [vault, MODULE_TYPES.PERPS_ORDERLY, moduleCalldata],
  });

  const hash = await getWalletClient(chainId).sendTransaction({
    to: cfg.routerAddr,
    data: txData,
  });

  await waitForReceipt(chainId, hash);
  return hash;
}
