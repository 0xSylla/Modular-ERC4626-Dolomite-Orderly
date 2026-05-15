import "dotenv/config";
import { ensureVaultSetup, getOpenPositionQty, getAlgoStatus, getOpenPositionEntry } from "../src/services/orderly";

const VAULT = (process.env.VAULT ?? "0xaC823b9A13694c4B4E692ea965235b84565E945a") as `0x${string}`;
const CHAIN = Number(process.env.CHAIN ?? 42161);
const PERPS = process.env.PERPS ?? "ETH";

async function main() {
  const symbol = `PERP_${PERPS}_USDC`;
  const tickerUrl = `https://api.orderly.org/v1/public/futures/${symbol}`;

  const tickerRes = await fetch(tickerUrl);
  const ticker = await tickerRes.json() as {
    data?: { mark_price?: number; index_price?: number; last_price?: number; "24h_close"?: number };
  };
  const mark  = ticker?.data?.mark_price;
  const index = ticker?.data?.index_price;
  const last  = ticker?.data?.last_price;

  await ensureVaultSetup(CHAIN, VAULT);
  const [qty, algo, entry] = await Promise.all([
    getOpenPositionQty(VAULT, PERPS).catch((e) => `err: ${e.message}`),
    getAlgoStatus(VAULT, PERPS).catch((e) => `err: ${e.message}`),
    getOpenPositionEntry(VAULT, PERPS).catch(() => null),
  ]);

  console.log("");
  console.log(`Market — ${symbol}`);
  console.log(`  mark:   $${mark?.toFixed(2) ?? "n/a"}`);
  console.log(`  index:  $${index?.toFixed(2) ?? "n/a"}`);
  console.log(`  last:   $${last?.toFixed(2) ?? "n/a"}`);
  console.log("");
  console.log(`Vault ${VAULT}`);
  console.log(`  open short qty:    ${qty}`);
  console.log(`  TP/SL algo:        ${algo}`);
  console.log(`  avg entry:         ${entry !== null ? `$${entry}` : "n/a (flat)"}`);

  if (entry !== null) {
    const tp = entry * 0.99;
    const sl = entry * 1.01;
    console.log("");
    console.log(`Trigger prices (1% rebalance threshold):`);
    console.log(`  TP (short profit, price falls): $${tp.toFixed(2)}`);
    console.log(`  SL (short loss,  price rises):  $${sl.toFixed(2)}`);

    if (mark !== undefined) {
      const moveFromEntry = ((mark - entry) / entry) * 100;
      const distToTP = ((mark - tp) / mark) * 100;
      const distToSL = ((sl - mark) / mark) * 100;
      console.log("");
      console.log(`Current vs entry:  ${moveFromEntry >= 0 ? "+" : ""}${moveFromEntry.toFixed(2)}%`);
      console.log(`Distance to TP:    ${distToTP.toFixed(2)}% (mark must drop)`);
      console.log(`Distance to SL:    ${distToSL.toFixed(2)}% (mark must rise)`);
    }
  }

  console.log("");
  if (qty === "0") {
    if (algo === "TAKE_PROFIT")      console.log("→ TP FIRED. Position closed at profit. Monitor will rebalance next tick.");
    else if (algo === "STOP_LOSS")   console.log("→ SL FIRED. Position closed at loss. Monitor will rebalance next tick.");
    else                              console.log("→ Position closed (manual or expired TP/SL).");
  } else {
    if (algo.startsWith("active:"))  console.log(`→ Position open, TP/SL live (algo id ${algo.slice(7)}). Neither child fired.`);
    else if (algo === "none")        console.log("→ Position open, no TP/SL active.");
    else                              console.log(`→ Position open. Algo state: ${algo}.`);
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
