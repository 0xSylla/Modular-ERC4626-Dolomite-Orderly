import { type Address } from "viem";
import { getChainConfig, getSwapApiKey, type ChainConfig } from "../config";

export interface SwapQuote {
  routerAddress: Address;
  routerData: `0x${string}`;
  minAmountOut: bigint;
  expectedAmountOut: bigint;
  collateralMarketId: bigint;
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
  };
}

// ============ Unified API ============

export async function getSwapQuote(
  chainId: number,
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint,
  slippageBps = 50,
  fromAddress?: Address
): Promise<SwapQuote> {
  const cfg = getChainConfig(chainId);
  if (cfg.swapProvider === "odos") {
    if (!fromAddress) throw new Error("fromAddress required for Odos quotes");
    return getOdosQuote(cfg, tokenIn, tokenOut, amountIn, fromAddress, slippageBps);
  }
  return getOogaBoogaQuote(cfg, tokenIn, tokenOut, amountIn, slippageBps);
}

export function estimateBorrowAmount(
  allocation: bigint,
  borrowRatioBps = 8000n
): bigint {
  return (allocation * borrowRatioBps) / 10000n;
}
