"use client";

import { createContext, useContext, useState, useEffect } from "react";
import { useAccount } from "wagmi";
import { DEFAULT_CHAIN } from "./wagmi";

interface ChainContextValue {
  browsingChainId: number;
  setBrowsingChainId: (id: number) => void;
}

const ChainContext = createContext<ChainContextValue>({
  browsingChainId: DEFAULT_CHAIN.id,
  setBrowsingChainId: () => {},
});

export function ChainProvider({ children }: { children: React.ReactNode }) {
  const { chain, isConnected } = useAccount();
  const [browsingChainId, setBrowsingChainId] = useState<number>(DEFAULT_CHAIN.id);

  // Keep browsing chain in sync with wallet when connected
  useEffect(() => {
    if (isConnected && chain) {
      setBrowsingChainId(chain.id);
    }
  }, [isConnected, chain]);

  return (
    <ChainContext.Provider value={{ browsingChainId, setBrowsingChainId }}>
      {children}
    </ChainContext.Provider>
  );
}

export function useBrowsingChain() {
  return useContext(ChainContext);
}
