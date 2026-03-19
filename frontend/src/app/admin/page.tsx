"use client";

import { useState, useEffect } from "react";
import {
  useAccount,
  useChainId,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { useAddresses, factoryAbi } from "@/lib/contracts";
import { keccak256, encodePacked, encodeAbiParameters, parseAbiParameters, toHex } from "viem";
import { healthCheck, initializeVault, confirmDelegateSigner } from "@/lib/api";

/* -------------------------------------------------------------------------- */
/*                                 Constants                                  */
/* -------------------------------------------------------------------------- */

const TABS = ["Fees", "Tokens", "Modules", "Roles", "Emergency", "Orderly"] as const;
type Tab = (typeof TABS)[number];

const KNOWN_MODULE_TYPES = [
  { label: "SWAP", key: "SWAP" },
  { label: "LENDING", key: "LENDING" },
  { label: "PERPS", key: "PERPS" },
];

/* -------------------------------------------------------------------------- */
/*                                  Helpers                                   */
/* -------------------------------------------------------------------------- */

function shortenAddress(addr: string): string {
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

function Spinner() {
  return (
    <div className="h-5 w-5 animate-spin rounded-full border-2 border-orange-400 border-t-transparent" />
  );
}

function Field({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div>
      <label className="block text-slate-300 text-sm mb-1">{label}</label>
      {children}
    </div>
  );
}

const inputClass =
  "w-full bg-slate-800 border border-slate-600 rounded-lg px-4 py-2.5 text-sm focus:border-orange-500 focus:outline-none text-white placeholder:text-slate-500 font-mono";

const btnPrimary =
  "px-5 py-2.5 rounded-lg font-medium bg-orange-600 hover:bg-orange-500 text-white disabled:opacity-40 disabled:cursor-not-allowed transition-colors text-sm";

const btnDanger =
  "px-5 py-2.5 rounded-lg font-medium bg-red-600 hover:bg-red-500 text-white disabled:opacity-40 disabled:cursor-not-allowed transition-colors text-sm";

const panelClass =
  "rounded-xl border border-slate-700 bg-slate-900/60 p-6 space-y-5";

/* -------------------------------------------------------------------------- */
/*                                 Component                                  */
/* -------------------------------------------------------------------------- */

export default function AdminPage() {
  const { address: userAddress, isConnected } = useAccount();
  const chainId = useChainId();
  const addresses = useAddresses();
  const [activeTab, setActiveTab] = useState<Tab>("Fees");

  /* ---- shared write hook ---- */
  const {
    writeContract,
    data: txHash,
    isPending: isWritePending,
    error: writeError,
    reset: resetWrite,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess: txConfirmed } =
    useWaitForTransactionReceipt({ hash: txHash });

  const [lastAction, setLastAction] = useState("");

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  function fireAction(label: string, args: any) {
    resetWrite();
    setLastAction(label);
    writeContract(args);
  }

  /* ---- read current fees ---- */
  const { data: protocolFees, refetch: refetchFees } = useReadContract({
    address: addresses.factory,
    abi: factoryAbi,
    functionName: "protocolFees",
  });

  // viem decodeAbiParameters returns a plain array even for named outputs
  const feesArr = protocolFees as readonly [bigint, bigint, `0x${string}`, `0x${string}`] | undefined;
  const fees = feesArr
    ? {
        protocolFeeBps: feesArr[0],
        daoFeeBps: feesArr[1],
        protocolFeeRecipient: feesArr[2],
        daoFeeRecipient: feesArr[3],
      }
    : undefined;

  /* ---- read current operator ---- */
  const { data: currentOperator, refetch: refetchOperator } = useReadContract({
    address: addresses.factory,
    abi: factoryAbi,
    functionName: "operator",
  });

  /* ---- admin role check ---- */
  const { data: adminRoleHash } = useReadContract({
    address: addresses.factory,
    abi: factoryAbi,
    functionName: "DIRAC_ADMIN_ROLE",
  });

  const { data: isAdmin } = useReadContract({
    address: addresses.factory,
    abi: factoryAbi,
    functionName: "hasRole",
    args: adminRoleHash && userAddress
      ? [adminRoleHash as `0x${string}`, userAddress]
      : undefined,
    query: { enabled: !!adminRoleHash && !!userAddress },
  });

  /* ---- auto-refetch on tx confirm ---- */
  useEffect(() => {
    if (txConfirmed) {
      refetchFees();
      refetchOperator();
    }
  }, [txConfirmed, refetchFees, refetchOperator]);

  /* ==================================================================== */
  /*  TAB: Fees                                                           */
  /* ==================================================================== */
  function FeesTab() {
    const [protocolBps, setProtocolBps] = useState("");
    const [protocolRecipient, setProtocolRecipient] = useState("");
    const [daoBps, setDaoBps] = useState("");
    const [daoRecipient, setDaoRecipient] = useState("");

    return (
      <div className="space-y-6">
        {/* Current fees display */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">Current Fees</h3>
          {fees ? (
            <div className="grid grid-cols-2 gap-4 text-sm">
              <div>
                <p className="text-xs text-slate-400">Protocol Fee</p>
                <p className="text-white font-medium">
                  {Number(fees.protocolFeeBps)} bps (
                  {(Number(fees.protocolFeeBps) / 100).toFixed(2)}%)
                </p>
              </div>
              <div>
                <p className="text-xs text-slate-400">Protocol Recipient</p>
                <p className="text-white font-mono text-xs">
                  {fees.protocolFeeRecipient}
                </p>
              </div>
              <div>
                <p className="text-xs text-slate-400">DAO Fee</p>
                <p className="text-white font-medium">
                  {Number(fees.daoFeeBps)} bps (
                  {(Number(fees.daoFeeBps) / 100).toFixed(2)}%)
                </p>
              </div>
              <div>
                <p className="text-xs text-slate-400">DAO Recipient</p>
                <p className="text-white font-mono text-xs">
                  {fees.daoFeeRecipient}
                </p>
              </div>
            </div>
          ) : (
            <div className="flex items-center gap-2 text-slate-400 text-sm">
              <Spinner /> Loading...
            </div>
          )}
        </div>

        {/* Set Protocol Fee */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Set Protocol Fee
          </h3>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Field label="Fee (bps)">
              <input
                type="number"
                min="0"
                value={protocolBps}
                onChange={(e) => setProtocolBps(e.target.value)}
                placeholder="e.g. 50 for 0.5%"
                className={inputClass}
              />
            </Field>
            <Field label="Recipient Address">
              <input
                type="text"
                value={protocolRecipient}
                onChange={(e) => setProtocolRecipient(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
          </div>
          <button
            disabled={isWritePending || !protocolBps || !protocolRecipient}
            onClick={() =>
              fireAction("Set Protocol Fee", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "setProtocolFee",
                args: [
                  BigInt(protocolBps),
                  protocolRecipient as `0x${string}`,
                ],
              })
            }
            className={btnPrimary}
          >
            {isWritePending && lastAction === "Set Protocol Fee"
              ? "Confirm in wallet..."
              : "Set Protocol Fee"}
          </button>
        </div>

        {/* Set DAO Fee */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">Set DAO Fee</h3>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Field label="Fee (bps)">
              <input
                type="number"
                min="0"
                value={daoBps}
                onChange={(e) => setDaoBps(e.target.value)}
                placeholder="e.g. 50 for 0.5%"
                className={inputClass}
              />
            </Field>
            <Field label="Recipient Address">
              <input
                type="text"
                value={daoRecipient}
                onChange={(e) => setDaoRecipient(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
          </div>
          <button
            disabled={isWritePending || !daoBps || !daoRecipient}
            onClick={() =>
              fireAction("Set DAO Fee", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "setDaoFee",
                args: [BigInt(daoBps), daoRecipient as `0x${string}`],
              })
            }
            className={btnPrimary}
          >
            {isWritePending && lastAction === "Set DAO Fee"
              ? "Confirm in wallet..."
              : "Set DAO Fee"}
          </button>
        </div>
      </div>
    );
  }

  /* ==================================================================== */
  /*  TAB: Tokens                                                         */
  /* ==================================================================== */
  function TokensTab() {
    const [depositToken, setDepositToken] = useState("");
    const [removeDepToken, setRemoveDepToken] = useState("");
    const [stratToken, setStratToken] = useState("");
    const [stratDolomiteId, setStratDolomiteId] = useState("");
    const [stratPerpsAssets, setStratPerpsAssets] = useState("");
    const [removeStratToken, setRemoveStratToken] = useState("");
    const [symToken, setSymToken] = useState("");
    const [symModuleKey, setSymModuleKey] = useState("perps.orderly");
    const [symSymbol, setSymSymbol] = useState("");

    return (
      <div className="space-y-6">
        {/* Whitelist Deposit Token */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Whitelist Deposit Token
          </h3>
          <Field label="Token Address">
            <input
              type="text"
              value={depositToken}
              onChange={(e) => setDepositToken(e.target.value)}
              placeholder="0x..."
              className={inputClass}
            />
          </Field>
          <button
            disabled={isWritePending || !depositToken}
            onClick={() =>
              fireAction("Whitelist Deposit Token", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "whitelistDepositToken",
                args: [depositToken as `0x${string}`],
              })
            }
            className={btnPrimary}
          >
            {isWritePending && lastAction === "Whitelist Deposit Token"
              ? "Confirm in wallet..."
              : "Whitelist Token"}
          </button>
        </div>

        {/* Remove Deposit Token */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Remove Deposit Token
          </h3>
          <Field label="Token Address">
            <input
              type="text"
              value={removeDepToken}
              onChange={(e) => setRemoveDepToken(e.target.value)}
              placeholder="0x..."
              className={inputClass}
            />
          </Field>
          <button
            disabled={isWritePending || !removeDepToken}
            onClick={() =>
              fireAction("Remove Deposit Token", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "removeDepositToken",
                args: [removeDepToken as `0x${string}`],
              })
            }
            className={btnDanger}
          >
            {isWritePending && lastAction === "Remove Deposit Token"
              ? "Confirm in wallet..."
              : "Remove Token"}
          </button>
        </div>

        {/* Whitelist Strategy Asset */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Whitelist Strategy Asset
          </h3>
          <p className="text-xs text-slate-400">
            Register a collateral asset and its allowed perps trading pairs.
            After whitelisting, use "Set Module Lending Config" below to configure the lending market ID.
          </p>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Field label="Token Address">
              <input
                type="text"
                value={stratToken}
                onChange={(e) => setStratToken(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
            <Field label="Allowed Perps Assets (comma-separated)">
              <input
                type="text"
                value={stratPerpsAssets}
                onChange={(e) => setStratPerpsAssets(e.target.value)}
                placeholder="e.g. PERP_BERA_USDC,PERP_ETH_USDC"
                className={inputClass}
              />
            </Field>
          </div>
          <button
            disabled={isWritePending || !stratToken}
            onClick={() => {
              const perpsArr = stratPerpsAssets
                .split(",")
                .map((s) => s.trim())
                .filter(Boolean);
              fireAction("Whitelist Strategy Asset", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "whitelistStrategyAsset",
                args: [
                  {
                    token: stratToken as `0x${string}`,
                    allowedPerpsAssets: perpsArr,
                  },
                ],
              });
            }}
            className={btnPrimary}
          >
            {isWritePending && lastAction === "Whitelist Strategy Asset"
              ? "Confirm in wallet..."
              : "Whitelist Strategy Asset"}
          </button>
        </div>

        {/* Set Module Lending Config */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Set Module Lending Config
          </h3>
          <p className="text-xs text-slate-400">
            Configure the lending market ID for a strategy asset + module type (e.g. Dolomite market ID).
          </p>
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <Field label="Token Address">
              <input
                type="text"
                value={stratToken}
                onChange={(e) => setStratToken(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
            <Field label="Module Type Hash (bytes32)">
              <input
                type="text"
                value={keccak256(toHex("lending.dolomite"))}
                readOnly
                className={inputClass + " opacity-60"}
              />
            </Field>
            <Field label="Dolomite Market ID">
              <input
                type="number"
                min="0"
                value={stratDolomiteId}
                onChange={(e) => setStratDolomiteId(e.target.value)}
                placeholder="e.g. 6"
                className={inputClass}
              />
            </Field>
          </div>
          <button
            disabled={isWritePending || !stratToken || !stratDolomiteId}
            onClick={() => {
              const moduleTypeHash = keccak256(toHex("lending.dolomite")) as `0x${string}`;
              const configBytes = encodeAbiParameters(parseAbiParameters("uint256"), [BigInt(stratDolomiteId)]);
              fireAction("Set Module Lending Config", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "setModuleLendingConfig",
                args: [moduleTypeHash, stratToken as `0x${string}`, configBytes],
              });
            }}
            className={btnPrimary}
          >
            {isWritePending && lastAction === "Set Module Lending Config"
              ? "Confirm in wallet..."
              : "Set Module Lending Config"}
          </button>
        </div>

        {/* Remove Strategy Asset */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Remove Strategy Asset
          </h3>
          <Field label="Token Address">
            <input
              type="text"
              value={removeStratToken}
              onChange={(e) => setRemoveStratToken(e.target.value)}
              placeholder="0x..."
              className={inputClass}
            />
          </Field>
          <button
            disabled={isWritePending || !removeStratToken}
            onClick={() =>
              fireAction("Remove Strategy Asset", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "removeStrategyAsset",
                args: [removeStratToken as `0x${string}`],
              })
            }
            className={btnDanger}
          >
            {isWritePending && lastAction === "Remove Strategy Asset"
              ? "Confirm in wallet..."
              : "Remove Asset"}
          </button>
        </div>

        {/* Set Perps Module Symbol */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Set Perps Module Symbol
          </h3>
          <p className="text-xs text-slate-400">
            Register the module-specific symbol/identifier for a collateral token.
            Each perps module can have its own naming convention (e.g. Orderly uses "PERP_IBGT_USDC").
          </p>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Field label="Collateral Token Address">
              <input
                type="text"
                value={symToken}
                onChange={(e) => setSymToken(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
            <Field label="Module Type Key (e.g. perps.orderly)">
              <input
                type="text"
                value={symModuleKey}
                onChange={(e) => setSymModuleKey(e.target.value)}
                placeholder="perps.orderly"
                className={inputClass}
              />
            </Field>
            <Field label="Symbol (e.g. PERP_IBGT_USDC)">
              <input
                type="text"
                value={symSymbol}
                onChange={(e) => setSymSymbol(e.target.value)}
                placeholder="PERP_IBGT_USDC"
                className={inputClass}
              />
            </Field>
          </div>
          <button
            disabled={isWritePending || !symToken || !symModuleKey || !symSymbol}
            onClick={() => {
              const moduleTypeHash = keccak256(encodePacked(["string"], [symModuleKey]));
              const symbolBytes = new TextEncoder().encode(symSymbol);
              fireAction("Set Perps Module Symbol", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "setPerpsModuleSymbol",
                args: [
                  symToken as `0x${string}`,
                  moduleTypeHash,
                  `0x${Array.from(symbolBytes).map((b) => b.toString(16).padStart(2, "0")).join("")}` as `0x${string}`,
                ],
              });
            }}
            className={btnPrimary}
          >
            {isWritePending && lastAction === "Set Perps Module Symbol"
              ? "Confirm in wallet..."
              : "Set Symbol"}
          </button>
        </div>
      </div>
    );
  }

  /* ==================================================================== */
  /*  TAB: Modules                                                        */
  /* ==================================================================== */
  function ModulesTab() {
    const [modType, setModType] = useState("SWAP");
    const [modAddress, setModAddress] = useState("");
    const [removeModType, setRemoveModType] = useState("SWAP");
    const [templateName, setTemplateName] = useState("");
    const [removeTemplateName, setRemoveTemplateName] = useState("");

    return (
      <div className="space-y-6">
        {/* Current Modules */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Registered Modules
          </h3>
          <div className="space-y-2">
            {KNOWN_MODULE_TYPES.map((m) => (
              <ModuleRow key={m.key} moduleKey={m.key} label={m.label} />
            ))}
          </div>
        </div>

        {/* Register Module */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">Register Module</h3>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Field label="Module Type">
              <select
                value={modType}
                onChange={(e) => setModType(e.target.value)}
                className={inputClass}
              >
                {KNOWN_MODULE_TYPES.map((m) => (
                  <option key={m.key} value={m.key}>
                    {m.label}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Module Address">
              <input
                type="text"
                value={modAddress}
                onChange={(e) => setModAddress(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
          </div>
          <button
            disabled={isWritePending || !modAddress}
            onClick={() => {
              const typeHash = keccak256(
                encodePacked(["string"], [modType])
              );
              fireAction("Register Module", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "registerModule",
                args: [typeHash, modAddress as `0x${string}`],
              });
            }}
            className={btnPrimary}
          >
            {isWritePending && lastAction === "Register Module"
              ? "Confirm in wallet..."
              : "Register Module"}
          </button>
        </div>

        {/* Remove Module */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">Remove Module</h3>
          <Field label="Module Type">
            <select
              value={removeModType}
              onChange={(e) => setRemoveModType(e.target.value)}
              className={inputClass}
            >
              {KNOWN_MODULE_TYPES.map((m) => (
                <option key={m.key} value={m.key}>
                  {m.label}
                </option>
              ))}
            </select>
          </Field>
          <button
            disabled={isWritePending}
            onClick={() => {
              const typeHash = keccak256(
                encodePacked(["string"], [removeModType])
              );
              fireAction("Remove Module", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "removeModule",
                args: [typeHash],
              });
            }}
            className={btnDanger}
          >
            {isWritePending && lastAction === "Remove Module"
              ? "Confirm in wallet..."
              : "Remove Module"}
          </button>
        </div>

        {/* Register Template */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Register Template
          </h3>
          <Field label="Template Name">
            <input
              type="text"
              value={templateName}
              onChange={(e) => setTemplateName(e.target.value)}
              placeholder="e.g. delta-neutral-v1"
              className={inputClass}
            />
          </Field>
          <button
            disabled={isWritePending || !templateName}
            onClick={() => {
              const templateId = keccak256(
                encodePacked(["string"], [templateName])
              );
              fireAction("Register Template", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "registerTemplate",
                args: [templateId],
              });
            }}
            className={btnPrimary}
          >
            {isWritePending && lastAction === "Register Template"
              ? "Confirm in wallet..."
              : "Register Template"}
          </button>
        </div>

        {/* Remove Template */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Remove Template
          </h3>
          <Field label="Template Name">
            <input
              type="text"
              value={removeTemplateName}
              onChange={(e) => setRemoveTemplateName(e.target.value)}
              placeholder="e.g. delta-neutral-v1"
              className={inputClass}
            />
          </Field>
          <button
            disabled={isWritePending || !removeTemplateName}
            onClick={() => {
              const templateId = keccak256(
                encodePacked(["string"], [removeTemplateName])
              );
              fireAction("Remove Template", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "removeTemplate",
                args: [templateId],
              });
            }}
            className={btnDanger}
          >
            {isWritePending && lastAction === "Remove Template"
              ? "Confirm in wallet..."
              : "Remove Template"}
          </button>
        </div>
      </div>
    );
  }

  /* ==================================================================== */
  /*  TAB: Roles                                                          */
  /* ==================================================================== */
  function RolesTab() {
    const [operatorAddr, setOperatorAddr] = useState("");
    const [grantOpVault, setGrantOpVault] = useState("");
    const [grantOpAddr, setGrantOpAddr] = useState("");
    const [revokeOpVault, setRevokeOpVault] = useState("");
    const [revokeOpAddr, setRevokeOpAddr] = useState("");
    const [grantCurVault, setGrantCurVault] = useState("");
    const [grantCurAddr, setGrantCurAddr] = useState("");
    const [revokeCurVault, setRevokeCurVault] = useState("");
    const [revokeCurAddr, setRevokeCurAddr] = useState("");
    const [batchOpAddr, setBatchOpAddr] = useState("");
    const [batchStart, setBatchStart] = useState("");
    const [batchEnd, setBatchEnd] = useState("");

    return (
      <div className="space-y-6">
        {/* Current Operator */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Global Operator
          </h3>
          <p className="text-sm text-slate-300 font-mono">
            {currentOperator
              ? (currentOperator as string)
              : "Loading..."}
          </p>
        </div>

        {/* Set Global Operator */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Set Global Operator
          </h3>
          <p className="text-xs text-slate-400">
            Sets the default operator for newly created vaults.
          </p>
          <Field label="Operator Address">
            <input
              type="text"
              value={operatorAddr}
              onChange={(e) => setOperatorAddr(e.target.value)}
              placeholder="0x..."
              className={inputClass}
            />
          </Field>
          <button
            disabled={isWritePending || !operatorAddr}
            onClick={() =>
              fireAction("Set Operator", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "setOperator",
                args: [operatorAddr as `0x${string}`],
              })
            }
            className={btnPrimary}
          >
            {isWritePending && lastAction === "Set Operator"
              ? "Confirm in wallet..."
              : "Set Operator"}
          </button>
        </div>

        {/* Batch Update Operator */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Batch Update Operator
          </h3>
          <p className="text-xs text-slate-400">
            Update operator across a range of vaults by index.
          </p>
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <Field label="New Operator">
              <input
                type="text"
                value={batchOpAddr}
                onChange={(e) => setBatchOpAddr(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
            <Field label="Start Index">
              <input
                type="number"
                min="0"
                value={batchStart}
                onChange={(e) => setBatchStart(e.target.value)}
                placeholder="0"
                className={inputClass}
              />
            </Field>
            <Field label="End Index">
              <input
                type="number"
                min="0"
                value={batchEnd}
                onChange={(e) => setBatchEnd(e.target.value)}
                placeholder="10"
                className={inputClass}
              />
            </Field>
          </div>
          <button
            disabled={isWritePending || !batchOpAddr || !batchEnd}
            onClick={() =>
              fireAction("Batch Update Operator", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "updateOperator",
                args: [
                  batchOpAddr as `0x${string}`,
                  BigInt(batchStart || "0"),
                  BigInt(batchEnd),
                ],
              })
            }
            className={btnPrimary}
          >
            {isWritePending && lastAction === "Batch Update Operator"
              ? "Confirm in wallet..."
              : "Update Operator on Vaults"}
          </button>
        </div>

        {/* Grant Vault Operator */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Grant Vault Operator
          </h3>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Field label="Vault Address">
              <input
                type="text"
                value={grantOpVault}
                onChange={(e) => setGrantOpVault(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
            <Field label="Operator Address">
              <input
                type="text"
                value={grantOpAddr}
                onChange={(e) => setGrantOpAddr(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
          </div>
          <button
            disabled={isWritePending || !grantOpVault || !grantOpAddr}
            onClick={() =>
              fireAction("Grant Vault Operator", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "grantVaultOperator",
                args: [
                  grantOpVault as `0x${string}`,
                  grantOpAddr as `0x${string}`,
                ],
              })
            }
            className={btnPrimary}
          >
            {isWritePending && lastAction === "Grant Vault Operator"
              ? "Confirm in wallet..."
              : "Grant Operator"}
          </button>
        </div>

        {/* Revoke Vault Operator */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Revoke Vault Operator
          </h3>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Field label="Vault Address">
              <input
                type="text"
                value={revokeOpVault}
                onChange={(e) => setRevokeOpVault(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
            <Field label="Operator Address">
              <input
                type="text"
                value={revokeOpAddr}
                onChange={(e) => setRevokeOpAddr(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
          </div>
          <button
            disabled={isWritePending || !revokeOpVault || !revokeOpAddr}
            onClick={() =>
              fireAction("Revoke Vault Operator", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "revokeVaultOperator",
                args: [
                  revokeOpVault as `0x${string}`,
                  revokeOpAddr as `0x${string}`,
                ],
              })
            }
            className={btnDanger}
          >
            {isWritePending && lastAction === "Revoke Vault Operator"
              ? "Confirm in wallet..."
              : "Revoke Operator"}
          </button>
        </div>

        {/* Grant Vault Curator */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Grant Vault Curator
          </h3>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Field label="Vault Address">
              <input
                type="text"
                value={grantCurVault}
                onChange={(e) => setGrantCurVault(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
            <Field label="Curator Address">
              <input
                type="text"
                value={grantCurAddr}
                onChange={(e) => setGrantCurAddr(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
          </div>
          <button
            disabled={isWritePending || !grantCurVault || !grantCurAddr}
            onClick={() =>
              fireAction("Grant Vault Curator", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "grantVaultCurator",
                args: [
                  grantCurVault as `0x${string}`,
                  grantCurAddr as `0x${string}`,
                ],
              })
            }
            className={btnPrimary}
          >
            {isWritePending && lastAction === "Grant Vault Curator"
              ? "Confirm in wallet..."
              : "Grant Curator"}
          </button>
        </div>

        {/* Revoke Vault Curator */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Revoke Vault Curator
          </h3>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Field label="Vault Address">
              <input
                type="text"
                value={revokeCurVault}
                onChange={(e) => setRevokeCurVault(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
            <Field label="Curator Address">
              <input
                type="text"
                value={revokeCurAddr}
                onChange={(e) => setRevokeCurAddr(e.target.value)}
                placeholder="0x..."
                className={inputClass}
              />
            </Field>
          </div>
          <button
            disabled={isWritePending || !revokeCurVault || !revokeCurAddr}
            onClick={() =>
              fireAction("Revoke Vault Curator", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "revokeVaultCurator",
                args: [
                  revokeCurVault as `0x${string}`,
                  revokeCurAddr as `0x${string}`,
                ],
              })
            }
            className={btnDanger}
          >
            {isWritePending && lastAction === "Revoke Vault Curator"
              ? "Confirm in wallet..."
              : "Revoke Curator"}
          </button>
        </div>
      </div>
    );
  }

  /* ==================================================================== */
  /*  TAB: Emergency                                                      */
  /* ==================================================================== */
  function EmergencyTab() {
    const [pauseVault, setPauseVault] = useState("");
    const [unpauseVault, setUnpauseVault] = useState("");
    const [endCycleVault, setEndCycleVault] = useState("");

    return (
      <div className="space-y-6">
        <div className="rounded-lg border border-red-800/40 bg-red-900/20 px-4 py-3 text-sm text-red-300">
          These actions are irreversible or high-impact. Use with caution.
        </div>

        {/* Emergency Pause */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Emergency Pause Vault
          </h3>
          <Field label="Vault Address">
            <input
              type="text"
              value={pauseVault}
              onChange={(e) => setPauseVault(e.target.value)}
              placeholder="0x..."
              className={inputClass}
            />
          </Field>
          <button
            disabled={isWritePending || !pauseVault}
            onClick={() =>
              fireAction("Emergency Pause", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "emergencyPause",
                args: [pauseVault as `0x${string}`],
              })
            }
            className={btnDanger}
          >
            {isWritePending && lastAction === "Emergency Pause"
              ? "Confirm in wallet..."
              : "Pause Vault"}
          </button>
        </div>

        {/* Emergency Unpause */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Emergency Unpause Vault
          </h3>
          <Field label="Vault Address">
            <input
              type="text"
              value={unpauseVault}
              onChange={(e) => setUnpauseVault(e.target.value)}
              placeholder="0x..."
              className={inputClass}
            />
          </Field>
          <button
            disabled={isWritePending || !unpauseVault}
            onClick={() =>
              fireAction("Emergency Unpause", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "emergencyUnpause",
                args: [unpauseVault as `0x${string}`],
              })
            }
            className={btnPrimary}
          >
            {isWritePending && lastAction === "Emergency Unpause"
              ? "Confirm in wallet..."
              : "Unpause Vault"}
          </button>
        </div>

        {/* Emergency End Cycle */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">
            Emergency End Cycle
          </h3>
          <p className="text-xs text-slate-400">
            Forces the vault cycle to CLOSED status regardless of current state.
          </p>
          <Field label="Vault Address">
            <input
              type="text"
              value={endCycleVault}
              onChange={(e) => setEndCycleVault(e.target.value)}
              placeholder="0x..."
              className={inputClass}
            />
          </Field>
          <button
            disabled={isWritePending || !endCycleVault}
            onClick={() =>
              fireAction("Emergency End Cycle", {
                address: addresses.factory,
                abi: factoryAbi,
                functionName: "emergencyEndCycle",
                args: [endCycleVault as `0x${string}`],
              })
            }
            className={btnDanger}
          >
            {isWritePending && lastAction === "Emergency End Cycle"
              ? "Confirm in wallet..."
              : "Force End Cycle"}
          </button>
        </div>
      </div>
    );
  }

  /* ==================================================================== */
  /*  TAB: Orderly                                                        */
  /* ==================================================================== */
  function OrderlyTab() {
    const [apiHealthy, setApiHealthy] = useState<boolean | null>(null);
    const [vaultAddr, setVaultAddr] = useState("");
    const [leverage, setLeverage] = useState("2");
    const [resumeTxHash, setResumeTxHash] = useState("");
    const [result, setResult] = useState<string | null>(null);
    const [error, setError] = useState<string | null>(null);
    const [isLoading, setIsLoading] = useState(false);

    useEffect(() => {
      healthCheck()
        .then(() => setApiHealthy(true))
        .catch(() => setApiHealthy(false));
    }, []);

    async function handleInitialize() {
      setError(null);
      setResult(null);
      setIsLoading(true);
      try {
        const res = await initializeVault(chainId, vaultAddr, parseInt(leverage));
        setResult(`Initialized! AccountId: ${res.accountId}, Key: ${res.orderlyPublicKey}`);
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : "Init failed");
      } finally {
        setIsLoading(false);
      }
    }

    async function handleResume() {
      setError(null);
      setResult(null);
      setIsLoading(true);
      try {
        const res = await confirmDelegateSigner(chainId, vaultAddr, resumeTxHash, parseInt(leverage));
        setResult(`Resumed! AccountId: ${res.accountId}, Key: ${res.orderlyPublicKey}`);
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : "Resume failed");
      } finally {
        setIsLoading(false);
      }
    }

    return (
      <div className="space-y-6">
        {/* API Connection */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">API Connection</h3>
          <div className="flex items-center gap-3">
            <div className={`h-3 w-3 rounded-full ${apiHealthy === null ? "bg-slate-500" : apiHealthy ? "bg-emerald-400" : "bg-red-400"}`} />
            <span className="text-sm text-slate-300">
              {apiHealthy === null ? "Checking..." : apiHealthy ? "API is running" : "API unreachable"}
            </span>
            <span className="font-mono text-xs text-slate-500">
              {process.env.NEXT_PUBLIC_API_URL || "http://localhost:3000"}
            </span>
          </div>
        </div>

        {/* Shared vault + leverage inputs */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">Vault</h3>
          <Field label="Vault Address">
            <input
              type="text"
              value={vaultAddr}
              onChange={(e) => setVaultAddr(e.target.value)}
              placeholder="0x..."
              className={inputClass}
            />
          </Field>
          <Field label="Leverage">
            <input
              type="number"
              value={leverage}
              onChange={(e) => setLeverage(e.target.value)}
              min="1"
              max="10"
              className="w-32 bg-slate-800 border border-slate-600 rounded-lg px-4 py-2.5 text-sm focus:border-orange-500 focus:outline-none text-white"
            />
          </Field>
        </div>

        {/* Initialize Vault on Orderly */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">Initialize Vault on Orderly</h3>
          <p className="text-sm text-slate-400">
            One-time setup: initializes Dolomite + Orderly modules, registers delegate signer,
            creates ed25519 key, sets leverage. Run after deploying the vault and granting operator role.
          </p>
          <button
            disabled={isLoading || !apiHealthy || !vaultAddr}
            onClick={handleInitialize}
            className={btnPrimary}
          >
            {isLoading ? <span className="flex items-center gap-2"><Spinner /> Initializing...</span> : "Initialize Vault"}
          </button>
        </div>

        {/* Resume Orderly Setup */}
        <div className={panelClass}>
          <h3 className="text-lg font-semibold text-white">Resume Orderly Setup</h3>
          <p className="text-sm text-slate-400">
            If the on-chain delegateSigner tx already succeeded but the API crashed,
            use this to resume from step 2 (off-chain confirmation).
          </p>
          <Field label="Delegate Signer Tx Hash">
            <input
              type="text"
              value={resumeTxHash}
              onChange={(e) => setResumeTxHash(e.target.value)}
              placeholder="0x..."
              className={inputClass}
            />
          </Field>
          <button
            disabled={isLoading || !apiHealthy || !vaultAddr || !resumeTxHash}
            onClick={handleResume}
            className="px-5 py-2.5 rounded-lg font-medium bg-slate-700 hover:bg-slate-600 text-white disabled:opacity-40 disabled:cursor-not-allowed transition-colors text-sm"
          >
            {isLoading ? <span className="flex items-center gap-2"><Spinner /> Resuming...</span> : "Resume Setup"}
          </button>
        </div>

        {result && (
          <div className="rounded-lg border border-emerald-500/40 bg-emerald-500/10 px-4 py-3 text-sm text-emerald-400">{result}</div>
        )}
        {error && (
          <div className="rounded-lg border border-red-500/40 bg-red-500/10 px-4 py-3 text-sm text-red-400">{error}</div>
        )}
      </div>
    );
  }

  /* ==================================================================== */
  /*  Module row helper                                                   */
  /* ==================================================================== */
  function ModuleRow({
    moduleKey,
    label,
  }: {
    moduleKey: string;
    label: string;
  }) {
    const typeHash = keccak256(encodePacked(["string"], [moduleKey]));
    const { data: moduleAddr } = useReadContract({
      address: addresses.factory,
      abi: factoryAbi,
      functionName: "getModule",
      args: [typeHash],
    });

    const addr = moduleAddr as `0x${string}` | undefined;
    const isSet =
      addr && addr !== "0x0000000000000000000000000000000000000000";

    return (
      <div className="flex items-center justify-between rounded-lg border border-slate-700 bg-slate-800/50 px-4 py-3">
        <span className="text-sm font-medium text-white">{label}</span>
        {isSet ? (
          <span className="font-mono text-xs text-emerald-400">
            {shortenAddress(addr)}
          </span>
        ) : (
          <span className="text-xs text-slate-500">Not registered</span>
        )}
      </div>
    );
  }

  /* ==================================================================== */
  /*  RENDER                                                              */
  /* ==================================================================== */

  return (
    <div className="min-h-screen bg-[#0b0f1a]">
      {/* Header */}
      <div className="border-b border-slate-800 px-6 py-4">
        <div className="mx-auto max-w-4xl">
          <h1 className="text-2xl font-bold text-white">Factory Admin</h1>
          <p className="text-sm text-slate-400 mt-1">
            Manage protocol-level settings on the DiracVaultFactory.
          </p>
          {isConnected && (
            <div className="mt-2 flex items-center gap-2">
              {isAdmin ? (
                <span className="inline-block rounded-full border border-emerald-500/40 bg-emerald-500/20 px-3 py-1 text-xs font-medium text-emerald-400">
                  Admin
                </span>
              ) : (
                <span className="inline-block rounded-full border border-red-500/40 bg-red-500/20 px-3 py-1 text-xs font-medium text-red-400">
                  Not Admin
                </span>
              )}
              <span className="font-mono text-xs text-slate-500">
                {userAddress}
              </span>
            </div>
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

      {/* Transaction status bar */}
      {(txHash || writeError) && (
        <div className="mx-auto max-w-4xl px-6 pt-4">
          <div
            className={`rounded-lg border px-4 py-3 text-sm ${
              writeError
                ? "border-red-800/40 bg-red-900/20 text-red-300"
                : txConfirmed
                  ? "border-emerald-800/40 bg-emerald-900/20 text-emerald-300"
                  : isConfirming
                    ? "border-amber-800/40 bg-amber-900/20 text-amber-300"
                    : "border-slate-700 bg-slate-800/50 text-slate-300"
            }`}
          >
            <span className="font-medium">{lastAction}: </span>
            {writeError
              ? writeError.message?.slice(0, 200)
              : txConfirmed
                ? "Transaction confirmed!"
                : isConfirming
                  ? "Confirming..."
                  : "Submitted"}
            {txHash && !writeError && (
              <a
                href={`https://berascan.com/tx/${txHash}`}
                target="_blank"
                rel="noopener noreferrer"
                className="ml-2 underline"
              >
                View on Berascan
              </a>
            )}
          </div>
        </div>
      )}

      {/* Content */}
      <div className="mx-auto max-w-4xl px-6 py-8">
        {!isConnected && (
          <div className="mb-6 rounded-lg border border-amber-500/40 bg-amber-500/10 px-4 py-3 text-sm text-amber-400">
            Connect your wallet to use admin functions.
          </div>
        )}

        {activeTab === "Fees" && <FeesTab />}
        {activeTab === "Tokens" && <TokensTab />}
        {activeTab === "Modules" && <ModulesTab />}
        {activeTab === "Roles" && <RolesTab />}
        {activeTab === "Emergency" && <EmergencyTab />}
        {activeTab === "Orderly" && <OrderlyTab />}
      </div>
    </div>
  );
}
