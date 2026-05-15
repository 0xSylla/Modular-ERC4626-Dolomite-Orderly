/**
 * Idempotent schema migration for the monitor-state table.
 *
 * Runs in Heroku's release phase on every deploy via `npm run migrate`.
 * The `IF NOT EXISTS` clauses make repeated runs safe.
 *
 * Locally, only invoke this when DATABASE_URL points at a real Postgres
 * (e.g. a docker pg container) — running it without DATABASE_URL set is a no-op
 * by design, since the local dev backend is the JSON file.
 */
import "dotenv/config";
import { Pool } from "pg";

async function main() {
  if (!process.env.DATABASE_URL) {
    console.log("[migrate] DATABASE_URL not set — skipping (local dev uses JSON file backend)");
    return;
  }

  const pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    ssl: process.env.DATABASE_URL.includes("amazonaws.com") || process.env.PGSSLMODE === "require"
      ? { rejectUnauthorized: false }
      : undefined,
  });

  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS monitor_positions (
        chain_id          INTEGER          NOT NULL,
        vault             VARCHAR(42)      NOT NULL,
        position_id       VARCHAR(78)      NOT NULL,
        mode              VARCHAR(16)      NOT NULL DEFAULT 'ACTIVE',
        perps_asset       VARCHAR(16)      NOT NULL DEFAULT '',
        entry_price       DOUBLE PRECISION NOT NULL DEFAULT 0,
        algo_order_id     BIGINT           NOT NULL DEFAULT 0,
        last_eval_ma_bps  DOUBLE PRECISION,
        updated_at        BIGINT           NOT NULL,
        PRIMARY KEY (chain_id, vault, position_id)
      )
    `);
    console.log("[migrate] monitor_positions table ensured");
  } finally {
    await pool.end();
  }
}

main().catch((err) => {
  console.error("[migrate] failed:", err);
  process.exit(1);
});
