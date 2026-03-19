import * as ed from "@noble/ed25519";
// @ts-ignore - noble-hashes v2 requires .js extension
import { sha512 } from "@noble/hashes/sha2.js";
import { base58 } from "@scure/base";

// Configure ed25519 v3 sync API: set hashes.sha512 (not etc.sha512Sync)
(ed as any).hashes.sha512 = sha512;

export interface OrderlyKeyPair {
  publicKey: string;   // "ed25519:base58encoded..."
  privateKey: string;  // hex string
}

/**
 * Generate a new ed25519 key pair for Orderly API authentication.
 */
export function generateOrderlyKeyPair(): OrderlyKeyPair {
  const privateKey = ed.utils.randomSecretKey();
  const publicKey = ed.getPublicKey(privateKey);

  return {
    publicKey: `ed25519:${base58.encode(publicKey)}`,
    privateKey: Buffer.from(privateKey).toString("hex"),
  };
}

/**
 * Sign a message with ed25519 for Orderly API authentication.
 * Returns base64url-encoded signature.
 */
export function signMessage(message: string, privateKeyHex: string): string {
  const privateKey = Buffer.from(privateKeyHex, "hex");
  const msgBytes = new TextEncoder().encode(message);
  // In @noble/ed25519 v3, sign() is synchronous (requires hashes.sha512 set above)
  const signature = ed.sign(msgBytes, privateKey);
  return Buffer.from(signature).toString("base64url");
}
