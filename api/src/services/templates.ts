/**
 * Template Engine — Plugin-based module calldata builders.
 *
 * Architecture:
 *   1. Each module variant registers calldata builders for its supported actions.
 *   2. Templates define the ORDER of actions (swap → supply → borrow → deposit).
 *   3. At execution time, the engine resolves the correct builder based on the vault's legs.
 *
 * Adding a new module:
 *   1. Create the ABI in api/src/abis/modules.ts
 *   2. Register builders below under the module's type hash
 *   3. That's it — templates and executor work automatically.
 */

import { keccak256, toHex, encodeFunctionData, decodeAbiParameters, type Hex } from "viem";
import type { PositionRecord, VaultLegs } from "./blockchain";
import { MODULE_TYPES } from "./blockchain";
import type { SwapQuote } from "./swap";
import { config, getChainConfig } from "../config";

// ============ ABIs ============

// Kodiak (Berachain swap)
const kodiakSwapAbi = [{
  type: "function", name: "swap", inputs: [
    { name: "tokenA", type: "address" }, { name: "aToB", type: "bool" },
    { name: "amount", type: "uint256" }, { name: "tokenB", type: "address" },
    { name: "bToA", type: "bool" }, { name: "minOut", type: "uint256" },
    { name: "swapInfo", type: "tuple", components: [
      { name: "router", type: "address" }, { name: "data", type: "bytes" },
    ]},
    { name: "feeInfo", type: "tuple", components: [
      { name: "feeQuote", type: "uint256" }, { name: "surplusFeeBps", type: "uint256" },
      { name: "refCode", type: "uint256" }, { name: "referrerFeeBps", type: "uint256" },
    ]},
  ], outputs: [], stateMutability: "payable",
}] as const;

// Odos (Arbitrum swap)
const odosSwapAbi = [{
  type: "function", name: "swap", inputs: [
    { name: "tokenIn", type: "address" }, { name: "amountIn", type: "uint256" },
    { name: "tokenOut", type: "address" }, { name: "minAmountOut", type: "uint256" },
    { name: "odosCalldata", type: "bytes" },
  ], outputs: [], stateMutability: "payable",
}] as const;

// Dolomite (Bera + Arb lending — same interface)
const dolomiteAbi = [
  { type: "function", name: "supplyCollateral", inputs: [
    { name: "_asset", type: "address" }, { name: "_amount", type: "uint256" },
    { name: "_marketId", type: "uint256" },
  ], outputs: [], stateMutability: "payable" },
  { type: "function", name: "borrow", inputs: [
    { name: "_amount", type: "uint256" }, { name: "_collateralMarketId", type: "uint256" },
    { name: "_borrowMarketId", type: "uint256" },
  ], outputs: [], stateMutability: "payable" },
  { type: "function", name: "repayDebtWithCollateral", inputs: [
    { name: "collateralAsset", type: "address" }, { name: "borrowAsset", type: "address" },
    { name: "minAmountOut", type: "uint256" }, { name: "expectedAmountOut", type: "uint256" },
    { name: "pathDefinition", type: "bytes" },
    { name: "collateralMarketId", type: "uint256" }, { name: "borrowMarketId", type: "uint256" },
  ], outputs: [], stateMutability: "payable" },
] as const;

// Morpho (Arbitrum lending) — exported so the executor's multi-step close helper can reuse it
export const morphoAbi = [
  { type: "function", name: "supplyCollateral", inputs: [
    { name: "collateralAsset", type: "address" }, { name: "_amount", type: "uint256" },
    { name: "loanToken", type: "address" }, { name: "oracle", type: "address" },
    { name: "irm", type: "address" }, { name: "lltv", type: "uint256" },
  ], outputs: [], stateMutability: "payable" },
  { type: "function", name: "borrowAsset", inputs: [
    { name: "borrowAsset", type: "address" }, { name: "_borrowAmount", type: "uint256" },
    { name: "collateralAsset", type: "address" }, { name: "oracle", type: "address" },
    { name: "irm", type: "address" }, { name: "lltv", type: "uint256" },
  ], outputs: [], stateMutability: "payable" },
  { type: "function", name: "repayDebt", inputs: [
    { name: "borrowAsset", type: "address" }, { name: "_amount", type: "uint256" },
    { name: "collateralAsset", type: "address" }, { name: "oracle", type: "address" },
    { name: "irm", type: "address" }, { name: "lltv", type: "uint256" },
  ], outputs: [], stateMutability: "payable" },
  { type: "function", name: "withdrawCollateral", inputs: [
    { name: "collateralAsset", type: "address" }, { name: "_amount", type: "uint256" },
    { name: "loanToken", type: "address" }, { name: "oracle", type: "address" },
    { name: "irm", type: "address" }, { name: "lltv", type: "uint256" },
  ], outputs: [], stateMutability: "payable" },
  { type: "function", name: "repayDebtWithCollateral", inputs: [
    { name: "collateralAsset", type: "address" }, { name: "borrowAsset", type: "address" },
    { name: "minAmountOut", type: "uint256" }, { name: "swapData", type: "bytes" },
    { name: "oracle", type: "address" }, { name: "irm", type: "address" },
    { name: "lltv", type: "uint256" },
  ], outputs: [], stateMutability: "payable" },
] as const;

// Swap module — Uniswap and Odos share the same on-chain signature (just hardcoded different routers)
export const swapModuleAbi = [{
  type: "function", name: "swap", inputs: [
    { name: "tokenIn", type: "address" }, { name: "amountIn", type: "uint256" },
    { name: "tokenOut", type: "address" }, { name: "minAmountOut", type: "uint256" },
    { name: "routerCalldata", type: "bytes" },
  ], outputs: [], stateMutability: "payable",
}] as const;

// Orderly (perps — same on all chains)
const orderlyAbi = [
  { type: "function", name: "deposit", inputs: [
    { name: "token", type: "address" },
    { name: "depositData", type: "tuple", components: [
      { name: "accountId", type: "bytes32" }, { name: "brokerHash", type: "bytes32" },
      { name: "tokenHash", type: "bytes32" }, { name: "tokenAmount", type: "uint128" },
    ]},
    { name: "fee", type: "uint256" },
  ], outputs: [], stateMutability: "payable" },
] as const;

// ============ Context Types ============

export interface OpenContext {
  position: PositionRecord;
  legs: VaultLegs;
  swapQuote: SwapQuote;
  borrowAmount: bigint;
  chainId: number;
  orderlyDepositData: {
    accountId: `0x${string}`;
    brokerHash: `0x${string}`;
    tokenHash: `0x${string}`;
    tokenAmount: bigint;
    fee: bigint;
  };
}

export interface CloseContext {
  position: PositionRecord;
  legs: VaultLegs;
  swapQuote: SwapQuote;
  chainId: number;
}

// ============ Builder Registry ============

type OpenBuilder = (action: string, ctx: OpenContext) => `0x${string}`;
type CloseBuilder = (action: string, ctx: CloseContext) => `0x${string}`;

interface ModulePlugin {
  openBuilder: OpenBuilder;
  closeBuilder: CloseBuilder;
}

const modulePlugins = new Map<Hex, ModulePlugin>();

/** Register a module variant. Call at import time. */
export function registerModule(moduleTypeHash: Hex, plugin: ModulePlugin) {
  modulePlugins.set(moduleTypeHash, plugin);
}

function getPlugin(moduleTypeHash: Hex): ModulePlugin {
  const p = modulePlugins.get(moduleTypeHash);
  if (!p) throw new Error(`No plugin registered for module type ${moduleTypeHash}`);
  return p;
}

// ============ Helpers ============

function decodeMorphoConfig(lendingConfig: `0x${string}`) {
  const [loanToken, collateralToken, oracle, irm, lltv] = decodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "address" }, { type: "address" }, { type: "uint256" }],
    lendingConfig,
  );
  return { loanToken, collateralToken, oracle, irm, lltv };
}

function getUsdcAddress(chainId: number): `0x${string}` {
  return getChainConfig(chainId).tokens.USDC;
}

function getDolomiteUsdcMarketId(chainId: number): bigint {
  return getChainConfig(chainId).dolomiteMarkets.USDC;
}

// ============ SWAP: Kodiak (Berachain) ============

registerModule(MODULE_TYPES.SWAP_KODIAK, {
  openBuilder(action, ctx) {
    if (action !== "swapDepositToCollateral") throw new Error(`Kodiak: unknown open action ${action}`);
    return encodeFunctionData({
      abi: kodiakSwapAbi, functionName: "swap",
      args: [
        getUsdcAddress(ctx.chainId), false, ctx.position.allocation,
        ctx.position.collateralAsset, false, ctx.swapQuote.minAmountOut,
        { router: ctx.swapQuote.routerAddress, data: ctx.swapQuote.routerData },
        { feeQuote: 0n, surplusFeeBps: 0n, refCode: 0n, referrerFeeBps: 0n },
      ],
    });
  },
  closeBuilder(_action, _ctx) {
    throw new Error("Kodiak has no close actions — lending module handles close");
  },
});

// ============ SWAP: Odos (Arbitrum) ============

// The Uniswap and Odos modules share the same on-chain swap signature
// (tokenIn, amountIn, tokenOut, minOut, routerCalldata) — the only difference
// is which router each module forwards to. So one builder works for both.
const arbitrumSwapPlugin = {
  openBuilder(action: string, ctx: OpenContext): `0x${string}` {
    if (action !== "swapDepositToCollateral") throw new Error(`Swap: unknown open action ${action}`);
    return encodeFunctionData({
      abi: odosSwapAbi, functionName: "swap",
      args: [
        getUsdcAddress(ctx.chainId), ctx.position.allocation,
        ctx.position.collateralAsset, ctx.swapQuote.minAmountOut,
        ctx.swapQuote.routerData,
      ],
    });
  },
  closeBuilder(_action: string, _ctx: CloseContext): `0x${string}` {
    throw new Error("Arbitrum swap modules have no close actions — lending module handles close");
  },
};

registerModule(MODULE_TYPES.SWAP_ODOS, arbitrumSwapPlugin);
registerModule(MODULE_TYPES.SWAP_UNISWAP, arbitrumSwapPlugin);

// ============ LENDING: Dolomite (Bera + Arb) ============

function registerDolomite(hash: Hex) {
  registerModule(hash, {
    openBuilder(action, ctx) {
      const mktId = ctx.swapQuote.collateralMarketId;
      switch (action) {
        case "supplyCollateral":
          return encodeFunctionData({
            abi: dolomiteAbi, functionName: "supplyCollateral",
            args: [ctx.position.collateralAsset, BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"), mktId],
          });
        case "borrow":
          return encodeFunctionData({
            abi: dolomiteAbi, functionName: "borrow",
            args: [ctx.borrowAmount, mktId, getDolomiteUsdcMarketId(ctx.chainId)],
          });
        default: throw new Error(`Dolomite: unknown open action ${action}`);
      }
    },
    closeBuilder(action, ctx) {
      if (action !== "repayDebtWithCollateral") throw new Error(`Dolomite: unknown close action ${action}`);
      const mktId = ctx.swapQuote.collateralMarketId;
      return encodeFunctionData({
        abi: dolomiteAbi, functionName: "repayDebtWithCollateral",
        args: [
          ctx.position.collateralAsset, getUsdcAddress(ctx.chainId),
          ctx.swapQuote.minAmountOut, ctx.swapQuote.expectedAmountOut,
          ctx.swapQuote.routerData, mktId, getDolomiteUsdcMarketId(ctx.chainId),
        ],
      });
    },
  });
}

registerDolomite(MODULE_TYPES.LENDING_DOLOMITE);

// ============ LENDING: Morpho (Arbitrum) ============

registerModule(MODULE_TYPES.LENDING_MORPHO, {
  openBuilder(action, ctx) {
    const lc = ctx.swapQuote.lendingConfig;
    if (!lc) throw new Error("Morpho: missing lendingConfig in swapQuote");
    const { loanToken, oracle, irm, lltv } = decodeMorphoConfig(lc);
    switch (action) {
      case "supplyCollateral":
        // MorphoModule.supplyCollateral does NOT interpret max as "full balance" (Dolomite does, Morpho doesn't).
        // Pass swap minAmountOut — guaranteed to be ≤ vault's wstETH balance after the swap step.
        return encodeFunctionData({
          abi: morphoAbi, functionName: "supplyCollateral",
          args: [ctx.position.collateralAsset, ctx.swapQuote.minAmountOut, loanToken, oracle, irm, lltv],
        });
      case "borrow":
        return encodeFunctionData({
          abi: morphoAbi, functionName: "borrowAsset",
          args: [loanToken, ctx.borrowAmount, ctx.position.collateralAsset, oracle, irm, lltv],
        });
      default: throw new Error(`Morpho: unknown open action ${action}`);
    }
  },
  closeBuilder(action, ctx) {
    if (action !== "repayDebtWithCollateral") throw new Error(`Morpho: unknown close action ${action}`);
    const lc = ctx.swapQuote.lendingConfig;
    if (!lc) throw new Error("Morpho: missing lendingConfig in swapQuote");
    const { oracle, irm, lltv } = decodeMorphoConfig(lc);
    return encodeFunctionData({
      abi: morphoAbi, functionName: "repayDebtWithCollateral",
      args: [
        ctx.position.collateralAsset, getUsdcAddress(ctx.chainId),
        ctx.swapQuote.minAmountOut, ctx.swapQuote.routerData,
        oracle, irm, lltv,
      ],
    });
  },
});

// ============ LENDING: Aave V3 (Arbitrum) — stub, add builders when ready ============

registerModule(MODULE_TYPES.LENDING_AAVE, {
  openBuilder(action, _ctx) {
    throw new Error(`Aave: open action "${action}" not yet implemented`);
  },
  closeBuilder(action, _ctx) {
    throw new Error(`Aave: close action "${action}" not yet implemented`);
  },
});

// ============ PERPS: Orderly (all chains) ============

registerModule(MODULE_TYPES.PERPS_ORDERLY, {
  openBuilder(action, ctx) {
    if (action !== "deposit") throw new Error(`Orderly: unknown open action ${action}`);
    return encodeFunctionData({
      abi: orderlyAbi, functionName: "deposit",
      args: [
        getUsdcAddress(ctx.chainId),
        {
          accountId: ctx.orderlyDepositData.accountId,
          brokerHash: ctx.orderlyDepositData.brokerHash,
          tokenHash: ctx.orderlyDepositData.tokenHash,
          tokenAmount: ctx.orderlyDepositData.tokenAmount,
        },
        ctx.orderlyDepositData.fee,
      ],
    });
  },
  closeBuilder(_action, _ctx) {
    throw new Error("Orderly has no close actions — off-chain close happens before on-chain");
  },
});

// ============ Template Registry ============

export const TEMPLATE_IDS = {
  DELTA_NEUTRAL_V1: keccak256(toHex("delta-neutral-v1")),
} as const;

type LegKey = "swap" | "lending" | "perps";

interface RecipeStep {
  leg: LegKey;
  action: string;
}

interface TemplateRecipe {
  open: RecipeStep[];
  close: RecipeStep[];
}

const templates: Record<string, TemplateRecipe> = {
  [TEMPLATE_IDS.DELTA_NEUTRAL_V1]: {
    open: [
      { leg: "swap", action: "swapDepositToCollateral" },
      { leg: "lending", action: "supplyCollateral" },
      { leg: "lending", action: "borrow" },
      { leg: "perps", action: "deposit" },
    ],
    close: [
      { leg: "lending", action: "repayDebtWithCollateral" },
    ],
  },
};

export function getTemplate(templateId: string): TemplateRecipe {
  const t = templates[templateId];
  if (!t) throw new Error(`Unknown template: ${templateId}`);
  return t;
}

// ============ Leg → Module Type Resolution ============

function legToModuleType(leg: LegKey, legs: VaultLegs): Hex {
  switch (leg) {
    case "swap": return legs.swapModuleType;
    case "lending": return legs.lendingModuleType;
    case "perps": return legs.perpsModuleType;
  }
}

// ============ Public Builders ============

export function buildOpenModulesAndData(
  templateId: string,
  ctx: OpenContext
): { modules: Hex[]; datas: `0x${string}`[] } {
  const recipe = getTemplate(templateId);
  const modules: Hex[] = [];
  const datas: `0x${string}`[] = [];

  for (const step of recipe.open) {
    const moduleType = legToModuleType(step.leg, ctx.legs);
    modules.push(moduleType);
    const plugin = getPlugin(moduleType);
    datas.push(plugin.openBuilder(step.action, ctx));
  }

  return { modules, datas };
}

export function buildCloseModulesAndData(
  templateId: string,
  ctx: CloseContext
): { modules: Hex[]; datas: `0x${string}`[] } {
  const recipe = getTemplate(templateId);
  const modules: Hex[] = [];
  const datas: `0x${string}`[] = [];

  for (const step of recipe.close) {
    const moduleType = legToModuleType(step.leg, ctx.legs);
    modules.push(moduleType);
    const plugin = getPlugin(moduleType);
    datas.push(plugin.closeBuilder(step.action, ctx));
  }

  return { modules, datas };
}
