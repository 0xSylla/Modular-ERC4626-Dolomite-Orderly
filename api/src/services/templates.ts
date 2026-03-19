import { keccak256, toHex, type Address, encodeFunctionData } from "viem";
import { kodiakModuleAbi, dolomiteModuleAbi, orderlyModuleAbi } from "../abis/modules";
import type { PositionRecord } from "./blockchain";
import type { SwapQuote } from "./swap";
import { config } from "../config";

// ============ Template IDs ============

export const TEMPLATE_IDS = {
  DELTA_NEUTRAL_V1: keccak256(toHex("delta-neutral-v1")),
} as const;

// ============ Recipe Step Types ============

type LegKey = "swap" | "lending" | "perps";

interface RecipeStep {
  leg: LegKey;
  action: string;
}

interface TemplateRecipe {
  open: RecipeStep[];
  close: RecipeStep[];
}

// ============ Template Registry ============

// Each template defines the order of module calls for open and close.
// The API uses this to build the modules[] and datas[] arrays.
const templates: Record<string, TemplateRecipe> = {
  // Delta-Neutral V1: swap USDC→collateral → supply → borrow USDC → deposit to Orderly
  [TEMPLATE_IDS.DELTA_NEUTRAL_V1]: {
    open: [
      { leg: "swap", action: "swapDepositToCollateral" },
      { leg: "lending", action: "supplyCollateral" },
      { leg: "lending", action: "borrow" },
      { leg: "perps", action: "deposit" },
    ],
    close: [
      // Off-chain: close short + settle PnL + withdraw from Orderly (done before this)
      // Single zap: repay debt with collateral (unwrap diBGT → iBGT → swap to USDC via OogaBooga inside Dolomite)
      { leg: "lending", action: "repayDebtWithCollateral" },
    ],
  },
};

export function getTemplate(templateId: string): TemplateRecipe {
  const t = templates[templateId];
  if (!t) throw new Error(`Unknown template: ${templateId}`);
  return t;
}

// ============ Calldata Builders ============

interface OpenContext {
  position: PositionRecord;
  swapQuote: SwapQuote;
  borrowAmount: bigint;
  orderlyDepositData: {
    accountId: `0x${string}`;
    brokerHash: `0x${string}`;
    tokenHash: `0x${string}`;
    tokenAmount: bigint;
    fee: bigint;
  };
}

interface CloseContext {
  position: PositionRecord;
  swapQuote: SwapQuote; // OogaBooga quote for collateral → USDC (used by repayDebtWithCollateral)
}

function legToModule(leg: LegKey, position: PositionRecord): Address {
  switch (leg) {
    case "swap":
      return position.legs.swapModule;
    case "lending":
      return position.legs.lendingModule;
    case "perps":
      return position.legs.perpsModule;
  }
}

function buildOpenStepCalldata(
  step: RecipeStep,
  ctx: OpenContext
): `0x${string}` {
  const { position, swapQuote, borrowAmount, orderlyDepositData } = ctx;

  switch (step.action) {
    case "swapDepositToCollateral":
      return encodeFunctionData({
        abi: kodiakModuleAbi,
        functionName: "swap",
        args: [
          config.tokens.USDC,
          false,
          position.allocation,
          position.collateralAsset,
          false,
          swapQuote.minAmountOut,
          { router: swapQuote.routerAddress, data: swapQuote.routerData },
          { feeQuote: 0n, surplusFeeBps: 0, refCode: 0, referrerFeeBps: 0 },
        ],
      });

    case "supplyCollateral": {
      const assetInfo = swapQuote.collateralMarketId;
      return encodeFunctionData({
        abi: dolomiteModuleAbi,
        functionName: "supplyCollateral",
        args: [
          position.collateralAsset,
          BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"), // type(uint256).max = entire balance
          assetInfo,
        ],
      });
    }

    case "borrow":
      return encodeFunctionData({
        abi: dolomiteModuleAbi,
        functionName: "borrow",
        args: [borrowAmount, swapQuote.collateralMarketId, config.dolomiteMarkets.USDC],
      });

    case "deposit":
      return encodeFunctionData({
        abi: orderlyModuleAbi,
        functionName: "deposit",
        args: [
          config.tokens.USDC,
          {
            accountId: orderlyDepositData.accountId,
            brokerHash: orderlyDepositData.brokerHash,
            tokenHash: orderlyDepositData.tokenHash,
            tokenAmount: orderlyDepositData.tokenAmount,
          },
          orderlyDepositData.fee,
        ],
      });

    default:
      throw new Error(`Unknown open action: ${step.action}`);
  }
}

function buildCloseStepCalldata(
  step: RecipeStep,
  ctx: CloseContext
): `0x${string}` {
  const { position, swapQuote } = ctx;

  switch (step.action) {
    case "repayDebtWithCollateral":
      // Single zap: unwrap diBGT → iBGT → swap to USDC inside Dolomite via OogaBooga
      // pathDefinition comes from OogaBooga quote (routerData field)
      return encodeFunctionData({
        abi: dolomiteModuleAbi,
        functionName: "repayDebtWithCollateral",
        args: [
          position.collateralAsset,        // iBGT
          config.tokens.USDC,              // borrow asset
          swapQuote.minAmountOut,           // minUSDCOut
          swapQuote.expectedAmountOut,      // expectedUSDCOut
          swapQuote.routerData,             // pathDefinition from OogaBooga
          swapQuote.collateralMarketId,     // diBGT market ID
          config.dolomiteMarkets.USDC,      // USDC market ID
        ],
      });

    default:
      throw new Error(`Unknown close action: ${step.action}`);
  }
}

// ============ Public Builders ============

export function buildOpenModulesAndData(
  templateId: string,
  ctx: OpenContext
): { modules: Address[]; datas: `0x${string}`[] } {
  const recipe = getTemplate(templateId);
  const modules: Address[] = [];
  const datas: `0x${string}`[] = [];

  for (const step of recipe.open) {
    modules.push(legToModule(step.leg, ctx.position));
    datas.push(buildOpenStepCalldata(step, ctx));
  }

  return { modules, datas };
}

export function buildCloseModulesAndData(
  templateId: string,
  ctx: CloseContext
): { modules: Address[]; datas: `0x${string}`[] } {
  const recipe = getTemplate(templateId);
  const modules: Address[] = [];
  const datas: `0x${string}`[] = [];

  for (const step of recipe.close) {
    modules.push(legToModule(step.leg, ctx.position));
    datas.push(buildCloseStepCalldata(step, ctx));
  }

  return { modules, datas };
}
