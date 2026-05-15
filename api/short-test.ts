import { openShort, getOrderlyHoldings } from "./src/services/orderly";

async function main() {
  const vault = "0x8FD7e57AA7dd520c2EaaF2b335A3e8fB5641f4D1" as `0x${string}`;

  console.log("=== Checking Orderly holdings ===");
  try {
    const holdings = await getOrderlyHoldings(vault);
    console.log("Holdings:", JSON.stringify(holdings, null, 2));
  } catch (e: any) {
    console.log("Holdings error:", e.message);
  }

  // Test with a tiny short — 0.0001 ETH (~$0.25)
  const quantity = "0.0001";
  console.log(`\n=== Opening short ${quantity} ETH ===`);
  try {
    const result = await openShort(vault, "ETH", quantity);
    console.log("Order result:", JSON.stringify(result, null, 2));
  } catch (e: any) {
    console.log("Order error:", e.message);
  }
}

main().catch(console.error);
