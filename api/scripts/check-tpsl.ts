/**
 * One-off: queries Orderly directly to determine whether the vault's
 * short on ETH-PERP has been closed (qty=0) and whether any TP/SL child
 * has fired. Doesn't depend on the funding-monitor state file.
 */
import "dotenv/config";
import { ensureVaultSetup, getOpenPositionQty, getAlgoStatus, getOpenPositionEntry } from "../src/services/orderly";

const VAULT  = (process.env.VAULT  ?? "0xaC823b9A13694c4B4E692ea965235b84565E945a") as `0x${string}`;
const CHAIN  = Number(process.env.CHAIN ?? 42161);
const PERPS  = process.env.PERPS ?? "ETH";

async function main() {
  console.log(`Checking vault ${VAULT} on chain ${CHAIN} for ${PERPS}-PERP\n`);

  // Re-init in-memory Orderly creds for this vault
  await ensureVaultSetup(CHAIN, VAULT);

  const [qty, algo, entry] = await Promise.all([
    getOpenPositionQty(VAULT, PERPS).catch((e) => `err: ${e.message}`),
    getAlgoStatus(VAULT, PERPS).catch((e) => `err: ${e.message}`),
    getOpenPositionEntry(VAULT, PERPS).catch((e) => null),
  ]);

  console.log(`  Open short qty:     ${qty}`);
  console.log(`  TP/SL algo status:  ${algo}`);
  console.log(`  Avg entry price:    ${entry !== null ? `$${entry}` : "n/a (flat)"}\n`);

  if (qty === "0") {
    if (algo === "TAKE_PROFIT") {
      console.log("→ TP HAS FIRED. Position is closed at profit. The funding monitor will trigger a rebalance on its next tick.");
    } else if (algo === "STOP_LOSS") {
      console.log("→ SL HAS FIRED. Position is closed at loss. The funding monitor will trigger a rebalance on its next tick.");
    } else {
      console.log("→ Position is closed but no TP/SL fired (manual close or expired order).");
    }
  } else {
    if (algo === "none") {
      console.log(`→ Position is still open (qty=${qty}), no TP/SL active.`);
    } else if (algo.startsWith("active:")) {
      console.log(`→ Position is still open (qty=${qty}). TP/SL is in place (algo id ${algo.slice(7)}). Neither child has fired.`);
    } else {
      console.log(`→ Position is still open (qty=${qty}). Algo status: ${algo}.`);
    }
  }
}

main().catch((e) => {
  console.error("Failed:", e);
  process.exit(1);
});
