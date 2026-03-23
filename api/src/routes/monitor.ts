import { Router, type Request, type Response } from "express";
import { type Address } from "viem";
import {
  startMonitor,
  stopMonitor,
  addVault,
  removeVault,
  getMonitorStatus,
  setEntryPrice,
} from "../services/rebalance-monitor";

export const monitorRouter = Router();

/**
 * GET /monitor/status
 * Returns current monitoring state: watched vaults, tracked prices, active rebalances.
 */
monitorRouter.get("/status", (_req: Request, res: Response) => {
  res.json(getMonitorStatus());
});

/**
 * POST /monitor/start
 * Start the monitor with a list of vaults.
 *
 * Body: { vaults: [{ chainId: number, vault: string, threshold?: number }] }
 */
monitorRouter.post("/start", (req: Request, res: Response) => {
  const { vaults } = req.body;
  if (!vaults || !Array.isArray(vaults) || vaults.length === 0) {
    res.status(400).json({ error: "Missing vaults array" });
    return;
  }

  const parsed = vaults.map((v: { chainId: number; vault: string; threshold?: number }) => ({
    chainId: Number(v.chainId),
    vault: v.vault as Address,
    threshold: v.threshold,
  }));

  startMonitor(parsed);
  res.json({ message: `Monitor started with ${parsed.length} vaults`, ...getMonitorStatus() });
});

/**
 * POST /monitor/stop
 * Stop the monitor.
 */
monitorRouter.post("/stop", (_req: Request, res: Response) => {
  stopMonitor();
  res.json({ message: "Monitor stopped" });
});

/**
 * POST /monitor/vaults/add
 * Add a vault to the watch list.
 *
 * Body: { chainId: number, vault: string, threshold?: number }
 */
monitorRouter.post("/vaults/add", (req: Request, res: Response) => {
  const { chainId, vault, threshold } = req.body;
  if (!chainId || !vault) {
    res.status(400).json({ error: "Missing chainId or vault" });
    return;
  }

  addVault({ chainId: Number(chainId), vault: vault as Address, threshold });
  res.json({ message: `Vault ${vault} added`, ...getMonitorStatus() });
});

/**
 * POST /monitor/vaults/remove
 * Remove a vault from the watch list.
 *
 * Body: { chainId: number, vault: string }
 */
monitorRouter.post("/vaults/remove", (req: Request, res: Response) => {
  const { chainId, vault } = req.body;
  if (!chainId || !vault) {
    res.status(400).json({ error: "Missing chainId or vault" });
    return;
  }

  removeVault(Number(chainId), vault as Address);
  res.json({ message: `Vault ${vault} removed`, ...getMonitorStatus() });
});

/**
 * POST /monitor/entry-price
 * Manually set an entry price for a position (for positions that were already open).
 *
 * Body: { chainId: number, vault: string, positionId: number, price: number }
 */
monitorRouter.post("/entry-price", (req: Request, res: Response) => {
  const { chainId, vault, positionId, price } = req.body;
  if (!chainId || !vault || positionId === undefined || !price) {
    res.status(400).json({ error: "Missing chainId, vault, positionId, or price" });
    return;
  }

  setEntryPrice(Number(chainId), vault as Address, BigInt(positionId), Number(price));
  res.json({ message: `Entry price set`, ...getMonitorStatus() });
});
