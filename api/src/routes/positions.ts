import { Router, type Request, type Response } from "express";
import { type Address } from "viem";
import { executeOpen, executeResumeOpen, executeClose, executeResumeClose, executeRebalance } from "../services/executor";
import { getJob } from "../services/jobs";
import { getPosition as getMonitorState } from "../services/monitor-state";

export const positionsRouter = Router();

/**
 * GET /positions/monitor-state/:chainId/:vault/:positionId
 * Returns the funding monitor's view of this position: current mode (ACTIVE / PAUSED-COLD / PAUSED-WARM),
 * last funding MA seen, last entry price, and current TP/SL algo order id. Used by the frontend
 * manage page to surface what the background loop is doing.
 */
positionsRouter.get(
  "/monitor-state/:chainId/:vault/:positionId",
  (req: Request, res: Response) => {
    try {
      const { chainId, vault, positionId } = req.params;
      const entry = getMonitorState(Number(chainId), vault as Address, String(positionId));
      if (!entry) {
        res.json({ tracked: false });
        return;
      }
      res.json({ tracked: true, ...entry });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  }
);

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
 * POST /positions/resume-open
 * Resume a position stuck in OPENING (on-chain leg succeeded but the API restarted
 * before the Orderly short / confirmOpen could run). Skips executeOpeningRequest;
 * polls Orderly balance → places short → confirmOpen.
 *
 * Body: { chainId, vault, positionId }
 */
positionsRouter.post("/resume-open", async (req: Request, res: Response) => {
  try {
    const { chainId, vault, positionId } = req.body;
    if (!chainId || !vault || positionId === undefined) {
      res.status(400).json({ error: "Missing chainId, vault, or positionId" });
      return;
    }
    const job = await executeResumeOpen(Number(chainId), vault as Address, BigInt(positionId));
    res.json({
      jobId: job.id,
      status: job.status,
      message: "Position resume in progress. Poll GET /positions/job/:id for status.",
    });
  } catch (err: any) {
    console.error("[POST /positions/resume-open]", err);
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
    if (!chainId || !vault || positionId === undefined) {
      res.status(400).json({ error: "Missing chainId, vault, or positionId" });
      return;
    }

    // shortQuantity / withdrawAmount are optional — executeClose auto-computes them
    // (close full Orderly position; withdraw Orderly balance minus fee buffer).
    const job = await executeClose(
      Number(chainId),
      vault as Address,
      BigInt(positionId),
      shortQuantity ?? "",
      withdrawAmount ?? ""
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
 * POST /positions/resume-close
 * Resume a stuck close: Orderly side already done, just run the on-chain unwind.
 * Body: { chainId, vault, positionId }
 */
positionsRouter.post("/resume-close", async (req: Request, res: Response) => {
  try {
    const { chainId, vault, positionId } = req.body;
    if (!chainId || !vault || positionId === undefined) {
      res.status(400).json({ error: "Missing chainId, vault, or positionId" });
      return;
    }
    const job = await executeResumeClose(Number(chainId), vault as Address, BigInt(positionId));
    res.json({ jobId: job.id, status: job.status, message: "Resume close in progress." });
  } catch (err: any) {
    console.error("[POST /positions/resume-close]", err);
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

/**
 * POST /positions/test-short
 * Test endpoint: directly call Orderly openShort. For manual cycle testing only.
 */
positionsRouter.post("/test-short", async (req: Request, res: Response) => {
  try {
    const { vault, perpsAsset, quantity } = req.body;
    const { openShort } = await import("../services/orderly");
    const result = await openShort(vault, perpsAsset || "ETH", String(quantity));
    res.json(result);
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});
