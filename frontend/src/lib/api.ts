/**
 * Client for the Dirac Express API (api/ folder).
 *
 * Endpoints:
 *   POST /vaults/initialize              — full Orderly setup
 *   POST /vaults/confirm-delegate-signer — resume setup from step 2
 *   POST /positions/open                 — automated open flow
 *   POST /positions/close                — automated close flow
 *   POST /positions/rebalance            — automated rebalance (close + reopen)
 *   GET  /positions/job/:id              — poll job status
 *   GET  /health                         — health check
 */

const API_URL =
  process.env.NEXT_PUBLIC_API_URL || "http://localhost:3000";
const API_KEY = process.env.NEXT_PUBLIC_API_KEY || "";

async function apiFetch<T = unknown>(
  path: string,
  options: RequestInit = {}
): Promise<T> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(API_KEY ? { "x-api-key": API_KEY } : {}),
    ...(options.headers as Record<string, string> | undefined),
  };

  const res = await fetch(`${API_URL}${path}`, {
    ...options,
    headers,
  });

  if (!res.ok) {
    const body = await res.json().catch(() => ({ error: res.statusText }));
    throw new Error(body.error || `API error ${res.status}`);
  }

  return res.json() as Promise<T>;
}

// ============ Health ============

export async function healthCheck() {
  return apiFetch<{ status: string }>("/health");
}

// ============ Vault Setup ============

interface InitializeResult {
  dolomiteTxHash: string;
  orderlyModuleTxHash: string;
  accountId: string;
  orderlyPublicKey: string;
  message: string;
}

export async function initializeVault(chainId: number, vault: string, leverage = 2) {
  return apiFetch<InitializeResult>("/vaults/initialize", {
    method: "POST",
    body: JSON.stringify({ chainId, vault, leverage }),
  });
}

interface OrderlyStatusResult {
  initialized: boolean;
  accountId: string;
  chainId: number;
}

export async function getOrderlyStatus(chainId: number, vault: string) {
  return apiFetch<OrderlyStatusResult>(
    `/vaults/orderly-status/${chainId}/${vault}`
  );
}

export interface MonitorState {
  tracked: boolean;
  chainId?: number;
  vault?: string;
  positionId?: string;
  mode?: "ACTIVE" | "PAUSED-COLD" | "PAUSED-WARM";
  perpsAsset?: string;
  entryPrice?: number;
  algoOrderId?: number;
  lastEvalMaBps?: number;
  updatedAt?: number;
}

export async function getMonitorState(chainId: number, vault: string, positionId: string | number) {
  return apiFetch<MonitorState>(`/positions/monitor-state/${chainId}/${vault}/${positionId}`);
}

export async function confirmDelegateSigner(
  chainId: number,
  vault: string,
  txHash: string,
  leverage = 2
) {
  return apiFetch<InitializeResult>("/vaults/confirm-delegate-signer", {
    method: "POST",
    body: JSON.stringify({ chainId, vault, txHash, leverage }),
  });
}

// ============ Position Execution ============

interface JobResponse {
  jobId: string;
  status: string;
  message: string;
}

export async function openPosition(chainId: number, vault: string, positionId: number) {
  return apiFetch<JobResponse>("/positions/open", {
    method: "POST",
    body: JSON.stringify({ chainId, vault, positionId: String(positionId) }),
  });
}

export async function closePosition(
  chainId: number,
  vault: string,
  positionId: number,
  shortQuantity: string,
  withdrawAmount: string
) {
  return apiFetch<JobResponse>("/positions/close", {
    method: "POST",
    body: JSON.stringify({
      chainId,
      vault,
      positionId: String(positionId),
      shortQuantity,
      withdrawAmount,
    }),
  });
}

export async function rebalancePosition(chainId: number, vault: string, positionId: number) {
  return apiFetch<JobResponse>("/positions/rebalance", {
    method: "POST",
    body: JSON.stringify({ chainId, vault, positionId: String(positionId) }),
  });
}

// ============ Job Polling ============

export interface Job {
  id: string;
  vault: string;
  positionId: string;
  action: "open" | "close" | "rebalance";
  status:
    | "executing_onchain"
    | "waiting_deposit"
    | "opening_short"
    | "confirming"
    | "completed"
    | "closing_short"
    | "settling_pnl"
    | "withdrawing"
    | "waiting_withdrawal"
    | "executing_close"
    | "close_completed"
    | "rebalance_closing_onchain"
    | "rebalance_closing_orderly"
    | "rebalance_withdrawing"
    | "rebalance_opening_onchain"
    | "rebalance_opening_orderly"
    | "failed";
  txHash?: string;
  error?: string;
  createdAt: number;
  updatedAt: number;
}

export async function getJob(jobId: string) {
  return apiFetch<Job>(`/positions/job/${jobId}`);
}

/**
 * Poll a job until it reaches a terminal status.
 * Calls onUpdate on each poll with the latest job state.
 */
export async function pollJob(
  jobId: string,
  onUpdate: (job: Job) => void,
  intervalMs = 3000,
  maxAttempts = 200
): Promise<Job> {
  for (let i = 0; i < maxAttempts; i++) {
    const job = await getJob(jobId);
    onUpdate(job);

    if (
      job.status === "completed" ||
      job.status === "close_completed" ||
      job.status === "failed"
    ) {
      return job;
    }

    await new Promise((r) => setTimeout(r, intervalMs));
  }

  throw new Error("Job polling timed out");
}
