"use client";

import { useState } from "react";
import Link from "next/link";
import { useAccount, useReadContracts } from "wagmi";
import { formatUnits, keccak256, toHex } from "viem";
import { useAddresses, factoryAbi, vaultAbi } from "@/lib/contracts";
import { useBrowsingChain } from "@/lib/ChainContext";

/* -------------------------------------------------------------------------- */
/*                                 Constants                                  */
/* -------------------------------------------------------------------------- */

const MAX_SCAN = 30;

const KNOWN_TEMPLATES: Record<string, string> = {
  [keccak256(toHex("delta-neutral-v1"))]: "Delta Neutral v1",
};

function templateLabel(hash: `0x${string}`): string {
  return KNOWN_TEMPLATES[hash] ?? `${hash.slice(0, 10)}…`;
}

const CYCLE_STATUS = ["Closed", "Deposits Open", "Trading", "Withdrawals Open"];

const CYCLE_COLORS: Record<number, string> = {
  0: "bg-white/5 text-[#818181] border-white/10",
  1: "bg-emerald-500/15 text-emerald-400 border-emerald-500/30",
  2: "bg-amber-500/15 text-amber-400 border-amber-500/30",
  3: "bg-[#FB5F07]/15 text-[#FB5F07] border-[#FB5F07]/30",
};

/* -------------------------------------------------------------------------- */
/*                                   Types                                    */
/* -------------------------------------------------------------------------- */

interface VaultCardData {
  address: `0x${string}`;
  name?: string;
  symbol?: string;
  totalAssets?: bigint;
  cycleStatus?: number;
  creator?: `0x${string}`;
  templateId?: `0x${string}`;
  deployedAt?: bigint;
}

/* -------------------------------------------------------------------------- */
/*                               Vault Card                                   */
/* -------------------------------------------------------------------------- */

function VaultCard({ data }: { data: VaultCardData }) {
  const addresses_cfg = useAddresses();
  const {
    address,
    name,
    symbol,
    totalAssets,
    cycleStatus = 0,
    creator,
    templateId,
    deployedAt,
  } = data;

  const tvl =
    totalAssets !== undefined ? Number(formatUnits(totalAssets, 6)) : null;

  const deployDate = deployedAt
    ? new Date(Number(deployedAt) * 1000).toLocaleDateString(undefined, {
        year: "numeric",
        month: "short",
        day: "numeric",
      })
    : "—";

  return (
    <div
      className="rounded-xl p-5 transition-all hover:border-[#FB5F07]/50 bg-no-repeat"
      style={{
        backgroundImage: "url('/images/backgrounds/bg-vaults-card.png')",
        backgroundSize: "cover",
        backgroundPosition: "center",
        border: "1px solid #3C323A",
      }}
    >
      {/* Header */}
      <div className="flex items-start justify-between mb-3">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <h3 className="text-base font-semibold text-white truncate">
              {name ?? "Loading…"}
            </h3>
            {symbol && (
              <span className="text-xs font-mono text-[#818181] shrink-0">
                {symbol}
              </span>
            )}
          </div>
          <p className="font-mono text-xs text-[#818181] mt-0.5 truncate">
            {address}
          </p>
        </div>
        <span
          className={`ml-3 inline-block shrink-0 rounded-full border px-2.5 py-0.5 text-xs font-medium ${
            CYCLE_COLORS[cycleStatus] ?? CYCLE_COLORS[0]
          }`}
        >
          {CYCLE_STATUS[cycleStatus] ?? "Unknown"}
        </span>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-4 gap-2 mt-3 mb-4">
        <div className="rounded-lg px-3 py-2" style={{ background: "#252525" }}>
          <p className="text-xs" style={{ color: "#818181" }}>TVL</p>
          <p className="text-sm font-semibold text-white">
            {tvl !== null
              ? `$${tvl.toLocaleString(undefined, {
                  minimumFractionDigits: 2,
                  maximumFractionDigits: 2,
                })}`
              : "—"}
          </p>
        </div>
        <div className="rounded-lg px-3 py-2" style={{ background: "#252525" }}>
          <p className="text-xs" style={{ color: "#818181" }}>Template</p>
          <p className="text-sm font-semibold text-white truncate">
            {templateId ? templateLabel(templateId) : "—"}
          </p>
        </div>
        <div className="rounded-lg px-3 py-2" style={{ background: "#252525" }}>
          <p className="text-xs" style={{ color: "#818181" }}>Deployer</p>
          <p className="text-sm font-mono text-white truncate">
            {creator
              ? `${creator.slice(0, 6)}…${creator.slice(-4)}`
              : "—"}
          </p>
        </div>
        <div className="rounded-lg px-3 py-2" style={{ background: "#252525" }}>
          <p className="text-xs" style={{ color: "#818181" }}>Deployed</p>
          <p className="text-sm font-semibold text-white">{deployDate}</p>
        </div>
      </div>

      {/* Actions */}
      <div className="flex gap-2">
        <Link
          href={`/vault/${address}`}
          className="btn-primary flex-1 px-3 py-2 text-center text-sm"
        >
          Deposit
        </Link>
        <Link
          href={`/manage/${address}`}
          className="btn-secondary flex-1 px-3 py-2 text-center text-sm"
        >
          Manage
        </Link>
        <a
          href={`${addresses_cfg.explorer}/address/${address}`}
          target="_blank"
          rel="noopener noreferrer"
          className="rounded-lg px-3 py-2 text-sm font-medium transition-colors hover:bg-white/5"
          style={{ background: "#252525", color: "#818181" }}
        >
          ↗
        </a>
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/*                               Helpers                                      */
/* -------------------------------------------------------------------------- */

function extractAddresses(results: readonly { status: string; result?: unknown }[] | undefined): `0x${string}`[] {
  if (!results) return [];
  const addrs: `0x${string}`[] = [];
  for (const r of results) {
    if (
      r?.status === "success" &&
      r.result &&
      r.result !== "0x0000000000000000000000000000000000000000"
    ) {
      addrs.push(r.result as `0x${string}`);
    } else {
      break;
    }
  }
  return addrs;
}

function buildMetaContracts(addresses: `0x${string}`[], factoryAddress: `0x${string}`, chainId: number) {
  const names = addresses.map((addr) => ({
    address: addr,
    abi: vaultAbi,
    functionName: "name" as const,
    chainId,
  }));
  const symbols = addresses.map((addr) => ({
    address: addr,
    abi: vaultAbi,
    functionName: "symbol" as const,
    chainId,
  }));
  const assets = addresses.map((addr) => ({
    address: addr,
    abi: vaultAbi,
    functionName: "totalAssets" as const,
    chainId,
  }));
  const cycles = addresses.map((addr) => ({
    address: addr,
    abi: vaultAbi,
    functionName: "getCurrentCycle" as const,
    chainId,
  }));
  const infos = addresses.map((addr) => ({
    address: factoryAddress,
    abi: factoryAbi,
    functionName: "vaultInfo" as const,
    args: [addr] as const,
    chainId,
  }));
  return { names, symbols, assets, cycles, infos };
}

function buildCards(
  addresses: `0x${string}`[],
  names: readonly { status: string; result?: unknown }[] | undefined,
  symbols: readonly { status: string; result?: unknown }[] | undefined,
  assets: readonly { status: string; result?: unknown }[] | undefined,
  cycles: readonly { status: string; result?: unknown }[] | undefined,
  infos: readonly { status: string; result?: unknown }[] | undefined,
): VaultCardData[] {
  return addresses.map((addr, i) => {
    const cycleData =
      cycles?.[i]?.status === "success"
        ? (cycles[i].result as { status: number })
        : undefined;
    // wagmi may return vaultInfo as a named object or positional array — handle both
    const rawInfo = infos?.[i]?.status === "success" ? (infos[i].result as Record<string, unknown> | unknown[]) : undefined;
    const getField = (obj: Record<string, unknown> | unknown[] | undefined, name: string, idx: number) =>
      obj ? ((obj as Record<string, unknown>)[name] ?? (obj as unknown[])[idx]) : undefined;

    return {
      address: addr,
      name:
        names?.[i]?.status === "success"
          ? (names[i].result as string)
          : undefined,
      symbol:
        symbols?.[i]?.status === "success"
          ? (symbols[i].result as string)
          : undefined,
      totalAssets:
        assets?.[i]?.status === "success"
          ? (assets[i].result as bigint)
          : undefined,
      cycleStatus: cycleData ? Number(cycleData.status) : 0,
      creator: getField(rawInfo, "creator", 1) as `0x${string}` | undefined,
      templateId: getField(rawInfo, "templateId", 2) as `0x${string}` | undefined,
      deployedAt: getField(rawInfo, "deployedAt", 3) as bigint | undefined,
    };
  });
}

function LoadingSpinner() {
  return (
    <div className="flex items-center justify-center py-16">
      <div className="h-8 w-8 animate-spin rounded-full border-2 border-orange-400 border-t-transparent" />
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/*                              All Vaults Tab                                */
/* -------------------------------------------------------------------------- */

function AllVaultsTab() {
  const addresses_cfg = useAddresses();
  const { browsingChainId } = useBrowsingChain();
  const enumContracts = Array.from({ length: MAX_SCAN }, (_, i) => ({
    address: addresses_cfg.factory,
    abi: factoryAbi,
    functionName: "allVaults" as const,
    args: [BigInt(i)] as const,
    chainId: browsingChainId,
  }));

  const { data: enumResults, isLoading: enumLoading } = useReadContracts({
    contracts: enumContracts,
  });

  const vaultAddrs = extractAddresses(enumResults);
  const enabled = vaultAddrs.length > 0;
  const { names, symbols, assets, cycles, infos } = buildMetaContracts(vaultAddrs, addresses_cfg.factory, browsingChainId);

  const { data: nameData } = useReadContracts({ contracts: names, query: { enabled } });
  const { data: symbolData } = useReadContracts({ contracts: symbols, query: { enabled } });
  const { data: assetData } = useReadContracts({ contracts: assets, query: { enabled } });
  const { data: cycleData } = useReadContracts({ contracts: cycles, query: { enabled } });
  const { data: infoData } = useReadContracts({ contracts: infos, query: { enabled } });

  if (enumLoading) return <LoadingSpinner />;

  if (vaultAddrs.length === 0) {
    return (
      <div className="text-center py-16 text-sm" style={{ color: "#818181" }}>
        No vaults deployed yet.
      </div>
    );
  }

  const cards = buildCards(vaultAddrs, nameData, symbolData, assetData, cycleData, infoData);

  return (
    <div className="space-y-4">
      {cards.map((card) => (
        <VaultCard key={card.address} data={card} />
      ))}
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/*                              My Vaults Tab                                 */
/* -------------------------------------------------------------------------- */

function MyVaultsTab() {
  const { address: userAddress, isConnected } = useAccount();
  const addresses_cfg = useAddresses();
  const { browsingChainId } = useBrowsingChain();

  const enumContracts =
    isConnected && userAddress
      ? Array.from({ length: MAX_SCAN }, (_, i) => ({
          address: addresses_cfg.factory,
          abi: factoryAbi,
          functionName: "vaultsByCurator" as const,
          args: [userAddress!, BigInt(i)] as const,
          chainId: browsingChainId,
        }))
      : [];

  const { data: enumResults, isLoading: enumLoading } = useReadContracts({
    contracts: enumContracts,
    query: { enabled: isConnected && !!userAddress },
  });

  const vaultAddrs = extractAddresses(enumResults);
  const enabled = vaultAddrs.length > 0;
  const { names, symbols, assets, cycles, infos } = buildMetaContracts(vaultAddrs, addresses_cfg.factory, browsingChainId);

  const { data: nameData } = useReadContracts({ contracts: names, query: { enabled } });
  const { data: symbolData } = useReadContracts({ contracts: symbols, query: { enabled } });
  const { data: assetData } = useReadContracts({ contracts: assets, query: { enabled } });
  const { data: cycleData } = useReadContracts({ contracts: cycles, query: { enabled } });
  const { data: infoData } = useReadContracts({ contracts: infos, query: { enabled } });

  if (!isConnected) {
    return (
      <div className="rounded-lg border border-amber-500/40 bg-amber-500/10 px-4 py-3 text-sm text-amber-400">
        Connect your wallet to see your vaults.
      </div>
    );
  }

  if (enumLoading) return <LoadingSpinner />;

  if (vaultAddrs.length === 0) {
    return (
      <div className="p-8 rounded-xl flex flex-col items-center gap-4" style={{ background: "#171717", border: "1px solid #3C323A" }}>
        <p className="text-sm" style={{ color: "#818181" }}>
          You haven&apos;t deployed any vaults yet.
        </p>
        <Link
          href="/deploy"
          className="btn-primary px-6 py-2.5"
        >
          Deploy a Vault
        </Link>
      </div>
    );
  }

  const cards = buildCards(vaultAddrs, nameData, symbolData, assetData, cycleData, infoData);

  return (
    <div className="space-y-4">
      <div className="space-y-4">
        {cards.map((card) => (
          <VaultCard key={card.address} data={card} />
        ))}
      </div>
      <div className="flex justify-end">
        <Link
          href="/deploy"
          className="btn-primary px-5 py-2 text-sm"
        >
          + Deploy New Vault
        </Link>
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/*                               Main Page                                    */
/* -------------------------------------------------------------------------- */

export default function VaultsRegistryPage() {
  const [tab, setTab] = useState<"all" | "mine">("all");

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-end justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">Vaults Registry</h1>
          <p className="mt-1" style={{ color: "#818181" }}>
            All delta-neutral vaults deployed on Dirac Finance.
          </p>
        </div>
        <Link
          href="/deploy"
          className="btn-primary px-5 py-2.5 text-sm"
        >
          Deploy Vault
        </Link>
      </div>

      {/* Tabs */}
      <div className="flex gap-1 border-b" style={{ borderColor: "#3C323A" }}>
        {(["all", "mine"] as const).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`px-4 py-2.5 text-sm font-semibold transition-colors border-b-2 -mb-px ${
              tab === t
                ? "border-[#FB5F07] text-white"
                : "border-transparent hover:text-white"
            }`}
            style={tab !== t ? { color: "#818181" } : undefined}
          >
            {t === "all" ? "All Vaults" : "My Vaults"}
          </button>
        ))}
      </div>

      {/* Tab content */}
      {tab === "all" ? <AllVaultsTab /> : <MyVaultsTab />}
    </div>
  );
}
