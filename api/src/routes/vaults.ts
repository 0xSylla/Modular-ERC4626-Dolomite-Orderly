import { Router, type Request, type Response } from "express";
import { type Address } from "viem";
import { setupVaultOrderly, resumeVaultOrderly, computeAccountId } from "../services/orderly";
import { initializeDolomite, initializeOrderlyModule } from "../services/blockchain";
import { config } from "../config";

export const vaultsRouter = Router();

/**
 * POST /vaults/initialize
 * One-time setup per vault. Called after vault creation + operator role granted.
 *
 * Body: { vault: string, leverage?: number }
 *
 * Performs:
 *   1. Initialize Dolomite module (authorize deposit/withdrawal router as operator)
 *   2. Initialize Orderly module (set Orderly vault address for deposits)
 *   3. delegateSigner on-chain (operator signs for the vault on Orderly)
 *   4. Confirm delegate signer off-chain (EIP-712)
 *   5. Register ed25519 orderly key off-chain (EIP-712)
 *   6. Set leverage on Orderly
 *
 * Returns: { dolomiteTxHash, orderlyModuleTxHash, accountId, orderlyPublicKey }
 */
vaultsRouter.post("/initialize", async (req: Request, res: Response) => {
  try {
    const { chainId, vault, leverage } = req.body;
    if (!chainId || !vault) {
      res.status(400).json({ error: "Missing chainId or vault address" });
      return;
    }

    const chain = Number(chainId);
    const vaultAddr = vault as Address;

    // Step 1: Initialize Dolomite (authorize deposit/withdrawal router)
    console.log(`[Initialize] Step 1: Dolomite init for vault ${vaultAddr} on chain ${chain}`);
    const dolomiteTxHash = await initializeDolomite(chain, vaultAddr);
    console.log(`[Initialize] Dolomite initialized, tx: ${dolomiteTxHash}`);

    // Step 2: Initialize Orderly module (set Orderly vault address)
    console.log(`[Initialize] Step 2: Orderly module init for vault ${vaultAddr}`);
    const orderlyModuleTxHash = await initializeOrderlyModule(chain, vaultAddr);
    console.log(`[Initialize] Orderly module initialized, tx: ${orderlyModuleTxHash}`);

    // Steps 3-6: Orderly off-chain setup
    console.log(`[Initialize] Steps 3-6: Orderly off-chain setup for vault ${vaultAddr}`);
    const orderlyResult = await setupVaultOrderly(chain, vaultAddr, leverage ?? 2);

    res.json({
      dolomiteTxHash,
      orderlyModuleTxHash,
      ...orderlyResult,
      message: "Vault initialized: Dolomite ready, Orderly ready for trading.",
    });
  } catch (err: any) {
    console.error("[POST /vaults/initialize]", err);
    res.status(500).json({ error: err.message });
  }
});

/**
 * POST /vaults/confirm-delegate-signer
 * Recovery endpoint: resume Orderly setup from step 2 when step 1 tx already exists
 * (e.g., if the API crashed after the on-chain delegateSigner tx succeeded).
 *
 * Body: { vault: string, txHash: string, leverage?: number }
 */
/**
 * GET /vaults/orderly-status/:chainId/:vault
 * Reports whether the vault has been registered on Orderly Network.
 * Queries Orderly's public `/v1/get_account` endpoint so the answer
 * survives API restarts (does not depend on in-memory credentials).
 *
 * Returns: { initialized: boolean, accountId: string }
 */
vaultsRouter.get(
  "/orderly-status/:chainId/:vault",
  async (req: Request, res: Response) => {
    try {
      const { chainId, vault } = req.params;
      const vaultAddr = vault as Address;
      const accountId = computeAccountId(vaultAddr);

      const url = `${config.orderlyApiUrl}/v1/get_account?address=${vaultAddr}&broker_id=${config.brokerId}`;
      const r = await fetch(url);

      // Orderly returns {success:true, data:{...account...}} when registered,
      // and {success:false, message:"account not exists"} (200) otherwise.
      // Some error states return non-200.
      let initialized = false;
      if (r.ok) {
        const body = (await r.json().catch(() => null)) as
          | { success?: boolean; data?: { account_id?: string } }
          | null;
        initialized = Boolean(body?.success && body?.data?.account_id);
      }

      res.json({ initialized, accountId, chainId: Number(chainId) });
    } catch (err: any) {
      console.error("[GET /vaults/orderly-status]", err);
      res.status(500).json({ error: err.message });
    }
  }
);

vaultsRouter.post("/confirm-delegate-signer", async (req: Request, res: Response) => {
  try {
    const { chainId, vault, txHash, leverage } = req.body;
    if (!chainId || !vault || !txHash) {
      res.status(400).json({ error: "Missing chainId, vault, or txHash" });
      return;
    }

    const result = await resumeVaultOrderly(Number(chainId), vault as Address, txHash, leverage ?? 2);

    res.json({
      ...result,
      message: "Orderly setup resumed and completed.",
    });
  } catch (err: any) {
    console.error("[POST /vaults/confirm-delegate-signer]", err);
    res.status(500).json({ error: err.message });
  }
});
