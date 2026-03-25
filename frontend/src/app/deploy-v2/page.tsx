"use client";

import { useState, useEffect, useCallback, useMemo } from "react";
import Link from "next/link";
import {
  useAccount,
  useWriteContract,
  useWaitForTransactionReceipt,
  useReadContracts,
  useSwitchChain,
} from "wagmi";
import { parseUnits, keccak256, encodePacked, toBytes } from "viem";
import { useAddresses, factoryAbi, vaultAbi, curatorRouterAbi } from "@/lib/contracts";
import { useBrowsingChain } from "@/lib/ChainContext";
import { initializeVault } from "@/lib/api";
import dynamic from "next/dynamic";

const BacktestEquityChart = dynamic(() => import("@/components/BacktestEquityChart"), { ssr: false });

/* -------------------------------------------------------------------------- */
/*                                   Types                                    */
/* -------------------------------------------------------------------------- */

type Step = "strategy" | "configure" | "review";

const STEPS: { key: Step; label: string }[] = [
  { key: "strategy",  label: "Strategy" },
  { key: "configure", label: "Configure" },
  { key: "review",    label: "Review & Deploy" },
];

/* -------------------------------------------------------------------------- */
/*                               Static data                                  */
/* -------------------------------------------------------------------------- */

interface TemplateInfo {
  id: string;
  name: string;
  description: string;
  tags: string[];
}

const TEMPLATES: TemplateInfo[] = [
  {
    id: "delta-neutral-v1",
    name: "Delta Neutral v1",
    description:
      "Market-neutral strategy that combines collateral lending on Dolomite with short perpetual positions on Orderly to capture yield while hedging price exposure. Ideal for stablecoin depositors seeking yield on volatile assets like iBGT.",
    tags: ["Lending", "Perps Hedging", "Yield"],
  },
];

interface CollateralAsset {
  label: string;
  address: `0x${string}`;
  description: string;
}

const ALL_SWAP_MODULES = [
  { key: "swap.kodiak", label: "Kodiak", hash: keccak256(encodePacked(["string"], ["swap.kodiak"])) },
  { key: "swap.odos",   label: "Odos",   hash: keccak256(encodePacked(["string"], ["swap.odos"])) },
] as const;

const KNOWN_MODULES_LENDING = [
  { key: "lending.dolomite", label: "Dolomite", hash: keccak256(encodePacked(["string"], ["lending.dolomite"])) },
  { key: "lending.aave",     label: "Aave V3",  hash: keccak256(encodePacked(["string"], ["lending.aave"])) },
  { key: "lending.morpho",   label: "Morpho",   hash: keccak256(encodePacked(["string"], ["lending.morpho"])) },
] as const;

const KNOWN_MODULES_PERPS = [
  { key: "perps.orderly", label: "Orderly", hash: keccak256(encodePacked(["string"], ["perps.orderly"])) },
] as const;

/* -------------------------------------------------------------------------- */
/*                               Shared styles                                */
/* -------------------------------------------------------------------------- */

const inputClass =
  "w-full bg-[#252525] border border-[#3C323A] rounded-lg px-4 py-2.5 focus:border-[#FB5F07] focus:outline-none text-white placeholder:text-[#818181]";

const selectClass =
  "w-full bg-[#252525] border border-[#3C323A] rounded-lg px-4 py-2.5 focus:border-[#FB5F07] focus:outline-none text-white";

/* -------------------------------------------------------------------------- */
/*                                  Component                                 */
/* -------------------------------------------------------------------------- */

export default function DeployV2Page() {
  const { address: connectedAddress, isConnected, chain: walletChain } = useAccount();
  const { browsingChainId: chainId } = useBrowsingChain();
  const addresses = useAddresses();
  const { switchChainAsync } = useSwitchChain();

  const DEPOSIT_TOKENS = [{ label: "USDC", address: addresses.USDC }];
  const COLLATERAL_ASSETS: CollateralAsset[] = addresses.strategyAssets.map((a) => ({
    ...a,
    description: "",
  }));

  /* ----------------------------- wizard state ----------------------------- */
  const [step, setStep] = useState<Step>("strategy");

  // Step 1: Strategy
  const [template, setTemplate] = useState("");

  // Step 2: All config combined
  const [vaultName, setVaultName]     = useState("");
  const [vaultSymbol, setVaultSymbol] = useState("");
  const [depositToken, setDepositToken] = useState<`0x${string}`>(addresses.USDC);
  const [maxDeposit, setMaxDeposit]   = useState("");
  const [curatorFeeBps, setCuratorFeeBps] = useState(100);
  const [feeRecipient, setFeeRecipient]   = useState("");
  const [selectedAssets, setSelectedAssets] = useState<Set<string>>(new Set());
  const [selectedSwapAddr,    setSelectedSwapAddr]    = useState("");
  const [selectedLendingAddr, setSelectedLendingAddr] = useState("");
  const [selectedPerpsAddr,   setSelectedPerpsAddr]   = useState("");
  const [rebalanceThreshold, setRebalanceThreshold]   = useState(25);
  const [execMode, setExecMode]                       = useState<"cex" | "dex">("dex");
  const [fundingFilterOn, setFundingFilterOn]           = useState(false);
  const [fundingSlider, setFundingSlider]             = useState(50);

  // Deploy state
  const [deployedVault, setDeployedVault]         = useState<`0x${string}` | null>(null);
  const [deployingTxIdx, setDeployingTxIdx]       = useState(-1);
  const [completedTxs, setCompletedTxs]           = useState<Set<number>>(new Set());
  const [parseError, setParseError]               = useState<string | null>(null);
  const [orderlyInitStatus, setOrderlyInitStatus] = useState<null | "loading" | "success" | "failed">(null);
  const [orderlyInitError, setOrderlyInitError]   = useState<string | null>(null);

  // Deploy modal
  const [showDeployModal, setShowDeployModal] = useState(false);

  // Which config section is expanded
  const [openSections, setOpenSections] = useState<Set<string>>(new Set(["assets", "lending", "perps", "risk"]));

  useEffect(() => {
    setDepositToken(addresses.USDC);
    const wstETH = addresses.strategyAssets.find((a) => a.label === "wstETH");
    setSelectedAssets(wstETH ? new Set([wstETH.address]) : new Set());
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [addresses.USDC]);

  useEffect(() => {
    if (connectedAddress && !feeRecipient) setFeeRecipient(connectedAddress);
  }, [connectedAddress, feeRecipient]);

  /* -------- fetch protocol fees ------------------------------------------ */
  const { data: feesData } = useReadContracts({
    contracts: [
      { address: addresses.factory, abi: factoryAbi, functionName: "protocolFees" as const, chainId },
    ],
  });

  const protocolFeesRaw = feesData?.[0]?.result as readonly [bigint, bigint, `0x${string}`, `0x${string}`] | undefined;
  const protocolFeeBps = protocolFeesRaw ? Number(protocolFeesRaw[0]) : null;
  const daoFeeBps      = protocolFeesRaw ? Number(protocolFeesRaw[1]) : null;

  /* -------- fetch all known module addresses ------------------------------ */
  const allModuleHashes = [
    ...ALL_SWAP_MODULES.map((m) => m.hash),
    ...KNOWN_MODULES_LENDING.map((m) => m.hash),
    ...KNOWN_MODULES_PERPS.map((m) => m.hash),
  ];

  const { data: moduleData } = useReadContracts({
    contracts: allModuleHashes.map((h) => ({
      address: addresses.factory as `0x${string}`,
      abi: factoryAbi,
      functionName: "getModule" as const,
      args: [h] as const,
      chainId,
    })),
  });

  let moduleResultIdx = 0;
  const ZERO_ADDR = "0x0000000000000000000000000000000000000000";

  const availableSwapModules = ALL_SWAP_MODULES.map((m) => ({
    ...m,
    address: (moduleData?.[moduleResultIdx++]?.result as string | undefined) ?? "",
  })).filter((m) => m.address && m.address !== ZERO_ADDR);

  const availableLendingModules = KNOWN_MODULES_LENDING.map((m) => ({
    ...m,
    address: (moduleData?.[moduleResultIdx++]?.result as string | undefined) ?? "",
  })).filter((m) => m.address && m.address !== ZERO_ADDR);

  const availablePerpsModules = KNOWN_MODULES_PERPS.map((m) => ({
    ...m,
    address: (moduleData?.[moduleResultIdx++]?.result as string | undefined) ?? "",
  })).filter((m) => m.address && m.address !== ZERO_ADDR);

  useEffect(() => {
    if (!selectedSwapAddr    && availableSwapModules[0])    setSelectedSwapAddr(availableSwapModules[0].address);
    if (!selectedLendingAddr && availableLendingModules.length > 0) {
      const morpho = availableLendingModules.find((m) => m.key === "lending.morpho");
      setSelectedLendingAddr(morpho ? morpho.address : availableLendingModules[0].address);
    }
    if (!selectedPerpsAddr   && availablePerpsModules[0])   setSelectedPerpsAddr(availablePerpsModules[0].address);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [moduleData]);

  const modulesValid =
    selectedSwapAddr.length > 0 &&
    selectedLendingAddr.length > 0 &&
    selectedPerpsAddr.length > 0;

  const isOrderlyPerps = (() => {
    const m = availablePerpsModules.find((m) => m.key === "perps.orderly");
    return !!m && m.address === selectedPerpsAddr;
  })();

  /* --------------------------- contract hooks ----------------------------- */
  const {
    writeContract,
    data: txHash,
    isPending: isSigning,
    error: writeError,
    reset: resetWrite,
  } = useWriteContract();

  const { data: receipt, isLoading: isConfirming } = useWaitForTransactionReceipt({ hash: txHash });

  /* ---------------------- computed tx queue ------------------------------- */
  const assetArr = useMemo(() => Array.from(selectedAssets) as `0x${string}`[], [selectedAssets]);

  const txQueue = useMemo(() => {
    const q: { label: string; description: string }[] = [
      { label: "Deploy Vault", description: "Create vault on the factory contract" },
    ];
    for (const addr of assetArr) {
      const known = COLLATERAL_ASSETS.find((a) => a.address === addr);
      const label = known ? known.label : `${addr.slice(0, 6)}…${addr.slice(-4)}`;
      q.push({ label: `Whitelist ${label}`, description: `Enable ${label} as collateral` });
    }
    q.push({ label: "Configure Modules", description: "Set swap / lending / perps modules on the vault" });
    return q;
  }, [assetArr]);

  /* ---------------------- fire each tx in sequence ----------------------- */
  const startTx = useCallback(
    (idx: number, vault: `0x${string}` | null) => {
      resetWrite();
      setParseError(null);

      if (idx === 0) {
        const templateId = keccak256(encodePacked(["string"], [template]));
        writeContract({
          address: addresses.factory,
          abi: factoryAbi,
          functionName: "createVault",
          args: [
            vaultName, vaultSymbol, depositToken,
            parseUnits(maxDeposit, 6),
            templateId,
            { curatorFeeBps: BigInt(curatorFeeBps), curatorFeeRecipient: feeRecipient as `0x${string}` },
          ],
        });
      } else if (idx <= assetArr.length) {
        if (!vault) return;
        writeContract({
          address: vault,
          abi: vaultAbi,
          functionName: "whitelistTargetAsset",
          args: [assetArr[idx - 1]],
        });
      } else {
        if (!vault || !modulesValid) return;
        writeContract({
          address: addresses.curatorRouter,
          abi: curatorRouterAbi,
          functionName: "setVaultLegs",
          args: [
            vault,
            {
              swapModule:    selectedSwapAddr    as `0x${string}`,
              lendingModule: selectedLendingAddr as `0x${string}`,
              perpsModule:   selectedPerpsAddr   as `0x${string}`,
            },
          ],
        });
      }
    },
    [
      resetWrite, template, vaultName, vaultSymbol, depositToken, maxDeposit,
      curatorFeeBps, feeRecipient, assetArr, modulesValid,
      selectedSwapAddr, selectedLendingAddr, selectedPerpsAddr, writeContract,
    ],
  );

  /* ---------------------- handle receipt ---------------------------------- */
  useEffect(() => {
    if (!receipt || !showDeployModal) return;

    let vaultAddr = deployedVault;

    if (deployingTxIdx === 0) {
      const VAULT_CREATED_TOPIC = keccak256(toBytes("VaultCreated(address,address,address)"));
      for (const log of receipt.logs) {
        if (log.topics[0]?.toLowerCase() === VAULT_CREATED_TOPIC.toLowerCase() && log.topics[1]) {
          vaultAddr = `0x${log.topics[1].slice(-40)}` as `0x${string}`;
          setDeployedVault(vaultAddr);
          break;
        }
      }
      if (!vaultAddr) { setParseError("Transaction confirmed but could not find VaultCreated event."); return; }
    }

    const nextIdx = deployingTxIdx + 1;
    setCompletedTxs((prev) => new Set(prev).add(deployingTxIdx));

    if (nextIdx >= txQueue.length) {
      setDeployingTxIdx(nextIdx);
      if (isOrderlyPerps && vaultAddr) {
        setOrderlyInitStatus("loading");
        initializeVault(chainId, vaultAddr, 2)
          .then(() => {
            setOrderlyInitStatus("success");
          })
          .catch((err: Error) => {
            setOrderlyInitError(err?.message ?? "Orderly initialization failed");
            setOrderlyInitStatus("failed");
          });
      }
    } else {
      setDeployingTxIdx(nextIdx);
      startTx(nextIdx, vaultAddr);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [receipt]);

  /* ---------------------- kick off deploy --------------------------------- */
  const handleStartDeploying = useCallback(async () => {
    if (walletChain?.id !== chainId) {
      try {
        await switchChainAsync({ chainId });
      } catch {
        setParseError(`Please switch your wallet to the correct network before deploying.`);
        return;
      }
    }
    setShowDeployModal(true);
    setDeployingTxIdx(0);
    setCompletedTxs(new Set());
    setDeployedVault(null);
    setParseError(null);
    setOrderlyInitStatus(null);
    setOrderlyInitError(null);
    startTx(0, null);
  }, [startTx, walletChain, chainId, switchChainAsync]);

  /* ----------------------------- validation ------------------------------- */
  const isConfigValid =
    vaultName.trim().length > 0 &&
    vaultSymbol.trim().length > 0 &&
    maxDeposit.trim().length > 0 &&
    Number(maxDeposit) > 0;

  const isFeesValid =
    curatorFeeBps >= 0 &&
    curatorFeeBps <= 200 &&
    /^0x[a-fA-F0-9]{40}$/.test(feeRecipient);

  const isRiskValid = rebalanceThreshold >= 1 && rebalanceThreshold <= 45;

  const isStep2Valid =
    isConfigValid && isFeesValid && selectedAssets.size > 0 && modulesValid && isRiskValid;

  /* ----------------------------- helpers ---------------------------------- */
  const depositTokenLabel = DEPOSIT_TOKENS.find((t) => t.address === depositToken)?.label ?? "Unknown";
  const selectedTemplate  = TEMPLATES.find((t) => t.id === template);
  const hasWstETH = Array.from(selectedAssets).some(
    (addr) => COLLATERAL_ASSETS.find((a) => a.address === addr)?.label === "wstETH"
  );

  function assetLabel(addr: string) {
    const known = COLLATERAL_ASSETS.find((a) => a.address === addr);
    return known ? known.label : `${addr.slice(0, 6)}...${addr.slice(-4)}`;
  }

  function moduleLabel(addr: string) {
    const all = [...availableSwapModules, ...availableLendingModules, ...availablePerpsModules];
    return all.find((m) => m.address === addr)?.label ?? addr.slice(0, 8);
  }

  function toggleAsset(addr: string) {
    setSelectedAssets((prev) => {
      const next = new Set(prev);
      if (next.has(addr)) next.delete(addr); else next.add(addr);
      return next;
    });
  }

  /* ---------------------------------------------------------------------- */
  /*                                Render                                  */
  /* ---------------------------------------------------------------------- */

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-bold text-white">Deploy a New Vault</h1>
        <p className="text-[#818181] mt-1">Streamlined deployment — configure everything in one step.</p>
      </div>

      <ProgressBar currentStep={step} />

      {/* ========================== STEP 1: STRATEGY ======================== */}
      {step === "strategy" && (
        <div className="space-y-5">
          <h2 className="text-lg font-semibold text-white">Select a Strategy Template</h2>
          <p className="text-sm text-[#818181]">
            Choose a vault strategy. Each template defines the modules and execution logic.
          </p>

          <div className="grid grid-cols-1 gap-4">
            {TEMPLATES.map((t) => {
              const isSelected = template === t.id;
              return (
                <button
                  key={t.id}
                  onClick={() => setTemplate(t.id)}
                  className={`text-left p-6 rounded-xl border-2 transition-all ${
                    isSelected ? "border-[#FB5F07] bg-[#FB5F07]/10" : "border-[#3C323A] bg-[#252525]/60 hover:border-[#818181]"
                  }`}
                >
                  <div className="flex items-start justify-between">
                    <div className="space-y-2">
                      <h3 className="text-lg font-semibold text-white">{t.name}</h3>
                      <p className="text-sm text-[#818181] leading-relaxed">{t.description}</p>
                      <div className="flex gap-2 pt-1">
                        {t.tags.map((tag) => (
                          <span key={tag} className="inline-block rounded-full bg-[#252525] border border-[#3C323A] px-2.5 py-0.5 text-xs font-medium text-[#818181]">
                            {tag}
                          </span>
                        ))}
                      </div>
                    </div>
                    <div className={`mt-1 h-5 w-5 shrink-0 rounded-full border-2 flex items-center justify-center ${isSelected ? "border-[#FB5F07]" : "border-[#3C323A]"}`}>
                      {isSelected && <div className="h-2.5 w-2.5 rounded-full bg-[#FB5F07]" />}
                    </div>
                  </div>
                </button>
              );
            })}
          </div>

          <div className="p-6 rounded-xl border-2 border-dashed border-[#3C323A] bg-[#252525]/30 opacity-50">
            <h3 className="text-lg font-semibold text-[#818181]">More strategies coming soon</h3>
            <p className="text-sm text-[#818181]/60 mt-1">Yield farming, basis trading, and more.</p>
          </div>

          <div className="flex justify-end pt-2">
            <button disabled={!template} onClick={() => setStep("configure")} className="btn-primary px-6 py-2.5 rounded-lg font-medium disabled:opacity-40 disabled:cursor-not-allowed">
              Continue
            </button>
          </div>
        </div>
      )}

      {/* ========================== STEP 2: CONFIGURE (ALL IN ONE) ========= */}
      {step === "configure" && (
        <div className="space-y-4">
          <div className="flex items-center justify-between">
            <div>
              <h2 className="text-lg font-semibold text-white">Configure Your Vault</h2>
              <p className="text-xs text-[#818181] mt-1">Strategy: {selectedTemplate?.name}</p>
            </div>
          </div>

          {/* --- Underlying Asset (first position) --- */}
          <AccordionSection
            title="Underlying Asset"
            subtitle={selectedAssets.size > 0 ? Array.from(selectedAssets).map(assetLabel).join(", ") : "Select underlying asset"}
            isOpen={openSections.has("assets")}
            onToggle={() => setOpenSections(s => { const n = new Set(s); n.has("assets") ? n.delete("assets") : n.add("assets"); return n; })}
            isValid={selectedAssets.size > 0}
          >
            <div className="flex flex-wrap gap-2">
              {COLLATERAL_ASSETS.map((asset) => {
                const isSelected = selectedAssets.has(asset.address);
                const enabled = chainId !== 42161 || asset.label === "wstETH";
                return (
                  <button
                    key={asset.address}
                    onClick={() => enabled && toggleAsset(asset.address)}
                    disabled={!enabled}
                    className={`flex items-center gap-2 px-3 py-2 rounded-lg border transition-all ${
                      !enabled ? "border-[#3C323A] bg-[#252525]/30 opacity-40 cursor-not-allowed"
                      : isSelected ? "border-[#FB5F07] bg-[#FB5F07]/10" : "border-[#3C323A] bg-[#252525]/50 hover:border-[#818181]"
                    }`}
                  >
                    <div className={`h-3.5 w-3.5 shrink-0 rounded border-2 flex items-center justify-center ${isSelected ? "border-[#FB5F07] bg-[#FB5F07]" : "border-[#3C323A]"}`}>
                      {isSelected && (
                        <svg className="h-2 w-2 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                          <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                        </svg>
                      )}
                    </div>
                    <span className={`text-sm font-medium ${enabled ? "text-white" : "text-[#818181]"}`}>{asset.label}</span>
                  </button>
                );
              })}
              {/* Extra greyed-out tokens */}
              {["XRP", "HYPE"].map((label) => (
                <button key={label} disabled className="flex items-center gap-2 px-3 py-2 rounded-lg border border-[#3C323A] bg-[#252525]/30 opacity-40 cursor-not-allowed">
                  <div className="h-3.5 w-3.5 shrink-0 rounded border-2 border-[#3C323A]" />
                  <span className="text-sm font-medium text-[#818181]">{label}</span>
                </button>
              ))}
            </div>
          </AccordionSection>

          {/* --- Lending Module (pill buttons) --- */}
          <AccordionSection
            title="Lending Module"
            subtitle={moduleLabel(selectedLendingAddr)}
            isOpen={openSections.has("lending")}
            onToggle={() => setOpenSections(s => { const n = new Set(s); n.has("lending") ? n.delete("lending") : n.add("lending"); return n; })}
            isValid={selectedLendingAddr.length > 0}
          >
            <div className="flex flex-wrap gap-2">
              {availableLendingModules.map((m) => {
                const isSelected = selectedLendingAddr === m.address;
                return (
                  <button key={m.key} onClick={() => setSelectedLendingAddr(m.address)}
                    className={`flex items-center gap-2 px-3 py-2 rounded-lg border transition-all ${
                      isSelected ? "border-[#FB5F07] bg-[#FB5F07]/10" : "border-[#3C323A] bg-[#252525]/50 hover:border-[#818181]"
                    }`}>
                    <div className={`h-3.5 w-3.5 shrink-0 rounded-full border-2 flex items-center justify-center ${isSelected ? "border-[#FB5F07] bg-[#FB5F07]" : "border-[#3C323A]"}`}>
                      {isSelected && <div className="h-1.5 w-1.5 rounded-full bg-white" />}
                    </div>
                    <span className="text-sm font-medium text-white">{m.label}</span>
                  </button>
                );
              })}
            </div>
          </AccordionSection>

          {/* --- Perps Module (pill buttons) --- */}
          <AccordionSection
            title="Perps Module"
            subtitle={moduleLabel(selectedPerpsAddr)}
            isOpen={openSections.has("perps")}
            onToggle={() => setOpenSections(s => { const n = new Set(s); n.has("perps") ? n.delete("perps") : n.add("perps"); return n; })}
            isValid={selectedPerpsAddr.length > 0}
          >
            <div className="flex flex-wrap gap-2">
              {availablePerpsModules.map((m) => {
                const isSelected = selectedPerpsAddr === m.address;
                return (
                  <button key={m.key} onClick={() => setSelectedPerpsAddr(m.address)}
                    className={`flex items-center gap-2 px-3 py-2 rounded-lg border transition-all ${
                      isSelected ? "border-[#FB5F07] bg-[#FB5F07]/10" : "border-[#3C323A] bg-[#252525]/50 hover:border-[#818181]"
                    }`}>
                    <div className={`h-3.5 w-3.5 shrink-0 rounded-full border-2 flex items-center justify-center ${isSelected ? "border-[#FB5F07] bg-[#FB5F07]" : "border-[#3C323A]"}`}>
                      {isSelected && <div className="h-1.5 w-1.5 rounded-full bg-white" />}
                    </div>
                    <span className="text-sm font-medium text-white">{m.label}</span>
                  </button>
                );
              })}
              {["Hyperliquid", "GMX"].map((label) => (
                <button key={label} disabled className="flex items-center gap-2 px-3 py-2 rounded-lg border border-[#3C323A] bg-[#252525]/30 opacity-40 cursor-not-allowed">
                  <div className="h-3.5 w-3.5 shrink-0 rounded-full border-2 border-[#3C323A]" />
                  <span className="text-sm font-medium text-[#818181]">{label}</span>
                </button>
              ))}
            </div>
          </AccordionSection>


          {/* --- Risk Parameters (before Vault Info when wstETH selected) --- */}
          {hasWstETH && (
            <AccordionSection
              title="Risk Parameters"
              subtitle={`Rebalance ${rebalanceThreshold}% | ${execMode.toUpperCase()}`}
              isOpen={openSections.has("risk")}
              onToggle={() => setOpenSections(s => { const n = new Set(s); n.has("risk") ? n.delete("risk") : n.add("risk"); return n; })}
              isValid={isRiskValid}
            >
              <div className="space-y-4">
                {/* Rebalancing threshold slider */}
                <div>
                  <div className="flex items-center justify-between mb-2">
                    <label className="text-xs text-[#818181] uppercase tracking-wider">Rebalancing Threshold</label>
                    <span className={`text-2xl font-bold font-mono ${
                      rebalanceThreshold <= 10 ? "text-red-400" : rebalanceThreshold <= 20 ? "text-amber-400" : rebalanceThreshold <= 30 ? "text-blue-400" : "text-emerald-400"
                    }`}>{rebalanceThreshold}%</span>
                  </div>
                  <input
                    type="range"
                    min={1}
                    max={45}
                    value={rebalanceThreshold}
                    onChange={(e) => setRebalanceThreshold(Number(e.target.value))}
                    className="w-full accent-orange-500"
                  />
                  <div className="flex justify-between text-[10px] text-[#818181] mt-1 px-0.5">
                    <span>1%</span><span>10%</span><span>20%</span><span>30%</span><span>45%</span>
                  </div>
                </div>

                {/* Backtest chart + stats */}
                <BacktestEquityChart threshold={rebalanceThreshold} execMode={execMode} fundingFilterOn={fundingFilterOn} fundingSlider={fundingSlider} />

                {/* Toggles row below chart */}
                <div className="flex items-center gap-4 flex-wrap">
                  {/* CEX / DEX toggle */}
                  <div className="flex items-center gap-2">
                    <span className="text-[10px] text-[#818181] uppercase tracking-wider">Execution</span>
                    <div className="flex rounded-lg border border-[#3C323A] overflow-hidden">
                      <button
                        onClick={() => setExecMode("dex")}
                        className={`px-3 py-1 text-xs font-medium font-mono transition-all ${
                          execMode === "dex"
                            ? "bg-[#ff4d4d]/15 text-[#ff4d4d]"
                            : "bg-[#252525] text-[#818181] hover:text-white"
                        }`}
                      >DEX</button>
                      <button
                        onClick={() => setExecMode("cex")}
                        className={`px-3 py-1 text-xs font-medium font-mono transition-all border-l border-[#3C323A] ${
                          execMode === "cex"
                            ? "bg-emerald-500/15 text-emerald-400"
                            : "bg-[#252525] text-[#818181] hover:text-white"
                        }`}
                      >CEX</button>
                    </div>
                  </div>

                  {/* Funding regime filter */}
                  <div className="flex items-center gap-2">
                    <span className="text-[10px] text-[#818181] uppercase tracking-wider">Funding Filter</span>
                    <button
                      onClick={() => setFundingFilterOn(!fundingFilterOn)}
                      className={`relative w-9 h-5 rounded-full transition-all ${
                        fundingFilterOn ? "bg-amber-500" : "bg-[#3C323A]"
                      }`}
                    >
                      <div className={`absolute top-0.5 h-4 w-4 rounded-full bg-white transition-all ${
                        fundingFilterOn ? "left-[18px]" : "left-0.5"
                      }`} />
                    </button>
                    {fundingFilterOn && (
                      <div className="flex items-center gap-1.5">
                        <input
                          type="range"
                          min={0}
                          max={100}
                          value={fundingSlider}
                          onChange={(e) => setFundingSlider(Number(e.target.value))}
                          className="w-24 accent-amber-500"
                        />
                        <span className="text-[10px] text-amber-400 font-mono font-medium min-w-[40px]">
                          {Math.round((fundingSlider / 100) * (-0.00033445) * 100000) / 10} bps
                        </span>
                      </div>
                    )}
                  </div>
                </div>

                <div className="rounded-lg border border-amber-500/40 bg-amber-500/10 px-4 py-2.5 text-xs text-amber-300">
                  Backtest is historical — past performance does not guarantee future results. Parameters saved locally for the rebalancing bot.
                </div>
              </div>
            </AccordionSection>
          )}

          {/* --- Vault Info Section --- */}
          <AccordionSection
            title="Vault Info"
            subtitle={vaultName ? `${vaultName} (${vaultSymbol})` : "Name, symbol, deposit token"}
            isOpen={openSections.has("vault")}
            onToggle={() => setOpenSections(s => { const n = new Set(s); n.has("vault") ? n.delete("vault") : n.add("vault"); return n; })}
            isValid={isConfigValid}
          >
            <Field label="Vault Name">
              <input type="text" value={vaultName} onChange={(e) => setVaultName(e.target.value)}
                placeholder="e.g. Dirac Delta Neutral USDC" className={inputClass} />
            </Field>
            <Field label="Vault Symbol">
              <input type="text" value={vaultSymbol} onChange={(e) => setVaultSymbol(e.target.value)}
                placeholder="e.g. dUSDC" className={inputClass} />
            </Field>
            <Field label="Deposit Token">
              <select value={depositToken} onChange={(e) => setDepositToken(e.target.value as `0x${string}`)} className={inputClass}>
                {DEPOSIT_TOKENS.map((t) => (
                  <option key={t.address} value={t.address}>{t.label} ({t.address.slice(0, 6)}...{t.address.slice(-4)})</option>
                ))}
              </select>
            </Field>
            <Field label="Max Deposit (human units, e.g. 1000000 for 1M USDC)">
              <input type="number" min="0" value={maxDeposit} onChange={(e) => setMaxDeposit(e.target.value)}
                placeholder="1000000" className={inputClass} />
            </Field>
          </AccordionSection>

          {/* --- Fees Section --- */}
          <AccordionSection
            title="Fees"
            subtitle={`Curator: ${(curatorFeeBps / 100).toFixed(2)}%${protocolFeeBps !== null && daoFeeBps !== null ? ` | Total: ${((protocolFeeBps + daoFeeBps + curatorFeeBps) / 100).toFixed(2)}%` : ""}`}
            isOpen={openSections.has("fees")}
            onToggle={() => setOpenSections(s => { const n = new Set(s); n.has("fees") ? n.delete("fees") : n.add("fees"); return n; })}
            isValid={isFeesValid}
          >
            {/* Protocol fees info */}
            <div className="rounded-lg border border-[#3C323A] bg-[#252525]/60 p-4 space-y-3">
              <p className="text-xs font-medium text-[#818181] uppercase tracking-wide">Protocol Fees (set by Dirac)</p>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <p className="text-xs text-[#818181]">Protocol Fee</p>
                  <p className="text-sm font-medium text-white">
                    {protocolFeeBps !== null ? `${(protocolFeeBps / 100).toFixed(2)}%` : "—"}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-[#818181]">DAO Fee</p>
                  <p className="text-sm font-medium text-white">
                    {daoFeeBps !== null ? `${(daoFeeBps / 100).toFixed(2)}%` : "—"}
                  </p>
                </div>
              </div>
            </div>

            <Field label={`Curator Fee: ${(curatorFeeBps / 100).toFixed(2)}% (${curatorFeeBps} bps)`}>
              <input type="range" min={0} max={200} step={1} value={curatorFeeBps}
                onChange={(e) => setCuratorFeeBps(Number(e.target.value))}
                className="w-full accent-orange-500" />
              <div className="flex justify-between text-xs text-[#818181] mt-1">
                <span>0%</span><span>1%</span><span>2% max</span>
              </div>
            </Field>

            <Field label="Curator Fee Recipient">
              <input type="text" value={feeRecipient} onChange={(e) => setFeeRecipient(e.target.value)}
                placeholder="0x..." className={`${inputClass} font-mono text-sm`} />
            </Field>
          </AccordionSection>


          {/* --- Risk Section (non-wstETH fallback) --- */}
          {!hasWstETH && (
            <AccordionSection
              title="Risk Parameters"
              subtitle={`Rebalance ${rebalanceThreshold}%`}
              isOpen={openSections.has("risk")}
              onToggle={() => setOpenSections(s => { const n = new Set(s); n.has("risk") ? n.delete("risk") : n.add("risk"); return n; })}
              isValid={isRiskValid}
            >
              <div>
                <div className="flex items-center justify-between mb-2">
                  <label className="text-xs text-[#818181] uppercase tracking-wider">Rebalancing Threshold</label>
                  <span className="text-lg font-bold font-mono text-white">{rebalanceThreshold}%</span>
                </div>
                <input
                  type="range"
                  min={1}
                  max={45}
                  value={rebalanceThreshold}
                  onChange={(e) => setRebalanceThreshold(Number(e.target.value))}
                  className="w-full accent-orange-500"
                />
                <div className="flex justify-between text-[10px] text-[#818181] mt-1">
                  <span>1%</span><span>10%</span><span>20%</span><span>30%</span><span>45%</span>
                </div>
              </div>
              <div className="rounded-lg border border-amber-500/40 bg-amber-500/10 px-4 py-2.5 text-xs text-amber-300">
                Saved locally for the rebalancing bot. Not stored on-chain.
              </div>
            </AccordionSection>
          )}

          {/* Nav */}
          <div className="flex justify-between pt-2">
            <button onClick={() => setStep("strategy")} className="btn-secondary px-6 py-2.5 rounded-lg font-medium">Back</button>
            <button disabled={!isStep2Valid} onClick={() => setStep("review")}
              className="btn-primary px-6 py-2.5 rounded-lg font-medium disabled:opacity-40 disabled:cursor-not-allowed">
              Review &amp; Deploy
            </button>
          </div>
        </div>
      )}

      {/* ========================== STEP 3: REVIEW ========================= */}
      {step === "review" && (
        <div className="p-6 rounded-xl bg-[#252525]/60 border border-[#3C323A] space-y-6">
          <h2 className="text-lg font-semibold text-white">Review &amp; Deploy</h2>

          <div className="grid grid-cols-2 gap-4 text-sm">
            <SummaryRow label="Strategy"      value={selectedTemplate?.name ?? template} />
            <SummaryRow label="Vault Name"    value={vaultName} />
            <SummaryRow label="Vault Symbol"  value={vaultSymbol} />
            <SummaryRow label="Deposit Token" value={depositTokenLabel} />
            <SummaryRow label="Max Deposit"   value={`${Number(maxDeposit).toLocaleString()} ${depositTokenLabel}`} />
            <SummaryRow label="Curator Fee"   value={`${(curatorFeeBps / 100).toFixed(2)}%`} />
            <SummaryRow label="Fee Recipient" value={`${feeRecipient.slice(0, 6)}...${feeRecipient.slice(-4)}`} full />
            <SummaryRow label="Collateral Assets" value={Array.from(selectedAssets).map(assetLabel).join(", ")} full />
            <SummaryRow label="Swap Module"    value={moduleLabel(selectedSwapAddr)} />
            <SummaryRow label="Lending Module" value={moduleLabel(selectedLendingAddr)} />
            <SummaryRow label="Perps Module"   value={moduleLabel(selectedPerpsAddr)} />
            <SummaryRow label="Rebalancing Threshold" value={`${rebalanceThreshold}%`} />
            <SummaryRow label="Execution Mode" value={execMode.toUpperCase()} />
          </div>

          <div className="rounded-lg border border-blue-500/40 bg-blue-500/10 px-4 py-3 text-sm text-blue-300">
            Your wallet will prompt you to sign each transaction in sequence.
          </div>

          <div className="flex justify-between pt-2">
            <button onClick={() => setStep("configure")} className="btn-secondary px-6 py-2.5 rounded-lg font-medium">Back</button>
            <button disabled={!isConnected || isSigning || !modulesValid} onClick={handleStartDeploying}
              className="btn-primary px-6 py-2.5 rounded-lg font-medium disabled:opacity-40 disabled:cursor-not-allowed">
              {!isConnected ? "Connect Wallet" : "Deploy Vault"}
            </button>
          </div>
        </div>
      )}

      {/* ========================== DEPLOY MODAL ============================ */}
      {showDeployModal && <DeployModal
        txQueue={txQueue}
        deployingTxIdx={deployingTxIdx}
        completedTxs={completedTxs}
        isSigning={isSigning}
        isConfirming={isConfirming}
        writeError={writeError}
        parseError={parseError}
        deployedVault={deployedVault}
        isOrderlyPerps={isOrderlyPerps}
        orderlyInitStatus={orderlyInitStatus}
        orderlyInitError={orderlyInitError}
        selectedAssets={selectedAssets}
        assetLabel={assetLabel}
        chainId={chainId}
        onRetryTx={(idx) => startTx(idx, deployedVault)}
        onResetError={() => { resetWrite(); setParseError(null); }}
        onRetryOrderly={() => {
          if (!deployedVault) return;
          setOrderlyInitStatus("loading");
          setOrderlyInitError(null);
          initializeVault(chainId, deployedVault, 2)
            .then(() => { setOrderlyInitStatus("success"); })
            .catch((err: Error) => {
              setOrderlyInitError(err?.message ?? "Orderly initialization failed");
              setOrderlyInitStatus("failed");
            });
        }}
      />}
    </div>
  );
}

/* ---------------------------------------------------------------------- */
/*                            Helper components                           */
/* ---------------------------------------------------------------------- */

function ProgressBar({ currentStep }: { currentStep: Step }) {
  const currentIdx = STEPS.findIndex((s) => s.key === currentStep);
  return (
    <div className="flex items-center gap-2 overflow-x-auto pb-2">
      {STEPS.map((s, i) => {
        const isCurrent = s.key === currentStep;
        const isDone    = i < currentIdx;
        return (
          <div key={s.key} className="flex items-center gap-2">
            {i > 0 && <div className={`h-px w-6 sm:w-10 ${isDone ? "bg-[#FB5F07]" : "bg-[#3C323A]"}`} />}
            <div className="flex items-center gap-1.5">
              <div className={`h-7 w-7 rounded-full flex items-center justify-center text-xs font-bold shrink-0 ${
                isCurrent ? "bg-[#FB5F07] text-white" : isDone ? "bg-[#FB5F07]/30 text-[#FB5F07]" : "bg-[#252525] text-[#818181]"
              }`}>
                {isDone ? (
                  <svg className="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                  </svg>
                ) : i + 1}
              </div>
              <span className={`text-xs font-medium hidden sm:inline whitespace-nowrap ${
                isCurrent ? "text-[#FB5F07]" : isDone ? "text-[#818181]" : "text-[#818181]/50"
              }`}>
                {s.label}
              </span>
            </div>
          </div>
        );
      })}
    </div>
  );
}

function AccordionSection({
  title, subtitle, isOpen, onToggle, isValid, children,
}: {
  title: string;
  subtitle: string;
  isOpen: boolean;
  onToggle: () => void;
  isValid: boolean;
  children: React.ReactNode;
}) {
  return (
    <div className={`rounded-xl border transition-all ${isOpen ? "border-[#FB5F07]/50 bg-[#252525]/80" : "border-[#3C323A] bg-[#252525]/40"}`}>
      <button onClick={onToggle} className="w-full flex items-center justify-between p-4 text-left">
        <div className="flex items-center gap-3">
          <div className={`h-5 w-5 shrink-0 rounded-full flex items-center justify-center ${isValid ? "bg-emerald-500/20" : "bg-[#3C323A]"}`}>
            {isValid ? (
              <svg className="h-3 w-3 text-emerald-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
              </svg>
            ) : (
              <div className="h-2 w-2 rounded-full bg-[#818181]" />
            )}
          </div>
          <div>
            <p className="text-sm font-medium text-white">{title}</p>
            <p className="text-xs text-[#818181] mt-0.5">{subtitle}</p>
          </div>
        </div>
        <svg className={`h-4 w-4 text-[#818181] transition-transform ${isOpen ? "rotate-180" : ""}`} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M19 9l-7 7-7-7" />
        </svg>
      </button>
      {isOpen && <div className="px-4 pb-4 space-y-4">{children}</div>}
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <label className="block text-[#818181] text-sm mb-1">{label}</label>
      {children}
    </div>
  );
}

function SummaryRow({ label, value, full }: { label: string; value: string; full?: boolean }) {
  return (
    <div className={full ? "col-span-2" : ""}>
      <p className="text-[#818181] text-xs">{label}</p>
      <p className="text-white font-medium">{value}</p>
    </div>
  );
}

function ModuleSelector({
  leg, description, options, value, onChange,
}: {
  leg: string;
  description: string;
  options: { key: string; label: string; address: string }[];
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <div className="p-3 rounded-lg border border-[#3C323A] bg-[#252525]/50 space-y-2">
      <div>
        <p className="text-xs font-medium text-[#818181] uppercase tracking-wide">{leg}</p>
        <p className="text-xs text-[#818181]/70">{description}</p>
      </div>
      {options.length === 0 ? (
        <div className="flex items-center gap-2 text-sm text-[#818181]">
          <div className="h-4 w-4 animate-spin rounded-full border-2 border-[#818181] border-t-transparent" />
          Loading…
        </div>
      ) : (
        <select value={value} onChange={(e) => onChange(e.target.value)}
          className="w-full bg-[#252525] border border-[#3C323A] rounded-lg px-3 py-2 focus:border-[#FB5F07] focus:outline-none text-white text-sm">
          {options.map((opt) => (
            <option key={opt.key} value={opt.address}>{opt.label}</option>
          ))}
        </select>
      )}
    </div>
  );
}

/* ---------------------------------------------------------------------- */
/*                            Deploy Modal                                 */
/* ---------------------------------------------------------------------- */

function DeployModal({
  txQueue, deployingTxIdx, completedTxs, isSigning, isConfirming,
  writeError, parseError, deployedVault, isOrderlyPerps,
  orderlyInitStatus, orderlyInitError, selectedAssets, assetLabel,
  chainId, onRetryTx, onResetError, onRetryOrderly,
}: {
  txQueue: { label: string; description: string }[];
  deployingTxIdx: number;
  completedTxs: Set<number>;
  isSigning: boolean;
  isConfirming: boolean;
  writeError: Error | null;
  parseError: string | null;
  deployedVault: `0x${string}` | null;
  isOrderlyPerps: boolean;
  orderlyInitStatus: null | "loading" | "success" | "failed";
  orderlyInitError: string | null;
  selectedAssets: Set<string>;
  assetLabel: (addr: string) => string;
  chainId: number;
  onRetryTx: (idx: number) => void;
  onResetError: () => void;
  onRetryOrderly: () => void;
}) {
  const allTxsDone = completedTxs.size >= txQueue.length;
  const isComplete = allTxsDone && (!isOrderlyPerps || orderlyInitStatus === "success") && !!deployedVault;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div className="absolute inset-0 bg-black/70 backdrop-blur-sm" />

      {/* Modal */}
      <div className="relative w-full max-w-lg mx-4 rounded-2xl border border-[#3C323A] bg-[#1a1a1a] shadow-2xl overflow-hidden">
        {!isComplete ? (
          /* ── Deploying state ── */
          <div className="p-6 space-y-5">
            <div className="text-center space-y-1">
              <h2 className="text-lg font-semibold text-white">Deploying Your Vault</h2>
              <p className="text-sm text-[#818181]">Sign each transaction in your wallet.</p>
            </div>

            <div className="space-y-2 max-h-[50vh] overflow-y-auto">
              {txQueue.map((tx, i) => {
                const isDone    = completedTxs.has(i);
                const isCurrent = i === deployingTxIdx;
                const isPending = i > deployingTxIdx;

                return (
                  <div key={i} className={`flex items-center gap-4 px-4 py-3 rounded-lg border transition-all ${
                    isDone    ? "border-emerald-500/40 bg-emerald-500/10"
                    : isCurrent ? "border-[#FB5F07]/60 bg-[#FB5F07]/10"
                    : "border-[#3C323A] bg-[#252525]/40 opacity-50"
                  }`}>
                    <div className="shrink-0">
                      {isDone ? (
                        <div className="h-7 w-7 rounded-full bg-emerald-500/20 flex items-center justify-center">
                          <svg className="h-4 w-4 text-emerald-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                            <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                          </svg>
                        </div>
                      ) : isCurrent ? (
                        <div className="h-7 w-7 rounded-full border-2 border-[#FB5F07] border-t-transparent animate-spin" />
                      ) : (
                        <div className="h-7 w-7 rounded-full bg-[#252525] flex items-center justify-center text-xs font-bold text-[#818181]">
                          {i + 1}
                        </div>
                      )}
                    </div>
                    <div className="flex-1">
                      <p className={`text-sm font-medium ${isDone ? "text-emerald-300" : isCurrent ? "text-white" : "text-[#818181]"}`}>
                        {tx.label}
                      </p>
                      {isCurrent && (
                        <p className="text-xs text-[#FB5F07] mt-0.5">
                          {isSigning ? "Waiting for wallet signature…" : isConfirming ? "Confirming on-chain…" : "Starting…"}
                        </p>
                      )}
                      {isDone && <p className="text-xs text-emerald-400 mt-0.5">Confirmed</p>}
                    </div>
                    {isCurrent && !isSigning && !isConfirming && !writeError && (
                      <button onClick={() => onRetryTx(i)}
                        className="btn-primary px-3 py-1.5 rounded-lg text-xs font-medium shrink-0">Sign</button>
                    )}
                    {isPending && <span className="text-xs text-[#818181] shrink-0">Pending</span>}
                  </div>
                );
              })}

              {/* Orderly init step */}
              {isOrderlyPerps && (
                <div className={`flex items-center gap-4 px-4 py-3 rounded-lg border transition-all ${
                  orderlyInitStatus === "success" ? "border-emerald-500/40 bg-emerald-500/10"
                  : orderlyInitStatus === "failed"  ? "border-red-500/40 bg-red-500/10"
                  : orderlyInitStatus === "loading" ? "border-[#FB5F07]/60 bg-[#FB5F07]/10"
                  : "border-[#3C323A] bg-[#252525]/40 opacity-50"
                }`}>
                  <div className="shrink-0">
                    {orderlyInitStatus === "success" ? (
                      <div className="h-7 w-7 rounded-full bg-emerald-500/20 flex items-center justify-center">
                        <svg className="h-4 w-4 text-emerald-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                          <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                        </svg>
                      </div>
                    ) : orderlyInitStatus === "failed" ? (
                      <div className="h-7 w-7 rounded-full bg-red-500/20 flex items-center justify-center">
                        <svg className="h-4 w-4 text-red-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                          <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                        </svg>
                      </div>
                    ) : orderlyInitStatus === "loading" ? (
                      <div className="h-7 w-7 rounded-full border-2 border-[#FB5F07] border-t-transparent animate-spin" />
                    ) : (
                      <div className="h-7 w-7 rounded-full bg-[#252525] flex items-center justify-center text-xs font-bold text-[#818181]">
                        {txQueue.length + 1}
                      </div>
                    )}
                  </div>
                  <div className="flex-1">
                    <p className={`text-sm font-medium ${
                      orderlyInitStatus === "success" ? "text-emerald-300"
                      : orderlyInitStatus === "failed"  ? "text-red-300"
                      : orderlyInitStatus === "loading" ? "text-white"
                      : "text-[#818181]"
                    }`}>Initialize Vault on Orderly</p>
                    {orderlyInitStatus === "loading" && <p className="text-xs text-[#FB5F07] mt-0.5">Registering vault with Orderly API…</p>}
                    {orderlyInitStatus === "success" && <p className="text-xs text-emerald-400 mt-0.5">Confirmed</p>}
                    {orderlyInitStatus === "failed" && orderlyInitError && <p className="text-xs text-red-400 mt-0.5 break-all">{orderlyInitError}</p>}
                  </div>
                  {orderlyInitStatus === "failed" && (
                    <button onClick={onRetryOrderly}
                      className="btn-primary px-3 py-1.5 rounded-lg text-xs font-medium shrink-0">Retry</button>
                  )}
                  {!orderlyInitStatus && <span className="text-xs text-[#818181] shrink-0">Pending</span>}
                </div>
              )}
            </div>

            {(writeError || parseError) && (
              <div className="p-4 rounded-lg bg-red-900/30 border border-red-700 text-red-300 text-sm space-y-2">
                <p className="break-all">{writeError?.message?.slice(0, 300) ?? parseError}</p>
                <button onClick={onResetError}
                  className="text-[#FB5F07] hover:text-orange-300 underline text-xs">
                  Retry transaction {deployingTxIdx + 1}
                </button>
              </div>
            )}

            <p className="text-center text-xs text-[#818181]">
              {completedTxs.size} of {txQueue.length} transactions confirmed
            </p>
          </div>
        ) : (
          /* ── Success state ── */
          <div className="p-8 flex flex-col items-center justify-center gap-5">
            <div className="flex items-center justify-center h-16 w-16 rounded-full bg-green-900/40 border-2 border-green-500">
              <svg className="h-8 w-8 text-green-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
              </svg>
            </div>

            <h2 className="text-xl font-bold text-white">Vault Deployed</h2>
            <p className="text-[#818181] text-sm font-mono break-all max-w-md text-center">{deployedVault}</p>

            <div className="flex flex-wrap gap-2 justify-center">
              {Array.from(selectedAssets).map((addr) => (
                <span key={addr} className="inline-block rounded-full border border-emerald-500/40 bg-emerald-500/20 px-3 py-1 text-xs font-medium text-emerald-400">
                  {assetLabel(addr)} whitelisted
                </span>
              ))}
              <span className="inline-block rounded-full border border-[#FB5F07]/40 bg-[#FB5F07]/20 px-3 py-1 text-xs font-medium text-[#FB5F07]">
                Modules configured
              </span>
              {isOrderlyPerps && (
                <span className="inline-block rounded-full border border-blue-500/40 bg-blue-500/20 px-3 py-1 text-xs font-medium text-blue-400">
                  Orderly initialized
                </span>
              )}
            </div>

            <div className="flex gap-4 pt-2">
              <Link href={`/manage/${deployedVault}`} className="btn-primary px-6 py-2.5 rounded-lg font-medium text-center">Manage Vault</Link>
              <Link href={`/vault/${deployedVault}`} className="btn-secondary px-6 py-2.5 rounded-lg font-medium text-center">View Vault</Link>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
