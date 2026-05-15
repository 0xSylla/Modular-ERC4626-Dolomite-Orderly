/**
 * Funding monitor — long-running background loop that drives each tracked
 * position through its lifecycle:
 *
 *   ACTIVE → if Orderly position closed (TP/SL fired): rebalance + reopen
 *   ACTIVE → if funding MA < pause threshold: pause (unwind to USDC)
 *   PAUSED → if funding MA ≥ pause threshold + hysteresis: resume
 *
 * Boots from monitor-state.json (created when a position is first opened
 * via the API). At startup, reconciles each tracked position against actual
 * on-chain + Orderly state in case the API was offline through transitions.
 *
 * Ticks every MONITOR_TICK_INTERVAL_MS (default 60s). Tick rate is fast
 * relative to the 8h funding period, so we re-evaluate every minute but
 * decisions only flip on the slow MA + hysteresis.
 */

import { type Address } from "viem";
import { listPositions, setMode, upsertPosition, type PositionEntry } from "./monitor-state";
import { evaluateFunding, configFromVault } from "./funding-filter";
import {
  ensureVaultSetup,
  getOpenPositionEntry,
  getAlgoStatus,
  cancelAllAlgoOrders,
  placeTpSlShort,
  getOpenPositionQty,
} from "./orderly";
import { executePause, executeResume, executeRebalance } from "./executor";
import { getPosition, getWalletClient, getPublicClient } from "./blockchain";
import { routerAbi } from "../abis/router";
import { getChainConfig } from "../config";

const TICK_MS = Number(process.env.MONITOR_TICK_INTERVAL_MS ?? "60000");
const TP_SL_DEFAULT_PCT = Number(process.env.TP_SL_DEFAULT_PCT ?? "5");
const TP_SL_MIN_PCT = Number(process.env.TP_SL_MIN_PCT ?? "0.5");
const TP_SL_MAX_PCT = Number(process.env.TP_SL_MAX_PCT ?? "20");
const MONITOR_ENABLED = (process.env.MONITOR_ENABLED ?? "true").toLowerCase() === "true";

async function readTpSlPctFromVault(chainId: number, vault: Address): Promise<number> {
  try {
    const { createPublicClient, http } = await import("viem");
    const { arbitrum } = await import("viem/chains");
    const { getChainConfig } = await import("../config");
    const cfg = getChainConfig(chainId);
    const pub = createPublicClient({ chain: arbitrum, transport: http(cfg.rpcUrl) });
    const raw = await pub.readContract({
      address: vault,
      abi: [{ type: "function", name: "getRebalanceThresholdBps", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" }] as const,
      functionName: "getRebalanceThresholdBps",
    }) as bigint;
    const pct = Number(raw) / 100;
    if (pct < TP_SL_MIN_PCT) return TP_SL_DEFAULT_PCT;
    if (pct > TP_SL_MAX_PCT) return TP_SL_MAX_PCT;
    return pct;
  } catch {
    return TP_SL_DEFAULT_PCT;
  }
}

let running = false;
let stopRequested = false;

/**
 * Reads on-chain `fundingRateThresholdBps` for this vault and converts it to the bps
 * threshold the funding filter uses.
 *
 * On-chain storage convention: |negative threshold| × 10 (0.1 bps precision).
 *   0  → pause when MA < 0 bps (strictest, default)
 *   167 → pause when MA < -16.7 bps (more tolerant)
 *
 * The funding filter expects a signed bps value, so we convert with the negation.
 */
async function readFundingThresholdBps(chainId: number, vault: Address): Promise<number> {
  try {
    const { createPublicClient, http } = await import("viem");
    const { arbitrum } = await import("viem/chains");
    const { getChainConfig } = await import("../config");
    const cfg = getChainConfig(chainId);
    const pub = createPublicClient({ chain: arbitrum, transport: http(cfg.rpcUrl) });
    const v = await pub.readContract({
      address: vault,
      abi: [{ type: "function", name: "getFundingRateThresholdBps", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" }] as const,
      functionName: "getFundingRateThresholdBps",
    }) as bigint;
    // The stored value is `|negative bps| × 10`. Convert to signed bps for the filter.
    return -(Number(v) / 10);
  } catch {
    return 0;
  }
}

async function tickPosition(entry: PositionEntry): Promise<void> {
  const { chainId, vault, positionId, perpsAsset } = entry;
  const tag = `${vault.slice(0, 8)}#${positionId}`;

  // Make sure we have in-memory creds for Orderly (auto-reinit after restart).
  await ensureVaultSetup(chainId, vault).catch((e) => {
    console.warn(`[monitor ${tag}] ensureVaultSetup failed: ${e.message}`);
  });

  // 1) Funding evaluation (single source of truth for pause/resume decisions).
  const thresholdBps = await readFundingThresholdBps(chainId, vault);
  const cfg = configFromVault(thresholdBps);
  const result = await evaluateFunding(perpsAsset, entry.mode, cfg);
  if (result) {
    await upsertPosition({ chainId, vault, positionId, lastEvalMaBps: result.maBps });
    console.log(
      `[monitor ${tag}] mode=${entry.mode} maBps=${result.maBps.toFixed(3)} ` +
      `pause<${result.thresholdBps} resume>=${result.thresholdBps + result.hysteresisBps} → ${result.decision}`
    );
  }

  // 2) Paused branches — only handle resume.
  if (entry.mode === "PAUSED-COLD" || entry.mode === "PAUSED-WARM") {
    if (result?.decision !== "RESUME") return;
    console.log(`[monitor ${tag}] funding RESUME triggered — re-establishing position`);
    await executeResume(chainId, vault, BigInt(positionId));
    return;
  }

  // 3) ACTIVE branch — pause path takes priority over TP/SL handling.
  if (result?.decision === "PAUSE") {
    console.log(`[monitor ${tag}] funding PAUSE triggered — unwinding to USDC`);
    await executePause(chainId, vault, BigInt(positionId));
    return;
  }

  // Check the curator router's view of the position.
  const onchain = await getPosition(chainId, vault, BigInt(positionId)).catch(() => null);
  if (!onchain) return;
  if (onchain.status !== 3 /* ACTIVE */) {
    if (onchain.status === 4 /* CLOSE_REQUESTED */) {
      // User-driven close in progress — back off and let it complete.
      console.log(`[monitor ${tag}] position is in user-driven flow (status=${onchain.status}), skipping tick`);
      return;
    }
    if (onchain.status === 0 /* IDLE */) {
      console.log(`[monitor ${tag}] position now IDLE — dropping from monitoring`);
      const { removePosition } = await import("./monitor-state");
      await removePosition(chainId, vault, positionId);
      return;
    }
    // status 5 (REBALANCE_REQUESTED) and 6 (REBALANCING) are not early-returned: if a prior
    // rebalance attempt crashed mid-flow (e.g. operator OOG), we want the qty=0 branch below
    // to retry the executor on the next tick.
  }

  // 4) Look at the Orderly side. If qty == 0 here, TP or SL fired and the short auto-closed.
  const shortQty = await getOpenPositionQty(vault, perpsAsset).catch(() => "0");
  if (shortQty === "0") {
    console.log(`[monitor ${tag}] short closed off-chain (TP/SL or manual) — triggering rebalance`);
    // executeRebalance requires status=REBALANCE_REQUESTED (5). If the on-chain position is
    // still ACTIVE (3), send requestRebalance ourselves to flip it. Idempotent: if a prior
    // tick already transitioned the position (e.g. executor crashed mid-flow), skip.
    if (onchain.status === 3 /* ACTIVE */) {
      try {
        const cfg = getChainConfig(chainId);
        const hash = await getWalletClient(chainId).writeContract({
          address: cfg.routerAddr,
          abi: routerAbi,
          functionName: "requestRebalance",
          args: [vault, BigInt(positionId)],
        });
        console.log(`[monitor ${tag}] requestRebalance tx: ${hash}`);
        await getPublicClient(chainId).waitForTransactionReceipt({ hash });
      } catch (err: any) {
        console.error(`[monitor ${tag}] requestRebalance failed: ${err.message?.slice(0, 200)}`);
        return;
      }
    } else if (onchain.status === 5 /* REBALANCE_REQUESTED */ || onchain.status === 6 /* REBALANCING */) {
      console.log(`[monitor ${tag}] position already in status=${onchain.status} — skipping requestRebalance`);
    } else {
      console.warn(`[monitor ${tag}] qty=0 but unexpected on-chain status ${onchain.status} — aborting rebalance`);
      return;
    }
    await executeRebalance(chainId, vault, BigInt(positionId));
    return;
  }

  // 5) Position is healthy. Make sure TP/SL is still in place; re-place if missing.
  const algo = await getAlgoStatus(vault, perpsAsset).catch(() => "none");
  if (algo === "none") {
    const live = await getOpenPositionEntry(vault, perpsAsset);
    if (live) {
      console.log(`[monitor ${tag}] no TP/SL on Orderly — re-placing at entry ${live}`);
      try {
        const pct = await readTpSlPctFromVault(chainId, vault);
        const id = await placeTpSlShort(vault, perpsAsset, live, pct, pct);
        await upsertPosition({ chainId, vault, positionId, entryPrice: live, algoOrderId: id });
      } catch (e: any) {
        console.warn(`[monitor ${tag}] TP/SL replace failed: ${e.message}`);
      }
    }
  } else if (algo === "TAKE_PROFIT" || algo === "STOP_LOSS") {
    // Algo recorded as triggered but qty is still nonzero — race window, will resolve next tick.
    console.log(`[monitor ${tag}] algo=${algo} but qty=${shortQty} — waiting for close to settle`);
  }
}

async function tick(): Promise<void> {
  const positions = listPositions();
  if (positions.length === 0) return;
  console.log(`[monitor] tick — ${positions.length} position(s)`);
  for (const p of positions) {
    try {
      await tickPosition(p);
    } catch (err: any) {
      console.error(`[monitor ${p.vault.slice(0, 8)}#${p.positionId}] tick error: ${err.message}`);
    }
  }
}

export function startFundingMonitor(): void {
  if (running) return;
  if (!MONITOR_ENABLED) {
    console.log("[funding-monitor] disabled via MONITOR_ENABLED=false");
    return;
  }
  running = true;
  stopRequested = false;
  console.log(`[funding-monitor] starting, tick interval = ${TICK_MS / 1000}s`);
  (async () => {
    while (!stopRequested) {
      try { await tick(); }
      catch (err: any) { console.error("[funding-monitor] tick threw:", err); }
      await new Promise((r) => setTimeout(r, TICK_MS));
    }
    running = false;
  })();
}

export function stopFundingMonitor(): void {
  stopRequested = true;
}

export function getFundingMonitorStatus() {
  return { running, tickMs: TICK_MS, enabled: MONITOR_ENABLED };
}
