/**
 * Per-position state persistence for the funding monitor.
 *
 * Tracks every (chainId, vault, positionId) the monitor knows about, plus the
 * current funding/lifecycle mode.
 *
 * Storage backend:
 *   - DATABASE_URL set  → Postgres (Heroku Postgres in prod). Writes are async.
 *   - DATABASE_URL unset → local JSON file `.monitor-state.json`. Writes are sync.
 *
 * In both modes an in-memory cache is the single source of truth at runtime:
 *   - Reads (`listPositions`, `getPosition`) are sync and hit the cache.
 *   - Writes (`upsertPosition`, `setMode`, `removePosition`) are async, persist
 *     to the backend and update the cache.
 *   - On process start, call `bootstrapMonitorState()` once before reading.
 */

import * as fs from "fs";
import * as path from "path";
import { Pool } from "pg";

export type MonitorMode =
  | "ACTIVE"        // position open on Orderly + Morpho leg
  | "PAUSED-COLD"   // fully exited: no short, no Morpho debt, no collateral; vault holds USDC
  | "PAUSED-WARM";  // short closed + debt repaid, wstETH still supplied to Morpho

export interface PositionEntry {
  chainId: number;
  vault: `0x${string}`;
  positionId: string;          // bigint serialized as string (JSON-safe)
  mode: MonitorMode;
  perpsAsset: string;          // e.g. "ETH"
  entryPrice: number;          // last observed avg open price
  algoOrderId: number;         // 0 = no algo
  lastEvalMaBps: number;       // last funding MA seen (basis points); NaN = unset
  updatedAt: number;           // ms epoch
}

interface StoreShape {
  positions: Record<string, PositionEntry>;
}

const DEFAULT_PATH = process.env.MONITOR_STATE_FILE
  ?? path.join(process.cwd(), ".monitor-state.json");

// ---- In-memory cache (single source of truth at runtime) ----
const cache: StoreShape = { positions: {} };

function key(chainId: number, vault: string, positionId: bigint | string): string {
  return `${chainId}:${vault.toLowerCase()}:${positionId.toString()}`;
}

// ---- Backend selection ----

let pgPool: Pool | null = null;
function getPg(): Pool {
  if (!pgPool) {
    pgPool = new Pool({
      connectionString: process.env.DATABASE_URL,
      // Heroku Postgres serves a chain that fails strict verification by default.
      // The standard workaround is to disable rejectUnauthorized on cloud DBs.
      ssl: process.env.DATABASE_URL?.includes("amazonaws.com") || process.env.PGSSLMODE === "require"
        ? { rejectUnauthorized: false }
        : undefined,
    });
  }
  return pgPool;
}

function useDb(): boolean {
  return !!process.env.DATABASE_URL;
}

// ---- File backend ----

function loadFromFile(): void {
  try {
    const raw = fs.readFileSync(DEFAULT_PATH, "utf8");
    const parsed = JSON.parse(raw) as StoreShape;
    if (parsed?.positions) {
      Object.assign(cache.positions, parsed.positions);
    }
  } catch {
    // Missing or invalid file → empty cache.
  }
}

function saveToFile(): void {
  try {
    fs.writeFileSync(DEFAULT_PATH, JSON.stringify(cache, null, 2));
  } catch (err: any) {
    console.warn(`[monitor-state] failed to persist ${DEFAULT_PATH}: ${err.message}`);
  }
}

// ---- DB backend ----

async function loadFromDb(): Promise<void> {
  const { rows } = await getPg().query<{
    chain_id: number;
    vault: string;
    position_id: string;
    mode: MonitorMode;
    perps_asset: string;
    entry_price: string;
    algo_order_id: string;
    last_eval_ma_bps: string | null;
    updated_at: string;
  }>(`SELECT chain_id, vault, position_id, mode, perps_asset, entry_price,
             algo_order_id, last_eval_ma_bps, updated_at
      FROM monitor_positions`);
  for (const r of rows) {
    const entry: PositionEntry = {
      chainId: r.chain_id,
      vault: r.vault as `0x${string}`,
      positionId: r.position_id,
      mode: r.mode,
      perpsAsset: r.perps_asset,
      entryPrice: Number(r.entry_price),
      algoOrderId: Number(r.algo_order_id),
      lastEvalMaBps: r.last_eval_ma_bps === null ? NaN : Number(r.last_eval_ma_bps),
      updatedAt: Number(r.updated_at),
    };
    cache.positions[key(entry.chainId, entry.vault, entry.positionId)] = entry;
  }
}

async function persistEntryToDb(e: PositionEntry): Promise<void> {
  await getPg().query(
    `INSERT INTO monitor_positions
       (chain_id, vault, position_id, mode, perps_asset, entry_price,
        algo_order_id, last_eval_ma_bps, updated_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
     ON CONFLICT (chain_id, vault, position_id)
     DO UPDATE SET
       mode = EXCLUDED.mode,
       perps_asset = EXCLUDED.perps_asset,
       entry_price = EXCLUDED.entry_price,
       algo_order_id = EXCLUDED.algo_order_id,
       last_eval_ma_bps = EXCLUDED.last_eval_ma_bps,
       updated_at = EXCLUDED.updated_at`,
    [
      e.chainId,
      e.vault.toLowerCase(),
      e.positionId,
      e.mode,
      e.perpsAsset,
      e.entryPrice,
      e.algoOrderId,
      Number.isFinite(e.lastEvalMaBps) ? e.lastEvalMaBps : null,
      e.updatedAt,
    ],
  );
}

async function deleteFromDb(chainId: number, vault: string, positionId: string): Promise<void> {
  await getPg().query(
    `DELETE FROM monitor_positions WHERE chain_id=$1 AND vault=$2 AND position_id=$3`,
    [chainId, vault.toLowerCase(), positionId],
  );
}

// ---- Public API ----

/**
 * Load all persisted state into the in-memory cache. Call once at process start
 * before invoking any reads or writes. Safe to call multiple times.
 */
export async function bootstrapMonitorState(): Promise<void> {
  for (const k of Object.keys(cache.positions)) delete cache.positions[k];
  if (useDb()) {
    await loadFromDb();
    console.log(`[monitor-state] loaded ${Object.keys(cache.positions).length} position(s) from Postgres`);
  } else {
    loadFromFile();
    console.log(`[monitor-state] loaded ${Object.keys(cache.positions).length} position(s) from ${DEFAULT_PATH}`);
  }
}

export function listPositions(): PositionEntry[] {
  return Object.values(cache.positions);
}

export function getPosition(
  chainId: number, vault: string, positionId: bigint | string,
): PositionEntry | null {
  return cache.positions[key(chainId, vault, positionId)] ?? null;
}

export async function upsertPosition(
  entry: Partial<PositionEntry> & Pick<PositionEntry, "chainId" | "vault" | "positionId">,
): Promise<PositionEntry> {
  const k = key(entry.chainId, entry.vault, entry.positionId);
  const existing = cache.positions[k];
  const next: PositionEntry = {
    chainId: entry.chainId,
    vault: entry.vault,
    positionId: entry.positionId,
    mode: entry.mode ?? existing?.mode ?? "ACTIVE",
    perpsAsset: entry.perpsAsset ?? existing?.perpsAsset ?? "",
    entryPrice: entry.entryPrice ?? existing?.entryPrice ?? 0,
    algoOrderId: entry.algoOrderId ?? existing?.algoOrderId ?? 0,
    lastEvalMaBps: entry.lastEvalMaBps ?? existing?.lastEvalMaBps ?? NaN,
    updatedAt: Date.now(),
  };
  cache.positions[k] = next;
  if (useDb()) {
    try { await persistEntryToDb(next); }
    catch (err: any) { console.warn(`[monitor-state] DB upsert failed (cache still updated): ${err.message}`); }
  } else {
    saveToFile();
  }
  return next;
}

export async function setMode(
  chainId: number, vault: string, positionId: bigint | string, mode: MonitorMode,
): Promise<void> {
  const e = getPosition(chainId, vault, positionId);
  if (!e) {
    await upsertPosition({ chainId, vault: vault as `0x${string}`, positionId: positionId.toString(), mode });
    return;
  }
  if (e.mode !== mode) {
    console.log(`[monitor-state] ${vault.slice(0, 8)}#${positionId}: ${e.mode} → ${mode}`);
    e.mode = mode;
    e.updatedAt = Date.now();
    if (useDb()) {
      try { await persistEntryToDb(e); }
      catch (err: any) { console.warn(`[monitor-state] DB setMode failed (cache still updated): ${err.message}`); }
    } else {
      saveToFile();
    }
  }
}

export async function removePosition(
  chainId: number, vault: string, positionId: bigint | string,
): Promise<void> {
  delete cache.positions[key(chainId, vault, positionId)];
  if (useDb()) {
    try { await deleteFromDb(chainId, vault, positionId.toString()); }
    catch (err: any) { console.warn(`[monitor-state] DB delete failed (cache evicted): ${err.message}`); }
  } else {
    saveToFile();
  }
}
