"use client";

import React, { useState, useEffect, useCallback } from "react";
import {
  useAccount,
  useChainId,
  useReadContract,
  useReadContracts,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import {
  useAddresses,
  vaultAbi,
  curatorRouterAbi,
  factoryAbi,
} from "@/lib/contracts";
import { formatUnits, parseUnits, parseEther } from "viem";
import Link from "next/link";
import {
  openPosition as apiOpenPosition,
  closePosition as apiClosePosition,
  rebalancePosition as apiRebalancePosition,
  pollJob,
  type Job,
} from "@/lib/api";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const CYCLE_STATUS_LABELS = ["Closed", "Deposits Open", "Trading", "Withdrawals Open"];
const CYCLE_STATUS_COLORS: Record<number, string> = {
  0: "bg-slate-500/20 text-slate-400 border-slate-500/40",
  1: "bg-emerald-500/20 text-emerald-400 border-emerald-500/40",
  2: "bg-amber-500/20 text-amber-400 border-amber-500/40",
  3: "bg-orange-500/20 text-orange-400 border-orange-500/40",
};

const POSITION_STATUS_LABELS = [
  "IDLE",
  "OPEN_REQUESTED",
  "OPENING",
  "ACTIVE",
  "CLOSE_REQUESTED",
  "REBALANCE_REQUESTED",
  "REBALANCING",
];
const POSITION_STATUS_COLORS: Record<number, string> = {
  0: "bg-slate-500/20 text-slate-400 border-slate-500/40",
  1: "bg-blue-500/20 text-blue-400 border-blue-500/40",
  2: "bg-cyan-500/20 text-cyan-400 border-cyan-500/40",
  3: "bg-emerald-500/20 text-emerald-400 border-emerald-500/40",
  4: "bg-red-500/20 text-red-400 border-red-500/40",
  5: "bg-violet-500/20 text-violet-400 border-violet-500/40",
  6: "bg-violet-500/20 text-violet-400 border-violet-500/40",
};


const TABS = ["Positions", "Setup"] as const;
type Tab = (typeof TABS)[number];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function shortenAddress(addr: string): string {
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

// ---------------------------------------------------------------------------
// Shared UI Components
// ---------------------------------------------------------------------------

function Spinner() {
  return (
    <div className="h-5 w-5 animate-spin rounded-full border-2 border-orange-400 border-t-transparent" />
  );
}

function TxStatus({
  hash,
  label,
}: {
  hash: `0x${string}` | undefined;
  label: string;
}) {
  const { isLoading, isSuccess, isError } = useWaitForTransactionReceipt({
    hash,
  });

  if (!hash) return null;

  return (
    <div className="mt-3 rounded-lg border border-slate-700 bg-slate-800/50 px-4 py-3 text-sm">
      <p className="mb-1 font-medium text-slate-300">{label}</p>
      <p className="truncate font-mono text-xs text-slate-500">{hash}</p>
      {isLoading && (
        <div className="mt-2 flex items-center gap-2 text-amber-400">
          <Spinner /> Confirming...
        </div>
      )}
      {isSuccess && (
        <p className="mt-2 text-emerald-400">Transaction confirmed.</p>
      )}
      {isError && (
        <p className="mt-2 text-red-400">Transaction failed.</p>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main Page
// ---------------------------------------------------------------------------

export default function ManagePage({
  params,
}: {
  params: Promise<{ address: string }>;
}) {
  const { address: vaultAddress } = React.use(params);
  const vault = vaultAddress as `0x${string}`;
  const { address: userAddress } = useAccount();
  const chainId = useChainId();
  const addresses = useAddresses();

  const [activeTab, setActiveTab] = useState<Tab>("Positions");

  // ---- Single write contract hook ----
  const {
    writeContract,
    data: txHash,
    isPending: isWritePending,
    error: writeError,
    reset: resetWrite,
  } = useWriteContract();

  const [lastAction, setLastAction] = useState("");

  // ---- Cycle data ----
  const {
    data: cycleData,
    isLoading: cycleLoading,
    refetch: refetchCycle,
  } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: "getCurrentCycle",
  });

  const { data: totalAssets } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: "totalAssets",
  });

  const { data: vaultName } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: "name",
  });


  // ---- Position count ----
  const {
    data: positionsCount,
    refetch: refetchPositionsCount,
  } = useReadContract({
    address: addresses.curatorRouter,
    abi: curatorRouterAbi,
    functionName: "getPositionsCount",
    args: [vault],
  });

  const posCount = positionsCount ? Number(positionsCount) : 0;

  // ---- Read all positions ----
  const positionContracts = Array.from({ length: posCount }, (_, i) => ({
    address: addresses.curatorRouter as `0x${string}`,
    abi: curatorRouterAbi,
    functionName: "getPosition" as const,
    args: [vault, BigInt(i)] as const,
  }));

  const {
    data: positionsData,
    isLoading: positionsLoading,
    refetch: refetchPositions,
  } = useReadContracts({
    contracts: positionContracts,
  });

  // ---- Parse cycle ----
  const cycle = cycleData as
    | {
        status: number;
        assetsAtCycleStart: bigint;
      }
    | undefined;

  const cycleStatus = cycle ? Number(cycle.status) : 0;
  const assetsAtCycleStart = cycle?.assetsAtCycleStart ?? BigInt(0);

  // ---- Tx confirmation auto-refetch ----
  const { isSuccess: txConfirmed } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  useEffect(() => {
    if (txConfirmed) {
      refetchCycle();
      refetchPositionsCount();
      refetchPositions();
    }
  }, [txConfirmed, refetchCycle, refetchPositionsCount, refetchPositions]);

  // ---- Helpers to fire write calls ----
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  function fireAction(label: string, args: any) {
    resetWrite();
    setLastAction(label);
    writeContract(args);
  }

  // ====================================================================
  // TAB 0: SETUP (Post-deployment configuration)
  // ====================================================================

  function SetupTab() {
    const [selectedAsset, setSelectedAsset] = useState("");
    const [newMaxDeposit, setNewMaxDeposit] = useState("");

    const KNOWN_ASSETS = addresses.strategyAssets;

    // Check whitelist status for all known assets
    const whitelistChecks = useReadContracts({
      contracts: KNOWN_ASSETS.map((a) => ({
        address: vault,
        abi: vaultAbi,
        functionName: "isTargetAssetWhitelisted" as const,
        args: [a.address] as const,
      })),
    });

    // Read current max deposit cap (custom getter, not ERC4626 maxDeposit)
    const { data: currentMaxDeposit, refetch: refetchMaxDeposit } = useReadContract({
      address: vault,
      abi: vaultAbi,
      functionName: "getMaxDeposit",
    });

    // Refetch on tx confirm
    useEffect(() => {
      if (txConfirmed) {
        whitelistChecks.refetch();
        refetchMaxDeposit();
      }
    }, [txConfirmed]);

    const whitelisted = KNOWN_ASSETS.filter(
      (_, i) => whitelistChecks.data?.[i]?.result === true
    );
    const notWhitelisted = KNOWN_ASSETS.filter(
      (_, i) => whitelistChecks.data?.[i]?.result !== true
    );

    // Default selectedAsset to first non-whitelisted option
    useEffect(() => {
      if (!selectedAsset && notWhitelisted.length > 0) {
        setSelectedAsset(notWhitelisted[0].address);
      }
    }, [notWhitelisted.length]);

    const selectedLabel =
      KNOWN_ASSETS.find((a) => a.address === selectedAsset)?.label ?? selectedAsset.slice(0, 6);

    return (
      <div className="space-y-6">
        {/* Trade Cycle */}
        <div className="rounded-xl border border-slate-700 bg-slate-900/60 p-6">
          <h3 className="text-lg font-semibold text-white mb-4">Trade Cycle</h3>

          {cycleLoading ? (
            <div className="flex items-center gap-2 text-sm text-slate-400"><Spinner /> Loading...</div>
          ) : (
            <div className="flex flex-wrap items-center gap-3">
              <span className={`inline-block rounded-full border px-3 py-1 text-xs font-medium ${CYCLE_STATUS_COLORS[cycleStatus] ?? CYCLE_STATUS_COLORS[0]}`}>
                {CYCLE_STATUS_LABELS[cycleStatus] ?? "Unknown"}
              </span>

              {(
                [
                  { label: "Open Deposits",    fn: "openDeposits",    activeAt: 0, color: "bg-emerald-600 hover:bg-emerald-500" },
                  { label: "Start Trading",    fn: "startTrading",    activeAt: 1, color: "bg-amber-600 hover:bg-amber-500" },
                  { label: "Open Withdrawals", fn: "openWithdrawals", activeAt: 2, color: "bg-orange-600 hover:bg-orange-500" },
                  { label: "Close Cycle",      fn: "closeCycle",      activeAt: 3, color: "bg-slate-600 hover:bg-slate-500" },
                ] as const
              ).map(({ label, fn, activeAt, color }) => {
                const isActive = cycleStatus === activeAt;
                const isSending = isWritePending && lastAction === label;
                return (
                  <button
                    key={fn}
                    disabled={!isActive || isWritePending}
                    onClick={() => fireAction(label, { address: addresses.curatorRouter, abi: curatorRouterAbi, functionName: fn, args: [vault] })}
                    className={`rounded-lg px-5 py-2 text-sm font-semibold text-white transition-colors disabled:cursor-not-allowed ${isActive ? `${color} disabled:opacity-50` : "bg-slate-800 opacity-30"}`}
                  >
                    {isSending ? <span className="flex items-center gap-2"><Spinner /> Sending...</span> : label}
                  </button>
                );
              })}
            </div>
          )}

          <TxStatus hash={txHash} label={lastAction} />
          {writeError && (
            <div className="mt-3 rounded-lg border border-red-500/40 bg-red-500/10 px-4 py-3 text-sm text-red-400">
              {(writeError as Error).message?.slice(0, 200) ?? "Transaction error"}
            </div>
          )}
        </div>

        {/* Whitelisted Collateral */}
        <div className="rounded-xl border border-slate-700 bg-slate-900/60 p-6 space-y-4">
          <h3 className="text-lg font-semibold text-white">
            Whitelisted Collateral
          </h3>

          {whitelistChecks.isLoading ? (
            <div className="flex items-center gap-2 text-sm text-slate-400">
              <Spinner /> Loading...
            </div>
          ) : whitelisted.length === 0 ? (
            <p className="text-sm text-slate-400">
              No collateral assets whitelisted yet.
            </p>
          ) : (
            <div className="space-y-2">
              {whitelisted.map((asset) => (
                <div
                  key={asset.address}
                  className="flex items-center justify-between rounded-lg border border-emerald-500/30 bg-emerald-500/5 px-4 py-3"
                >
                  <div className="flex items-center gap-3">
                    <span className="text-sm font-medium text-white">
                      {asset.label}
                    </span>
                    <span className="font-mono text-xs text-slate-500">
                      {asset.address.slice(0, 6)}…{asset.address.slice(-4)}
                    </span>
                  </div>
                  <span className="inline-block rounded-full border border-emerald-500/40 bg-emerald-500/20 px-3 py-1 text-xs font-medium text-emerald-400">
                    Whitelisted
                  </span>
                </div>
              ))}
            </div>
          )}

          {/* Dropdown to whitelist another asset */}
          {notWhitelisted.length > 0 && (
            <div className="flex items-center gap-3 pt-2 border-t border-slate-700/60">
              <select
                value={selectedAsset}
                onChange={(e) => setSelectedAsset(e.target.value)}
                className="flex-1 rounded-lg border border-slate-600 bg-slate-800 px-3 py-2.5 text-sm text-white focus:border-orange-500 focus:outline-none"
              >
                {notWhitelisted.map((a) => (
                  <option key={a.address} value={a.address}>
                    {a.label} — {a.address.slice(0, 6)}…{a.address.slice(-4)}
                  </option>
                ))}
              </select>
              <button
                disabled={isWritePending || !selectedAsset}
                onClick={() =>
                  fireAction(`Whitelist ${selectedLabel}`, {
                    address: vault,
                    abi: vaultAbi,
                    functionName: "whitelistTargetAsset",
                    args: [selectedAsset as `0x${string}`],
                  })
                }
                className="shrink-0 rounded-lg bg-orange-600 px-4 py-2.5 text-sm font-medium text-white transition-colors hover:bg-orange-500 disabled:cursor-not-allowed disabled:opacity-40"
              >
                {isWritePending && lastAction === `Whitelist ${selectedLabel}`
                  ? "Confirming..."
                  : "Whitelist"}
              </button>
            </div>
          )}
        </div>

        {/* Update Max Deposit */}
        <div className="rounded-xl border border-slate-700 bg-slate-900/60 p-6 space-y-5">
          <h3 className="text-lg font-semibold text-white">
            Update Max Deposit
          </h3>
          {currentMaxDeposit !== undefined && (
            <p className="text-sm text-slate-400">
              Current cap:{" "}
              <span className="text-white font-medium">
                {Number(
                  formatUnits(currentMaxDeposit as bigint, 6)
                ).toLocaleString()}{" "}
                USDC
              </span>
            </p>
          )}
          <div>
            <label className="block text-slate-300 text-sm mb-1">
              New cap (USDC)
            </label>
            <input
              type="number"
              min="0"
              value={newMaxDeposit}
              onChange={(e) => setNewMaxDeposit(e.target.value)}
              placeholder="1000000"
              className="w-full bg-slate-800 border border-slate-600 rounded-lg px-4 py-2.5 text-sm focus:border-orange-500 focus:outline-none text-white placeholder:text-slate-500"
            />
          </div>
          <button
            disabled={isWritePending || !newMaxDeposit}
            onClick={() =>
              fireAction("Set Max Deposit", {
                address: vault,
                abi: vaultAbi,
                functionName: "setMaxDeposit",
                args: [parseUnits(newMaxDeposit, 6)],
              })
            }
            className="px-5 py-2.5 rounded-lg font-medium bg-orange-600 hover:bg-orange-500 text-white disabled:opacity-40 disabled:cursor-not-allowed transition-colors text-sm"
          >
            {isWritePending && lastAction === "Set Max Deposit"
              ? "Confirm in wallet..."
              : "Update Max Deposit"}
          </button>
        </div>

      </div>
    );
  }

  // ====================================================================
  // TAB 1: POSITION MANAGEMENT
  // ====================================================================

  function PositionsTab() {
    const [positionSubTab, setPositionSubTab] = useState<"waiting" | "active">("waiting");
    const [collateralAsset, setCollateralAsset] = useState<string>(addresses.strategyAssets[0]?.address ?? "");
    const [perpsAsset, setPerpsAsset] = useState("BERA");
    const [allocation, setAllocation] = useState("");

    // API job state
    const [activeJobId, setActiveJobId] = useState<string | null>(null);
    const [jobStatus, setJobStatus] = useState<Job | null>(null);
    const [apiError, setApiError] = useState<string | null>(null);

    async function handleApiOpen(positionId: number) {
      setApiError(null);
      try {
        const res = await apiOpenPosition(chainId, vault, positionId);
        setActiveJobId(res.jobId);
        const final = await pollJob(res.jobId, (j) => setJobStatus(j));
        if (final.status === "failed") setApiError(final.error || "Job failed");
        setActiveJobId(null);
        refetchPositions?.();
        refetchPositionsCount?.();
      } catch (err: unknown) {
        setApiError(err instanceof Error ? err.message : "API error");
        setActiveJobId(null);
      }
    }

    async function handleApiClose(positionId: number, shortQty: string, withdrawAmt: string) {
      setApiError(null);
      try {
        const res = await apiClosePosition(chainId, vault, positionId, shortQty, withdrawAmt);
        setActiveJobId(res.jobId);
        const final = await pollJob(res.jobId, (j) => setJobStatus(j));
        if (final.status === "failed") setApiError(final.error || "Job failed");
        setActiveJobId(null);
        refetchPositions?.();
        refetchPositionsCount?.();
      } catch (err: unknown) {
        setApiError(err instanceof Error ? err.message : "API error");
        setActiveJobId(null);
      }
    }

    async function handleApiRebalance(positionId: number) {
      setApiError(null);
      try {
        const res = await apiRebalancePosition(chainId, vault, positionId);
        setActiveJobId(res.jobId);
        const final = await pollJob(res.jobId, (j) => setJobStatus(j));
        if (final.status === "failed") setApiError(final.error || "Job failed");
        setActiveJobId(null);
        refetchPositions?.();
        refetchPositionsCount?.();
      } catch (err: unknown) {
        setApiError(err instanceof Error ? err.message : "API error");
        setActiveJobId(null);
      }
    }

    // Parse positions
    type Position = {
      id: bigint;
      vault: string;
      collateralAsset: string;
      perpsAsset: string;
      allocation: bigint;
      status: number;
    };

    const positions: Position[] = [];
    if (positionsData) {
      for (const entry of positionsData) {
        if (entry.status === "success" && entry.result) {
          const r = entry.result as Position;
          positions.push(r);
        }
      }
    }

    // IDLE(0) and OPEN_REQUESTED(1) are waiting; everything else is in-flight/active
    const waitingPositions = positions.filter((p) => Number(p.status) <= 1);
    const activePositions = positions.filter((p) => Number(p.status) >= 2);

    function PositionCard({ pos }: { pos: Position }) {
      const status = Number(pos.status);
      return (
        <div className="rounded-lg border border-slate-700 bg-slate-800/50 p-4">
          <div className="mb-3 flex flex-wrap items-center gap-3">
            <span className="text-sm font-medium text-white">
              Position #{Number(pos.id)}
            </span>
            <span
              className={`rounded-full border px-2.5 py-0.5 text-xs font-medium ${
                POSITION_STATUS_COLORS[status] ?? POSITION_STATUS_COLORS[0]
              }`}
            >
              {POSITION_STATUS_LABELS[status] ?? "Unknown"}
            </span>
          </div>

          <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
            <div>
              <p className="text-xs text-slate-400">Collateral Asset</p>
              <p className="truncate font-mono text-xs text-white">
                {shortenAddress(pos.collateralAsset)}
              </p>
            </div>
            <div>
              <p className="text-xs text-slate-400">Perps Asset</p>
              <p className="text-white">{pos.perpsAsset}</p>
            </div>
            <div>
              <p className="text-xs text-slate-400">Allocation</p>
              <p className="text-white">
                {Number(formatUnits(pos.allocation, 18)).toLocaleString(
                  undefined,
                  { maximumFractionDigits: 4 }
                )}
              </p>
            </div>
          </div>

          {/* Action buttons */}
          <div className="mt-4 flex flex-wrap gap-2">
            {/* IDLE -> Request Opening */}
            {status === 0 && (
              <button
                disabled={isWritePending}
                onClick={() =>
                  fireAction(`Request Opening #${Number(pos.id)}`, {
                    address: addresses.curatorRouter,
                    abi: curatorRouterAbi,
                    functionName: "requestOpeningPosition",
                    args: [vault, pos.id],
                  })
                }
                className="rounded-lg bg-blue-600 px-4 py-2 text-xs font-semibold text-white transition-colors hover:bg-blue-500 disabled:cursor-not-allowed disabled:opacity-50"
              >
                Request Opening
              </button>
            )}

            {/* OPEN_REQUESTED -> Execute via API */}
            {status === 1 && (
              <button
                disabled={!!activeJobId}
                onClick={() => handleApiOpen(Number(pos.id))}
                className="rounded-lg bg-cyan-600 px-4 py-2 text-xs font-semibold text-white transition-colors hover:bg-cyan-500 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {activeJobId ? "Job running..." : "Execute Opening (API)"}
              </button>
            )}

            {/* OPENING -> Confirm Open */}
            {status === 2 && (
              <button
                disabled={isWritePending}
                onClick={() =>
                  fireAction(`Confirm Open #${Number(pos.id)}`, {
                    address: addresses.curatorRouter,
                    abi: curatorRouterAbi,
                    functionName: "confirmOpen",
                    args: [vault, pos.id],
                  })
                }
                className="rounded-lg bg-emerald-600 px-4 py-2 text-xs font-semibold text-white transition-colors hover:bg-emerald-500 disabled:cursor-not-allowed disabled:opacity-50"
              >
                Confirm Open
              </button>
            )}

            {/* ACTIVE -> Request Closing + Request Rebalance */}
            {status === 3 && (
              <>
                <button
                  disabled={isWritePending}
                  onClick={() =>
                    fireAction(`Request Closing #${Number(pos.id)}`, {
                      address: addresses.curatorRouter,
                      abi: curatorRouterAbi,
                      functionName: "requestClosingPosition",
                      args: [vault, pos.id],
                    })
                  }
                  className="rounded-lg bg-red-600 px-4 py-2 text-xs font-semibold text-white transition-colors hover:bg-red-500 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  Request Closing
                </button>
                <button
                  disabled={isWritePending}
                  onClick={() =>
                    fireAction(`Request Rebalance #${Number(pos.id)}`, {
                      address: addresses.curatorRouter,
                      abi: curatorRouterAbi,
                      functionName: "requestRebalance",
                      args: [vault, pos.id],
                    })
                  }
                  className="rounded-lg bg-violet-600 px-4 py-2 text-xs font-semibold text-white transition-colors hover:bg-violet-500 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  Rebalance
                </button>
              </>
            )}

            {/* REBALANCE_REQUESTED -> Execute via API */}
            {status === 5 && (
              <button
                disabled={!!activeJobId}
                onClick={() => handleApiRebalance(Number(pos.id))}
                className="rounded-lg bg-violet-600 px-4 py-2 text-xs font-semibold text-white transition-colors hover:bg-violet-500 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {activeJobId ? "Job running..." : "Execute Rebalance (API)"}
              </button>
            )}

            {/* REBALANCING -> informational only */}
            {status === 6 && (
              <p className="text-xs text-violet-400">
                Rebalancing — operator is running Orderly close + reopen…
              </p>
            )}

            {/* CLOSE_REQUESTED -> Execute via API */}
            {status === 4 && (
              <div className="flex flex-wrap items-center gap-2">
                <input
                  type="text"
                  placeholder="Short qty"
                  className="w-24 rounded border border-slate-600 bg-slate-800 px-2 py-1 text-xs text-white"
                  id={`close-qty-${Number(pos.id)}`}
                />
                <input
                  type="text"
                  placeholder="Withdraw amt"
                  className="w-24 rounded border border-slate-600 bg-slate-800 px-2 py-1 text-xs text-white"
                  id={`close-withdraw-${Number(pos.id)}`}
                />
                <button
                  disabled={!!activeJobId}
                  onClick={() => {
                    const qty = (
                      document.getElementById(
                        `close-qty-${Number(pos.id)}`
                      ) as HTMLInputElement
                    )?.value;
                    const amt = (
                      document.getElementById(
                        `close-withdraw-${Number(pos.id)}`
                      ) as HTMLInputElement
                    )?.value;
                    if (qty && amt) handleApiClose(Number(pos.id), qty, amt);
                  }}
                  className="rounded-lg bg-red-600 px-4 py-2 text-xs font-semibold text-white transition-colors hover:bg-red-500 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  {activeJobId ? "Job running..." : "Execute Closing (API)"}
                </button>
              </div>
            )}
          </div>
        </div>
      );
    }

    return (
      <div className="space-y-6">
        {/* Positions card with sub-tabs */}
        <div className="rounded-xl border border-slate-700 bg-slate-900/60 p-6">
          <div className="mb-4 flex items-center justify-between">
            <h3 className="text-lg font-semibold text-white">
              Positions ({posCount})
            </h3>
            {/* Sub-tab nav */}
            <div className="flex rounded-lg border border-slate-700 bg-slate-800 p-0.5">
              {(["waiting", "active"] as const).map((t) => (
                <button
                  key={t}
                  onClick={() => setPositionSubTab(t)}
                  className={`rounded-md px-3 py-1 text-xs font-medium transition-colors ${
                    positionSubTab === t
                      ? "bg-slate-600 text-white"
                      : "text-slate-400 hover:text-white"
                  }`}
                >
                  {t === "waiting" ? (
                    <>Waiting <span className="ml-1 rounded-full bg-blue-500/20 px-1.5 text-blue-400">{waitingPositions.length}</span></>
                  ) : (
                    <>Active <span className="ml-1 rounded-full bg-emerald-500/20 px-1.5 text-emerald-400">{activePositions.length}</span></>
                  )}
                </button>
              ))}
            </div>
          </div>

          {positionsLoading ? (
            <div className="flex items-center justify-center py-8">
              <Spinner />
            </div>
          ) : (
            <>
              {positionSubTab === "waiting" && (
                <div className="space-y-4">
                  {waitingPositions.length === 0 ? (
                    <p className="text-sm text-slate-400">No positions waiting to be executed.</p>
                  ) : (
                    waitingPositions.map((pos, idx) => (
                      <PositionCard key={idx} pos={pos} />
                    ))
                  )}
                </div>
              )}
              {positionSubTab === "active" && (
                <div className="space-y-4">
                  {activePositions.length === 0 ? (
                    <p className="text-sm text-slate-400">No active positions.</p>
                  ) : (
                    activePositions.map((pos, idx) => (
                      <PositionCard key={idx} pos={pos} />
                    ))
                  )}
                </div>
              )}
            </>
          )}
        </div>

        {/* API Job Status */}
        {(activeJobId || jobStatus) && (
          <div className="rounded-xl border border-cyan-700/50 bg-cyan-950/20 p-4">
            <h4 className="text-sm font-semibold text-cyan-300 mb-2">
              API Job {activeJobId ? `(${activeJobId.slice(0, 8)}...)` : ""}
            </h4>
            {jobStatus && (
              <div className="flex items-center gap-3">
                {activeJobId && <Spinner />}
                <span className="text-sm text-white">
                  Status: <span className="font-mono text-cyan-400">{jobStatus.status}</span>
                </span>
                {jobStatus.txHash && (
                  <a
                    href={`https://berascan.com/tx/${jobStatus.txHash}`}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="text-xs text-cyan-400 underline"
                  >
                    View Tx
                  </a>
                )}
              </div>
            )}
          </div>
        )}

        {apiError && (
          <div className="rounded-lg border border-red-500/40 bg-red-500/10 px-4 py-3 text-sm text-red-400">
            API Error: {apiError}
          </div>
        )}

        {/* Define New Position */}
        <div className="rounded-xl border border-slate-700 bg-slate-900/60 p-6">
          <h3 className="text-lg font-semibold text-white mb-4">
            Define New Position
          </h3>

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            {/* Collateral Asset */}
            <div>
              <label className="mb-1 block text-xs text-slate-400">
                Collateral Asset
              </label>
              <select
                value={collateralAsset}
                onChange={(e) => setCollateralAsset(e.target.value)}
                className="w-full rounded-lg border border-slate-600 bg-slate-800 px-4 py-2.5 text-sm text-white focus:border-orange-500 focus:outline-none"
              >
                {addresses.strategyAssets.map((a) => (
                  <option key={a.address} value={a.address}>{a.label} ({shortenAddress(a.address)})</option>
                ))}
                <option value="">Custom...</option>
              </select>
              {collateralAsset === "" && (
                <input
                  type="text"
                  placeholder="0x..."
                  onChange={(e) => setCollateralAsset(e.target.value)}
                  className="mt-2 w-full rounded-lg border border-slate-600 bg-slate-800 px-4 py-2.5 font-mono text-sm text-white focus:border-orange-500 focus:outline-none"
                />
              )}
            </div>

            {/* Perps Asset */}
            <div>
              <label className="mb-1 block text-xs text-slate-400">
                Perps Asset
              </label>
              <input
                type="text"
                value={perpsAsset}
                onChange={(e) => setPerpsAsset(e.target.value)}
                placeholder="e.g. BERA"
                className="w-full rounded-lg border border-slate-600 bg-slate-800 px-4 py-2.5 text-sm text-white focus:border-orange-500 focus:outline-none"
              />
            </div>

            {/* Allocation */}
            <div>
              <label className="mb-1 block text-xs text-slate-400">
                Allocation (token amount, 18 decimals)
              </label>
              <input
                type="text"
                value={allocation}
                onChange={(e) => setAllocation(e.target.value)}
                placeholder="e.g. 1000000000000000000"
                className="w-full rounded-lg border border-slate-600 bg-slate-800 px-4 py-2.5 font-mono text-sm text-white focus:border-orange-500 focus:outline-none"
              />
            </div>

          </div>

          <button
            disabled={isWritePending || !collateralAsset || !perpsAsset || !allocation}
            onClick={() => {
              const allocationBn = BigInt(allocation);
              fireAction("Define Position", {
                address: addresses.curatorRouter,
                abi: curatorRouterAbi,
                functionName: "definePosition",
                args: [
                  vault,
                  collateralAsset as `0x${string}`,
                  perpsAsset,
                  allocationBn,
                ],
              });
            }}
            className="mt-4 rounded-lg bg-orange-600 px-6 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-orange-500 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {isWritePending && lastAction === "Define Position" ? (
              <span className="flex items-center gap-2">
                <Spinner /> Sending...
              </span>
            ) : (
              "Define Position"
            )}
          </button>
        </div>

        {/* Tx feedback */}
        <TxStatus hash={txHash} label={lastAction} />
        {writeError && (
          <div className="rounded-lg border border-red-500/40 bg-red-500/10 px-4 py-3 text-sm text-red-400">
            {(writeError as Error).message?.slice(0, 200) ?? "Transaction error"}
          </div>
        )}
      </div>
    );
  }

  // ====================================================================
  // RENDER
  // ====================================================================

  return (
    <div className="min-h-screen bg-[#0b0f1a]">
      {/* Breadcrumb */}
      <div className="border-b border-slate-800 px-6 py-4">
        <div className="mx-auto max-w-4xl">
          <nav className="flex items-center gap-2 text-sm text-slate-400">
            <Link href="/" className="hover:text-white transition-colors">
              Vaults
            </Link>
            <span>/</span>
            <span className="text-white">
              Manage{" "}
              <span className="font-mono text-orange-400">
                {shortenAddress(vault)}
              </span>
            </span>
          </nav>
          {vaultName && (
            <h1 className="mt-2 text-2xl font-bold text-white">
              {vaultName as string}
            </h1>
          )}
        </div>
      </div>

      {/* Tabs */}
      <div className="border-b border-slate-800">
        <div className="mx-auto max-w-4xl px-6">
          <div className="flex gap-1">
            {TABS.map((tab) => (
              <button
                key={tab}
                onClick={() => {
                  setActiveTab(tab);
                  resetWrite();
                }}
                className={`px-5 py-3 text-sm font-medium transition-colors ${
                  activeTab === tab
                    ? "border-b-2 border-orange-500 text-orange-400"
                    : "text-slate-400 hover:text-white"
                }`}
              >
                {tab}
              </button>
            ))}
          </div>
        </div>
      </div>

      {/* Content */}
      <div className="mx-auto max-w-4xl px-6 py-8">
        {!userAddress && (
          <div className="mb-6 rounded-lg border border-amber-500/40 bg-amber-500/10 px-4 py-3 text-sm text-amber-400">
            Connect your wallet to manage this vault.
          </div>
        )}

        {activeTab === "Positions" && <PositionsTab />}
        {activeTab === "Setup" && <SetupTab />}
      </div>
    </div>
  );
}
