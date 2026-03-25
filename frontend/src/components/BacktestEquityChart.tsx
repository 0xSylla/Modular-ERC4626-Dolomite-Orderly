"use client";

import { useMemo } from "react";
import {
  ResponsiveContainer,
  AreaChart,
  Area,
  BarChart,
  Bar,
  LineChart,
  Line,
  XAxis,
  YAxis,
  Tooltip,
  CartesianGrid,
  ReferenceLine,
  Cell,
} from "recharts";
import { runBacktest, MIN_FR } from "./WstethLiveFunding";

type ExecMode = "cex" | "dex";

interface Props {
  threshold: number;        // 1–45 rebalancing %
  execMode: ExecMode;
  fundingFilterOn: boolean;
  fundingSlider: number;    // 0–100 mapped to 0 → MIN_FR
}

const fmt = (n: number) =>
  n >= 0
    ? `$${Math.abs(n).toLocaleString(undefined, { maximumFractionDigits: 0 })}`
    : `-$${Math.abs(n).toLocaleString(undefined, { maximumFractionDigits: 0 })}`;

const fP = (n: number) => `${n >= 0 ? "+" : ""}${n.toFixed(2)}%`;

function ChartTooltip({ active, payload, label }: any) {
  if (!active || !payload?.length) return null;
  return (
    <div className="rounded-lg border border-[#3C323A] bg-[#0a0a0f] px-3 py-2 text-xs shadow-lg font-mono">
      <p className="text-[#818181] mb-1 text-[10px]">{label}</p>
      {payload.filter((p: any) => p.value != null).map((p: any, i: number) => (
        <p key={i} style={{ color: p.color }} className="mt-0.5">{p.name}: ${p.value?.toLocaleString()}</p>
      ))}
    </div>
  );
}

export default function BacktestEquityChart({ threshold, execMode, fundingFilterOn, fundingSlider }: Props) {
  const sf = execMode === "dex" ? 0.003 : 0.0;
  const frThreshold = (fundingSlider / 100) * MIN_FR;

  const result = useMemo(
    () => runBacktest(threshold / 100, sf, fundingFilterOn, frThreshold),
    [threshold, sf, fundingFilterOn, frThreshold]
  );

  const noFilterResult = useMemo(() => {
    if (!fundingFilterOn) return null;
    return runBacktest(threshold / 100, sf, false, 0);
  }, [threshold, sf, fundingFilterOn]);

  const { dd: curve, s: stats } = result;
  if (!stats || !curve?.length) return null;

  const gross = (stats.funding ?? 0) + (stats.staking ?? 0) - (stats.borrow ?? 0);
  const netYield = stats.pnl ?? 0;
  const curveColor = stats.apy >= 0 ? "#2ecc71" : "#ff4d4d";

  // Sharpe Ratio: annualized mean daily return / std daily return
  const sharpe = useMemo(() => {
    if (!curve || curve.length < 2) return 0;
    const returns = curve.map((d: any) => (d.pnl ?? 0) / 1000000); // daily return as fraction of $1M
    const mean = returns.reduce((a: number, b: number) => a + b, 0) / returns.length;
    const variance = returns.reduce((a: number, b: number) => a + (b - mean) ** 2, 0) / returns.length;
    const std = Math.sqrt(variance);
    if (std === 0) return 0;
    return Math.round((mean / std) * Math.sqrt(365) * 10) / 10;
  }, [curve]);

  return (
    <div className="space-y-3">
      {/* KPI row */}
      <div className="flex flex-wrap gap-2">
        {([
          { label: "Net APY", val: fP(stats.apy), color: stats.apy >= 0 ? "text-emerald-400" : "text-red-400", big: true },
          { label: "Net Yield", val: fmt(netYield), color: netYield >= 0 ? "text-emerald-400" : "text-red-400", big: false },
          { label: "Gross Yield", val: fP(gross), color: "text-emerald-400/70", big: false },
          { label: "Execution Costs", val: String(stats.fees ?? 0), color: "text-[#b08850]", big: false },
          { label: "Max Drawdown", val: fP(-stats.mdd), color: "text-red-400", big: false },
          { label: "Sharpe Ratio", val: String(sharpe), color: "text-[#7aab7a]", big: false },
          { label: "Rebalances", val: String(stats.rb), color: "text-white", big: false },
        ] as { label: string; val: string; color: string; big: boolean }[]).map(({ label, val, color, big }) => (
          <div key={label} className={`rounded-lg border border-[#3C323A] bg-[#1a1a1a] ${big ? "px-3 py-2 flex-[1_1_130px]" : "px-2.5 py-1.5 flex-[1_1_80px]"}`}>
            <p className="text-[7px] text-[#818181] uppercase tracking-wider">{label}</p>
            <p className={`${big ? "text-lg" : "text-sm"} font-bold font-mono leading-tight ${color}`}>{val}</p>
          </div>
        ))}
      </div>

      {/* Equity Curve */}
      <div className="h-48">
        <div className="flex items-center gap-2 mb-1 px-1">
          <span className="text-[8px] text-[#818181] uppercase tracking-wider">Equity Curve</span>
        </div>
        <ResponsiveContainer width="100%" height="100%">
          <AreaChart data={curve} margin={{ top: 4, right: 4, bottom: 0, left: 4 }}>
            <defs>
              <linearGradient id="btGrad" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor={curveColor} stopOpacity={0.15} />
                <stop offset="100%" stopColor={curveColor} stopOpacity={0.01} />
              </linearGradient>
            </defs>
            <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.025)" />
            <XAxis dataKey="date" tick={{ fontSize: 8, fill: "#555" }} tickLine={false} axisLine={false} interval={Math.floor(curve.length / 6)} />
            <YAxis tick={{ fontSize: 8, fill: "#555" }} tickLine={false} axisLine={false} tickFormatter={(v: number) => `$${(v / 1e6).toFixed(2)}M`} domain={["auto", "auto"]} width={50} />
            <Tooltip content={<ChartTooltip />} />
            <ReferenceLine y={1000000} stroke="rgba(255,255,255,0.06)" strokeDasharray="6 4" />
            <Area type="monotone" dataKey="equity" name="Equity" stroke={curveColor} strokeWidth={2} fill="url(#btGrad)" dot={false} isAnimationActive={false} />
          </AreaChart>
        </ResponsiveContainer>
      </div>

      {/* Daily P&L Histogram */}
      <div className="h-28">
        <div className="flex items-center gap-2 mb-1 px-1">
          <span className="text-[8px] text-[#818181] uppercase tracking-wider">Daily P&L</span>
        </div>
        <ResponsiveContainer width="100%" height="85%">
          <BarChart data={curve}>
            <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.02)" />
            <XAxis dataKey="date" tick={{ fill: "#383844", fontSize: 7 }} tickLine={false} axisLine={false} interval={Math.floor(curve.length / 6)} />
            <YAxis tick={{ fill: "#383844", fontSize: 7 }} tickLine={false} axisLine={false} tickFormatter={(v: number) => `$${(v / 1000).toFixed(0)}k`} width={36} />
            <Tooltip content={<ChartTooltip />} />
            <ReferenceLine y={0} stroke="rgba(255,255,255,0.06)" />
            <Bar dataKey="pnl" name="Daily P&L" radius={[2, 2, 0, 0]}>
              {curve.map((d: any, i: number) => <Cell key={i} fill={(d.pnl ?? 0) >= 0 ? "#2ecc71" : "#ff4d4d"} opacity={0.8} />)}
            </Bar>
          </BarChart>
        </ResponsiveContainer>
      </div>

      {/* Funding P&L Histogram */}
      <div className="h-28">
        <div className="flex items-center gap-2 mb-1 px-1">
          <span className="text-[8px] text-[#818181] uppercase tracking-wider">Funding P&L</span>
          <span className="text-[7px] text-[#555]">Green = received · Red = paid</span>
        </div>
        <ResponsiveContainer width="100%" height="85%">
          <BarChart data={curve}>
            <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.02)" />
            <XAxis dataKey="date" tick={{ fill: "#383844", fontSize: 7 }} tickLine={false} axisLine={false} interval={Math.floor(curve.length / 6)} />
            <YAxis tick={{ fill: "#383844", fontSize: 7 }} tickLine={false} axisLine={false} tickFormatter={(v: number) => `$${(v / 1000).toFixed(0)}k`} width={36} />
            <Tooltip content={<ChartTooltip />} />
            <ReferenceLine y={0} stroke="rgba(255,255,255,0.08)" />
            <Bar dataKey="fr" name="Funding" radius={[2, 2, 0, 0]}>
              {curve.map((d: any, i: number) => <Cell key={i} fill={d.fr > 0 ? "#2ecc71" : d.fr < 0 ? "#ff4d4d" : "#333"} opacity={d.fr === 0 ? 0.3 : 0.8} />)}
            </Bar>
          </BarChart>
        </ResponsiveContainer>
      </div>

      {/* Performance & Costs Breakdown — side by side */}
      <div className="grid grid-cols-2 gap-3">
        {/* Performance Breakdown */}
        <div className="h-36">
          <div className="flex items-center gap-2 mb-1 px-1 flex-wrap">
            <span className="text-[8px] text-[#818181] uppercase tracking-wider">Performance Breakdown</span>
            <span className="text-[7px] text-white">● Net</span>
            <span className="text-[7px] text-emerald-400">● Funding</span>
            <span className="text-[7px] text-[#5a9a6a]">● Staking</span>
          </div>
          <ResponsiveContainer width="100%" height="85%">
            <LineChart data={curve}>
              <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.02)" />
              <XAxis dataKey="date" tick={{ fill: "#383844", fontSize: 6 }} tickLine={false} axisLine={false} interval={Math.floor(curve.length / 4)} />
              <YAxis tick={{ fill: "#383844", fontSize: 6 }} tickLine={false} axisLine={false} tickFormatter={(v: number) => `$${(v / 1000).toFixed(0)}k`} width={32} />
              <Tooltip content={<ChartTooltip />} />
              <ReferenceLine y={0} stroke="rgba(255,255,255,0.08)" />
              <Line type="monotone" dataKey="cNet" name="Net" stroke="#ffffff" strokeWidth={2} dot={false} />
              <Line type="monotone" dataKey="cFr" name="Funding" stroke="#2ecc71" strokeWidth={1.5} dot={false} />
              <Line type="monotone" dataKey="cSy" name="Staking" stroke="#5a9a6a" strokeWidth={1.5} dot={false} />
            </LineChart>
          </ResponsiveContainer>
        </div>

        {/* Costs Breakdown */}
        <div className="h-36">
          <div className="flex items-center gap-2 mb-1 px-1 flex-wrap">
            <span className="text-[8px] text-[#818181] uppercase tracking-wider">Costs Breakdown</span>
            <span className="text-[7px] text-red-400">● Borrow</span>
            <span className="text-[7px] text-amber-400">● Exec</span>
          </div>
          <ResponsiveContainer width="100%" height="85%">
            <LineChart data={curve}>
              <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.02)" />
              <XAxis dataKey="date" tick={{ fill: "#383844", fontSize: 6 }} tickLine={false} axisLine={false} interval={Math.floor(curve.length / 4)} />
              <YAxis tick={{ fill: "#383844", fontSize: 6 }} tickLine={false} axisLine={false} tickFormatter={(v: number) => `$${(v / 1000).toFixed(0)}k`} width={32} />
              <Tooltip content={<ChartTooltip />} />
              <ReferenceLine y={0} stroke="rgba(255,255,255,0.08)" />
              <Line type="monotone" dataKey="cBc" name="Borrow" stroke="#ff4d4d" strokeWidth={1.5} dot={false} />
              <Line type="monotone" dataKey="cEc" name="Exec Cost" stroke="#e8a838" strokeWidth={1.5} dot={false} strokeDasharray="4 3" />
            </LineChart>
          </ResponsiveContainer>
        </div>
      </div>

      {/* Funding filter impact */}
      {fundingFilterOn && noFilterResult && (() => {
        const nf = noFilterResult.s;
        const netEffect = (stats.pnl ?? 0) - (nf.pnl ?? 0);
        return (
          <div className="rounded-lg border border-amber-500/20 bg-amber-500/5 px-3 py-2 text-xs space-y-1">
            <p className="text-[8px] text-amber-400 uppercase tracking-wider font-mono">Funding filter P&L impact</p>
            <div className="flex gap-4 text-[10px]">
              <span className="text-[#818181]">Without filter: <span className={nf.apy >= 0 ? "text-emerald-400" : "text-red-400"}>{fP(nf.apy)}</span></span>
              <span className="text-[#818181]">Pause costs: <span className="text-red-400">{fmt(-(stats.pauseCost ?? 0))}</span></span>
              <span className="text-[#818181]">Net effect: <span className={netEffect >= 0 ? "text-emerald-400" : "text-red-400"}>{netEffect >= 0 ? "+" : ""}{fmt(netEffect)}</span></span>
            </div>
          </div>
        );
      })()}

      <p className="text-[8px] text-[#818181]/50 text-center">
        wstETH delta-neutral · Morpho Arbitrum + Orderly · backtest Mar 2025 → Mar 2026 · $1M initial
      </p>
    </div>
  );
}
