/**
 * Rebalance Monitor (Arbitrum + Chainlink)
 *
 * Watches active vault positions on Arbitrum and automatically triggers
 * rebalancing when the underlying asset's Chainlink price deviates
 * beyond a threshold from the entry price.
 *
 * Flow:
 *   1. Poll all configured vaults for ACTIVE positions
 *   2. Fetch prices from Chainlink oracles on Arbitrum
 *   3. On first sight of an ACTIVE position, record the price as entry price
 *   4. If |current - entry| / entry >= threshold → requestRebalance on-chain → API rebalance
 *   5. After rebalance completes, reset entry price on next ACTIVE poll
 */

import { type Address } from "viem";
import { getPublicClient, getWalletClient, getPosition } from "./blockchain";
import { getChainConfig } from "../config";
import { routerAbi } from "../abis/router";
import { executeRebalance } from "./executor";

// ============ Config ============

const POLL_INTERVAL_MS = Number(process.env.REBALANCE_POLL_MS || 60_000); // 1 minute default
const DEFAULT_THRESHOLD = Number(process.env.REBALANCE_THRESHOLD || 0.25); // 25%
const MAX_POSITIONS_PER_VAULT = 20;
const ARBITRUM_CHAIN_ID = 42161;

// ============ Chainlink Oracle Addresses (Arbitrum One) ============

const CHAINLINK_FEEDS: Record<string, Address> = {
  ETH:  "0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612", // ETH/USD
  WETH: "0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612", // ETH/USD (same feed)
  BTC:  "0xd0C7101eACbB49F3deCcCc166d238410D6D46d57", // BTC/USD
  WBTC: "0xd0C7101eACbB49F3deCcCc166d238410D6D46d57", // BTC/USD (same feed)
  ARB:  "0xb2A824043730FE05F3DA2efaFa1CBbe83fa548D6", // ARB/USD
  LINK: "0x86E53CF1B870786351Da77A57575e79CB55812CB", // LINK/USD
  UNI:  "0x9C917083fDb403ab5ADbEC26Ee294f6EcAda2720", // UNI/USD
  AAVE: "0xaD1d5344AaDE45F43E596773Bcc4c423EAbdD034", // AAVE/USD
  GMX:  "0xDB98056FecFff59D032aB628337A4887110df3dB", // GMX/USD
  SOL:  "0x24ceA4b8ce57cdA5058b924B9B9987992450590c", // SOL/USD
  DOGE: "0x9A7FB1b3950837a8D9b40517626E11D4127C098C", // DOGE/USD
  AVAX: "0x8bf61728eeDCE2F32c456454d87B5d6eD6150208", // AVAX/USD
};

// Chainlink AggregatorV3Interface — only latestRoundData needed
const aggregatorAbi = [
  {
    type: "function",
    name: "latestRoundData",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "decimals",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
    stateMutability: "view",
  },
] as const;

// ============ Types ============

interface WatchedVault {
  chainId: number;
  vault: Address;
  /** Override default threshold (0-1 scale, e.g. 0.25 = 25%) */
  threshold?: number;
}

interface EntryRecord {
  entryPrice: number;
  perpsAsset: string;
  positionId: bigint;
  recordedAt: number;
}

// key = `${chainId}:${vault}:${positionId}`
const entryPrices = new Map<string, EntryRecord>();

// Positions currently being rebalanced (to avoid double-triggers)
const rebalancingSet = new Set<string>();

// Cache oracle decimals (they don't change)
const decimalsCache = new Map<Address, number>();

// ============ Chainlink Price Fetching ============

async function getOracleDecimals(feedAddress: Address): Promise<number> {
  const cached = decimalsCache.get(feedAddress);
  if (cached !== undefined) return cached;

  const client = getPublicClient(ARBITRUM_CHAIN_ID);
  const d = await client.readContract({
    address: feedAddress,
    abi: aggregatorAbi,
    functionName: "decimals",
  });
  const decimals = Number(d);
  decimalsCache.set(feedAddress, decimals);
  return decimals;
}

/**
 * Fetch prices for all known assets from Chainlink oracles on Arbitrum.
 * Returns a map of asset symbol → USD price.
 */
async function fetchChainlinkPrices(): Promise<Map<string, number>> {
  const client = getPublicClient(ARBITRUM_CHAIN_ID);
  const prices = new Map<string, number>();
  const seen = new Set<Address>(); // avoid duplicate reads for aliases (WETH=ETH, WBTC=BTC)

  const entries = Object.entries(CHAINLINK_FEEDS);

  await Promise.all(
    entries.map(async ([symbol, feedAddress]) => {
      try {
        // Read price
        const [, answer] = (await client.readContract({
          address: feedAddress,
          abi: aggregatorAbi,
          functionName: "latestRoundData",
        })) as [bigint, bigint, bigint, bigint, bigint];

        // Get decimals (cached after first call)
        const decimals = await getOracleDecimals(feedAddress);
        const price = Number(answer) / 10 ** decimals;

        prices.set(symbol, price);
      } catch (err: any) {
        console.warn(`[Monitor] Failed to read Chainlink feed for ${symbol}: ${err.message}`);
      }
    })
  );

  return prices;
}

// ============ Vault Scanning ============

async function getActivePositions(chainId: number, vault: Address) {
  const client = getPublicClient(chainId);
  const cfg = getChainConfig(chainId);

  const nextId = (await client.readContract({
    address: cfg.routerAddr,
    abi: routerAbi,
    functionName: "nextPositionId",
    args: [vault],
  })) as bigint;

  const positions = [];
  for (let i = 0n; i < nextId && i < BigInt(MAX_POSITIONS_PER_VAULT); i++) {
    try {
      const pos = await getPosition(chainId, vault, i);
      if (pos.status === 3) {
        // 3 = ACTIVE
        positions.push(pos);
      }
    } catch {
      // Position may not exist, skip
    }
  }
  return positions;
}

// ============ Rebalance Trigger ============

async function triggerRebalance(chainId: number, vault: Address, positionId: bigint) {
  const key = `${chainId}:${vault}:${positionId}`;

  if (rebalancingSet.has(key)) {
    console.log(`[Monitor] Skipping ${key} — already rebalancing`);
    return;
  }

  rebalancingSet.add(key);

  try {
    // Step 1: Call requestRebalance on-chain (curator tx)
    console.log(`[Monitor] Calling requestRebalance on-chain for vault=${vault} pos=${positionId}`);
    const cfg = getChainConfig(chainId);
    const hash = await getWalletClient(chainId).writeContract({
      address: cfg.routerAddr,
      abi: routerAbi,
      functionName: "requestRebalance",
      args: [vault, positionId],
    });
    console.log(`[Monitor] requestRebalance tx: ${hash}`);

    // Wait for confirmation
    await getPublicClient(chainId).waitForTransactionReceipt({ hash });

    // Step 2: Trigger the API rebalance executor
    console.log(`[Monitor] Triggering rebalance executor for vault=${vault} pos=${positionId}`);
    const job = await executeRebalance(chainId, vault, positionId);
    console.log(`[Monitor] Rebalance job started: ${job.id}`);

    // Remove entry price so it gets re-recorded after rebalance completes
    entryPrices.delete(key);
  } catch (err: any) {
    console.error(`[Monitor] Rebalance trigger failed for ${key}:`, err.message);
  } finally {
    rebalancingSet.delete(key);
  }
}

// ============ Main Loop ============

let watchedVaults: WatchedVault[] = [];
let running = false;
let timer: ReturnType<typeof setTimeout> | null = null;

async function pollCycle() {
  if (watchedVaults.length === 0) return;

  try {
    const chainlinkPrices = await fetchChainlinkPrices();
    console.log(
      `[Monitor] Chainlink prices: ${Array.from(chainlinkPrices.entries())
        .map(([s, p]) => `${s}=$${p.toFixed(2)}`)
        .join(", ")}. Watching ${watchedVaults.length} vaults.`
    );

    for (const { chainId, vault, threshold } of watchedVaults) {
      const effectiveThreshold = threshold ?? DEFAULT_THRESHOLD;

      let positions;
      try {
        positions = await getActivePositions(chainId, vault);
      } catch (err: any) {
        console.error(`[Monitor] Failed to scan vault ${vault} on chain ${chainId}:`, err.message);
        continue;
      }

      for (const pos of positions) {
        const key = `${chainId}:${vault}:${pos.id}`;
        const currentPrice = chainlinkPrices.get(pos.perpsAsset);

        if (!currentPrice) {
          console.warn(
            `[Monitor] No Chainlink feed for "${pos.perpsAsset}". ` +
              `Available: ${Array.from(chainlinkPrices.keys()).join(", ")}. ` +
              `Skipping position ${pos.id}.`
          );
          continue;
        }

        // Record entry price on first sight
        const existing = entryPrices.get(key);
        if (!existing) {
          entryPrices.set(key, {
            entryPrice: currentPrice,
            perpsAsset: pos.perpsAsset,
            positionId: pos.id,
            recordedAt: Date.now(),
          });
          console.log(
            `[Monitor] Recorded entry price for ${key}: ${pos.perpsAsset} @ $${currentPrice.toFixed(4)}`
          );
          continue;
        }

        // Calculate deviation
        const deviation = Math.abs(currentPrice - existing.entryPrice) / existing.entryPrice;
        const direction = currentPrice > existing.entryPrice ? "UP" : "DOWN";

        if (deviation >= effectiveThreshold) {
          console.log(
            `[Monitor] THRESHOLD HIT for ${key}: ` +
              `${pos.perpsAsset} moved ${(deviation * 100).toFixed(1)}% ${direction} ` +
              `(entry=$${existing.entryPrice.toFixed(4)}, now=$${currentPrice.toFixed(4)}, threshold=${(effectiveThreshold * 100).toFixed(0)}%)`
          );
          triggerRebalance(chainId, vault as Address, pos.id);
        } else if (deviation > effectiveThreshold * 0.8) {
          // Log warning at 80% of threshold
          console.log(
            `[Monitor] WARNING ${key}: ${pos.perpsAsset} at ${(deviation * 100).toFixed(1)}% deviation ` +
              `(threshold=${(effectiveThreshold * 100).toFixed(0)}%)`
          );
        }
      }
    }
  } catch (err: any) {
    console.error("[Monitor] Poll cycle error:", err.message);
  }
}

// ============ Public API ============

export function startMonitor(vaults: WatchedVault[]) {
  if (running) {
    console.log("[Monitor] Already running, updating vault list");
    watchedVaults = vaults;
    return;
  }

  watchedVaults = vaults;
  running = true;

  console.log(
    `[Monitor] Started — polling every ${POLL_INTERVAL_MS / 1000}s, ` +
      `default threshold ${(DEFAULT_THRESHOLD * 100).toFixed(0)}%, ` +
      `watching ${vaults.length} vaults, ` +
      `price source: Chainlink (Arbitrum)`
  );

  pollCycle();
  timer = setInterval(pollCycle, POLL_INTERVAL_MS);
}

export function stopMonitor() {
  if (timer) clearInterval(timer);
  running = false;
  watchedVaults = [];
  console.log("[Monitor] Stopped");
}

export function addVault(vault: WatchedVault) {
  const exists = watchedVaults.find(
    (v) => v.chainId === vault.chainId && v.vault.toLowerCase() === vault.vault.toLowerCase()
  );
  if (!exists) {
    watchedVaults.push(vault);
    console.log(`[Monitor] Added vault ${vault.vault} on chain ${vault.chainId}`);
  }
}

export function removeVault(chainId: number, vault: Address) {
  watchedVaults = watchedVaults.filter(
    (v) => !(v.chainId === chainId && v.vault.toLowerCase() === vault.toLowerCase())
  );
  for (const key of entryPrices.keys()) {
    if (key.startsWith(`${chainId}:${vault.toLowerCase()}`)) {
      entryPrices.delete(key);
    }
  }
  console.log(`[Monitor] Removed vault ${vault} from chain ${chainId}`);
}

export function getMonitorStatus() {
  return {
    running,
    pollIntervalMs: POLL_INTERVAL_MS,
    defaultThreshold: DEFAULT_THRESHOLD,
    priceSource: "Chainlink (Arbitrum)",
    supportedAssets: Object.keys(CHAINLINK_FEEDS),
    watchedVaults: watchedVaults.map((v) => ({
      chainId: v.chainId,
      vault: v.vault,
      threshold: v.threshold ?? DEFAULT_THRESHOLD,
    })),
    trackedPositions: Array.from(entryPrices.entries()).map(([key, record]) => ({
      key,
      perpsAsset: record.perpsAsset,
      entryPrice: record.entryPrice,
      recordedAt: new Date(record.recordedAt).toISOString(),
    })),
    rebalancingNow: Array.from(rebalancingSet),
  };
}

export function setEntryPrice(chainId: number, vault: Address, positionId: bigint, price: number) {
  const key = `${chainId}:${vault}:${positionId}`;
  entryPrices.set(key, {
    entryPrice: price,
    perpsAsset: "",
    positionId,
    recordedAt: Date.now(),
  });
  console.log(`[Monitor] Manually set entry price for ${key}: $${price}`);
}
