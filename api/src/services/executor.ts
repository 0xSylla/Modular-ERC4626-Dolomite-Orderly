import { type Address, keccak256, stringToHex, decodeAbiParameters } from "viem";
import {
  getVaultInfo,
  getPosition,
  getVaultLegs,
  getModuleLendingConfig,
  executeOpeningRequest,
  confirmOpen,
  executeClosingRequest,
  executeRebalanceClose,
  executeRebalanceOpen,
  MODULE_TYPES,
} from "./blockchain";
import { buildOpenModulesAndData, buildCloseModulesAndData } from "./templates";
import { getSwapQuote, estimateBorrowAmount } from "./swap";
import {
  openShort,
  closeShort,
  settlePnL,
  withdrawFromOrderly,
  getOrderlyBalance,
  computeAccountId,
  getVaultCredentials,
} from "./orderly";
import { createJob, updateJob, type Job } from "./jobs";
import { config, getChainConfig } from "../config";

const POLL_INTERVAL_MS = 5_000;
const POLL_MAX_ATTEMPTS = 120;
const ORDERLY_DEPOSIT_FEE = 25000000000000000n; // 0.025 native token for LayerZero

// ============ Open Position Flow ============

export async function executeOpen(
  chainId: number,
  vault: Address,
  positionId: bigint
): Promise<Job> {
  const job = createJob(vault, positionId.toString(), "open");
  const cfg = getChainConfig(chainId);

  try {
    getVaultCredentials(vault);

    const [vaultInfo, position, legs] = await Promise.all([
      getVaultInfo(chainId, vault),
      getPosition(chainId, vault, positionId),
      getVaultLegs(chainId, vault),
    ]);

    if (position.status !== 1) {
      throw new Error(`Position status is ${position.status}, expected 1 (OPEN_REQUESTED)`);
    }

    const swapQuote = await getSwapQuote(
      chainId,
      cfg.tokens.USDC,
      position.collateralAsset,
      position.allocation
    );
    const lendingConfigRaw = await getModuleLendingConfig(chainId, MODULE_TYPES.LENDING_DOLOMITE, position.collateralAsset);
    const [collateralMarketId] = decodeAbiParameters([{ type: "uint256" }], lendingConfigRaw);
    swapQuote.collateralMarketId = collateralMarketId;

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
        orderlyDepositData: {
          accountId: accountId as `0x${string}`,
          brokerHash: brokerHash as `0x${string}`,
          tokenHash:
            "0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eaa" as `0x${string}`,
          tokenAmount: borrowAmount,
          fee: ORDERLY_DEPOSIT_FEE,
        },
      }
    );

    const { hash } = await executeOpeningRequest(chainId, vault, positionId, modules, datas, ORDERLY_DEPOSIT_FEE);
    updateJob(job.id, { status: "waiting_deposit", txHash: hash });

    pollAndConfirmOpen(chainId, job.id, vault, positionId, position.perpsAsset, borrowAmount);
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
  depositAmount: bigint
) {
  try {
    const depositSettled = await pollOrderlyDeposit(vault, depositAmount);
    if (!depositSettled) {
      updateJob(jobId, { status: "failed", error: "Orderly deposit did not settle within timeout" });
      return;
    }

    updateJob(jobId, { status: "opening_short" });
    const shortQuantity = formatUsdcToShortQty(depositAmount);
    const orderResult = await openShort(vault, perpsAsset, shortQuantity);
    if (!orderResult.success) {
      updateJob(jobId, { status: "failed", error: "Failed to open short on Orderly" });
      return;
    }

    updateJob(jobId, { status: "confirming" });
    const { hash } = await confirmOpen(chainId, vault, positionId);

    updateJob(jobId, { status: "completed", txHash: hash });
    console.log(`[Job ${jobId}] Position ${positionId} is now ACTIVE`);
  } catch (err: any) {
    console.error(`[Job ${jobId}] Background error:`, err);
    updateJob(jobId, { status: "failed", error: err.message });
  }
}

async function pollOrderlyDeposit(vault: Address, expectedAmount: bigint): Promise<boolean> {
  const baseline = await getOrderlyUsdcBalance(vault);

  for (let i = 0; i < POLL_MAX_ATTEMPTS; i++) {
    await sleep(POLL_INTERVAL_MS);
    const current = await getOrderlyUsdcBalance(vault);

    const threshold = (expectedAmount * 90n) / 100n;
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

async function runCloseFlow(
  chainId: number,
  jobId: string,
  vault: Address,
  positionId: bigint,
  shortQuantity: string,
  withdrawAmount: string
) {
  try {
    const cfg = getChainConfig(chainId);
    const [vaultInfo, position] = await Promise.all([
      getVaultInfo(chainId, vault),
      getPosition(chainId, vault, positionId),
    ]);

    if (position.status !== 4) {
      throw new Error(`Position status is ${position.status}, expected 4 (CLOSE_REQUESTED)`);
    }

    updateJob(jobId, { status: "closing_short" });
    const closeResult = await closeShort(vault, position.perpsAsset, shortQuantity);
    if (!closeResult.success) {
      throw new Error("Failed to close short on Orderly");
    }

    updateJob(jobId, { status: "settling_pnl" });
    await settlePnL(chainId, vault);

    updateJob(jobId, { status: "withdrawing" });
    await withdrawFromOrderly(chainId, vault, withdrawAmount);

    updateJob(jobId, { status: "waiting_withdrawal" });
    const settled = await pollOrderlyWithdrawal(vault);
    if (!settled) {
      throw new Error("Orderly withdrawal did not settle within timeout");
    }

    updateJob(jobId, { status: "executing_close" });

    const swapQuote = await getSwapQuote(
      chainId,
      position.collateralAsset,
      cfg.tokens.USDC,
      position.allocation
    );
    const lendingConfigRaw = await getModuleLendingConfig(chainId, MODULE_TYPES.LENDING_DOLOMITE, position.collateralAsset);
    const [collateralMarketId] = decodeAbiParameters([{ type: "uint256" }], lendingConfigRaw);
    swapQuote.collateralMarketId = collateralMarketId;

    const legs = await getVaultLegs(chainId, vault);
    const { modules, datas } = buildCloseModulesAndData(
      vaultInfo.templateId,
      { position, legs, swapQuote }
    );

    const { hash } = await executeClosingRequest(chainId, vault, positionId, modules, datas);

    updateJob(jobId, { status: "close_completed", txHash: hash });
    console.log(`[Job ${jobId}] Position ${positionId} is now IDLE`);
  } catch (err: any) {
    console.error(`[Job ${jobId}] Close error:`, err);
    updateJob(jobId, { status: "failed", error: err.message });
  }
}

async function pollOrderlyWithdrawal(vault: Address): Promise<boolean> {
  for (let i = 0; i < POLL_MAX_ATTEMPTS; i++) {
    await sleep(POLL_INTERVAL_MS);
    const balance = await getOrderlyUsdcBalance(vault);
    if (balance < 1_000_000n) {
      return true;
    }
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
    const cfg = getChainConfig(chainId);
    const [vaultInfo, position, legs] = await Promise.all([
      getVaultInfo(chainId, vault),
      getPosition(chainId, vault, positionId),
      getVaultLegs(chainId, vault),
    ]);

    if (position.status !== 5) {
      throw new Error(`Position status is ${position.status}, expected 5 (REBALANCE_REQUESTED)`);
    }

    const lendingConfigRaw = await getModuleLendingConfig(chainId, MODULE_TYPES.LENDING_DOLOMITE, position.collateralAsset);
    const [collateralMarketId] = decodeAbiParameters([{ type: "uint256" }], lendingConfigRaw);

    // Step 1: Close on-chain legs
    updateJob(jobId, { status: "rebalance_closing_onchain" });
    const closeSwapQuote = await getSwapQuote(chainId, position.collateralAsset, cfg.tokens.USDC, position.allocation);
    closeSwapQuote.collateralMarketId = collateralMarketId;

    const { modules: closeModules, datas: closeDatas } = buildCloseModulesAndData(
      vaultInfo.templateId,
      { position, legs, swapQuote: closeSwapQuote }
    );

    const { hash: closeHash } = await executeRebalanceClose(chainId, vault, positionId, closeModules, closeDatas);
    updateJob(jobId, { status: "rebalance_closing_orderly", txHash: closeHash });

    // Step 2: Close Orderly short + settle PnL
    const shortQty = formatUsdcToShortQty(position.allocation);
    const closeResult = await closeShort(vault, position.perpsAsset, shortQty);
    if (!closeResult.success) {
      throw new Error("Failed to close Orderly short during rebalance");
    }

    await settlePnL(chainId, vault);

    // Step 3: Withdraw from Orderly
    updateJob(jobId, { status: "rebalance_withdrawing" });
    const withdrawAmt = (Number(position.allocation) / 1e6).toString();
    await withdrawFromOrderly(chainId, vault, withdrawAmt);

    const withdrawSettled = await pollOrderlyWithdrawal(vault);
    if (!withdrawSettled) {
      throw new Error("Orderly withdrawal did not settle during rebalance");
    }

    // Step 4: Re-open on-chain legs
    updateJob(jobId, { status: "rebalance_opening_onchain" });
    const openSwapQuote = await getSwapQuote(chainId, cfg.tokens.USDC, position.collateralAsset, position.allocation);
    openSwapQuote.collateralMarketId = collateralMarketId;

    const borrowAmount = estimateBorrowAmount(position.allocation);
    const accountId = computeAccountId(vault);
    const brokerHash = keccak256(stringToHex(config.brokerId));

    const { modules: openModules, datas: openDatas } = buildOpenModulesAndData(
      vaultInfo.templateId,
      {
        position,
        legs,
        swapQuote: openSwapQuote,
        borrowAmount,
        orderlyDepositData: {
          accountId: accountId as `0x${string}`,
          brokerHash: brokerHash as `0x${string}`,
          tokenHash: "0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eaa" as `0x${string}`,
          tokenAmount: borrowAmount,
          fee: ORDERLY_DEPOSIT_FEE,
        },
      }
    );

    const { hash: openHash } = await executeRebalanceOpen(chainId, vault, positionId, openModules, openDatas, ORDERLY_DEPOSIT_FEE);
    updateJob(jobId, { status: "rebalance_opening_orderly", txHash: openHash });

    // Step 5: Poll Orderly deposit + reopen short
    const depositSettled = await pollOrderlyDeposit(vault, borrowAmount);
    if (!depositSettled) {
      throw new Error("Orderly re-deposit did not settle during rebalance");
    }

    const openResult = await openShort(vault, position.perpsAsset, formatUsdcToShortQty(borrowAmount));
    if (!openResult.success) {
      throw new Error("Failed to reopen Orderly short during rebalance");
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

function formatUsdcToShortQty(usdcAmount: bigint): string {
  return (Number(usdcAmount) / 1e6).toString();
}
