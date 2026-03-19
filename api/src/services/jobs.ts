import { randomUUID } from "crypto";
import { config } from "../config";

export type JobStatus =
  | "executing_onchain"           // On-chain legs in progress (open)
  | "waiting_deposit"             // Polling Orderly for deposit settlement
  | "opening_short"               // Placing short order on Orderly
  | "confirming"                  // Calling confirmOpen on-chain
  | "completed"                   // Position is ACTIVE
  | "closing_short"               // Closing short on Orderly
  | "settling_pnl"                // Settling PnL on Orderly (required before withdrawal)
  | "withdrawing"                 // Withdrawing from Orderly
  | "waiting_withdrawal"          // Waiting for Orderly withdrawal to settle
  | "executing_close"             // On-chain close legs in progress
  | "close_completed"             // Position is IDLE
  | "rebalance_closing_onchain"   // Step 1: unwind on-chain legs
  | "rebalance_closing_orderly"   // Step 2: close Orderly short + settle + withdraw
  | "rebalance_withdrawing"       // Step 3: waiting for Orderly withdrawal
  | "rebalance_opening_onchain"   // Step 4: re-open on-chain legs
  | "rebalance_opening_orderly"   // Step 5: reopen Orderly short
  | "failed";

const TERMINAL_STATUSES: ReadonlySet<JobStatus> = new Set([
  "completed",
  "close_completed",
  "failed",
]);

export interface Job {
  id: string;
  vault: string;
  positionId: string;
  action: "open" | "close" | "rebalance";
  status: JobStatus;
  txHash?: string;
  error?: string;
  createdAt: number;
  updatedAt: number;
}

// In-memory job store (use Redis/DB in production)
const jobs = new Map<string, Job>();

export function createJob(vault: string, positionId: string, action: "open" | "close" | "rebalance"): Job {
  const initialStatus: JobStatus =
    action === "open" ? "executing_onchain" :
    action === "close" ? "closing_short" :
    "rebalance_closing_onchain";

  const job: Job = {
    id: randomUUID(),
    vault,
    positionId,
    action,
    status: initialStatus,
    createdAt: Date.now(),
    updatedAt: Date.now(),
  };
  jobs.set(job.id, job);
  return job;
}

export function updateJob(id: string, update: Partial<Job>): Job {
  const job = jobs.get(id);
  if (!job) throw new Error(`Job ${id} not found`);
  Object.assign(job, update, { updatedAt: Date.now() });
  return job;
}

export function getJob(id: string): Job | undefined {
  return jobs.get(id);
}

/**
 * Remove terminal jobs older than TTL to prevent unbounded memory growth.
 * Called periodically from the main process.
 */
export function cleanupStaleJobs(): number {
  const now = Date.now();
  let removed = 0;
  for (const [id, job] of jobs) {
    if (TERMINAL_STATUSES.has(job.status) && now - job.updatedAt > config.jobTtlMs) {
      jobs.delete(id);
      removed++;
    }
  }
  return removed;
}
