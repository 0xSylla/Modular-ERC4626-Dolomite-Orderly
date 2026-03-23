import { arbitrum, berachain } from "./wagmi";

const ZERO = "0x0000000000000000000000000000000000000000" as `0x${string}`;

export type ChainConfig = {
  /** Display name */
  name: string;
  /** Contract addresses */
  factory: `0x${string}`;
  curatorRouter: `0x${string}`;
  userRouter: `0x${string}`;
  /** Deposit token (USDC) */
  USDC: `0x${string}`;
  /** Known collateral/strategy assets available on this chain */
  strategyAssets: { label: string; address: `0x${string}` }[];
  /** Block explorer base URL */
  explorer: string;
};

export const CHAIN_CONFIGS: Record<number, ChainConfig> = {
  [arbitrum.id]: {
    name: "Arbitrum",
    factory: (process.env.NEXT_PUBLIC_FACTORY_ADDR_ARB || ZERO) as `0x${string}`,
    curatorRouter: (process.env.NEXT_PUBLIC_ROUTER_ADDR_ARB || ZERO) as `0x${string}`,
    userRouter: (process.env.NEXT_PUBLIC_USER_ROUTER_ADDR_ARB || ZERO) as `0x${string}`,
    USDC: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    strategyAssets: [
      { label: "WBTC",   address: "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f" },
      { label: "WETH",   address: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1" },
      { label: "wstETH", address: "0x5979d7B546E38E9Ab8B0d483b5C0c2C99b27C399" },
    ],
    explorer: "https://arbiscan.io",
  },
  [berachain.id]: {
    name: "Berachain",
    factory: "0xD1b62F897435491293161a46a0D5CD47dCeEbcc0",
    curatorRouter: "0xCe3D4A56cDf37E379E992b42Aad0185622C23977",
    userRouter: "0xFF613CE01fdC6Eca33cACcc49Ce0f7527b86932D",
    USDC: "0x549943e04f40284185054145c6E4e9568C1D3241",
    strategyAssets: [
      { label: "iBGT", address: "0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b" },
      { label: "WBTC", address: "0x0555E30da8f98308EdB960aa94C0Db47230d2B9c" },
      { label: "WETH", address: "0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590" },
    ],
    explorer: "https://berascan.com",
  },
};

export function getChainConfig(chainId: number): ChainConfig {
  return CHAIN_CONFIGS[chainId] ?? CHAIN_CONFIGS[berachain.id];
}
