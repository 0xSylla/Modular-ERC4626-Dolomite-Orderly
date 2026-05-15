import "dotenv/config";
import {
  createPublicClient, createWalletClient, http, keccak256, encodeAbiParameters,
  decodeAbiParameters, encodeFunctionData,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { getChainConfig, getOperatorPrivateKey } from "../src/config";
import { getModuleLendingConfig, MODULE_TYPES } from "../src/services/blockchain";
import { getSwapQuote } from "../src/services/swap";
import { routerAbi } from "../src/abis/router";

const VAULT = (process.env.VAULT ?? "0x6bBeaa348b8b11A70E38fEbaDC89BBA695A8c3Ba") as `0x${string}`;
const POS = 0n;
const MORPHO = "0x6c247b1F6182318877311737BaC0844bAa518F5e" as `0x${string}`;
const ODOS_QUOTE = "https://api.odos.xyz/sor/quote/v2";
const ODOS_ASSEMBLE = "https://api.odos.xyz/sor/assemble";

const morphoAbi = [{
  type: "function", name: "position",
  inputs: [{ name: "id", type: "bytes32" }, { name: "user", type: "address" }],
  outputs: [
    { name: "supplyShares", type: "uint256" },
    { name: "borrowShares", type: "uint128" },
    { name: "collateral", type: "uint128" },
  ],
  stateMutability: "view",
}, {
  type: "function", name: "market",
  inputs: [{ name: "id", type: "bytes32" }],
  outputs: [
    { name: "totalSupplyAssets",  type: "uint128" },
    { name: "totalSupplyShares",  type: "uint128" },
    { name: "totalBorrowAssets",  type: "uint128" },
    { name: "totalBorrowShares",  type: "uint128" },
    { name: "lastUpdate",         type: "uint128" },
    { name: "fee",                type: "uint128" },
  ],
  stateMutability: "view",
}] as const;

const morphoModuleAbi = [
  { type: "function", name: "repayDebt", stateMutability: "payable", outputs: [],
    inputs: [
      { name: "borrowAsset", type: "address" }, { name: "_amount", type: "uint256" },
      { name: "collateralAsset", type: "address" }, { name: "oracle", type: "address" },
      { name: "irm", type: "address" }, { name: "lltv", type: "uint256" },
    ],
  },
  { type: "function", name: "withdrawCollateral", stateMutability: "payable", outputs: [],
    inputs: [
      { name: "collateralAsset", type: "address" }, { name: "_amount", type: "uint256" },
      { name: "loanToken", type: "address" }, { name: "oracle", type: "address" },
      { name: "irm", type: "address" }, { name: "lltv", type: "uint256" },
    ],
  },
] as const;

const odosModuleAbi = [
  { type: "function", name: "swap", stateMutability: "payable", outputs: [],
    inputs: [
      { name: "tokenIn", type: "address" }, { name: "amountIn", type: "uint256" },
      { name: "tokenOut", type: "address" }, { name: "minAmountOut", type: "uint256" },
      { name: "odosCalldata", type: "bytes" },
    ],
  },
] as const;

const erc20 = [{type:"function",name:"balanceOf",inputs:[{type:"address"}],outputs:[{type:"uint256"}],stateMutability:"view"}] as const;

async function odosQuote(tokenIn: string, tokenOut: string, amount: bigint, user: string, slippageBps: number) {
  const slippagePct = slippageBps / 100;
  const q = await (await fetch(ODOS_QUOTE, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      chainId: 42161,
      inputTokens: [{ tokenAddress: tokenIn, amount: amount.toString() }],
      outputTokens: [{ tokenAddress: tokenOut, proportion: 1 }],
      slippageLimitPercent: slippagePct,
      userAddr: user,
      referralCode: 0, disableRFQs: false, compact: true,
    }),
  })).json() as any;
  if (!q.pathId) throw new Error(`Odos quote: ${JSON.stringify(q)}`);
  const a = await (await fetch(ODOS_ASSEMBLE, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ userAddr: user, pathId: q.pathId, simulate: false }),
  })).json() as any;
  if (!a.transaction?.data) throw new Error(`Odos assemble: ${JSON.stringify(a)}`);
  const expected = BigInt(a.outputTokens[0].amount);
  const minOut = (expected * BigInt(10000 - slippageBps)) / 10000n;
  return { calldata: a.transaction.data as `0x${string}`, expected, minOut };
}

async function odosQuoteWithRetry(...args: Parameters<typeof odosQuote>) {
  for (let i = 0; i < 4; i++) {
    try { return await odosQuote(...args); }
    catch (e: any) {
      if (i === 3 || !/5\d\d|3110|fetch failed/i.test(e.message)) throw e;
      console.log("  Odos transient, retrying...");
      await new Promise(r => setTimeout(r, 800 * (i + 1)));
    }
  }
  throw new Error("unreachable");
}

async function main() {
  const cfg = getChainConfig(42161);
  const pub = createPublicClient({ chain: arbitrum, transport: http(cfg.rpcUrl) });
  const account = privateKeyToAccount(getOperatorPrivateKey());
  const wc = createWalletClient({ account, chain: arbitrum, transport: http(cfg.rpcUrl) });

  const wstETH = "0x5979D7b546E38E414F7E9822514be443A4800529" as `0x${string}`;
  const lc = await getModuleLendingConfig(42161, MODULE_TYPES.LENDING_MORPHO, wstETH);
  const [loanToken, collateralToken, oracle, irm, lltv] = decodeAbiParameters(
    [{type:"address"},{type:"address"},{type:"address"},{type:"address"},{type:"uint256"}], lc!) as
    [`0x${string}`,`0x${string}`,`0x${string}`,`0x${string}`,bigint];

  const marketId = keccak256(encodeAbiParameters(
    [{type:"tuple",components:[
      {name:"loanToken",type:"address"},{name:"collateralToken",type:"address"},
      {name:"oracle",type:"address"},{name:"irm",type:"address"},{name:"lltv",type:"uint256"}
    ]}],
    [{ loanToken, collateralToken, oracle, irm, lltv }] as any
  ));

  const [pos, mkt, oraclePrice, vUsdc, vWst] = await Promise.all([
    pub.readContract({ address: MORPHO, abi: morphoAbi, functionName: "position", args: [marketId, VAULT] }) as Promise<readonly [bigint, bigint, bigint]>,
    pub.readContract({ address: MORPHO, abi: morphoAbi, functionName: "market", args: [marketId] }) as Promise<readonly [bigint, bigint, bigint, bigint, bigint, bigint]>,
    pub.readContract({ address: oracle, abi: [{type:"function",name:"price",inputs:[],outputs:[{type:"uint256"}],stateMutability:"view"}] as const, functionName: "price" }) as Promise<bigint>,
    pub.readContract({ address: loanToken, abi: erc20, functionName: "balanceOf", args: [VAULT] }) as Promise<bigint>,
    pub.readContract({ address: collateralToken, abi: erc20, functionName: "balanceOf", args: [VAULT] }) as Promise<bigint>,
  ]);

  const totalCollateral = BigInt(pos[2]);
  const borrowShares = BigInt(pos[1]);
  const debtAssets = (borrowShares * BigInt(mkt[2])) / BigInt(mkt[3]) + 1n;
  console.log("Morpho debt (USDC raw):", debtAssets.toString());
  console.log("Morpho collateral (wstETH wei):", totalCollateral.toString());
  console.log("Vault USDC:", vUsdc.toString(), "wstETH:", vWst.toString());

  const partialRepayAmt = vUsdc > debtAssets ? debtAssets : vUsdc;
  const remainingDebt = debtAssets - partialRepayAmt;
  console.log("\npartial repay:", partialRepayAmt.toString(), "remaining debt:", remainingDebt.toString());

  // minCollateral with 10% buffer (the on-chain check uses spot oracle price; we want headroom)
  const minCollateral = (remainingDebt * (10n ** 36n) * (10n ** 18n) * 110n) / (oraclePrice * lltv * 100n);
  if (minCollateral >= totalCollateral) throw new Error("minCollateral >= totalCollateral");
  const partialWithdrawAmt = totalCollateral - minCollateral;
  console.log("partial withdraw:", partialWithdrawAmt.toString(), "/ leaving:", minCollateral.toString());

  // Use the unified getSwapQuote which prefers Uniswap V3 on Arbitrum (the module whitelisted on
  // this vault) and falls back to Odos automatically. The returned `source` tells us which
  // module hash to use in the executeClosingRequest call below.
  console.log("\nFetching swap quote 1 (partial)...");
  const sq1 = await getSwapQuote(42161, wstETH, loanToken, partialWithdrawAmt, 200, VAULT);
  console.log("  source:", sq1.source, "expected:", sq1.expectedAmountOut.toString(), "minOut:", sq1.minAmountOut.toString());
  const q1 = { calldata: sq1.routerData, expected: sq1.expectedAmountOut, minOut: sq1.minAmountOut };

  const swap2Amt = minCollateral + vWst;
  console.log("Fetching swap quote 2 (remainder + dust =", swap2Amt.toString(), ")...");
  const sq2 = await getSwapQuote(42161, wstETH, loanToken, swap2Amt, 200, VAULT);
  console.log("  source:", sq2.source, "expected:", sq2.expectedAmountOut.toString(), "minOut:", sq2.minAmountOut.toString());
  const q2 = { calldata: sq2.routerData, expected: sq2.expectedAmountOut, minOut: sq2.minAmountOut };

  // Both swaps must use the SAME source to avoid mixing module hashes in the modules array;
  // if they ever disagree (e.g. Uniswap routed one but not the other), the fallback is still
  // correct because both Uniswap and Odos modules have identical swap signatures — but pick
  // one consistently for clarity.
  const SWAP_MODULE_HASH = sq1.source === "uniswap" && sq2.source === "uniswap"
    ? MODULE_TYPES.SWAP_UNISWAP
    : MODULE_TYPES.SWAP_ODOS;
  console.log("Using swap module hash:", SWAP_MODULE_HASH);

  const repayPartialData = encodeFunctionData({ abi: morphoModuleAbi, functionName: "repayDebt",
    args: [loanToken, partialRepayAmt, collateralToken, oracle, irm, lltv] });
  const withdrawPartialData = encodeFunctionData({ abi: morphoModuleAbi, functionName: "withdrawCollateral",
    args: [collateralToken, partialWithdrawAmt, loanToken, oracle, irm, lltv] });
  const swap1Data = encodeFunctionData({ abi: odosModuleAbi, functionName: "swap",
    args: [collateralToken, partialWithdrawAmt, loanToken, q1.minOut, q1.calldata] });
  const repayFullData = encodeFunctionData({ abi: morphoModuleAbi, functionName: "repayDebt",
    args: [loanToken, BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"), collateralToken, oracle, irm, lltv] });
  const withdrawRestData = encodeFunctionData({ abi: morphoModuleAbi, functionName: "withdrawCollateral",
    args: [collateralToken, minCollateral, loanToken, oracle, irm, lltv] });
  const swap2Data = encodeFunctionData({ abi: odosModuleAbi, functionName: "swap",
    args: [collateralToken, swap2Amt, loanToken, q2.minOut, q2.calldata] });

  const modules = [
    MODULE_TYPES.LENDING_MORPHO, MODULE_TYPES.LENDING_MORPHO, SWAP_MODULE_HASH,
    MODULE_TYPES.LENDING_MORPHO, MODULE_TYPES.LENDING_MORPHO, SWAP_MODULE_HASH,
  ];
  const datas = [
    repayPartialData, withdrawPartialData, swap1Data,
    repayFullData, withdrawRestData, swap2Data,
  ];

  console.log("\nSimulating executeClosingRequest...");
  try {
    await pub.simulateContract({
      account: account.address,
      address: cfg.routerAddr,
      abi: routerAbi,
      functionName: "executeClosingRequest",
      args: [VAULT, POS, modules, datas],
    });
    console.log("Simulation passed");
  } catch (e: any) {
    console.log("SIMULATE REVERT:", e.shortMessage);
    if (e.metaMessages) console.log("meta:", e.metaMessages.slice(0, 3));
    throw e;
  }

  console.log("Broadcasting tx...");
  const data = encodeFunctionData({
    abi: routerAbi, functionName: "executeClosingRequest",
    args: [VAULT, POS, modules, datas],
  });
  const hash = await wc.sendTransaction({ to: cfg.routerAddr, data, value: 0n });
  console.log("tx:", hash);
  const rcpt = await pub.waitForTransactionReceipt({ hash });
  console.log("status:", rcpt.status, "gas used:", rcpt.gasUsed.toString());

  const [finalUsdc, finalWst] = await Promise.all([
    pub.readContract({ address: loanToken, abi: erc20, functionName: "balanceOf", args: [VAULT] }) as Promise<bigint>,
    pub.readContract({ address: collateralToken, abi: erc20, functionName: "balanceOf", args: [VAULT] }) as Promise<bigint>,
  ]);
  console.log("\n=== FINAL VAULT STATE ===");
  console.log("USDC:  ", (Number(finalUsdc) / 1e6).toFixed(4));
  console.log("wstETH:", (Number(finalWst) / 1e18).toFixed(6));
}
main().catch((e) => { console.error("recover.ts failed:", e.message ?? e); process.exit(1); });
