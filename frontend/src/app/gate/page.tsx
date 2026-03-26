"use client";

import { useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import Image from "next/image";

export default function GatePage() {
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const router = useRouter();
  const searchParams = useSearchParams();
  const next = searchParams.get("next") || "/";

  async function handleProceed() {
    if (!code.trim()) return;
    setLoading(true);
    setError("");

    try {
      const res = await fetch("/api/gate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: code.trim(), next }),
      });

      if (res.ok) {
        router.push(next);
        router.refresh();
      } else {
        setError("Invalid code");
      }
    } catch {
      setError("Something went wrong");
    } finally {
      setLoading(false);
    }
  }

  function handleCancel() {
    setCode("");
    setError("");
  }

  return (
    <div className="fixed inset-0 z-[100] flex items-center justify-center" style={{ background: "#171717" }}>
      <div className="rounded-xl border border-[#3C323A] bg-[#252525] p-8 max-w-sm w-full mx-4 space-y-6">
        <div className="flex justify-center">
          <Image
            src="/logos/dirac-logos/dirac_finance_logo_WH.svg"
            width={120}
            height={35}
            alt="Dirac Finance"
          />
        </div>

        <h2 className="text-xl font-bold text-white text-center">Enter Curation Access Code</h2>

        <div>
          <input
            type="text"
            value={code}
            onChange={(e) => { setCode(e.target.value); setError(""); }}
            onKeyDown={(e) => e.key === "Enter" && handleProceed()}
            placeholder="Access code"
            className="w-full px-4 py-3 rounded-lg border border-[#3C323A] bg-[#171717] text-white placeholder-[#818181] focus:border-[#FB5F07] focus:outline-none transition-colors text-center font-mono tracking-widest"
            autoFocus
          />
          {error && <p className="text-red-400 text-sm mt-2 text-center">{error}</p>}
        </div>

        <div className="flex gap-3">
          <button
            onClick={handleCancel}
            className="btn-secondary flex-1 px-4 py-2.5 rounded-lg font-medium"
          >
            Cancel
          </button>
          <button
            onClick={handleProceed}
            disabled={loading}
            className="btn-primary flex-1 px-4 py-2.5 rounded-lg font-medium disabled:opacity-50"
          >
            {loading ? "..." : "Proceed"}
          </button>
        </div>
      </div>
    </div>
  );
}
