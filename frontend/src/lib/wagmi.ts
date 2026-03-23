import { http, createConfig } from "wagmi";
import { defineChain } from "viem";
import { arbitrum } from "viem/chains";
import { injected } from "wagmi/connectors";

export const berachain = defineChain({
  id: 80094,
  name: "Berachain",
  nativeCurrency: { name: "BERA", symbol: "BERA", decimals: 18 },
  rpcUrls: {
    default: {
      http: ["https://rpc.berachain.com/"],
    },
  },
  blockExplorers: {
    default: { name: "Berascan", url: "https://berascan.com" },
  },
});

export { arbitrum };

/** Default chain users are forced to on connect. */
export const DEFAULT_CHAIN = berachain;

/** All chains the app supports. */
export const SUPPORTED_CHAINS = [berachain, arbitrum] as const;

export const config = createConfig({
  chains: [berachain, arbitrum],
  connectors: [injected()],
  transports: {
    [berachain.id]: http("https://rpc.berachain.com/"),
    [arbitrum.id]: http(),
  },
  ssr: true,
});
