import { type Address, createPublicClient, http, encodeFunctionData, encodePacked } from "viem";
import { arbitrum } from "viem/chains";
import { getChainConfig, getSwapApiKey, type ChainConfig } from "../config";

export type SwapSource = "uniswap" | "odos" | "oogabooga";

export interface SwapQuote {
  routerAddress: Address;
  routerData: `0x${string}`;
  minAmountOut: bigint;
  expectedAmountOut: bigint;
  collateralMarketId: bigint;
  lendingConfig?: `0x${string}`; // Raw lending config for non-Dolomite modules
  /** Which provider produced this quote — drives which on-chain module the executor invokes. */
  source: SwapSource;
}

// ============ OogaBooga (Berachain) ============

interface OogaBoogaQuoteResponse {
  routerAddress: string;
  data: string;
  expectedOutput: string;
  minimumOutput: string;
}

async function getOogaBoogaQuote(
  cfg: ChainConfig,
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint,
  slippageBps: number
): Promise<SwapQuote> {
  const url = new URL(`${cfg.swapApiUrl}/v1/swap/quote`);
  url.searchParams.set("tokenIn", tokenIn);
  url.searchParams.set("tokenOut", tokenOut);
  url.searchParams.set("amount", amountIn.toString());
  url.searchParams.set("slippage", (slippageBps / 10000).toString());

  const res = await fetch(url.toString(), {
    headers: { Authorization: `Bearer ${getSwapApiKey()}` },
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`OogaBooga quote failed (${res.status}): ${text}`);
  }

  const data: OogaBoogaQuoteResponse = await res.json();

  return {
    routerAddress: data.routerAddress as Address,
    routerData: data.data as `0x${string}`,
    minAmountOut: BigInt(data.minimumOutput),
    expectedAmountOut: BigInt(data.expectedOutput),
    collateralMarketId: 0n,
    source: "oogabooga",
  };
}

// ============ Odos (Arbitrum) ============

interface OdosQuoteResponse {
  pathId: string;
  outAmounts: string[];
  outValues: string[];
  gasEstimate: number;
}

interface OdosAssembleResponse {
  transaction: {
    to: string;
    data: string;
    value: string;
  };
  outputTokens: Array<{ amount: string }>;
}

async function getOdosQuote(
  cfg: ChainConfig,
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint,
  fromAddress: Address,
  slippageBps: number
): Promise<SwapQuote> {
  const slippagePct = slippageBps / 100;
  // Odos /sor/assemble occasionally returns 500 with errorCode 3110 ("please try again")
  // for small or thinly-routed swaps. Retry up to 3 times with a short delay.
  const MAX_RETRIES = 3;
  let lastErr: Error | null = null;

  for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
    try {
      const quoteRes = await fetch(`${cfg.swapApiUrl}/sor/quote/v2`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chainId: cfg.chainId,
          inputTokens: [{ tokenAddress: tokenIn, amount: amountIn.toString() }],
          outputTokens: [{ tokenAddress: tokenOut, proportion: 1 }],
          slippageLimitPercent: slippagePct,
          userAddr: fromAddress,
          referralCode: 0,
          disableRFQs: false,
          compact: true,
        }),
      });

      if (!quoteRes.ok) {
        const text = await quoteRes.text();
        throw new Error(`Odos quote failed (${quoteRes.status}): ${text}`);
      }

      const quote: OdosQuoteResponse = await quoteRes.json();

      const assembleRes = await fetch(`${cfg.swapApiUrl}/sor/assemble`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          userAddr: fromAddress,
          pathId: quote.pathId,
          simulate: false,
        }),
      });

      if (!assembleRes.ok) {
        const text = await assembleRes.text();
        throw new Error(`Odos assemble failed (${assembleRes.status}): ${text}`);
      }

      const assembled: OdosAssembleResponse = await assembleRes.json();
      const expectedOut = BigInt(assembled.outputTokens[0].amount);
      const minOut = (expectedOut * BigInt(10000 - slippageBps)) / 10000n;

      return {
        routerAddress: assembled.transaction.to as Address,
        routerData: assembled.transaction.data as `0x${string}`,
        minAmountOut: minOut,
        expectedAmountOut: expectedOut,
        collateralMarketId: 0n,
        source: "odos",
      };
    } catch (e: any) {
      lastErr = e;
      // Only retry on transient assemble/quote failures (5xx, errorCode 3110, network).
      const msg = e?.message ?? "";
      const transient = /\(5\d\d\)|3110|fetch failed|ETIMEDOUT|ECONNRESET/i.test(msg);
      if (!transient || attempt === MAX_RETRIES - 1) throw e;
      console.warn(`[Odos] transient error on attempt ${attempt + 1}: ${msg.slice(0, 120)} — retrying…`);
      await new Promise((r) => setTimeout(r, 500 * (attempt + 1)));
    }
  }
  throw lastErr ?? new Error("Odos quote failed after retries");
}

// ============ Uniswap V3 (Arbitrum) — primary swap provider ============

/// Uniswap V3 SwapRouter — canonical address, same on Arbitrum/Ethereum/Optimism/Polygon
const UNISWAP_V3_ROUTER = "0xE592427A0AEce92De3Edee1F18E0157C05861564" as Address;
/// Uniswap V3 QuoterV2 on Arbitrum (for off-chain price queries)
const UNISWAP_V3_QUOTER_ARB = "0x61fFE014bA17989E743c5F6cB21bF9697530B21e" as Address;

// Known assets on Arbitrum used for routing
const ARB_USDC   = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831".toLowerCase();
const ARB_WSTETH = "0x5979D7b546E38E414F7E9822514be443A4800529".toLowerCase();
const ARB_WBTC   = "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f".toLowerCase();
const ARB_WETH   = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1".toLowerCase();

/**
 * Build the Uniswap V3 multi-hop path bytes for known token pairs on Arbitrum.
 * Path is `tokenA | fee | tokenB | fee | tokenC`, where fee is uint24 (3 bytes).
 * Returns null if we don't have a known route for the pair (caller should fall back to Odos).
 */
function buildArbUniswapPath(tokenIn: Address, tokenOut: Address): `0x${string}` | null {
  const a = tokenIn.toLowerCase();
  const b = tokenOut.toLowerCase();

  // Direct pools we know about
  // USDC ↔ WETH @ 500
  if ((a === ARB_USDC && b === ARB_WETH) || (a === ARB_WETH && b === ARB_USDC)) {
    return encodePacked(["address", "uint24", "address"], [tokenIn, 500, tokenOut]);
  }
  // USDC ↔ wstETH via WETH (USDC-500-WETH, WETH-100-wstETH)
  if ((a === ARB_USDC && b === ARB_WSTETH) || (a === ARB_WSTETH && b === ARB_USDC)) {
    if (a === ARB_USDC) return encodePacked(["address", "uint24", "address", "uint24", "address"], [tokenIn, 500, ARB_WETH as Address, 100, tokenOut]);
    return encodePacked(["address", "uint24", "address", "uint24", "address"], [tokenIn, 100, ARB_WETH as Address, 500, tokenOut]);
  }
  // USDC ↔ WBTC via WETH (USDC-500-WETH, WETH-500-WBTC)
  if ((a === ARB_USDC && b === ARB_WBTC) || (a === ARB_WBTC && b === ARB_USDC)) {
    if (a === ARB_USDC) return encodePacked(["address", "uint24", "address", "uint24", "address"], [tokenIn, 500, ARB_WETH as Address, 500, tokenOut]);
    return encodePacked(["address", "uint24", "address", "uint24", "address"], [tokenIn, 500, ARB_WETH as Address, 500, tokenOut]);
  }
  // wstETH ↔ WETH @ 100 (used by close path on partial collateral swaps if ever needed)
  if ((a === ARB_WSTETH && b === ARB_WETH) || (a === ARB_WETH && b === ARB_WSTETH)) {
    return encodePacked(["address", "uint24", "address"], [tokenIn, 100, tokenOut]);
  }
  return null;
}

const uniswapRouterAbi = [{
  type: "function", name: "exactInput", stateMutability: "payable",
  inputs: [{
    type: "tuple", name: "params", components: [
      { name: "path", type: "bytes" },
      { name: "recipient", type: "address" },
      { name: "deadline", type: "uint256" },
      { name: "amountIn", type: "uint256" },
      { name: "amountOutMinimum", type: "uint256" },
    ],
  }],
  outputs: [{ name: "amountOut", type: "uint256" }],
}] as const;

const quoterV2Abi = [{
  type: "function", name: "quoteExactInput", stateMutability: "nonpayable",
  inputs: [
    { name: "path", type: "bytes" },
    { name: "amountIn", type: "uint256" },
  ],
  outputs: [
    { name: "amountOut", type: "uint256" },
    { name: "sqrtPriceX96AfterList", type: "uint160[]" },
    { name: "initializedTicksCrossedList", type: "uint32[]" },
    { name: "gasEstimate", type: "uint256" },
  ],
}] as const;

async function getUniswapV3Quote(
  cfg: ChainConfig,
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint,
  recipient: Address,
  slippageBps: number,
): Promise<SwapQuote> {
  if (cfg.chainId !== 42161) throw new Error(`Uniswap quote only wired for Arbitrum (got chainId ${cfg.chainId})`);

  const path = buildArbUniswapPath(tokenIn, tokenOut);
  if (!path) throw new Error(`No Uniswap path for ${tokenIn} → ${tokenOut} on Arbitrum`);

  // Off-chain price discovery via QuoterV2 (callStatic / eth_call on a nonpayable fn).
  const pub = createPublicClient({ chain: arbitrum, transport: http(cfg.rpcUrl) });
  const { result } = await pub.simulateContract({
    address: UNISWAP_V3_QUOTER_ARB,
    abi: quoterV2Abi,
    functionName: "quoteExactInput",
    args: [path, amountIn],
  });
  const expectedOut = result[0] as bigint;
  if (expectedOut === 0n) throw new Error("Uniswap quoter returned 0");

  const minOut = (expectedOut * BigInt(10000 - slippageBps)) / 10000n;

  const routerData = encodeFunctionData({
    abi: uniswapRouterAbi, functionName: "exactInput",
    args: [{
      path,
      recipient,
      deadline: BigInt(Math.floor(Date.now() / 1000) + 600),
      amountIn,
      // Uniswap's own min-check is set to 1 — slippage is enforced by the vault module's `minAmountOut`
      // (which is what `executor` passes alongside this calldata). Letting Uniswap revert later would
      // surface a less-useful "STF" error.
      amountOutMinimum: 1n,
    }],
  });

  return {
    routerAddress: UNISWAP_V3_ROUTER,
    routerData,
    minAmountOut: minOut,
    expectedAmountOut: expectedOut,
    collateralMarketId: 0n,
    source: "uniswap",
  };
}

// ============ Unified API ============

/**
 * Force an Odos quote. Used by close paths where MorphoModule's internal swap router
 * is hardcoded to Odos — using Uniswap calldata there would send Uniswap-encoded data
 * to the Odos router and revert.
 */
export async function getOdosSwapQuote(
  chainId: number,
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint,
  fromAddress: Address,
  slippageBps = 200,
): Promise<SwapQuote> {
  return getOdosQuote(getChainConfig(chainId), tokenIn, tokenOut, amountIn, fromAddress, slippageBps);
}

/**
 * Get a swap quote, preferring Uniswap V3 on Arbitrum and falling back to Odos.
 * On Berachain, OogaBooga is the only path. The returned `source` tells the executor
 * which on-chain module (swap.uniswap vs swap.odos) to invoke.
 */
export async function getSwapQuote(
  chainId: number,
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint,
  slippageBps = 50,
  fromAddress?: Address
): Promise<SwapQuote> {
  const cfg = getChainConfig(chainId);

  // Berachain: only OogaBooga supported
  if (cfg.swapProvider === "oogabooga") {
    return getOogaBoogaQuote(cfg, tokenIn, tokenOut, amountIn, slippageBps);
  }

  // Arbitrum: try Uniswap V3 first; on failure (no path / low liquidity / RPC error), fall back to Odos.
  if (!fromAddress) throw new Error("fromAddress required for Arbitrum quotes");
  try {
    const q = await getUniswapV3Quote(cfg, tokenIn, tokenOut, amountIn, fromAddress, slippageBps);
    console.log(`[swap] Uniswap V3 quote OK: ${amountIn} ${tokenIn.slice(0,6)} → ${q.expectedAmountOut} ${tokenOut.slice(0,6)}`);
    return q;
  } catch (uniErr: any) {
    console.warn(`[swap] Uniswap unavailable (${uniErr.message?.slice(0, 100)}) — falling back to Odos`);
    return getOdosQuote(cfg, tokenIn, tokenOut, amountIn, fromAddress, slippageBps);
  }
}

/**
 * Borrow amount = allocation × borrowRatioBps / 10000.
 *
 * Default 50%: keeps the Morpho position well below the 86% LLTV liquidation
 * threshold. Earlier code defaulted to 80% (margin-efficient) but didn't leave
 * headroom for adverse moves — a 7-8% price drop in wstETH/USDC could push the
 * position toward liquidation. At 50% LTV the position can absorb a 40%+ adverse
 * move before health becomes a concern, matching the 35% max rebalance threshold.
 */
export function estimateBorrowAmount(
  allocation: bigint,
  borrowRatioBps = 5000n
): bigint {
  return (allocation * borrowRatioBps) / 10000n;
}
