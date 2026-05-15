/**
 * One-off: register a position in the monitor cache + persistence layer without
 * triggering an actual open/rebalance. Use when a position already exists on
 * Orderly + on-chain (e.g. recovering after a state-file wipe or first
 * deployment on Heroku Postgres) but the monitor doesn't know about it yet.
 *
 * Inputs via env vars (all required except LAST_EVAL_MA_BPS):
 *   CHAIN_ID         — e.g. 42161 for Arbitrum
 *   VAULT            — vault address
 *   POSITION_ID      — bigint as string (typically "0")
 *   MODE             — ACTIVE | PAUSED-COLD | PAUSED-WARM
 *   PERPS_ASSET      — e.g. ETH
 *   ENTRY_PRICE      — last observed Orderly entry price
 *   ALGO_ORDER_ID    — current TP/SL algo id (0 if none)
 *   LAST_EVAL_MA_BPS — optional, last evaluated funding MA
 *
 * Heroku invocation:
 *   heroku run --no-tty -- npm run register-position \
 *     CHAIN_ID=42161 VAULT=0xac8... POSITION_ID=0 MODE=ACTIVE PERPS_ASSET=ETH \
 *     ENTRY_PRICE=2316.5 ALGO_ORDER_ID=62433078
 */
import "dotenv/config";
import { bootstrapMonitorState, upsertPosition } from "../services/monitor-state";

async function main() {
  const required = ["CHAIN_ID", "VAULT", "POSITION_ID", "MODE", "PERPS_ASSET", "ENTRY_PRICE", "ALGO_ORDER_ID"];
  const missing = required.filter((k) => !process.env[k]);
  if (missing.length) {
    console.error(`Missing required env vars: ${missing.join(", ")}`);
    process.exit(1);
  }

  await bootstrapMonitorState();
  const entry = await upsertPosition({
    chainId: Number(process.env.CHAIN_ID),
    vault: process.env.VAULT!.toLowerCase() as `0x${string}`,
    positionId: process.env.POSITION_ID!,
    mode: process.env.MODE as any,
    perpsAsset: process.env.PERPS_ASSET!,
    entryPrice: Number(process.env.ENTRY_PRICE),
    algoOrderId: Number(process.env.ALGO_ORDER_ID),
    lastEvalMaBps: process.env.LAST_EVAL_MA_BPS ? Number(process.env.LAST_EVAL_MA_BPS) : NaN,
  });

  console.log("Registered position:");
  console.log(JSON.stringify(entry, null, 2));
  // Force-exit so any open pg pool doesn't hold the process.
  process.exit(0);
}

main().catch((err) => {
  console.error("register-position failed:", err);
  process.exit(1);
});
