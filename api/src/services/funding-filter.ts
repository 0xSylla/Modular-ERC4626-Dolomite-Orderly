/**
 * Funding-rate filter — smooths the noisy 8h funding rate into a 9-period
 * (3-day) moving average with hysteresis, and emits a per-position decision
 * (PAUSE / RESUME / HOLD) the monitor uses to gate entry & exit.
 *
 * Ported from DiracDeltaNeutral/script/rebalancer-ts-funding/src/funding-filter.ts,
 * adapted to read the pause threshold from each vault's on-chain `fundingRateThresholdBps`
 * instead of a single global env var.
 *
 * Decision logic (per position):
 *   ACTIVE  + MA  < pauseThreshold                  → PAUSE
 *   PAUSED  + MA >= pauseThreshold + hysteresisBps  → RESUME
 *   else                                            → HOLD
 */

import { getFundingHistory } from "./orderly";
import type { MonitorMode } from "./monitor-state";

export type FundingDecision = "PAUSE" | "RESUME" | "HOLD";

export interface FundingEvalResult {
  ma: number;          // moving average, decimal (1e-4 == 1 bp per 8h)
  maBps: number;       // ma × 10000
  periodsUsed: number;
  decision: FundingDecision;
  thresholdBps: number;
  hysteresisBps: number;
}

export interface FundingConfig {
  pauseThresholdBps: number; // pause when MA below this
  hysteresisBps: number;     // resume when MA above threshold + this
  maPeriods: number;         // window size; 9 = 3 days of 8h funding
}

const HYSTERESIS_BPS_DEFAULT = Number(process.env.FUNDING_HYSTERESIS_BPS ?? "0.5");
const MA_PERIODS_DEFAULT = Number(process.env.FUNDING_MA_PERIODS ?? "9");

/**
 * Build a config from a vault's on-chain `fundingRateThresholdBps`.
 * Falls back to 0 (pause as soon as funding goes negative for shorts) if the
 * vault was deployed with the threshold unset.
 */
export function configFromVault(fundingRateThresholdBps: number): FundingConfig {
  return {
    pauseThresholdBps: fundingRateThresholdBps,
    hysteresisBps: HYSTERESIS_BPS_DEFAULT,
    maPeriods: MA_PERIODS_DEFAULT,
  };
}

export function evaluateRates(rates: number[], mode: MonitorMode, cfg: FundingConfig): FundingEvalResult {
  const periodsUsed = Math.min(rates.length, cfg.maPeriods);
  const slice = rates.slice(0, periodsUsed);
  const ma = periodsUsed > 0 ? slice.reduce((s, x) => s + x, 0) / periodsUsed : 0;
  const maBps = ma * 10000;

  let decision: FundingDecision = "HOLD";
  if (mode === "ACTIVE") {
    if (maBps < cfg.pauseThresholdBps) decision = "PAUSE";
  } else {
    if (maBps >= cfg.pauseThresholdBps + cfg.hysteresisBps) decision = "RESUME";
  }

  return {
    ma, maBps, periodsUsed, decision,
    thresholdBps: cfg.pauseThresholdBps,
    hysteresisBps: cfg.hysteresisBps,
  };
}

/**
 * Fetch + evaluate in one call. Returns `null` on network failure so the caller can
 * decide whether to HOLD (which is what `monitor.ts` does — never act on stale data).
 */
export async function evaluateFunding(
  perpsAsset: string,
  mode: MonitorMode,
  cfg: FundingConfig,
): Promise<FundingEvalResult | null> {
  try {
    const rates = await getFundingHistory(perpsAsset, cfg.maPeriods);
    return evaluateRates(rates, mode, cfg);
  } catch (err: any) {
    console.warn(`[funding-filter] fetch failed for ${perpsAsset}: ${err.message}`);
    return null;
  }
}
