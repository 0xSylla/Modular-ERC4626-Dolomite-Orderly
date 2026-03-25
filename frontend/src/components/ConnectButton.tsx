"use client";

import { useEffect, useRef, useState } from "react";
import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { DEFAULT_CHAIN, SUPPORTED_CHAINS, LIVE_CHAINS } from "@/lib/wagmi";
import { useBrowsingChain } from "@/lib/ChainContext";

const CHAIN_STYLES: Record<number, { dot: string; badge: string }> = {
  80094:  { dot: "bg-[#FB5F07]",  badge: "bg-[#FB5F07]/10 text-[#FB5F07] border-[#FB5F07]/30" },  // Berachain
  42161:  { dot: "bg-sky-400",    badge: "bg-sky-900/60 text-sky-300 border-sky-700/50" },          // Arbitrum
  1:      { dot: "bg-blue-500",   badge: "bg-blue-900/60 text-blue-300 border-blue-700/50" },       // Ethereum
  43114:  { dot: "bg-red-500",    badge: "bg-red-900/60 text-red-300 border-red-700/50" },          // Avalanche
  8453:   { dot: "bg-blue-400",   badge: "bg-blue-900/60 text-blue-300 border-blue-700/50" },       // Base
  56:     { dot: "bg-yellow-400", badge: "bg-yellow-900/60 text-yellow-300 border-yellow-700/50" }, // BNB Chain
  10:     { dot: "bg-red-400",    badge: "bg-red-900/60 text-red-300 border-red-700/50" },          // Optimism
  137:    { dot: "bg-purple-500", badge: "bg-purple-900/60 text-purple-300 border-purple-700/50" }, // Polygon
  324:    { dot: "bg-indigo-400", badge: "bg-indigo-900/60 text-indigo-300 border-indigo-700/50" }, // zkSync
  1012:   { dot: "bg-cyan-400",   badge: "bg-cyan-900/60 text-cyan-300 border-cyan-700/50" },       // Plasma
  10143:  { dot: "bg-violet-400", badge: "bg-violet-900/60 text-violet-300 border-violet-700/50" }, // Monad
};

export default function ConnectButton() {
  const { address, isConnected, chain } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: isSwitching } = useSwitchChain();
  const { browsingChainId, setBrowsingChainId } = useBrowsingChain();
  const [dropdownOpen, setDropdownOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);

  // Auto-switch wallet to default chain on connect if on unsupported chain
  useEffect(() => {
    if (!isConnected || !chain) return;
    const isSupported = SUPPORTED_CHAINS.some((c) => c.id === chain.id);
    if (!isSupported) {
      switchChain({ chainId: DEFAULT_CHAIN.id });
    }
  }, [isConnected, chain, switchChain]);

  // Close dropdown on outside click
  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
        setDropdownOpen(false);
      }
    }
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, []);

  const isLive = (chainId: number) => LIVE_CHAINS.some((c) => c.id === chainId);

  function handleChainSelect(chainId: number) {
    if (!isLive(chainId)) return; // coming soon chains are not selectable
    setDropdownOpen(false);
    setBrowsingChainId(chainId);
    if (isConnected) switchChain({ chainId });
  }

  const currentChainId = browsingChainId;
  const currentChainName = SUPPORTED_CHAINS.find((c) => c.id === currentChainId)?.name ?? DEFAULT_CHAIN.name;
  const styles = CHAIN_STYLES[currentChainId] ?? CHAIN_STYLES[DEFAULT_CHAIN.id];

  return (
    <div className="flex items-center gap-3">
      {/* Chain switcher — always visible */}
      <div className="relative" ref={dropdownRef}>
        <button
          onClick={() => setDropdownOpen((o) => !o)}
          disabled={isSwitching}
          className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-sm font-medium border transition-colors cursor-pointer ${styles.badge}`}
        >
          <span className={`w-2 h-2 rounded-full ${styles.dot}`} />
          {isSwitching ? "Switching…" : currentChainName}
          <svg className="w-3 h-3 opacity-60" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>

        {dropdownOpen && (
          <div className="absolute right-0 mt-1 w-52 rounded-lg shadow-xl z-50 overflow-hidden max-h-80 overflow-y-auto" style={{ background: "#252525", border: "1px solid #3C323A" }}>
            {SUPPORTED_CHAINS.map((c) => {
              const s = CHAIN_STYLES[c.id];
              const active = c.id === currentChainId;
              const live = isLive(c.id);
              return (
                <button
                  key={c.id}
                  onClick={() => handleChainSelect(c.id)}
                  className={`w-full flex items-center gap-2 px-3 py-2.5 text-sm text-left transition-colors
                    ${!live ? "opacity-50 cursor-default" : active ? "text-white" : "text-[#818181] hover:text-white hover:bg-[#3C323A]"}`}
                  style={active ? { background: "#3C323A" } : undefined}
                >
                  <span className={`w-2 h-2 rounded-full ${s?.dot ?? "bg-gray-500"}`} />
                  {c.name}
                  {!live && (
                    <span className="ml-auto text-[10px] px-1.5 py-0.5 rounded-full bg-[#3C323A] text-[#818181]">Soon</span>
                  )}
                  {active && live && (
                    <svg className="ml-auto w-3.5 h-3.5" style={{ color: "#FB5F07" }} fill="currentColor" viewBox="0 0 20 20">
                      <path fillRule="evenodd" d="M16.707 5.293a1 1 0 010 1.414L8.414 15l-4.121-4.121a1 1 0 011.414-1.414L8.414 12.172l7.879-7.879a1 1 0 011.414 0z" clipRule="evenodd" />
                    </svg>
                  )}
                </button>
              );
            })}
          </div>
        )}
      </div>

      {/* Connect / address + disconnect */}
      {!isConnected ? (
        <button
          onClick={() => connect({ connector: connectors[0] })}
          className="btn-primary px-4 py-2"
        >
          Connect Wallet
        </button>
      ) : (
        <>
          <span className="font-mono text-sm" style={{ color: "#818181" }}>
            {address?.slice(0, 6)}...{address?.slice(-4)}
          </span>
          <button
            onClick={() => disconnect()}
            className="btn-secondary px-3 py-1.5 text-sm"
          >
            Disconnect
          </button>
        </>
      )}
    </div>
  );
}
