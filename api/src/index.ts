import express from "express";
import cors from "cors";
import { config, getApiKey } from "./config";
import { positionsRouter } from "./routes/positions";
import { vaultsRouter } from "./routes/vaults";
import { monitorRouter } from "./routes/monitor";
import { stopMonitor } from "./services/rebalance-monitor";
import { startFundingMonitor, stopFundingMonitor } from "./services/funding-monitor";
import { operatorAddress } from "./services/blockchain";
import { cleanupStaleJobs } from "./services/jobs";
import { bootstrapMonitorState } from "./services/monitor-state";

const app = express();

// CORS — restrict in production
const allowedOrigins = process.env.CORS_ORIGINS
  ? process.env.CORS_ORIGINS.split(",")
  : undefined; // undefined = allow all (dev)

app.use(
  cors(
    allowedOrigins
      ? { origin: allowedOrigins }
      : undefined
  )
);

app.use(express.json());

// API key auth middleware (skip for health check)
const apiKey = getApiKey();
if (apiKey) {
  app.use((req, res, next) => {
    if (req.path === "/health") return next();
    const key = req.headers["x-api-key"];
    if (key !== apiKey) {
      res.status(401).json({ error: "Unauthorized" });
      return;
    }
    next();
  });
}

// Health check (minimal — no contract addresses)
app.get("/health", (_req, res) => {
  res.json({ status: "ok" });
});

// Routes
app.use("/vaults", vaultsRouter);
app.use("/positions", positionsRouter);
app.use("/monitor", monitorRouter);

// Job cleanup interval (every 10 minutes)
const cleanupInterval = setInterval(() => {
  const removed = cleanupStaleJobs();
  if (removed > 0) console.log(`[Cleanup] Removed ${removed} stale jobs`);
}, 10 * 60 * 1000);

// Graceful shutdown
const server = app.listen(config.port, async () => {
  console.log(`Dirac API running on port ${config.port}`);
  console.log(`Operator: ${operatorAddress}`);
  // Hydrate the in-memory monitor cache from Postgres (prod) or the JSON file
  // (local dev). Must complete before the funding monitor starts ticking,
  // otherwise the first tick sees an empty position list.
  try {
    await bootstrapMonitorState();
  } catch (err: any) {
    console.error(`[boot] bootstrapMonitorState failed: ${err.message}`);
    process.exit(1);
  }
  // Funding-rate monitor: long-running background loop that drives pause/resume
  // and post-TP/SL rebalances for every tracked position.
  startFundingMonitor();
});

function shutdown() {
  console.log("Shutting down...");
  stopMonitor();
  stopFundingMonitor();
  clearInterval(cleanupInterval);
  server.close(() => process.exit(0));
  // Force exit after 10s if connections don't close
  setTimeout(() => process.exit(1), 10_000);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
