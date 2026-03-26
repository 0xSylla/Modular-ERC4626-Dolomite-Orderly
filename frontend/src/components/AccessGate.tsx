"use client";

import { useState, useEffect } from "react";

const VALID_CODES = ["CURATOR1"];
const STORAGE_KEY = "dirac-access-code";

export default function AccessGate({ children }: { children: React.ReactNode }) {
  const [unlocked, setUnlocked] = useState(false);
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    const saved = sessionStorage.getItem(STORAGE_KEY);
    if (saved && VALID_CODES.includes(saved)) {
      setUnlocked(true);
    }
    setLoaded(true);
  }, []);

  function handleProceed() {
    if (VALID_CODES.includes(code.trim())) {
      sessionStorage.setItem(STORAGE_KEY, code.trim());
      setUnlocked(true);
      setError("");
    } else {
      setError("Invalid code");
    }
  }

  function handleCancel() {
    setCode("");
    setError("");
  }

  if (!loaded) return null;
  if (unlocked) return <>{children}</>;

  return (
    <div className="fixed inset-0 z-[100] flex items-center justify-center" style={{ background: "#171717" }}>
      <div className="rounded-xl border border-[#3C323A] bg-[#252525] p-8 max-w-sm w-full mx-4 space-y-5">
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
            className="btn-primary flex-1 px-4 py-2.5 rounded-lg font-medium"
          >
            Proceed
          </button>
        </div>
      </div>
    </div>
  );
}
