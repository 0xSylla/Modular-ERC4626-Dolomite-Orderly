import { Router, type Request, type Response } from "express";
import { type Address } from "viem";
import { executeOpen, executeClose, executeRebalance } from "../services/executor";
import { getJob } from "../services/jobs";

export const positionsRouter = Router();

/**
 * POST /positions/open
 * Single trigger from frontend after curator calls requestOpeningPosition on-chain.
 *
 * Body: { vault: string, positionId: string }
 *
 * The API handles everything automatically:
 *   1. Execute on-chain legs (swap → supply → borrow → deposit to Orderly)
 *   2. Poll Orderly until deposit settles
 *   3. Open short on Orderly
 *   4. Call confirmOpen on-chain → ACTIVE
 *
 * Returns a job ID to track progress via GET /positions/job/:id
 */
positionsRouter.post("/open", async (req: Request, res: Response) => {
  try {
    const { chainId, vault, positionId } = req.body;
    if (!chainId || !vault || positionId === undefined) {
      res.status(400).json({ error: "Missing chainId, vault, or positionId" });
      return;
    }

    const job = await executeOpen(Number(chainId), vault as Address, BigInt(positionId));

    res.json({
      jobId: job.id,
      status: job.status,
      message: "Position opening in progress. Poll GET /positions/job/:id for status.",
    });
  } catch (err: any) {
    console.error("[POST /positions/open]", err);
    res.status(500).json({ error: err.message });
  }
});

/**
 * POST /positions/close
 * Single trigger from frontend after curator calls requestClosingPosition on-chain.
 *
 * Body: { vault: string, positionId: string, shortQuantity: string, withdrawAmount: string }
 *
 * The API handles everything automatically:
 *   1. Close short on Orderly
 *   2. Withdraw from Orderly
 *   3. Wait for withdrawal to settle
 *   4. Execute on-chain close (repay → withdraw collateral → swap to USDC)
 *
 * Returns a job ID to track progress via GET /positions/job/:id
 */
positionsRouter.post("/close", async (req: Request, res: Response) => {
  try {
    const { chainId, vault, positionId, shortQuantity, withdrawAmount } = req.body;
    if (!chainId || !vault || positionId === undefined || !shortQuantity || !withdrawAmount) {
      res.status(400).json({
        error: "Missing chainId, vault, positionId, shortQuantity, or withdrawAmount",
      });
      return;
    }

    const job = await executeClose(
      Number(chainId),
      vault as Address,
      BigInt(positionId),
      shortQuantity,
      withdrawAmount
    );

    res.json({
      jobId: job.id,
      status: job.status,
      message: "Position closing in progress. Poll GET /positions/job/:id for status.",
    });
  } catch (err: any) {
    console.error("[POST /positions/close]", err);
    res.status(500).json({ error: err.message });
  }
});

/**
 * POST /positions/rebalance
 * Single trigger from frontend after curator calls requestRebalance on-chain (status 5).
 *
 * Body: { vault: string, positionId: string }
 *
 * Full automated flow:
 *   1. executeRebalanceClose: unwind on-chain legs → REBALANCING
 *   2. Close Orderly short + settle PnL + withdraw USDC
 *   3. executeRebalanceOpen: re-open on-chain legs → ACTIVE
 *   4. Reopen short on Orderly
 */
positionsRouter.post("/rebalance", async (req: Request, res: Response) => {
  try {
    const { chainId, vault, positionId } = req.body;
    if (!chainId || !vault || positionId === undefined) {
      res.status(400).json({ error: "Missing chainId, vault, or positionId" });
      return;
    }

    const job = await executeRebalance(Number(chainId), vault as Address, BigInt(positionId));

    res.json({
      jobId: job.id,
      status: job.status,
      message: "Rebalance in progress. Poll GET /positions/job/:id for status.",
    });
  } catch (err: any) {
    console.error("[POST /positions/rebalance]", err);
    res.status(500).json({ error: err.message });
  }
});

/**
 * GET /positions/job/:id
 * Poll job status. Frontend uses this to show progress to the curator.
 */
positionsRouter.get("/job/:id", (req: Request, res: Response) => {
  const job = getJob(req.params.id as string);
  if (!job) {
    res.status(404).json({ error: "Job not found" });
    return;
  }
  res.json(job);
});
