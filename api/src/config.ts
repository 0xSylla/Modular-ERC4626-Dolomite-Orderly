import "dotenv/config";

function env(key: string, fallback?: string): string {
  const val = process.env[key] ?? fallback;
  if (val === undefined) throw new Error(`Missing env: ${key}`);
  return val;
}

// Secrets — loaded once, never exported on the config object.
const _operatorPrivateKey = env("OPERATOR_PRIVATE_KEY") as `0x${string}`;
const _apiKey = env("API_KEY", "");
const _swapApiKey = env("SWAP_API_KEY", env("OOGABOOGA_API_KEY", ""));

export function getOperatorPrivateKey(): `0x${string}` {
  return _operatorPrivateKey;
}

export function getApiKey(): string {
  return _apiKey;
}

export function getSwapApiKey(): string {
  return _swapApiKey;
}

// ============ Per-chain config ============

export interface ChainConfig {
  chainId: number;
  rpcUrl: string;
  factoryAddr: `0x${string}`;
  routerAddr: `0x${string}`;
  tokens: Record<string, `0x${string}`>;
  dolomiteMarkets: Record<string, bigint>;
  swapApiUrl: string;
  swapProvider: "oogabooga" | "odos";
  orderlyVaultAddr: `0x${string}`;
  orderlyLedgerContract: `0x${string}`;
}

const CHAIN_CONFIGS: Record<number, ChainConfig> = {
  80094: {
    chainId: 80094,
    rpcUrl: env("RPC_URL_BERA", env("RPC_URL", "https://rpc.berachain.com")),
    factoryAddr: env("FACTORY_ADDR_BERA", env("FACTORY_ADDR", "0x0000000000000000000000000000000000000000")) as `0x${string}`,
    routerAddr: env("ROUTER_ADDR_BERA", env("ROUTER_ADDR", "0x0000000000000000000000000000000000000000")) as `0x${string}`,
    tokens: {
      USDC: "0x549943e04f40284185054145c6E4e9568C1D3241" as `0x${string}`,
      iBGT: "0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b" as `0x${string}`,
    },
    dolomiteMarkets: {
      USDC: 2n,
      iBGT: 34n,
      diBGT: 38n,
    },
    swapApiUrl: env("SWAP_API_URL_BERA", env("SWAP_API_URL", env("OOGABOOGA_API_URL", "https://mainnet.api.oogabooga.io"))),
    swapProvider: "oogabooga",
    orderlyVaultAddr: env("ORDERLY_VAULT_ADDR", "0x816f722424B49Cf1275cc86DA9840Fbd5a6167e9") as `0x${string}`,
    orderlyLedgerContract: "0x6F7a338F2aA472838dEFD3283eB360d4Dff5D203" as `0x${string}`,
  },
  42161: {
    chainId: 42161,
    rpcUrl: env("RPC_URL_ARB", "https://arb1.arbitrum.io/rpc"),
    factoryAddr: env("FACTORY_ADDR_ARB", "0x0000000000000000000000000000000000000000") as `0x${string}`,
    routerAddr: env("ROUTER_ADDR_ARB", "0x0000000000000000000000000000000000000000") as `0x${string}`,
    tokens: {
      USDC: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831" as `0x${string}`,
      WBTC: "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f" as `0x${string}`,
      WETH: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1" as `0x${string}`,
    },
    dolomiteMarkets: {
      USDC: 17n,
      WBTC: 4n,
      WETH: 0n,
    },
    swapApiUrl: env("SWAP_API_URL_ARB", "https://api.odos.xyz"),
    swapProvider: "odos",
    orderlyVaultAddr: env("ORDERLY_VAULT_ADDR", "0x816f722424B49Cf1275cc86DA9840Fbd5a6167e9") as `0x${string}`,
    orderlyLedgerContract: "0x6F7a338F2aA472838dEFD3283eB360d4Dff5D203" as `0x${string}`,
  },
};

export function getChainConfig(chainId: number): ChainConfig {
  const cfg = CHAIN_CONFIGS[chainId];
  if (!cfg) throw new Error(`Unsupported chain: ${chainId}`);
  return cfg;
}

export const SUPPORTED_CHAIN_IDS = Object.keys(CHAIN_CONFIGS).map(Number);

// ============ Global (chain-agnostic) config ============

export const config = {
  port: Number(env("PORT", "3000")),
  brokerId: env("BROKER_ID", "honeypot"),
  orderlyApiUrl: env("ORDERLY_API_URL", "https://api.orderly.org"),
  orderlyVerifyingContract: "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC" as `0x${string}`,
  jobTtlMs: Number(env("JOB_TTL_MS", String(60 * 60 * 1000))),
} as const;
