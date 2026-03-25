import { http, createConfig } from "wagmi";
import { defineChain } from "viem";
import {
  mainnet,
  arbitrum,
  avalanche,
  base,
  bsc,
  optimism,
  polygon,
  zksync,
} from "viem/chains";
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

export const plasma = defineChain({
  id: 1012,
  name: "Plasma",
  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://rpc.plasma.io/"] },
  },
  blockExplorers: {
    default: { name: "Plasma Explorer", url: "https://explorer.plasma.io" },
  },
});

export const monad = defineChain({
  id: 10143,
  name: "Monad",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://rpc.monad.xyz/"] },
  },
  blockExplorers: {
    default: { name: "Monad Explorer", url: "https://explorer.monad.xyz" },
  },
});

export { mainnet, arbitrum, avalanche, base, bsc, optimism, polygon, zksync };

/** Default chain users are forced to on connect. */
export const DEFAULT_CHAIN = arbitrum;

/** All chains the app supports (browsable in dropdown). */
export const SUPPORTED_CHAINS = [
  arbitrum,
  berachain,
  mainnet,
  avalanche,
  base,
  bsc,
  optimism,
  polygon,
  zksync,
  plasma,
  monad,
] as const;

/** Chains with deployed contracts (wallet can connect). */
export const LIVE_CHAINS = [arbitrum, berachain] as const;

export const config = createConfig({
  chains: [berachain, arbitrum],
  connectors: [injected()],
  transports: {
    [berachain.id]: http("https://rpc.berachain.com/"),
    [arbitrum.id]: http(),
  },
  ssr: true,
});
