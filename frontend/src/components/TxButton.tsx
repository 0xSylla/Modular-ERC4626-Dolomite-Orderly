"use client";

import { useWaitForTransactionReceipt } from "wagmi";

interface TxButtonProps {
  label: string;
  hash: `0x${string}` | undefined;
  isPending: boolean;
  error: Error | null;
  onClick: () => void;
  disabled?: boolean;
  className?: string;
}

export default function TxButton({
  label,
  hash,
  isPending,
  error,
  onClick,
  disabled,
  className,
}: TxButtonProps) {
  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  const isDisabled = disabled || isPending || isConfirming;

  return (
    <div className="space-y-2">
      <button
        onClick={onClick}
        disabled={isDisabled}
        className={`px-4 py-2.5 disabled:opacity-50 disabled:cursor-not-allowed ${
          className || "btn-primary"
        }`}
      >
        {isPending
          ? "Confirm in wallet..."
          : isConfirming
          ? "Confirming..."
          : label}
      </button>

      {isConfirming && (
        <div className="flex items-center gap-2 text-sm" style={{ color: "#FB5F07" }}>
          <div className="animate-spin w-4 h-4 border-2 border-t-transparent rounded-full" style={{ borderColor: "#FB5F07", borderTopColor: "transparent" }} />
          Waiting for confirmation...
        </div>
      )}

      {isSuccess && (
        <div className="text-sm text-emerald-400 bg-emerald-950/30 border border-emerald-800/40 rounded-lg px-3 py-2">
          Transaction confirmed!
          {hash && (
            <a
              href={`https://berascan.com/tx/${hash}`}
              target="_blank"
              rel="noopener noreferrer"
              className="ml-2 underline text-emerald-300"
            >
              View on Berascan
            </a>
          )}
        </div>
      )}

      {error && (
        <div className="text-sm text-red-400 bg-red-950/30 border border-red-800/40 rounded-lg px-3 py-2">
          {error.message?.slice(0, 200)}
        </div>
      )}
    </div>
  );
}
