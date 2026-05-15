import { createPublicClient, http } from "viem";
import { arbitrum, mainnet, berachain, optimism, base } from "viem/chains";

const NFT = "0x2a2d56802ecb44eac0110f76731981131219667c" as `0x${string}`;
const CHAINS = [
  { name: "Ethereum", obj: mainnet, rpc: "https://eth.llamarpc.com" },
  { name: "Arbitrum", obj: arbitrum, rpc: process.env.MAINNET_RPC_URL_ARB ?? "https://arb1.arbitrum.io/rpc" },
  { name: "Berachain", obj: berachain, rpc: "https://rpc.berachain.com" },
  { name: "Optimism", obj: optimism, rpc: "https://mainnet.optimism.io" },
  { name: "Base", obj: base, rpc: "https://mainnet.base.org" },
];

(async () => {
  for (const { name, obj, rpc } of CHAINS) {
    const pub = createPublicClient({ chain: obj, transport: http(rpc) });
    try {
      const code = await pub.getBytecode({ address: NFT });
      if (!code || code === "0x") { console.log(`${name}: no contract`); continue; }
      try {
        const n = await pub.readContract({
          address: NFT,
          abi: [{ type: "function", name: "name", inputs: [], outputs: [{ type: "string" }], stateMutability: "view" }] as const,
          functionName: "name",
        });
        const s = await pub.readContract({
          address: NFT,
          abi: [{ type: "function", name: "symbol", inputs: [], outputs: [{ type: "string" }], stateMutability: "view" }] as const,
          functionName: "symbol",
        }).catch(() => "");
        const t = await pub.readContract({
          address: NFT,
          abi: [{ type: "function", name: "totalSupply", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" }] as const,
          functionName: "totalSupply",
        }).catch(() => 0n);
        console.log(`${name}: contract present — name="${n}" symbol="${s}" totalSupply=${t}`);
      } catch (e: any) {
        console.log(`${name}: contract present but ERC721 calls failed`);
      }
    } catch (e: any) {
      console.log(`${name}: rpc err — ${e.message?.slice(0, 50)}`);
    }
  }
})();
