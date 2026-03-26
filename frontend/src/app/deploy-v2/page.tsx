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
import nextDynamic from "next/dynamic";

const BacktestEquityChart = nextDynamic(() => import("@/components/BacktestEquityChart"), { ssr: false });

/* -------------------------------------------------------------------------- */
/*                                   Types                                    */
/* -------------------------------------------------------------------------- */

type Step = "strategy" | "configure" | "review";

const STEPS: { key: Step; label: string }[] = [
  { key: "strategy",  label: "Select Strategy" },
  { key: "configure", label: "Configure Vault" },
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
    name: "Lending + Perps Delta Neutral",
    description:
      "Deposit USDC → delta-neutral exposure → capture yield\n\nCuration: Rebalancing · Execution · Funding regime\nYield sources: Staking · Lending · Funding",
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
  { key: "lending.morpho",   label: "Morpho",   hash: keccak256(encodePacked(["string"], ["lending.morpho"])) },
  { key: "lending.dolomite", label: "Dolomite", hash: keccak256(encodePacked(["string"], ["lending.dolomite"])) },
  { key: "lending.aave",     label: "Aave V3",  hash: keccak256(encodePacked(["string"], ["lending.aave"])) },
] as const;

const KNOWN_MODULES_PERPS = [
  { key: "perps.gmx",         label: "GMX",         hash: keccak256(encodePacked(["string"], ["perps.gmx"])) },
  { key: "perps.hyperliquid", label: "Hyperliquid", hash: keccak256(encodePacked(["string"], ["perps.hyperliquid"])) },
  { key: "perps.d8x",         label: "D8X",         hash: keccak256(encodePacked(["string"], ["perps.d8x"])) },
  { key: "perps.orderly",     label: "Orderly",     hash: keccak256(encodePacked(["string"], ["perps.orderly"])) },
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
  const [performanceFee, setPerformanceFee] = useState("");
  const [managementFee, setManagementFee]   = useState("");
  const [feeRecipient, setFeeRecipient]     = useState("");
  const curatorFeeBps = Math.round((Number(performanceFee) || 0) * 100);
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
  const [showSubmitModal, setShowSubmitModal] = useState(false);

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
    performanceFee.length > 0 &&
    managementFee.length > 0 &&
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
        <h1 className="text-2xl font-bold text-white">Configure Vault</h1>
      </div>

      <ProgressBar currentStep={step} />

      {/* ========================== STEP 1: STRATEGY ======================== */}
      {step === "strategy" && (
        <div className="space-y-5">
          <div />

          <div className="grid grid-cols-1 gap-4">
            {TEMPLATES.map((t) => {
              const isSelected = template === t.id;
              return (
                <button
                  key={t.id}
                  onClick={() => setTemplate(template === t.id ? "" : t.id)}
                  className={`text-left p-6 rounded-xl border-2 transition-all ${
                    isSelected ? "border-[#FB5F07]" : "border-[#3C323A] hover:border-[#818181]"
                  }`}
                  style={{ background: isSelected
                    ? "linear-gradient(135deg, #2d1a0e 0%, #3a1f10 30%, #4a2510 60%, #5a2a12 100%)"
                    : "rgba(30, 20, 30, 0.7)"
                  }}
                >
                  <div className="flex items-start justify-between">
                    <div className="space-y-2">
                      <h3 className="text-lg font-semibold text-white">{t.name}</h3>
                      <p className="text-sm text-[#818181] leading-relaxed whitespace-pre-line">{t.description}</p>
                    </div>
                    <div className={`mt-1 h-5 w-5 shrink-0 rounded-full border-2 flex items-center justify-center ${isSelected ? "border-[#FB5F07]" : "border-[#3C323A]"}`}>
                      {isSelected && <div className="h-2.5 w-2.5 rounded-full bg-[#FB5F07]" />}
                    </div>
                  </div>
                </button>
              );
            })}
          </div>

          {/* Strategy Under Review cards */}
          {[
            { name: "RWA Strategy" },
            { name: "Options Strategy" },
          ].map((s) => (
            <div key={s.name} className="relative rounded-xl overflow-hidden border-l-4 border-[#FB5F07]/40" style={{ background: "rgba(60, 30, 50, 0.35)" }}>
              <div className="absolute inset-0" />
              <div className="relative p-5">
                <h3 className="text-lg font-bold text-white">{s.name}</h3>
                <p className="text-xs font-semibold text-[#818181] mt-1">Under Review</p>
                <p className="text-sm text-[#FB5F07] mt-1.5">Submitted by strategists</p>
                <p className="text-sm text-[#FB5F07]">Evaluated by Dirac quants</p>
              </div>
            </div>
          ))}

          {/* More strategies + Submit */}
          <div className="pt-2">
            <h3 className="text-lg font-bold text-white mb-3">More strategies coming</h3>
            <button onClick={() => setShowSubmitModal(true)} className="btn-primary px-5 py-2.5 rounded-lg font-medium">
              Submit a Strategy
            </button>
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
                      !enabled ? "border-[#3C323A] bg-[#252525]/30 opacity-40 cursor-default"
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
                <button key={label} disabled className="flex items-center gap-2 px-3 py-2 rounded-lg border border-[#3C323A] bg-[#252525]/30 opacity-40 cursor-default">
                  <div className="h-3.5 w-3.5 shrink-0 rounded border-2 border-[#3C323A]" />
                  <span className="text-sm font-medium text-[#818181]">{label}</span>
                </button>
              ))}
            </div>
          </AccordionSection>

          {/* --- Lending Protocol (pill buttons) --- */}
          <AccordionSection
            title="Lending Protocol"
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

          {/* --- Perps Protocol (pill buttons) --- */}
          <AccordionSection
            title="Perps Protocol"
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
              {["SNX", "GNS"].map((label) => (
                <button key={label} disabled className="flex items-center gap-2 px-3 py-2 rounded-lg border border-[#3C323A] bg-[#252525]/30 opacity-40 cursor-default">
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
                <style>{`
                  input[type=range]{-webkit-appearance:none;width:100%;height:8px;border-radius:4px;outline:none;background:transparent;}
                  input[type=range]::-webkit-slider-runnable-track{height:8px;border-radius:4px;}
                  input[type=range]::-moz-range-track{height:8px;border-radius:4px;border:none;}
                  input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:20px;height:20px;border-radius:50%;background:radial-gradient(circle at 40% 35%,#ffffff,#e0e0e0);border:2.5px solid rgba(255,255,255,0.9);cursor:pointer;box-shadow:0 0 0 4px rgba(255,255,255,0.15),0 2px 10px rgba(0,0,0,0.6);margin-top:-6px;}
                  input[type=range]::-moz-range-thumb{width:20px;height:20px;border-radius:50%;background:radial-gradient(circle at 40% 35%,#ffffff,#e0e0e0);border:2.5px solid rgba(255,255,255,0.9);cursor:pointer;box-shadow:0 0 0 4px rgba(255,255,255,0.15),0 2px 10px rgba(0,0,0,0.6);}
                  .rb-slider::-webkit-slider-runnable-track{background:linear-gradient(90deg,#ff8800 0%,#ffaa33 25%,#ffcc66 50%,#ffe0a0 75%,#f0f0d0 90%,#88dd66 100%);}
                  .rb-slider::-moz-range-track{background:linear-gradient(90deg,#ff8800 0%,#ffaa33 25%,#ffcc66 50%,#ffe0a0 75%,#f0f0d0 90%,#88dd66 100%);}
                  .fr-slider::-webkit-slider-runnable-track{background:linear-gradient(90deg,#ff8800 0%,#ffaa33 25%,#ffcc66 50%,#ffe0a0 75%,#f0f0d0 90%,#88dd66 100%);}
                  .fr-slider::-moz-range-track{background:linear-gradient(90deg,#ff8800 0%,#ffaa33 25%,#ffcc66 50%,#ffe0a0 75%,#f0f0d0 90%,#88dd66 100%);}
                `}</style>

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
                    className="rb-slider"
                  />
                  <div className="flex justify-between text-[10px] text-[#818181] mt-1 px-0.5">
                    <span>1%</span><span>10%</span><span>20%</span><span>30%</span><span>45%</span>
                  </div>
                </div>

                {/* Funding regime filter — below rebalancing slider */}
                <div className="rounded-lg border border-[#3C323A] bg-[#252525] p-3">
                  <div className="flex items-center justify-between mb-2">
                    <div className="flex items-center gap-2">
                      <span className="text-xs text-[#818181] uppercase tracking-wider">Funding Filter</span>
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
                    </div>
                    {fundingFilterOn && (
                      <span className="text-sm text-amber-400 font-mono font-bold">
                        {Math.round((fundingSlider / 100) * (-0.00033445) * 100000) / 10} bps
                      </span>
                    )}
                  </div>
                  {fundingFilterOn && (
                    <input
                      type="range"
                      min={0}
                      max={100}
                      value={fundingSlider}
                      onChange={(e) => setFundingSlider(Number(e.target.value))}
                      className="fr-slider"
                    />
                  )}
                </div>

                {/* Backtest chart + stats */}
                <BacktestEquityChart threshold={rebalanceThreshold} execMode={execMode} fundingFilterOn={fundingFilterOn} fundingSlider={fundingSlider} />

                {/* CEX / DEX toggle below chart */}
                <div className="flex items-center gap-4 flex-wrap">
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
                </div>

                <div className="rounded-lg border border-amber-500/40 bg-amber-500/10 px-4 py-2.5 text-xs text-amber-300">
                  Historical Simulation. Past performance is not indicative of future results.
                </div>
              </div>
            </AccordionSection>
          )}

          {/* --- Vault Info Section --- */}
          <AccordionSection
            title="Vault Parameters"
            subtitle={vaultName ? `${vaultName} (${vaultSymbol})` : ""}
            isOpen={openSections.has("vault")}
            onToggle={() => setOpenSections(s => { const n = new Set(s); n.has("vault") ? n.delete("vault") : n.add("vault"); return n; })}
            isValid={isConfigValid}
          >
            <Field label="Vault Name">
              <input type="text" value={vaultName} onChange={(e) => setVaultName(e.target.value)}
                placeholder="e.g. Delta Neutral ETH" className={inputClass} />
            </Field>
            <Field label="Vault Symbol">
              <input type="text" value={vaultSymbol} onChange={(e) => setVaultSymbol(e.target.value)}
                placeholder="e.g. dnETH" className={inputClass} />
            </Field>
            <Field label="Deposit Asset">
              <select value={depositToken} onChange={(e) => setDepositToken(e.target.value as `0x${string}`)} className={inputClass}>
                {DEPOSIT_TOKENS.map((t) => (
                  <option key={t.address} value={t.address}>{t.label} ({t.address.slice(0, 6)}...{t.address.slice(-4)})</option>
                ))}
              </select>
            </Field>
            <Field label="Capacity">
              <input type="number" min="0" value={maxDeposit} onChange={(e) => setMaxDeposit(e.target.value)}
                placeholder="1000000" className={inputClass} />
            </Field>
          </AccordionSection>

          {/* --- Fees Section --- */}
          <AccordionSection
            title="Fees"
            subtitle={performanceFee || managementFee ? `Perf: ${performanceFee || 0}% · Mgmt: ${managementFee || 0}%` : ""}
            isOpen={openSections.has("fees")}
            onToggle={() => setOpenSections(s => { const n = new Set(s); n.has("fees") ? n.delete("fees") : n.add("fees"); return n; })}
            isValid={isFeesValid}
          >
            <Field label="Performance Fee">
              <input type="text" value={performanceFee} onChange={(e) => setPerformanceFee(e.target.value)}
                placeholder="e.g. 10%" className={inputClass} />
            </Field>

            <Field label="Management Fee">
              <input type="text" value={managementFee} onChange={(e) => setManagementFee(e.target.value)}
                placeholder="e.g. 0.5%" className={inputClass} />
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
                  className="rb-slider"
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
        <div className="space-y-6">
          <h2 className="text-lg font-semibold text-white">Review &amp; Deploy</h2>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
            {/* Strategy */}
            <div className="rounded-xl border border-[#FB5F07]/40 bg-[#252525]/60 p-4">
              <p className="text-xs text-[#818181] uppercase tracking-wider mb-2">Strategy</p>
              <p className="text-sm font-semibold text-white">{selectedTemplate?.name ?? template}</p>
            </div>

            {/* Network */}
            <div className="rounded-xl border border-[#FB5F07]/40 bg-[#252525]/60 p-4">
              <p className="text-xs text-[#818181] uppercase tracking-wider mb-2">Network</p>
              <p className="text-sm font-semibold text-white">{addresses.name}</p>
            </div>

            {/* Vault */}
            <div className="rounded-xl border border-[#FB5F07]/40 bg-[#252525]/60 p-4 space-y-1">
              <p className="text-xs text-[#818181] uppercase tracking-wider mb-2">Vault</p>
              <p className="text-xs text-[#818181]">Name: <span className="text-white">{vaultName}</span></p>
              <p className="text-xs text-[#818181]">Symbol: <span className="text-white">{vaultSymbol}</span></p>
              <p className="text-xs text-[#818181]">Deposit Asset: <span className="text-white">{depositTokenLabel}</span></p>
              <p className="text-xs text-[#818181]">Capacity: <span className="text-white">{Number(maxDeposit).toLocaleString()}</span></p>
            </div>

            {/* Execution */}
            <div className="rounded-xl border border-[#FB5F07]/40 bg-[#252525]/60 p-4 space-y-1">
              <p className="text-xs text-[#818181] uppercase tracking-wider mb-2">Execution</p>
              <p className="text-xs text-[#818181]">Lending: <span className="text-white">{moduleLabel(selectedLendingAddr)}</span></p>
              <p className="text-xs text-[#818181]">Perps: <span className="text-white">{moduleLabel(selectedPerpsAddr)}</span></p>
              <p className="text-xs text-[#818181]">Mode: <span className="text-white">{execMode.toUpperCase()}</span></p>
            </div>

            {/* Risk Parameters */}
            <div className="rounded-xl border border-[#FB5F07]/40 bg-[#252525]/60 p-4 space-y-1">
              <p className="text-xs text-[#818181] uppercase tracking-wider mb-2">Risk Parameters</p>
              <p className="text-xs text-[#818181]">Rebalancing Threshold: <span className="text-white">{rebalanceThreshold}%</span></p>
              {fundingFilterOn && (
                <p className="text-xs text-[#818181]">Funding Filter: <span className="text-white">{Math.round((fundingSlider / 100) * (-0.00033445) * 100000) / 10} bps</span></p>
              )}
            </div>

            {/* Fees */}
            <div className="rounded-xl border border-[#FB5F07]/40 bg-[#252525]/60 p-4 space-y-1">
              <p className="text-xs text-[#818181] uppercase tracking-wider mb-2">Fees</p>
              <p className="text-xs text-[#818181]">Performance fee: <span className="text-white">{performanceFee}%</span></p>
              <p className="text-xs text-[#818181]">Management fee: <span className="text-white">{managementFee}%</span></p>
              <p className="text-xs text-[#818181]">Recipient: <span className="text-white font-mono">{feeRecipient.slice(0, 6)}...{feeRecipient.slice(-4)}</span></p>
            </div>
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

      {/* ========================== INLINE DEPLOY STATUS ===================== */}
      {(isSigning || isConfirming || deployedVault) && (
        <div className="mt-4 rounded-lg border border-[#3C323A] bg-[#252525] p-4 space-y-2">
          {isSigning && <p className="text-sm text-amber-300">Waiting for wallet signature...</p>}
          {isConfirming && <p className="text-sm text-blue-300">Confirming on-chain...</p>}
          {writeError && <p className="text-sm text-red-400">{(writeError as Error).message}</p>}
          {parseError && <p className="text-sm text-red-400">{parseError}</p>}
          {deployedVault && (
            <p className="text-sm text-emerald-400">Vault deployed: <span className="font-mono">{deployedVault}</span></p>
          )}
        </div>
      )}

      {/* ========================== SUBMIT STRATEGY MODAL ================= */}
      {showSubmitModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm" onClick={() => setShowSubmitModal(false)}>
          <div className="rounded-xl border border-[#3C323A] bg-[#171717] p-6 max-w-md w-full mx-4 space-y-4" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-xl font-bold text-white">Submit a Strategy</h2>
            <p className="text-sm text-[#818181]">
              Submit your strategy via a ticket on Dirac Discord.
            </p>
            <div className="text-sm text-white space-y-1">
              <p className="text-[#818181] mb-2">Include:</p>
              <ul className="list-disc list-inside space-y-1 text-[#818181]">
                <li>Description</li>
                <li>Yield sources</li>
                <li>Risks</li>
                <li>Backtest</li>
              </ul>
            </div>
            <p className="text-sm text-[#FB5F07] font-medium">Reviewed by Dirac</p>
            <div className="flex justify-end gap-3 pt-2">
              <button onClick={() => setShowSubmitModal(false)} className="btn-secondary px-4 py-2 rounded-lg text-sm">Close</button>
              <a href="https://discord.com/invite/xQVwD9Xad9" target="_blank" rel="noopener noreferrer" className="btn-primary px-4 py-2 rounded-lg text-sm font-medium inline-block text-center">
                Go to Discord
              </a>
            </div>
          </div>
        </div>
      )}
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
