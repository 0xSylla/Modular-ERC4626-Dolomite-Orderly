import { createPublicClient, http, formatUnits } from "viem";
import { arbitrum } from "viem/chains";
(async () => {
  const pub = createPublicClient({ chain: arbitrum, transport: http(process.env.MAINNET_RPC_URL_ARB ?? "https://arb1.arbitrum.io/rpc") });
  const bal = await pub.readContract({
    address: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    abi: [{ type: "function", name: "balanceOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" }] as const,
    functionName: "balanceOf", args: ["0xaC823b9A13694c4B4E692ea965235b84565E945a"],
  });
  console.log(`Vault USDC: ${formatUnits(bal as bigint, 6)}`);
})();
