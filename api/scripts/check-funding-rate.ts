/**
 * Fetches the most recent ETH-PERP funding rates from Orderly and prints
 * the latest rate + the 9-period MA the monitor uses.
 *
 * Orderly returns `funding_rate` as a decimal per 8h period.
 *   rate × 10_000 = bps per 8h
 *   rate × 3 × 365 = annualized rate (decimal); × 100 = APR%
 */
import "dotenv/config";

const PERPS = process.env.PERPS ?? "ETH";
const COUNT = Number(process.env.COUNT ?? 9);

async function main() {
  const symbol = `PERP_${PERPS}_USDC`;
  const url = `https://api.orderly.org/v1/public/funding_rate_history?symbol=${encodeURIComponent(symbol)}&page_size=${COUNT}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Orderly funding history failed (${res.status})`);
  const body = await res.json() as {
    data?: { rows?: Array<{ funding_rate?: number | string; funding_rate_timestamp?: number }> };
  };
  const rows = body?.data?.rows ?? [];
  if (rows.length === 0) {
    console.log("No funding rows returned.");
    return;
  }

  console.log(`${symbol} — last ${rows.length} funding periods (newest first):\n`);
  console.log("  idx  timestamp (UTC)        rate              bps/8h     APR");
  console.log("  ---  ---------------------  ----------------  ---------  ---------");
  rows.forEach((r, i) => {
    const rate = Number(r.funding_rate);
    const bps = rate * 10_000;
    const apr = rate * 3 * 365 * 100;
    const ts = r.funding_rate_timestamp ? new Date(r.funding_rate_timestamp).toISOString().replace("T", " ").slice(0, 19) : "n/a";
    console.log(`  ${String(i).padStart(3)}  ${ts}  ${rate.toExponential(6).padStart(16)}  ${bps.toFixed(3).padStart(8)}  ${apr.toFixed(2).padStart(7)}%`);
  });

  const rates = rows.map((r) => Number(r.funding_rate)).filter((n) => Number.isFinite(n));
  const latest = rates[0];
  const ma = rates.reduce((s, x) => s + x, 0) / rates.length;

  console.log("\nLatest period:");
  console.log(`  rate    = ${latest}`);
  console.log(`  bps/8h  = ${(latest * 10_000).toFixed(4)} bps`);
  console.log(`  APR     = ${(latest * 3 * 365 * 100).toFixed(2)}%`);

  console.log(`\n${rates.length}-period MA (3-day, what the monitor uses):`);
  console.log(`  rate    = ${ma}`);
  console.log(`  bps/8h  = ${(ma * 10_000).toFixed(4)} bps`);
  console.log(`  APR     = ${(ma * 3 * 365 * 100).toFixed(2)}%`);

  console.log(`\nVs vault threshold of 0 bps (current setting for 0xaC8…945a):`);
  const maBps = ma * 10_000;
  if (maBps < 0) {
    console.log(`  MA (${maBps.toFixed(3)} bps) < 0 → monitor would PAUSE`);
  } else {
    console.log(`  MA (${maBps.toFixed(3)} bps) ≥ 0 → monitor stays ACTIVE`);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
