import { type Address, keccak256, stringToHex, decodeAbiParameters, encodeFunctionData, encodeAbiParameters, createPublicClient, http } from "viem";
import { arbitrum } from "viem/chains";
import {
  getVaultInfo,
  getPosition,
  getVaultLegs,
  getModuleLendingConfig,
  getMorphoCollateral,
  executeOpeningRequest,
  confirmOpen,
  executeClosingRequest,
  executeRebalanceClose,
  executeRebalanceOpen,
  vaultExecuteBatch,
  MODULE_TYPES,
  type PositionRecord,
} from "./blockchain";
import { buildOpenModulesAndData, buildCloseModulesAndData, morphoAbi, swapModuleAbi } from "./templates";
import { getSwapQuote, getOdosSwapQuote, estimateBorrowAmount, type SwapQuote } from "./swap";

/**
 * Vault legs declare the curator-preferred swap module (e.g. swap.uniswap), but if our
 * quote came from a different provider (e.g. Odos fallback when Uniswap had no route),
 * the executor must invoke the matching on-chain module. This rewrites the swap-leg
 * module hash in place based on the chosen quote's source.
 *
 * The swap leg is the first call in the open recipe (index 0). If recipes ever change,
 * update this together with the recipe.
 */
function overrideSwapModuleFromQuote(modules: `0x${string}`[], quote: SwapQuote): void {
  if (modules.length === 0) return;
  if (quote.source === "uniswap") modules[0] = MODULE_TYPES.SWAP_UNISWAP;
  else if (quote.source === "odos") modules[0] = MODULE_TYPES.SWAP_ODOS;
  // oogabooga: no override needed — Berachain only has the one module
}

/**
 * Dispatch helper used by all close paths (runCloseFlow, runResumeCloseFlow, runRebalanceFlow).
 * Morpho uses the multi-step pattern (robust to the partial-USDC case). Dolomite uses the
 * existing single-call repayDebtWithCollateral template (it doesn't have the same bug because
 * its module handles the partial-path correctly).
 */
async function closeBuilderFor(
  chainId: number,
  vault: Address,
  position: PositionRecord,
  legs: { swapModuleType: `0x${string}`; lendingModuleType: `0x${string}`; perpsModuleType: `0x${string}` },
  lendingConfigRaw: `0x${string}`,
  templateId: string,
  jobId: string,
): Promise<{ modules: `0x${string}`[]; datas: `0x${string}`[] }> {
  if (legs.lendingModuleType === MODULE_TYPES.LENDING_MORPHO) {
    console.log(`[Job ${jobId}] using multi-step Morpho close`);
    return buildMultiStepClose(chainId, vault, position, legs, lendingConfigRaw);
  }
  // Dolomite path — existing single-call template.
  console.log(`[Job ${jobId}] using single-step Dolomite close template`);
  const cfg = getChainConfig(chainId);
  const swapQuote = await getOdosSwapQuote(
    chainId,
    position.collateralAsset,
    cfg.tokens.USDC,
    position.allocation,
    vault,
    200,
  );
  if (lendingConfigRaw && lendingConfigRaw !== "0x") {
    if (legs.lendingModuleType === MODULE_TYPES.LENDING_DOLOMITE) {
      const [mktId] = decodeAbiParameters([{ type: "uint256" }], lendingConfigRaw);
      swapQuote.collateralMarketId = mktId;
    } else {
      swapQuote.lendingConfig = lendingConfigRaw;
    }
  }
  return buildCloseModulesAndData(templateId, { position, legs, swapQuote, chainId });
}

const MORPHO_BLUE_ARB = "0x6c247b1F6182318877311737BaC0844bAa518F5e" as `0x${string}`;
const MAX_UINT256 = (1n << 256n) - 1n;
const morphoBlueAbi = [
  { type: "function", name: "position", inputs: [{ name: "id", type: "bytes32" }, { name: "user", type: "address" }],
    outputs: [{ name: "supplyShares", type: "uint256" }, { name: "borrowShares", type: "uint128" }, { name: "collateral", type: "uint128" }],
    stateMutability: "view" },
  { type: "function", name: "market", inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      { name: "totalSupplyAssets",  type: "uint128" }, { name: "totalSupplyShares",  type: "uint128" },
      { name: "totalBorrowAssets",  type: "uint128" }, { name: "totalBorrowShares",  type: "uint128" },
      { name: "lastUpdate",         type: "uint128" }, { name: "fee",                type: "uint128" },
    ], stateMutability: "view" },
] as const;

/**
 * Builds the modules/datas arrays for a 6-step Morpho close, used by `executeClosingRequest`
 * and `executeRebalanceClose`. Replaces the single-call `Morpho.repayDebtWithCollateral`
 * which is broken when vault USDC < debt (its partial path runs but the on-chain Odos
 * calldata is pre-encoded for full collateral, causing the swap to revert).
 *
 * Steps:
 *   1. repayDebt(vaultUSDC) — partial repay using whatever the vault holds (skipped if zero)
 *   2. withdrawCollateral(partialAmount) — withdraw what health allows (keeps minColl for remaining debt)
 *   3. swap(partialAmount → USDC) — first swap, replenishes USDC for the next repay
 *   4. repayDebt(MAX) — full repay; uses shares-based path, takes only what's needed
 *   5. withdrawCollateral(minColl) — withdraw the leftover collateral (debt is now zero)
 *   6. swap(minColl + dust → USDC) — second swap; converts any remaining collateral back
 *
 * Returns `{ modules, datas }` ready to pass to `executeClosingRequest` / `executeRebalanceClose`.
 * Caller must already have vault USDC ≈ debt (achieved by closing Orderly + withdrawing FIRST).
 */
export async function buildMultiStepClose(
  chainId: number,
  vault: Address,
  position: PositionRecord,
  legs: { swapModuleType: `0x${string}`; lendingModuleType: `0x${string}` },
  lendingConfigRaw: `0x${string}`,
): Promise<{ modules: `0x${string}`[]; datas: `0x${string}`[] }> {
  if (legs.lendingModuleType !== MODULE_TYPES.LENDING_MORPHO) {
    throw new Error(`buildMultiStepClose: only Morpho is supported (got ${legs.lendingModuleType})`);
  }
  const cfg = getChainConfig(chainId);
  const collateralToken = position.collateralAsset;
  const loanToken = cfg.tokens.USDC;

  const [decLoan, decCol, decOracle, decIrm, decLltv] = decodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "address" }, { type: "address" }, { type: "uint256" }],
    lendingConfigRaw,
  );
  const oracle = decOracle as Address;
  const irm = decIrm as Address;
  const lltv = decLltv as bigint;

  // Read live state from Morpho + the vault + the oracle in parallel.
  const pub = createPublicClient({ chain: arbitrum, transport: http(cfg.rpcUrl) });
  const marketId = keccak256(encodeAbiParameters(
    [{ type: "tuple", components: [
      { name: "loanToken", type: "address" }, { name: "collateralToken", type: "address" },
      { name: "oracle", type: "address" }, { name: "irm", type: "address" }, { name: "lltv", type: "uint256" },
    ]}],
    [{ loanToken, collateralToken, oracle, irm, lltv }] as any
  ));
  const [mpos, mkt, oraclePrice, vUsdc, vCol] = await Promise.all([
    pub.readContract({ address: MORPHO_BLUE_ARB, abi: morphoBlueAbi, functionName: "position", args: [marketId, vault] }) as Promise<readonly [bigint, bigint, bigint]>,
    pub.readContract({ address: MORPHO_BLUE_ARB, abi: morphoBlueAbi, functionName: "market", args: [marketId] }) as Promise<readonly [bigint, bigint, bigint, bigint, bigint, bigint]>,
    pub.readContract({ address: oracle, abi: [{ type: "function", name: "price", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" }] as const, functionName: "price" }) as Promise<bigint>,
    pub.readContract({ address: loanToken, abi: [{ type: "function", name: "balanceOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" }] as const, functionName: "balanceOf", args: [vault] }) as Promise<bigint>,
    pub.readContract({ address: collateralToken, abi: [{ type: "function", name: "balanceOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" }] as const, functionName: "balanceOf", args: [vault] }) as Promise<bigint>,
  ]);
  const totalCollateral = BigInt(mpos[2]);
  const borrowShares = BigInt(mpos[1]);
  const debtAssets = (borrowShares * BigInt(mkt[2])) / BigInt(mkt[3]) + 1n;

  // Pick the right close path based on vault USDC vs Morpho debt.
  // Apply an interest buffer (1 USDC or 1% of debt, whichever bigger) so that the on-chain
  // execution still has slack after Morpho accrues interest between our read and submit.
  const interestBuffer = debtAssets / 100n > 1_000_000n ? debtAssets / 100n : 1_000_000n;

  const swapHashForPath = (sq1: SwapQuote, sq2?: SwapQuote): `0x${string}` => {
    const uniBoth = sq1.source === "uniswap" && (sq2 ? sq2.source === "uniswap" : true);
    if (uniBoth) return MODULE_TYPES.SWAP_UNISWAP;
    return MODULE_TYPES.SWAP_ODOS;
  };

  // ============ Path A: full repay via shares (vault USDC clearly covers debt + interest buffer) ============
  // Steps: repay(shares→MAX) → withdraw(all collateral) → swap(all)
  // Plus an optional 4th step swapping any pre-existing wstETH dust in the vault.
  if (vUsdc >= debtAssets + interestBuffer) {
    console.log(`[multi-step close] PATH A (full-repay): vault USDC ${vUsdc} >= debt ${debtAssets} + buf ${interestBuffer}`);
    // Swap quote covers Morpho's collateral PLUS any vault dust in one call (single approval, one swap).
    const totalToSwap = totalCollateral + vCol;
    const sq = await getSwapQuote(chainId, collateralToken, loanToken, totalToSwap, 200, vault);
    const sHash = swapHashForPath(sq);

    const repayFullData = encodeFunctionData({ abi: morphoAbi, functionName: "repayDebt",
      args: [loanToken, MAX_UINT256, collateralToken, oracle, irm, lltv] });
    const withdrawAllData = encodeFunctionData({ abi: morphoAbi, functionName: "withdrawCollateral",
      args: [collateralToken, totalCollateral, loanToken, oracle, irm, lltv] });
    const swapData = encodeFunctionData({ abi: swapModuleAbi, functionName: "swap",
      args: [collateralToken, totalToSwap, loanToken, sq.minAmountOut, sq.routerData] });

    return {
      modules: [MODULE_TYPES.LENDING_MORPHO, MODULE_TYPES.LENDING_MORPHO, sHash],
      datas: [repayFullData, withdrawAllData, swapData],
    };
  }

  // ============ Path B: partial-repay + partial-withdraw + swap + full-repay + withdraw-rest + swap ============
  // Used when vault USDC < debt + buffer; we partially repay with what we have, withdraw enough
  // collateral to cover the shortfall, swap, then fully repay and unwind the rest.
  console.log(`[multi-step close] PATH B (partial-repay): vault USDC ${vUsdc} < debt ${debtAssets} + buf ${interestBuffer}`);
  // Leave the interest buffer in vault during partial repay so we have slack for step 4 (full-repay).
  const partialRepayAmt = vUsdc > interestBuffer ? vUsdc - interestBuffer : 0n;
  const remainingDebt = debtAssets - partialRepayAmt;

  // minCollateral covers `remainingDebt` with a 50% safety buffer (over the Morpho health check)
  // to absorb interest accrual + oracle drift between off-chain compute and on-chain execution.
  let minCollateral = (remainingDebt * (10n ** 36n) * (10n ** 18n) * 150n) / (oraclePrice * lltv * 100n);
  if (minCollateral >= totalCollateral) {
    throw new Error(
      `Multi-step close infeasible: minCollateral (${minCollateral}) >= totalCollateral (${totalCollateral}). ` +
      `Vault USDC ${vUsdc} too far below debt ${debtAssets}.`
    );
  }
  const partialWithdrawAmt = totalCollateral - minCollateral;

  const sq1 = await getSwapQuote(chainId, collateralToken, loanToken, partialWithdrawAmt, 200, vault);
  const swap2Amt = minCollateral + vCol;
  const sq2 = await getSwapQuote(chainId, collateralToken, loanToken, swap2Amt, 200, vault);

  let sHash: `0x${string}`;
  if (sq1.source === "uniswap" && sq2.source === "uniswap") sHash = MODULE_TYPES.SWAP_UNISWAP;
  else if (legs.swapModuleType === MODULE_TYPES.SWAP_UNISWAP) {
    const sq1Forced = await getOdosSwapQuote(chainId, collateralToken, loanToken, partialWithdrawAmt, vault, 200);
    const sq2Forced = await getOdosSwapQuote(chainId, collateralToken, loanToken, swap2Amt, vault, 200);
    return buildCallsPathB(sq1Forced, sq2Forced, MODULE_TYPES.SWAP_ODOS);
  } else sHash = MODULE_TYPES.SWAP_ODOS;
  return buildCallsPathB(sq1, sq2, sHash);

  function buildCallsPathB(quote1: SwapQuote, quote2: SwapQuote, hash: `0x${string}`) {
    const repayPartialData = encodeFunctionData({ abi: morphoAbi, functionName: "repayDebt",
      args: [loanToken, partialRepayAmt, collateralToken, oracle, irm, lltv] });
    const withdrawPartialData = encodeFunctionData({ abi: morphoAbi, functionName: "withdrawCollateral",
      args: [collateralToken, partialWithdrawAmt, loanToken, oracle, irm, lltv] });
    const swap1Data = encodeFunctionData({ abi: swapModuleAbi, functionName: "swap",
      args: [collateralToken, partialWithdrawAmt, loanToken, quote1.minAmountOut, quote1.routerData] });
    const repayFullData = encodeFunctionData({ abi: morphoAbi, functionName: "repayDebt",
      args: [loanToken, MAX_UINT256, collateralToken, oracle, irm, lltv] });
    const withdrawRestData = encodeFunctionData({ abi: morphoAbi, functionName: "withdrawCollateral",
      args: [collateralToken, minCollateral, loanToken, oracle, irm, lltv] });
    const swap2Data = encodeFunctionData({ abi: swapModuleAbi, functionName: "swap",
      args: [collateralToken, swap2Amt, loanToken, quote2.minAmountOut, quote2.routerData] });

    const modules: `0x${string}`[] = [];
    const datas: `0x${string}`[] = [];
    if (partialRepayAmt > 0n) {
      modules.push(MODULE_TYPES.LENDING_MORPHO);
      datas.push(repayPartialData);
    }
    modules.push(MODULE_TYPES.LENDING_MORPHO, hash, MODULE_TYPES.LENDING_MORPHO, MODULE_TYPES.LENDING_MORPHO, hash);
    datas.push(withdrawPartialData, swap1Data, repayFullData, withdrawRestData, swap2Data);
    return { modules, datas };
  }
}
import {
  openShort,
  closeShort,
  settlePnL,
  withdrawFromOrderly,
  getOrderlyBalance,
  computeAccountId,
  getVaultCredentials,
  ensureVaultSetup,
  getMarkPrice,
  getSymbolInfo,
  getOpenPositionQty,
  getOpenPositionEntry,
  placeTpSlShort,
  cancelAllAlgoOrders,
} from "./orderly";
import { createJob, updateJob, type Job } from "./jobs";
import { config, getChainConfig } from "../config";

const POLL_INTERVAL_MS = 5_000;
const POLL_MAX_ATTEMPTS = 120;
// LayerZero fee for Orderly deposit: Berachain needs more, Arbitrum needs less
function getOrderlyDepositFee(chainId: number): bigint {
  if (chainId === 42161) return 100000000000000n;  // Arbitrum: 0.0001 ETH
  return 25000000000000000n;                        // Berachain: 0.025 BERA
}

// ============ Open Position Flow ============

export async function executeOpen(
  chainId: number,
  vault: Address,
  positionId: bigint
): Promise<Job> {
  const job = createJob(vault, positionId.toString(), "open");
  const cfg = getChainConfig(chainId);

  try {
    await ensureVaultSetup(chainId, vault);

    const [vaultInfo, position, legs] = await Promise.all([
      getVaultInfo(chainId, vault),
      getPosition(chainId, vault, positionId),
      getVaultLegs(chainId, vault),
    ]);

    if (position.status !== 1) {
      throw new Error(`Position status is ${position.status}, expected 1 (OPEN_REQUESTED)`);
    }

    // Pre-flight #1: Orderly minimum allocation. The notional check on the short order
    // is the final gate, but failing here is much cheaper — we avoid burning swap fees and
    // gas for an open that Orderly will reject. Mirrors the frontend ORDERLY_MIN_ALLOCATION_USDC.
    const ORDERLY_MIN_ALLOC = 12_000_000n; // 12 USDC (6 decimals)
    const isOrderlyPerps = legs.perpsModuleType === MODULE_TYPES.PERPS_ORDERLY;
    if (isOrderlyPerps && position.allocation < ORDERLY_MIN_ALLOC) {
      throw new Error(
        `Allocation ${position.allocation} (${Number(position.allocation) / 1e6} USDC) is below ` +
        `the Orderly minimum (${ORDERLY_MIN_ALLOC} = ${Number(ORDERLY_MIN_ALLOC) / 1e6} USDC). ` +
        `Define a new position with a larger allocation.`
      );
    }

    // Pre-flight #2: vault must actually hold the allocation in USDC. If it doesn't, the
    // swap step would revert with a generic "execution reverted" on Uniswap's pull, wasting
    // the operator's gas. Surface a clear, actionable error here instead.
    const vaultUsdc = await readVaultUsdc(chainId, vault);
    if (vaultUsdc < position.allocation) {
      throw new Error(
        `Vault USDC balance ${vaultUsdc} (${Number(vaultUsdc) / 1e6} USDC) is below the ` +
        `position allocation ${position.allocation} (${Number(position.allocation) / 1e6} USDC). ` +
        `Deposit USDC to the vault before executing.`
      );
    }

    // 200 bps slippage: small swaps (≤ tens of USDC) routing through Arbitrum DEX aggregators
    // often deliver below a 50-bps minAmountOut by the time the tx is mined into the next block,
    // which would revert with ModuleExecutionFailed. 200 bps gives the route headroom to land.
    const swapQuote = await getSwapQuote(
      chainId,
      cfg.tokens.USDC,
      position.collateralAsset,
      position.allocation,
      200,
      vault
    );
    // Read lending config using the vault's actual lending module type
    const lendingConfigRaw = await getModuleLendingConfig(chainId, legs.lendingModuleType as `0x${string}`, position.collateralAsset);
    if (lendingConfigRaw && lendingConfigRaw !== "0x") {
      if (legs.lendingModuleType === MODULE_TYPES.LENDING_DOLOMITE) {
        const [collateralMarketId] = decodeAbiParameters([{ type: "uint256" }], lendingConfigRaw);
        swapQuote.collateralMarketId = collateralMarketId;
      } else {
        // Morpho/Aave — pass raw config for the template plugin to decode
        swapQuote.lendingConfig = lendingConfigRaw;
      }
    }

    const borrowAmount = estimateBorrowAmount(position.allocation);

    const accountId = computeAccountId(vault);
    const brokerHash = keccak256(stringToHex(config.brokerId));

    const { modules, datas } = buildOpenModulesAndData(
      vaultInfo.templateId,
      {
        position,
        legs,
        swapQuote,
        borrowAmount,
        chainId,
        orderlyDepositData: {
          accountId: accountId as `0x${string}`,
          brokerHash: brokerHash as `0x${string}`,
          tokenHash:
            "0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eaa" as `0x${string}`,
          tokenAmount: borrowAmount,
          fee: getOrderlyDepositFee(chainId),
        },
      }
    );

    // Vault leg declares the curator-preferred swap module (e.g. swap.uniswap), but if the
    // quote fell back to a different provider (Odos when Uniswap had no route), invoke that
    // provider's module instead so the vault calls the right router on-chain.
    overrideSwapModuleFromQuote(modules, swapQuote);

    // Pre-flight: make sure the operator has enough ETH to cover (gas + value).
    // Without this, a balance shortfall manifests as a generic "execution reverted" from
    // the RPC's eth_estimateGas, which is impossible to debug.
    {
      const { getPublicClient } = await import("./blockchain");
      const pub = getPublicClient(chainId);
      const fee = getOrderlyDepositFee(chainId);
      const [balance, gasPrice] = await Promise.all([
        pub.getBalance({ address: "0xdF2F0C8c58Ade470c780c73e2a3c71b5EB787E9B" as `0x${string}` }),
        pub.getGasPrice(),
      ]);
      const gasBuffer = 2_500_000n; // open path uses ~1.55M gas; pad to 2.5M for safety
      const needed = fee + gasBuffer * gasPrice;
      if (balance < needed) {
        throw new Error(
          `Operator wallet has insufficient ETH on chain ${chainId}. Balance: ${balance} wei, ` +
          `need at least ${needed} wei (Orderly fee ${fee} + ~${gasBuffer} gas × ${gasPrice} gwei). ` +
          `Top up the operator (0xdF2F0C8c58Ade470c780c73e2a3c71b5EB787E9B) with native gas token.`
        );
      }
    }

    const { hash } = await executeOpeningRequest(chainId, vault, positionId, modules, datas, getOrderlyDepositFee(chainId));
    updateJob(job.id, { status: "waiting_deposit", txHash: hash });

    pollAndConfirmOpen(chainId, job.id, vault, positionId, position.perpsAsset, borrowAmount);
  } catch (err: any) {
    console.error("[Open] FAILED:", err.message);
    updateJob(job.id, { status: "failed", error: err.message });
  }

  return job;
}

/**
 * Resume a stuck OPENING position: place the Orderly short + confirmOpen on-chain.
 * Use when executeOpen's on-chain leg succeeded but the background polling routine
 * was killed (e.g., API restart). Skips the on-chain executeOpeningRequest step.
 */
export async function executeResumeOpen(
  chainId: number,
  vault: Address,
  positionId: bigint
): Promise<Job> {
  const job = createJob(vault, positionId.toString(), "open");
  try {
    await ensureVaultSetup(chainId, vault);
    const position = await getPosition(chainId, vault, positionId);
    if (position.status !== 2) {
      throw new Error(`Position status is ${position.status}, expected 2 (OPENING)`);
    }
    const borrowAmount = estimateBorrowAmount(position.allocation);
    updateJob(job.id, { status: "waiting_deposit" });
    pollAndConfirmOpen(chainId, job.id, vault, positionId, position.perpsAsset, borrowAmount, /*skipBaseline=*/ true);
  } catch (err: any) {
    updateJob(job.id, { status: "failed", error: err.message });
  }
  return job;
}

async function pollAndConfirmOpen(
  chainId: number,
  jobId: string,
  vault: Address,
  positionId: bigint,
  perpsAsset: string,
  depositAmount: bigint,
  skipBaseline = false
) {
  try {
    const depositSettled = await pollOrderlyDeposit(vault, depositAmount, skipBaseline);
    if (!depositSettled) {
      updateJob(jobId, { status: "failed", error: "Orderly deposit did not settle within timeout" });
      return;
    }

    updateJob(jobId, { status: "opening_short" });
    const shortQuantity = await computeShortQuantity(perpsAsset, depositAmount);
    console.log(`[Job ${jobId}] Opening ${perpsAsset} short qty=${shortQuantity} from ${depositAmount} USDC margin`);
    const orderResult = await openShort(vault, perpsAsset, shortQuantity);
    if (!orderResult.success) {
      updateJob(jobId, { status: "failed", error: "Failed to open short on Orderly" });
      return;
    }

    updateJob(jobId, { status: "confirming" });
    const { hash } = await confirmOpen(chainId, vault, positionId);

    // Place TP/SL on the now-active short so the monitor can react when it triggers.
    await placePositionTpSl(chainId, vault, perpsAsset, jobId);

    // Register in the funding monitor so the background loop picks it up.
    {
      const { upsertPosition } = await import("./monitor-state");
      const entry = (await getOpenPositionEntry(vault, perpsAsset)) ?? 0;
      await upsertPosition({
        chainId, vault, positionId: positionId.toString(),
        mode: "ACTIVE", perpsAsset, entryPrice: entry,
      });
    }

    updateJob(jobId, { status: "completed", txHash: hash });
    console.log(`[Job ${jobId}] Position ${positionId} is now ACTIVE`);
  } catch (err: any) {
    console.error(`[Job ${jobId}] Background error:`, err);
    updateJob(jobId, { status: "failed", error: err.message });
  }
}

async function pollOrderlyDeposit(
  vault: Address,
  expectedAmount: bigint,
  skipBaseline = false
): Promise<boolean> {
  // Resume mode: no baseline — assume any prior deposit is "ours" and check absolute balance.
  const baseline = skipBaseline ? 0n : await getOrderlyUsdcBalance(vault);
  const threshold = (expectedAmount * 90n) / 100n;

  // Fast-path: if balance already meets threshold (resume case), return immediately.
  if (skipBaseline) {
    const current = await getOrderlyUsdcBalance(vault);
    if (current >= threshold) return true;
  }

  for (let i = 0; i < POLL_MAX_ATTEMPTS; i++) {
    await sleep(POLL_INTERVAL_MS);
    const current = await getOrderlyUsdcBalance(vault);
    if (current - baseline >= threshold) {
      return true;
    }
  }

  return false;
}

async function getOrderlyUsdcBalance(vault: Address): Promise<bigint> {
  const result = (await getOrderlyBalance(vault)) as {
    data?: { holding?: Array<{ token: string; holding: number }> };
  };
  const usdc = result?.data?.holding?.find((h) => h.token === "USDC");
  return BigInt(Math.floor((usdc?.holding ?? 0) * 1e6));
}

// ============ Close Position Flow ============

export async function executeClose(
  chainId: number,
  vault: Address,
  positionId: bigint,
  shortQuantity: string,
  withdrawAmount: string
): Promise<Job> {
  const job = createJob(vault, positionId.toString(), "close");

  runCloseFlow(chainId, job.id, vault, positionId, shortQuantity, withdrawAmount);

  return job;
}

/**
 * Resume a stuck close: skips Orderly short close / settle / withdraw and jumps straight
 * to the on-chain repay-debt-with-collateral leg. Use when an earlier close ran the
 * Orderly side but the API died or the on-chain leg never fired.
 */
export async function executeResumeClose(
  chainId: number,
  vault: Address,
  positionId: bigint,
): Promise<Job> {
  const job = createJob(vault, positionId.toString(), "close");
  runResumeCloseFlow(chainId, job.id, vault, positionId);
  return job;
}

async function runResumeCloseFlow(chainId: number, jobId: string, vault: Address, positionId: bigint) {
  try {
    await ensureVaultSetup(chainId, vault);
    const cfg = getChainConfig(chainId);
    const [vaultInfo, position] = await Promise.all([
      getVaultInfo(chainId, vault),
      getPosition(chainId, vault, positionId),
    ]);
    if (position.status !== 4) {
      throw new Error(`Position status is ${position.status}, expected 4 (CLOSE_REQUESTED)`);
    }
    updateJob(jobId, { status: "executing_close" });

    const legs = await getVaultLegs(chainId, vault);
    const lendingConfigRaw = await getModuleLendingConfig(chainId, legs.lendingModuleType as `0x${string}`, position.collateralAsset);

    const { modules, datas } = await closeBuilderFor(chainId, vault, position, legs, lendingConfigRaw, vaultInfo.templateId, jobId);
    const { hash } = await executeClosingRequest(chainId, vault, positionId, modules, datas);
    updateJob(jobId, { status: "close_completed", txHash: hash });
    console.log(`[Resume close ${jobId}] Position ${positionId} closed, tx ${hash}`);
  } catch (err: any) {
    console.error(`[Resume close ${jobId}] error:`, err);
    updateJob(jobId, { status: "failed", error: err.message });
  }
}

async function runCloseFlow(
  chainId: number,
  jobId: string,
  vault: Address,
  positionId: bigint,
  shortQuantity: string,
  withdrawAmount: string
) {
  try {
    await ensureVaultSetup(chainId, vault);
    const cfg = getChainConfig(chainId);
    const [vaultInfo, position] = await Promise.all([
      getVaultInfo(chainId, vault),
      getPosition(chainId, vault, positionId),
    ]);

    if (position.status !== 4) {
      throw new Error(`Position status is ${position.status}, expected 4 (CLOSE_REQUESTED)`);
    }

    // If callers don't provide shortQuantity/withdrawAmount, compute them so the close
    // unwinds the position fully without the user having to type anything.
    //
    // CRITICAL: read the actual open position from Orderly rather than recomputing from
    // margin. The mark price drifts between open and close, so the margin-derived qty can
    // be 1 base_tick less than what was actually opened — leaving a residual short that
    // locks the margin and blocks withdrawal.
    let resolvedShortQty = shortQuantity;
    if (!resolvedShortQty || resolvedShortQty.trim() === "") {
      resolvedShortQty = await getOpenPositionQty(vault, position.perpsAsset);
      if (resolvedShortQty === "0") {
        console.log(`[Job ${jobId}] No open Orderly position — skipping closeShort`);
      } else {
        console.log(`[Job ${jobId}] resolved short qty from live position = ${resolvedShortQty} ${position.perpsAsset}`);
      }
    }

    updateJob(jobId, { status: "closing_short" });
    if (resolvedShortQty !== "0") {
      const closeResult = await closeShort(vault, position.perpsAsset, resolvedShortQty);
      if (!closeResult.success) {
        throw new Error("Failed to close short on Orderly");
      }
    }

    updateJob(jobId, { status: "settling_pnl" });
    await settlePnL(chainId, vault);

    let resolvedWithdraw = withdrawAmount;
    let expectedWithdrawRaw = 0n;
    if (!resolvedWithdraw || resolvedWithdraw.trim() === "") {
      // Withdraw the full Orderly balance. Orderly's cross-chain (LayerZero) fee is
      // taken from the amount being bridged, NOT from the remaining account balance —
      // so we DON'T need to leave a buffer. Leaving one strands USDC on Orderly that
      // would then cost another withdrawal fee (~$1) to recover.
      const balUsdc = await getOrderlyUsdcBalance(vault);
      resolvedWithdraw = (Number(balUsdc) / 1e6).toString();
      expectedWithdrawRaw = balUsdc;
      console.log(`[Job ${jobId}] auto-resolved withdraw = ${resolvedWithdraw} USDC (full Orderly bal ${balUsdc})`);
    } else {
      expectedWithdrawRaw = BigInt(Math.floor(parseFloat(resolvedWithdraw) * 1e6));
    }

    updateJob(jobId, { status: "withdrawing" });
    const vaultUsdcBefore = await readVaultUsdc(chainId, vault);
    await withdrawFromOrderly(chainId, vault, resolvedWithdraw);

    updateJob(jobId, { status: "waiting_withdrawal" });
    const settled = await pollOrderlyWithdrawal(vault);
    if (!settled) {
      throw new Error("Orderly withdrawal did not settle within timeout");
    }
    // Confirm the LayerZero bridge delivered to the vault (Orderly burning its side isn't enough).
    const arrived = await pollVaultUsdcIncrease(chainId, vault, vaultUsdcBefore, (expectedWithdrawRaw * 70n) / 100n);
    if (!arrived) {
      throw new Error(`LayerZero bridge did not deliver expected USDC to vault during close`);
    }

    updateJob(jobId, { status: "executing_close" });

    const legs = await getVaultLegs(chainId, vault);
    const lendingConfigRaw = await getModuleLendingConfig(chainId, legs.lendingModuleType as `0x${string}`, position.collateralAsset);
    const { modules, datas } = await closeBuilderFor(chainId, vault, position, legs, lendingConfigRaw, vaultInfo.templateId, jobId);
    const { hash } = await executeClosingRequest(chainId, vault, positionId, modules, datas);

    updateJob(jobId, { status: "close_completed", txHash: hash });
    console.log(`[Job ${jobId}] Position ${positionId} is now IDLE`);
  } catch (err: any) {
    console.error(`[Job ${jobId}] Close error:`, err);
    updateJob(jobId, { status: "failed", error: err.message });
  }
}

async function pollOrderlyWithdrawal(vault: Address): Promise<boolean> {
  // Orderly's ~1 USDC cross-chain withdrawal fee + sub-cent rounding can leave a
  // residual of 1.0–1.5 USDC even when "everything" has been withdrawn.
  // Treat any residual under 2 USDC as fully settled.
  for (let i = 0; i < POLL_MAX_ATTEMPTS; i++) {
    await sleep(POLL_INTERVAL_MS);
    const balance = await getOrderlyUsdcBalance(vault);
    if (balance < 2_000_000n) {
      return true;
    }
  }
  return false;
}

async function readVaultUsdc(chainId: number, vault: Address): Promise<bigint> {
  const cfg = getChainConfig(chainId);
  const { getPublicClient } = await import("./blockchain");
  return getPublicClient(chainId).readContract({
    address: cfg.tokens.USDC,
    abi: [{ type: "function", name: "balanceOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" }] as const,
    functionName: "balanceOf", args: [vault],
  }) as Promise<bigint>;
}

/**
 * Waits for the vault's USDC balance to increase by at least `minIncrease` over `baseline`.
 * Used after an Orderly withdrawal to ensure the LayerZero bridge has actually delivered
 * funds — `pollOrderlyWithdrawal` only confirms Orderly's side burned the balance, not
 * that the bridge has arrived on the destination chain.
 */
async function pollVaultUsdcIncrease(
  chainId: number,
  vault: Address,
  baseline: bigint,
  minIncrease: bigint,
): Promise<boolean> {
  for (let i = 0; i < POLL_MAX_ATTEMPTS; i++) {
    const bal = await readVaultUsdc(chainId, vault);
    if (bal >= baseline + minIncrease) return true;
    await sleep(POLL_INTERVAL_MS);
  }
  return false;
}

// ============ Rebalance Position Flow ============

export async function executeRebalance(
  chainId: number,
  vault: Address,
  positionId: bigint
): Promise<Job> {
  const job = createJob(vault, positionId.toString(), "rebalance");

  runRebalanceFlow(chainId, job.id, vault, positionId);

  return job;
}

async function runRebalanceFlow(
  chainId: number,
  jobId: string,
  vault: Address,
  positionId: bigint
) {
  try {
    await ensureVaultSetup(chainId, vault);
    const cfg = getChainConfig(chainId);
    const [vaultInfo, position, legs] = await Promise.all([
      getVaultInfo(chainId, vault),
      getPosition(chainId, vault, positionId),
      getVaultLegs(chainId, vault),
    ]);

    // Accept status 5 (REBALANCE_REQUESTED) and 6 (REBALANCING — mid-flow resume).
    // If we're at 6, a previous attempt already ran the on-chain close — Steps 1, 2 below
    // are idempotent (skip if Orderly is already closed/withdrawn), and Step 3 (the close)
    // is gated below.
    if (position.status !== 5 && position.status !== 6) {
      throw new Error(`Position status is ${position.status}, expected 5 (REBALANCE_REQUESTED) or 6 (REBALANCING)`);
    }
    const resumingFromRebalancing = position.status === 6;

    const lendingConfigRaw = await getModuleLendingConfig(chainId, legs.lendingModuleType as `0x${string}`, position.collateralAsset);

    // ====== Reordered rebalance flow ======
    // Original order ran on-chain close FIRST with vault USDC = 0, which made Morpho's close
    // path hit its broken partial-USDC code path. New order: close Orderly first so the vault
    // has ~debt USDC by the time the on-chain close fires, which makes the multi-step close
    // pattern work correctly.

    // Step 1: Close Orderly short + settle PnL (off-chain, no status change)
    updateJob(jobId, { status: "rebalance_closing_orderly" });
    const shortQty = await getOpenPositionQty(vault, position.perpsAsset);
    if (shortQty !== "0") {
      const closeResult = await closeShort(vault, position.perpsAsset, shortQty);
      if (!closeResult.success) {
        throw new Error("Failed to close Orderly short during rebalance");
      }
    }
    await settlePnL(chainId, vault);

    // Step 2: Withdraw full Orderly balance to vault (skipped if Orderly already empty,
    // e.g., a prior failed rebalance attempt already burned the balance).
    updateJob(jobId, { status: "rebalance_withdrawing" });
    const orderlyBalRaw = await getOrderlyUsdcBalance(vault);
    if (orderlyBalRaw > 1_000_000n) {
      const withdrawAmt = (Number(orderlyBalRaw) / 1e6).toString();
      const vaultUsdcBefore = await readVaultUsdc(chainId, vault);
      await withdrawFromOrderly(chainId, vault, withdrawAmt);
      const withdrawSettled = await pollOrderlyWithdrawal(vault);
      if (!withdrawSettled) {
        throw new Error("Orderly withdrawal did not settle during rebalance");
      }
      // Orderly burning the balance is necessary but not sufficient — the LayerZero bridge
      // still has to deliver USDC to the vault on Arbitrum. Poll until ≥ 70% of expected.
      const expectedArrival = (orderlyBalRaw * 70n) / 100n;
      const arrived = await pollVaultUsdcIncrease(chainId, vault, vaultUsdcBefore, expectedArrival);
      if (!arrived) {
        throw new Error(
          `LayerZero bridge did not deliver expected USDC to vault (before=${vaultUsdcBefore}, ` +
          `expected ≥ ${vaultUsdcBefore + expectedArrival})`
        );
      }
    } else {
      console.log(`[Job ${jobId}] Orderly balance ${orderlyBalRaw} below threshold — skipping withdraw step`);
    }

    // Step 3: On-chain close (vault now has USDC; multi-step Morpho close handles any small fee gap)
    // Skip if status is already 6 — a prior crashed attempt already ran this step.
    let closeHash: `0x${string}` | undefined;
    if (!resumingFromRebalancing) {
      updateJob(jobId, { status: "rebalance_closing_onchain" });
      const { modules: closeModules, datas: closeDatas } =
        await closeBuilderFor(chainId, vault, position, legs, lendingConfigRaw, vaultInfo.templateId, jobId);
      const res = await executeRebalanceClose(chainId, vault, positionId, closeModules, closeDatas);
      closeHash = res.hash;
    } else {
      console.log(`[Job ${jobId}] Resuming mid-rebalance — skipping on-chain close (status already 6)`);
    }

    // Step 4: Re-open on-chain legs (open swap uses Uniswap-primary; Odos fallback)
    updateJob(jobId, { status: "rebalance_opening_onchain", txHash: closeHash });
    // Clamp swap input to what the vault actually holds — over many cycles, fee leakage
    // makes vault.USDC < position.allocation. Use a 0.01 USDC buffer for rounding.
    // The position's nominal allocation stays at its original value; the deployed size
    // shrinks by the per-cycle fee cost. If vault USDC falls below the Orderly floor,
    // bail with a clear message instead of pushing through with a doomed swap.
    const vaultUsdcOnHand = await readVaultUsdc(chainId, vault);
    const BUFFER = 10_000n; // 0.01 USDC
    const ORDERLY_MIN_USDC = 12_000_000n; // matches frontend ORDERLY_MIN_ALLOCATION_USDC
    const safeBal = vaultUsdcOnHand > BUFFER ? vaultUsdcOnHand - BUFFER : 0n;
    const effectiveAllocation = safeBal < position.allocation ? safeBal : position.allocation;
    if (effectiveAllocation < ORDERLY_MIN_USDC) {
      throw new Error(
        `Vault USDC (${vaultUsdcOnHand}) below the Orderly reopen minimum (${ORDERLY_MIN_USDC}). ` +
        `Top up the vault or close the position manually.`
      );
    }
    if (effectiveAllocation < position.allocation) {
      console.log(
        `[Job ${jobId}] Reopen sized to vault balance: ${effectiveAllocation} ` +
        `(nominal allocation ${position.allocation}, shortfall ${position.allocation - effectiveAllocation})`
      );
    }
    const openSwapQuote = await getSwapQuote(chainId, cfg.tokens.USDC, position.collateralAsset, effectiveAllocation, 200, vault);
    if (lendingConfigRaw && lendingConfigRaw !== "0x") {
      if (legs.lendingModuleType === MODULE_TYPES.LENDING_DOLOMITE) {
        const [mktId] = decodeAbiParameters([{ type: "uint256" }], lendingConfigRaw);
        openSwapQuote.collateralMarketId = mktId;
      } else { openSwapQuote.lendingConfig = lendingConfigRaw; }
    }

    const borrowAmount = estimateBorrowAmount(effectiveAllocation);
    const accountId = computeAccountId(vault);
    const brokerHash = keccak256(stringToHex(config.brokerId));

    const { modules: openModules, datas: openDatas } = buildOpenModulesAndData(
      vaultInfo.templateId,
      {
        position,
        legs,
        swapQuote: openSwapQuote,
        borrowAmount,
        chainId,
        orderlyDepositData: {
          accountId: accountId as `0x${string}`,
          brokerHash: brokerHash as `0x${string}`,
          tokenHash: "0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eaa" as `0x${string}`,
          tokenAmount: borrowAmount,
          fee: getOrderlyDepositFee(chainId),
        },
      }
    );
    overrideSwapModuleFromQuote(openModules, openSwapQuote);

    const { hash: openHash } = await executeRebalanceOpen(chainId, vault, positionId, openModules, openDatas, getOrderlyDepositFee(chainId));
    updateJob(jobId, { status: "rebalance_opening_orderly", txHash: openHash });

    // Step 5: Poll Orderly deposit + reopen short
    const depositSettled = await pollOrderlyDeposit(vault, borrowAmount);
    if (!depositSettled) {
      throw new Error("Orderly re-deposit did not settle during rebalance");
    }

    const openResult = await openShort(vault, position.perpsAsset, await computeShortQuantity(position.perpsAsset, borrowAmount));
    if (!openResult.success) {
      throw new Error("Failed to reopen Orderly short during rebalance");
    }

    // Place a fresh TP/SL — the previous one was orphaned when the old short closed.
    await placePositionTpSl(chainId, vault, position.perpsAsset, jobId);

    // Re-register in monitor state with the fresh entry price.
    {
      const { upsertPosition } = await import("./monitor-state");
      const entry = (await getOpenPositionEntry(vault, position.perpsAsset)) ?? 0;
      await upsertPosition({
        chainId, vault, positionId: positionId.toString(),
        mode: "ACTIVE", perpsAsset: position.perpsAsset, entryPrice: entry,
      });
    }

    updateJob(jobId, { status: "completed", txHash: openHash });
    console.log(`[Job ${jobId}] Position ${positionId} rebalanced → ACTIVE`);
  } catch (err: any) {
    console.error(`[Job ${jobId}] Rebalance error:`, err);
    updateJob(jobId, { status: "failed", error: err.message });
  }
}

// ============ Helpers ============

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Convert a USDC margin amount (in 1e6 units) into the perp's base-asset quantity to short.
 *
 * For Orderly perps, `order_quantity` is the BASE asset (e.g. ETH for PERP_ETH_USDC),
 * NOT the USDC notional. So we must convert via the mark price + intended leverage:
 *
 *     notionalUsd  = marginUsd × leverage × safety
 *     quantity     = notionalUsd / markPrice
 *
 * We use `safety = 0.95` to keep below the maintenance-margin frontier (Orderly will
 * reject -1101 "margin will be insufficient after" if we ride too close to the edge).
 * The result is snapped down to the symbol's base_tick and clamped to base_min.
 */
const LEVERAGE = 2;
const SAFETY = 0.95;

// TP/SL — % move from entry that triggers automatic close. Reads each vault's
// `rebalanceThresholdBps` on-chain so the same value drives both the Chainlink-based
// rebalance and the Orderly-side TP/SL trigger. Curator sets it once at deploy time.
//
// Hard floor + cap to keep us out of pathological territory (e.g. a curator who set
// rebalance threshold to 0 or 45 would otherwise produce a TP/SL that triggers instantly
// or never).
const TP_SL_MIN_PCT = Number(process.env.TP_SL_MIN_PCT ?? "0.5");
const TP_SL_MAX_PCT = Number(process.env.TP_SL_MAX_PCT ?? "20");
const TP_SL_DEFAULT_PCT = Number(process.env.TP_SL_DEFAULT_PCT ?? "5");

/** Read vault's rebalanceThresholdBps and convert to a percentage suitable for TP/SL. */
async function readTpSlPctFromVault(chainId: number, vault: Address): Promise<number> {
  try {
    const { createPublicClient, http } = await import("viem");
    const { arbitrum } = await import("viem/chains");
    const cfg = getChainConfig(chainId);
    const pub = createPublicClient({ chain: arbitrum, transport: http(cfg.rpcUrl) });
    const raw = await pub.readContract({
      address: vault,
      abi: [{ type: "function", name: "getRebalanceThresholdBps", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" }] as const,
      functionName: "getRebalanceThresholdBps",
    }) as bigint;
    // Stored as percentage × 100 (e.g. 8% = 800).
    const pct = Number(raw) / 100;
    if (pct < TP_SL_MIN_PCT) return TP_SL_DEFAULT_PCT;
    if (pct > TP_SL_MAX_PCT) return TP_SL_MAX_PCT;
    return pct;
  } catch {
    return TP_SL_DEFAULT_PCT;
  }
}

/**
 * Places a TP/SL algo on the Orderly short for the given vault+perp. Reads the
 * actual fill price from /v1/positions (so we don't rely on a fill price returned
 * by openShort, which can be missing).
 *
 * TP and SL distance is the vault's `rebalanceThresholdBps` (curator-chosen at deploy).
 * Cancels any pre-existing algo for the symbol first.
 */
async function placePositionTpSl(chainId: number, vault: Address, perpsAsset: string, jobId: string): Promise<void> {
  try {
    await cancelAllAlgoOrders(vault, perpsAsset);
    const entry = await getOpenPositionEntry(vault, perpsAsset);
    if (!entry) {
      console.warn(`[Job ${jobId}] no open position on Orderly — skipping TP/SL placement`);
      return;
    }
    const pct = await readTpSlPctFromVault(chainId, vault);
    const algoId = await placeTpSlShort(vault, perpsAsset, entry, pct, pct);
    console.log(`[Job ${jobId}] TP/SL placed for short @ ${entry}: algoId=${algoId} (±${pct}% from vault.rebalanceThresholdBps)`);
  } catch (e: any) {
    // Don't fail the open because TP/SL placement glitched — the monitor will retry.
    console.warn(`[Job ${jobId}] TP/SL placement failed: ${e?.message ?? e}`);
  }
}
async function computeShortQuantity(perpsAsset: string, marginUsdc: bigint): Promise<string> {
  const [price, info] = await Promise.all([getMarkPrice(perpsAsset), getSymbolInfo(perpsAsset)]);
  const marginUsd = Number(marginUsdc) / 1e6;
  const notional = marginUsd * LEVERAGE * SAFETY;
  let qty = notional / price;
  // Snap down to base_tick (avoid lot-size rejections)
  const ticks = Math.floor(qty / info.baseTick);
  qty = ticks * info.baseTick;
  if (qty < info.minQty) {
    throw new Error(
      `Computed short quantity ${qty} ${perpsAsset} is below Orderly's min_qty (${info.minQty}). ` +
      `Margin ${marginUsd} USDC × ${LEVERAGE}x leverage at price ${price} is too small for ${perpsAsset}-PERP.`
    );
  }
  // Notional check: Orderly returns code -1101 "margin will be insufficient" when notional < min_notional.
  // Surface it as a clear API error rather than a cryptic on-chain or remote revert.
  // Borrow ratio is 50% (see swap.ts: estimateBorrowAmount default 5000 bps).
  const BORROW_RATIO = 0.5;
  const realizedNotional = qty * price;
  if (realizedNotional < info.minNotional) {
    const minAlloc = info.minNotional / (LEVERAGE * SAFETY * BORROW_RATIO);
    throw new Error(
      `Order notional (${realizedNotional.toFixed(2)} USDC) is below Orderly's min_notional ` +
      `(${info.minNotional} USDC). Minimum allocation is about ${minAlloc.toFixed(2)} USDC for ${perpsAsset}-PERP.`
    );
  }
  // Format to a reasonable number of decimals based on base_tick
  const decimals = Math.max(0, -Math.floor(Math.log10(info.baseTick)));
  return qty.toFixed(decimals);
}

// ============================================================================
// Pause / Resume — funding-filter executors
// ============================================================================
//
// These run while the curator router still considers the position ACTIVE. They
// call vault.executeBatch directly (operator role + TRADING cycle), so the
// curator state machine isn't disturbed: a paused position is internally just
// "ACTIVE but unwound to USDC".
//
// Pause flow (mirrors the rebalancer-ts-funding reference, adapted to our stack):
//   1. close Orderly short (live qty)
//   2. settle PnL
//   3. withdraw full Orderly balance to vault
//   4. wait for LayerZero bridge
//   5. on-chain unwind: multi-step Morpho close → vault holds USDC only
//
// Resume flow:
//   1. read vault USDC; quote swap USDC→collateral
//   2. build 4 calls: swap + supply + borrow + Orderly deposit (same as initial open)
//   3. vault.executeBatch with LZ fee value
//   4. wait for Orderly deposit
//   5. openShort + place TP/SL
// ============================================================================

export async function executePause(chainId: number, vault: Address, positionId: bigint): Promise<Job> {
  const job = createJob(vault, positionId.toString(), "close");  // reuse "close" action shape
  runPauseFlow(chainId, job.id, vault, positionId);
  return job;
}

async function runPauseFlow(chainId: number, jobId: string, vault: Address, positionId: bigint) {
  try {
    await ensureVaultSetup(chainId, vault);
    const cfg = getChainConfig(chainId);
    const [vaultInfo, position] = await Promise.all([
      getVaultInfo(chainId, vault),
      getPosition(chainId, vault, positionId),
    ]);
    if (position.status !== 3) {
      throw new Error(`Pause requires position status ACTIVE (3), got ${position.status}`);
    }

    // Step 1+2: close short + settle (mirrors close flow's Orderly side)
    updateJob(jobId, { status: "closing_short" });
    const shortQty = await getOpenPositionQty(vault, position.perpsAsset);
    if (shortQty !== "0") {
      console.log(`[Pause ${jobId}] closing Orderly short qty=${shortQty}`);
      await cancelAllAlgoOrders(vault, position.perpsAsset);
      const r = await closeShort(vault, position.perpsAsset, shortQty);
      if (!r.success) throw new Error("Pause: failed to close Orderly short");
    } else {
      console.log(`[Pause ${jobId}] no open short on Orderly — skipping closeShort`);
    }
    updateJob(jobId, { status: "settling_pnl" });
    await settlePnL(chainId, vault);

    // Step 3+4: withdraw full Orderly balance and wait for bridge arrival
    updateJob(jobId, { status: "withdrawing" });
    const orderlyBalRaw = await getOrderlyUsdcBalance(vault);
    if (orderlyBalRaw > 1_000_000n) {
      const withdrawAmt = (Number(orderlyBalRaw) / 1e6).toString();
      const vaultUsdcBefore = await readVaultUsdc(chainId, vault);
      await withdrawFromOrderly(chainId, vault, withdrawAmt);
      updateJob(jobId, { status: "waiting_withdrawal" });
      if (!(await pollOrderlyWithdrawal(vault))) throw new Error("Pause: Orderly withdraw did not settle");
      if (!(await pollVaultUsdcIncrease(chainId, vault, vaultUsdcBefore, (orderlyBalRaw * 70n) / 100n))) {
        throw new Error("Pause: LayerZero bridge did not deliver USDC to vault");
      }
    } else {
      console.log(`[Pause ${jobId}] Orderly balance ${orderlyBalRaw} — skipping withdraw`);
    }

    // Step 5: multi-step on-chain unwind (Morpho repay → withdraw collateral → swap to USDC)
    updateJob(jobId, { status: "executing_close" });
    const legs = await getVaultLegs(chainId, vault);
    const lendingConfigRaw = await getModuleLendingConfig(chainId, legs.lendingModuleType as `0x${string}`, position.collateralAsset);
    const { modules, datas } = await closeBuilderFor(chainId, vault, position, legs, lendingConfigRaw, vaultInfo.templateId, jobId);
    // Call vault.executeBatch directly — keeps curator position state ACTIVE.
    const { hash } = await vaultExecuteBatch(chainId, vault, modules, datas);

    updateJob(jobId, { status: "close_completed", txHash: hash });
    console.log(`[Pause ${jobId}] position unwound to USDC, vault paused`);

    // Mark monitor state. Import lazily to avoid circular import at module load.
    const { setMode } = await import("./monitor-state");
    await setMode(chainId, vault, positionId, "PAUSED-COLD");
  } catch (err: any) {
    console.error(`[Pause ${jobId}] error:`, err);
    updateJob(jobId, { status: "failed", error: err.message });
  }
}

export async function executeResume(chainId: number, vault: Address, positionId: bigint): Promise<Job> {
  const job = createJob(vault, positionId.toString(), "open");
  runResumeFlow(chainId, job.id, vault, positionId);
  return job;
}

async function runResumeFlow(chainId: number, jobId: string, vault: Address, positionId: bigint) {
  try {
    await ensureVaultSetup(chainId, vault);
    const cfg = getChainConfig(chainId);
    const [position, legs] = await Promise.all([
      getPosition(chainId, vault, positionId),
      getVaultLegs(chainId, vault),
    ]);
    if (position.status !== 3) {
      throw new Error(`Resume requires position status ACTIVE (3), got ${position.status}`);
    }

    // Use whatever USDC the vault has — pause exited everything to cash, that's what we redeploy.
    const vaultUsdc = await readVaultUsdc(chainId, vault);
    if (vaultUsdc < 5_000_000n) {
      throw new Error(`Resume: vault has insufficient USDC (${vaultUsdc}) — need at least 5 USDC`);
    }
    // Leave a small reserve so vault isn't empty (helps close path later).
    const allocation = vaultUsdc;
    const borrowAmount = estimateBorrowAmount(allocation);
    console.log(`[Resume ${jobId}] redeploying ${vaultUsdc} USDC, borrow ${borrowAmount}`);

    // Build the same 4 calls as a fresh open. We synthesize a position-shaped object using
    // the live allocation so the template builders work unchanged.
    const swapQuote = await getSwapQuote(chainId, cfg.tokens.USDC, position.collateralAsset, allocation, 200, vault);
    const lendingConfigRaw = await getModuleLendingConfig(chainId, legs.lendingModuleType as `0x${string}`, position.collateralAsset);
    if (lendingConfigRaw && lendingConfigRaw !== "0x") {
      if (legs.lendingModuleType === MODULE_TYPES.LENDING_DOLOMITE) {
        const [mktId] = decodeAbiParameters([{ type: "uint256" }], lendingConfigRaw);
        swapQuote.collateralMarketId = mktId;
      } else {
        swapQuote.lendingConfig = lendingConfigRaw;
      }
    }

    const accountId = computeAccountId(vault);
    const brokerHash = keccak256(stringToHex(config.brokerId));
    const vaultInfo = await getVaultInfo(chainId, vault);
    const positionShadow: PositionRecord = { ...position, allocation };

    const { modules, datas } = buildOpenModulesAndData(vaultInfo.templateId, {
      position: positionShadow,
      legs,
      swapQuote,
      borrowAmount,
      chainId,
      orderlyDepositData: {
        accountId: accountId as `0x${string}`,
        brokerHash: brokerHash as `0x${string}`,
        tokenHash: "0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eaa" as `0x${string}`,
        tokenAmount: borrowAmount,
        fee: getOrderlyDepositFee(chainId),
      },
    });
    overrideSwapModuleFromQuote(modules, swapQuote);

    updateJob(jobId, { status: "executing_onchain" });
    const { hash } = await vaultExecuteBatch(chainId, vault, modules, datas, getOrderlyDepositFee(chainId));
    updateJob(jobId, { status: "waiting_deposit", txHash: hash });
    console.log(`[Resume ${jobId}] on-chain redeploy tx ${hash}, waiting Orderly deposit`);

    if (!(await pollOrderlyDeposit(vault, borrowAmount, true))) {
      throw new Error("Resume: Orderly deposit did not settle");
    }

    updateJob(jobId, { status: "opening_short" });
    const qty = await computeShortQuantity(position.perpsAsset, borrowAmount);
    const orderResult = await openShort(vault, position.perpsAsset, qty);
    if (!orderResult.success) throw new Error("Resume: failed to open Orderly short");

    await placePositionTpSl(chainId, vault, position.perpsAsset, jobId);

    updateJob(jobId, { status: "completed", txHash: hash });
    console.log(`[Resume ${jobId}] position re-established → ACTIVE`);

    const { setMode } = await import("./monitor-state");
    await setMode(chainId, vault, positionId, "ACTIVE");
  } catch (err: any) {
    console.error(`[Resume ${jobId}] error:`, err);
    updateJob(jobId, { status: "failed", error: err.message });
  }
}
