/**
 * Reads the vault's on-chain funding / rebalance thresholds and decodes them
 * into human-readable values.
 *
 * Convention: getFundingRateThresholdBps() returns `|neg threshold| × 10`
 *   (0.1 bps precision). 0 = strictest (pause when MA<0). Higher = more tolerant.
 */
import "dotenv/config";
import { createPublicClient, http } from "viem";
import { arbitrum } from "viem/chains";
import { getChainConfig } from "../src/config";

const VAULT = (process.env.VAULT ?? "0xaC823b9A13694c4B4E692ea965235b84565E945a") as `0x${string}`;
const CHAIN = Number(process.env.CHAIN ?? 42161);

async function main() {
  const cfg = getChainConfig(CHAIN);
  const pub = createPublicClient({ chain: arbitrum, transport: http(cfg.rpcUrl) });

  const [fundingRaw, rebalRaw] = await Promise.all([
    pub.readContract({
      address: VAULT,
      abi: [{ type: "function", name: "getFundingRateThresholdBps", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" }] as const,
      functionName: "getFundingRateThresholdBps",
    }) as Promise<bigint>,
    pub.readContract({
      address: VAULT,
      abi: [{ type: "function", name: "getRebalanceThresholdBps", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" }] as const,
      functionName: "getRebalanceThresholdBps",
    }) as Promise<bigint>,
  ]);

  const fundingStored = Number(fundingRaw);
  const fundingBps = -(fundingStored / 10);
  const fundingPctPer8h = fundingBps / 100;
  const fundingPctAPR = fundingPctPer8h * 3 * 365;

  console.log(`Vault ${VAULT}\n`);
  console.log(`Raw on-chain values:`);
  console.log(`  getFundingRateThresholdBps() = ${fundingStored}   (stored as |neg bps| × 10)`);
  console.log(`  getRebalanceThresholdBps()   = ${rebalRaw}   (raw bps)\n`);
  console.log(`Decoded:`);
  console.log(`  Funding pause threshold:  ${fundingBps} bps  (3-day MA must be >= this to stay ACTIVE)`);
  console.log(`                            = ${fundingPctPer8h.toFixed(4)}% per 8h funding period`);
  console.log(`                            ~= ${fundingPctAPR.toFixed(2)}% APR (negative means cost-to-short)`);
  console.log(`  Rebalance / TP-SL pct:    ${Number(rebalRaw) / 100}%   (raw ${rebalRaw} bps)`);

  if (fundingStored === 0) {
    console.log(`\n  -> Strictest mode. Position pauses as soon as 3d MA funding drops below 0 bps.`);
  } else {
    console.log(`\n  -> Tolerant of negative funding down to ${fundingBps} bps. Pauses only if MA < ${fundingBps} bps.`);
    console.log(`     Resume threshold = pause + hysteresis (default 4 bps) = ${fundingBps + 4} bps`);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
