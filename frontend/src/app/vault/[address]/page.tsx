"use client";

import React, { useState, useEffect } from "react";
import Link from "next/link";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { parseUnits, formatUnits } from "viem";
import { useAddresses, vaultAbi, userRouterAbi, erc20Abi } from "@/lib/contracts";
import { useBrowsingChain } from "@/lib/ChainContext";

const CYCLE_LABELS: Record<number, string> = {
  0: "Closed",
  1: "Deposit Open",
  2: "Trading",
  3: "Withdraw Open",
};

const CYCLE_COLORS: Record<number, string> = {
  0: "bg-white/5 text-[#818181]",
  1: "bg-emerald-500/15 text-emerald-400",
  2: "bg-blue-500/15 text-blue-400",
  3: "bg-[#FB5F07]/15 text-[#FB5F07]",
};

function shortenAddress(addr: string) {
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

function formatUsdc(value: bigint | undefined): string {
  if (value === undefined) return "—";
  return Number(formatUnits(value, 6)).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

function formatShares(value: bigint | undefined): string {
  if (value === undefined) return "—";
  return Number(formatUnits(value, 18)).toLocaleString("en-US", {
    minimumFractionDigits: 4,
    maximumFractionDigits: 4,
  });
}

// ---------------------------------------------------------------------------
// Sub-components
// ---------------------------------------------------------------------------

function StatCard({
  label,
  value,
  badge,
}: {
  label: string;
  value: React.ReactNode;
  badge?: { text: string; className: string };
}) {
  return (
    <div className="rounded-xl p-4" style={{ background: "#171717", border: "1px solid #3C323A" }}>
      <p className="text-xs uppercase tracking-wide mb-1" style={{ color: "#818181" }}>
        {label}
      </p>
      {badge ? (
        <span
          className={`inline-block text-xs font-semibold px-2.5 py-1 rounded-full ${badge.className}`}
        >
          {badge.text}
        </span>
      ) : (
        <p className="text-lg font-semibold text-white">{value}</p>
      )}
    </div>
  );
}

function InfoBanner({ message }: { message: string }) {
  return (
    <div className="rounded-lg px-4 py-3 text-sm text-center" style={{ background: "#252525", border: "1px solid #3C323A", color: "#818181" }}>
      {message}
    </div>
  );
}

function TxStatus({
  hash,
  error,
  isPending,
  onConfirmed,
}: {
  hash: `0x${string}` | undefined;
  error: Error | null;
  isPending: boolean;
  onConfirmed?: () => void;
}) {
  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess && onConfirmed) onConfirmed();
  }, [isSuccess, onConfirmed]);

  if (isPending) {
    return (
      <div className="flex items-center gap-2 text-sm mt-2" style={{ color: "#FB5F07" }}>
        <div className="animate-spin w-4 h-4 border-2 border-t-transparent rounded-full" style={{ borderColor: "#FB5F07", borderTopColor: "transparent" }} />
        Confirm in wallet...
      </div>
    );
  }

  if (isConfirming) {
    return (
      <div className="flex items-center gap-2 text-sm mt-2" style={{ color: "#FB5F07" }}>
        <div className="animate-spin w-4 h-4 border-2 border-t-transparent rounded-full" style={{ borderColor: "#FB5F07", borderTopColor: "transparent" }} />
        Waiting for confirmation...
      </div>
    );
  }

  if (isSuccess && hash) {
    return (
      <div className="text-sm text-emerald-400 bg-emerald-950/30 border border-emerald-800/40 rounded-lg px-3 py-2 mt-2">
        Transaction confirmed!
        <a
          href={`https://berascan.com/tx/${hash}`}
          target="_blank"
          rel="noopener noreferrer"
          className="ml-2 underline text-emerald-300"
        >
          View on Berascan
        </a>
      </div>
    );
  }

  if (error) {
    return (
      <div className="text-sm text-red-400 bg-red-950/30 border border-red-800/40 rounded-lg px-3 py-2 mt-2">
        {error.message?.slice(0, 200)}
      </div>
    );
  }

  return null;
}

// ---------------------------------------------------------------------------
// Deposit Section
// ---------------------------------------------------------------------------

function DepositSection({
  vaultAddress,
  cycleStatus,
}: {
  vaultAddress: `0x${string}`;
  cycleStatus: number;
}) {
  const { address: userAddress } = useAccount();
  const addresses = useAddresses();
  const [amount, setAmount] = useState("");
  const [step, setStep] = useState<"approve" | "deposit">("approve");

  const parsedAmount =
    amount && !isNaN(Number(amount)) ? parseUnits(amount, 6) : BigInt(0);
  const isEnabled = cycleStatus === 1 && !!userAddress;

  // USDC balance
  const { data: usdcBalance, refetch: refetchUsdcBalance } = useReadContract({
    address: addresses.USDC,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: userAddress ? [userAddress] : undefined,
    query: { enabled: !!userAddress, refetchInterval: 5000 },
  });

  // USDC allowance for UserRouter
  const { data: usdcAllowance, refetch: refetchAllowance } = useReadContract({
    address: addresses.USDC,
    abi: erc20Abi,
    functionName: "allowance",
    args: userAddress ? [userAddress, addresses.userRouter] : undefined,
    query: { enabled: !!userAddress, refetchInterval: 5000 },
  });

  // Preview deposit
  const { data: previewShares } = useReadContract({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: "previewDeposit",
    args: [parsedAmount],
    query: { enabled: parsedAmount > BigInt(0), refetchInterval: 5000 },
  });

  // Determine step based on allowance
  useEffect(() => {
    if (
      usdcAllowance !== undefined &&
      parsedAmount > BigInt(0) &&
      usdcAllowance >= parsedAmount
    ) {
      setStep("deposit");
    } else {
      setStep("approve");
    }
  }, [usdcAllowance, parsedAmount]);

  // Approve USDC
  const {
    writeContract: approveUsdc,
    data: approveHash,
    isPending: approvePending,
    error: approveError,
    reset: resetApprove,
  } = useWriteContract();

  // Deposit via UserRouter
  const {
    writeContract: deposit,
    data: depositHash,
    isPending: depositPending,
    error: depositError,
    reset: resetDeposit,
  } = useWriteContract();

  function handleApprove() {
    resetApprove();
    approveUsdc({
      address: addresses.USDC,
      abi: erc20Abi,
      functionName: "approve",
      args: [addresses.userRouter, parsedAmount],
    });
  }

  function handleDeposit() {
    if (!userAddress) return;
    resetDeposit();
    deposit({
      address: addresses.userRouter,
      abi: userRouterAbi,
      functionName: "depositIntoVault",
      args: [vaultAddress, parsedAmount, userAddress],
    });
  }

  function handleMax() {
    if (usdcBalance !== undefined) {
      setAmount(formatUnits(usdcBalance as bigint, 6));
    }
  }

  const handleApproveConfirmed = React.useCallback(() => {
    refetchAllowance();
  }, [refetchAllowance]);

  const handleDepositConfirmed = React.useCallback(() => {
    refetchUsdcBalance();
    setAmount("");
  }, [refetchUsdcBalance]);

  return (
    <div className="rounded-xl p-6 space-y-4" style={{ background: "#171717", border: "1px solid #3C323A" }}>
      <h2 className="text-lg font-bold text-white">Deposit</h2>

      {cycleStatus !== 1 && (
        <InfoBanner message="Deposits are not currently open. The vault must be in the Deposit Open phase." />
      )}

      {/* Balance */}
      <div className="flex items-center justify-between text-sm">
        <span style={{ color: "#818181" }}>Your USDC Balance</span>
        <span className="text-white font-medium">
          {usdcBalance !== undefined
            ? formatUsdc(usdcBalance as bigint)
            : "—"}{" "}
          USDC
        </span>
      </div>

      {/* Input */}
      <div className="relative">
        <input
          type="text"
          inputMode="decimal"
          placeholder="0.00"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          disabled={!isEnabled}
          className="w-full rounded-lg px-4 py-2.5 focus:outline-none text-white pr-16 disabled:opacity-50"
          style={{ background: "#252525", border: "1px solid #3C323A" }}
          onFocus={(e) => (e.target.style.borderColor = "#FB5F07")}
          onBlur={(e) => (e.target.style.borderColor = "#3C323A")}
        />
        <button
          onClick={handleMax}
          disabled={!isEnabled}
          className="absolute right-2 top-1/2 -translate-y-1/2 text-xs font-semibold text-orange-400 hover:text-orange-300 disabled:opacity-50"
        >
          MAX
        </button>
      </div>

      {/* Preview */}
      {parsedAmount > BigInt(0) && (
        <div className="text-sm" style={{ color: "#818181" }}>
          You will receive ~{" "}
          <span className="text-white font-medium">
            {formatShares(previewShares as bigint | undefined)}
          </span>{" "}
          shares
        </div>
      )}

      {/* Buttons */}
      {step === "approve" ? (
        <>
          <button
            onClick={handleApprove}
            disabled={!isEnabled || parsedAmount === BigInt(0) || approvePending}
            className="btn-primary w-full px-4 py-2.5"
          >
            {approvePending ? "Confirm in wallet..." : "Approve USDC"}
          </button>
          <TxStatus
            hash={approveHash}
            error={approveError}
            isPending={approvePending}
            onConfirmed={handleApproveConfirmed}
          />
        </>
      ) : (
        <>
          <button
            onClick={handleDeposit}
            disabled={!isEnabled || parsedAmount === BigInt(0) || depositPending}
            className="btn-primary w-full px-4 py-2.5"
          >
            {depositPending ? "Confirm in wallet..." : "Deposit"}
          </button>
          <TxStatus
            hash={depositHash}
            error={depositError}
            isPending={depositPending}
            onConfirmed={handleDepositConfirmed}
          />
        </>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Withdraw / Redeem Section
// ---------------------------------------------------------------------------

function WithdrawRedeemSection({
  vaultAddress,
  cycleStatus,
}: {
  vaultAddress: `0x${string}`;
  cycleStatus: number;
}) {
  const { address: userAddress } = useAccount();
  const addresses = useAddresses();
  const [tab, setTab] = useState<"withdraw" | "redeem">("redeem");
  const [amount, setAmount] = useState("");
  const [step, setStep] = useState<"approve" | "execute">("approve");

  const isEnabled = cycleStatus === 3 && !!userAddress;

  // Parse amount based on tab
  const parsedAmount =
    amount && !isNaN(Number(amount))
      ? tab === "withdraw"
        ? parseUnits(amount, 6) // assets = USDC 6 decimals
        : parseUnits(amount, 18) // shares = 18 decimals
      : BigInt(0);

  // User's vault shares
  const { data: userShares, refetch: refetchShares } = useReadContract({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: "balanceOf",
    args: userAddress ? [userAddress] : undefined,
    query: { enabled: !!userAddress, refetchInterval: 5000 },
  });

  // Vault share allowance to UserRouter
  const { data: shareAllowance, refetch: refetchShareAllowance } =
    useReadContract({
      address: vaultAddress,
      abi: vaultAbi,
      functionName: "allowance",
      args: userAddress ? [userAddress, addresses.userRouter] : undefined,
      query: { enabled: !!userAddress, refetchInterval: 5000 },
    });

  // Preview withdraw (assets -> shares needed)
  const { data: previewWithdrawShares } = useReadContract({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: "previewWithdraw",
    args: [parsedAmount],
    query: {
      enabled: tab === "withdraw" && parsedAmount > BigInt(0),
      refetchInterval: 5000,
    },
  });

  // Preview redeem (shares -> assets received)
  const { data: previewRedeemAssets } = useReadContract({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: "previewRedeem",
    args: [parsedAmount],
    query: {
      enabled: tab === "redeem" && parsedAmount > BigInt(0),
      refetchInterval: 5000,
    },
  });

  // Determine required allowance: for redeem it's the shares directly, for withdraw it's previewWithdraw result
  const requiredAllowance =
    tab === "redeem"
      ? parsedAmount
      : (previewWithdrawShares as bigint) ?? BigInt(0);

  useEffect(() => {
    if (
      shareAllowance !== undefined &&
      requiredAllowance > BigInt(0) &&
      (shareAllowance as bigint) >= requiredAllowance
    ) {
      setStep("execute");
    } else {
      setStep("approve");
    }
  }, [shareAllowance, requiredAllowance]);

  // Approve shares
  const {
    writeContract: approveShares,
    data: approveHash,
    isPending: approvePending,
    error: approveError,
    reset: resetApprove,
  } = useWriteContract();

  // Withdraw/Redeem
  const {
    writeContract: executeWithdraw,
    data: executeHash,
    isPending: executePending,
    error: executeError,
    reset: resetExecute,
  } = useWriteContract();

  function handleApprove() {
    resetApprove();
    approveShares({
      address: vaultAddress,
      abi: vaultAbi,
      functionName: "approve",
      args: [addresses.userRouter, requiredAllowance],
    });
  }

  function handleExecute() {
    if (!userAddress) return;
    resetExecute();
    if (tab === "withdraw") {
      executeWithdraw({
        address: addresses.userRouter,
        abi: userRouterAbi,
        functionName: "withdrawFromVault",
        args: [vaultAddress, parsedAmount, userAddress],
      });
    } else {
      executeWithdraw({
        address: addresses.userRouter,
        abi: userRouterAbi,
        functionName: "redeemFromVault",
        args: [vaultAddress, parsedAmount, userAddress],
      });
    }
  }

  function handleMax() {
    if (tab === "redeem" && userShares !== undefined) {
      setAmount(formatUnits(userShares as bigint, 18));
    }
    // For withdraw-by-assets, max is not straightforward; leave to user
  }

  function handleTabSwitch(newTab: "withdraw" | "redeem") {
    setTab(newTab);
    setAmount("");
    resetApprove();
    resetExecute();
  }

  const handleApproveConfirmed = React.useCallback(() => {
    refetchShareAllowance();
  }, [refetchShareAllowance]);

  const handleExecuteConfirmed = React.useCallback(() => {
    refetchShares();
    setAmount("");
  }, [refetchShares]);

  return (
    <div className="rounded-xl p-6 space-y-4" style={{ background: "#171717", border: "1px solid #3C323A" }}>
      <h2 className="text-lg font-bold text-white">Withdraw / Redeem</h2>

      {cycleStatus !== 3 && (
        <InfoBanner message="Withdrawals are not currently open. The vault must be in the Withdraw Open phase." />
      )}

      {/* Tab toggle */}
      <div className="flex rounded-lg overflow-hidden" style={{ border: "1px solid #3C323A" }}>
        <button
          onClick={() => handleTabSwitch("withdraw")}
          className={`flex-1 px-4 py-2 text-sm font-semibold transition-colors ${
            tab === "withdraw" ? "text-white" : "hover:text-white"
          }`}
          style={tab === "withdraw"
            ? { background: "linear-gradient(to right, #FF512F, #e97808)", color: "#fff" }
            : { background: "#252525", color: "#818181" }}
        >
          Withdraw (by assets)
        </button>
        <button
          onClick={() => handleTabSwitch("redeem")}
          className={`flex-1 px-4 py-2 text-sm font-semibold transition-colors ${
            tab === "redeem" ? "text-white" : "hover:text-white"
          }`}
          style={tab === "redeem"
            ? { background: "linear-gradient(to right, #FF512F, #e97808)", color: "#fff" }
            : { background: "#252525", color: "#818181" }}
        >
          Redeem (by shares)
        </button>
      </div>

      {/* Balance */}
      <div className="flex items-center justify-between text-sm">
        <span style={{ color: "#818181" }}>Your Shares</span>
        <span className="text-white font-medium">
          {userShares !== undefined
            ? formatShares(userShares as bigint)
            : "—"}
        </span>
      </div>

      {/* Input */}
      <div className="relative">
        <input
          type="text"
          inputMode="decimal"
          placeholder="0.00"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          disabled={!isEnabled}
          className="w-full rounded-lg px-4 py-2.5 focus:outline-none text-white pr-16 disabled:opacity-50"
          style={{ background: "#252525", border: "1px solid #3C323A" }}
          onFocus={(e) => (e.target.style.borderColor = "#FB5F07")}
          onBlur={(e) => (e.target.style.borderColor = "#3C323A")}
        />
        {tab === "redeem" && (
          <button
            onClick={handleMax}
            disabled={!isEnabled}
            className="absolute right-2 top-1/2 -translate-y-1/2 text-xs font-bold disabled:opacity-50"
            style={{ color: "#FB5F07" }}
          >
            MAX
          </button>
        )}
      </div>

      {/* Unit label */}
      <p className="text-xs" style={{ color: "#818181" }}>
        {tab === "withdraw" ? "Amount in USDC (6 decimals)" : "Amount in shares (18 decimals)"}
      </p>

      {/* Preview */}
      {parsedAmount > BigInt(0) && (
        <div className="text-sm" style={{ color: "#818181" }}>
          {tab === "withdraw" ? (
            <>
              Shares burned: ~{" "}
              <span className="text-white font-medium">
                {formatShares(previewWithdrawShares as bigint | undefined)}
              </span>
            </>
          ) : (
            <>
              Assets received: ~{" "}
              <span className="text-white font-medium">
                {formatUsdc(previewRedeemAssets as bigint | undefined)}
              </span>{" "}
              USDC
            </>
          )}
        </div>
      )}

      {/* Buttons */}
      {step === "approve" ? (
        <>
          <button
            onClick={handleApprove}
            disabled={
              !isEnabled ||
              parsedAmount === BigInt(0) ||
              requiredAllowance === BigInt(0) ||
              approvePending
            }
            className="btn-primary w-full px-4 py-2.5"
          >
            {approvePending ? "Confirm in wallet..." : "Approve Shares"}
          </button>
          <TxStatus
            hash={approveHash}
            error={approveError}
            isPending={approvePending}
            onConfirmed={handleApproveConfirmed}
          />
        </>
      ) : (
        <>
          <button
            onClick={handleExecute}
            disabled={!isEnabled || parsedAmount === BigInt(0) || executePending}
            className="btn-primary w-full px-4 py-2.5"
          >
            {executePending
              ? "Confirm in wallet..."
              : tab === "withdraw"
              ? "Withdraw"
              : "Redeem"}
          </button>
          <TxStatus
            hash={executeHash}
            error={executeError}
            isPending={executePending}
            onConfirmed={handleExecuteConfirmed}
          />
        </>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main Page
// ---------------------------------------------------------------------------

export default function VaultPage({
  params,
}: {
  params: Promise<{ address: string }>;
}) {
  const { address: vaultAddress } = React.use(params);
  const vaultAddr = vaultAddress as `0x${string}`;
  const { address: userAddress, isConnected } = useAccount();
  const { browsingChainId } = useBrowsingChain();

  // ---- Vault reads ----

  const { data: vaultName, isLoading: nameLoading } = useReadContract({
    address: vaultAddr,
    abi: vaultAbi,
    functionName: "name",
    chainId: browsingChainId,
    query: { refetchInterval: 5000 },
  });

  const { data: vaultSymbol } = useReadContract({
    address: vaultAddr,
    abi: vaultAbi,
    functionName: "symbol",
    chainId: browsingChainId,
    query: { refetchInterval: 5000 },
  });

  const { data: totalAssets } = useReadContract({
    address: vaultAddr,
    abi: vaultAbi,
    functionName: "totalAssets",
    chainId: browsingChainId,
    query: { refetchInterval: 5000 },
  });

  const { data: sharePrice } = useReadContract({
    address: vaultAddr,
    abi: vaultAbi,
    functionName: "convertToAssets",
    args: [parseUnits("1", 18)],
    chainId: browsingChainId,
    query: { refetchInterval: 5000 },
  });

  const { data: cycleData } = useReadContract({
    address: vaultAddr,
    abi: vaultAbi,
    functionName: "getCurrentCycle",
    chainId: browsingChainId,
    query: { refetchInterval: 5000 },
  });

  const { data: maxDeposit } = useReadContract({
    address: vaultAddr,
    abi: vaultAbi,
    functionName: "getMaxDeposit",
    chainId: browsingChainId,
    query: { refetchInterval: 5000 },
  });

  const { data: userShares } = useReadContract({
    address: vaultAddr,
    abi: vaultAbi,
    functionName: "balanceOf",
    args: userAddress ? [userAddress] : undefined,
    chainId: browsingChainId,
    query: { enabled: !!userAddress, refetchInterval: 5000 },
  });

  // Extract cycle status
  const cycleStatus =
    cycleData !== undefined ? Number((cycleData as any).status ?? (cycleData as any)[0] ?? 0) : 0;

  const isLoading = nameLoading;

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="flex items-center gap-3" style={{ color: "#818181" }}>
          <div className="animate-spin w-5 h-5 border-2 border-t-transparent rounded-full" style={{ borderColor: "#FB5F07", borderTopColor: "transparent" }} />
          Loading vault...
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen text-white">
      <div className="max-w-4xl mx-auto px-4 py-8 space-y-8">
        {/* Breadcrumb */}
        <nav className="flex items-center gap-2 text-sm" style={{ color: "#818181" }}>
          <Link href="/" className="hover:text-white transition-colors" style={{ color: "#FB5F07" }}>
            Vaults
          </Link>
          <span>/</span>
          <span className="text-white">
            Vault {shortenAddress(vaultAddress)}
          </span>
        </nav>

        {/* Vault Name */}
        <div>
          <h1 className="text-2xl font-bold text-white">
            {(vaultName as string) ?? "Vault"}{" "}
            <span className="text-lg font-normal" style={{ color: "#818181" }}>
              ({(vaultSymbol as string) ?? "—"})
            </span>
          </h1>
          <p className="text-sm mt-1 font-mono" style={{ color: "#818181" }}>
            {vaultAddress}
          </p>
        </div>

        {/* Stat Cards */}
        <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
          <StatCard
            label="Total Assets"
            value={`${formatUsdc(totalAssets as bigint | undefined)} USDC`}
          />
          <StatCard
            label="Share Price"
            value={
              sharePrice !== undefined
                ? `${formatUsdc(sharePrice as bigint)} USDC`
                : "—"
            }
          />
          <StatCard
            label="Cycle Status"
            value=""
            badge={{
              text: CYCLE_LABELS[cycleStatus] ?? "Unknown",
              className: CYCLE_COLORS[cycleStatus] ?? "bg-slate-600 text-slate-200",
            }}
          />
          <StatCard
            label="Max Deposit"
            value={`${formatUsdc(maxDeposit as bigint | undefined)} USDC`}
          />
          <StatCard
            label="Your Shares"
            value={
              isConnected
                ? formatShares(userShares as bigint | undefined)
                : "Connect wallet"
            }
          />
          <StatCard
            label="Name / Symbol"
            value={`${(vaultName as string) ?? "—"} / ${(vaultSymbol as string) ?? "—"}`}
          />
        </div>

        {/* Connect wallet notice */}
        {!isConnected && (
          <div className="rounded-xl p-6 text-center" style={{ background: "#171717", border: "1px solid #3C323A", color: "#818181" }}>
            Connect your wallet to deposit or withdraw.
          </div>
        )}

        {/* Deposit + Withdraw/Redeem */}
        {isConnected && (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            <DepositSection
              vaultAddress={vaultAddr}
              cycleStatus={cycleStatus}
            />
            <WithdrawRedeemSection
              vaultAddress={vaultAddr}
              cycleStatus={cycleStatus}
            />
          </div>
        )}
      </div>
    </div>
  );
}
