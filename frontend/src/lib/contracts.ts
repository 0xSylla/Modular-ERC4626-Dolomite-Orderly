import { factoryAbi } from "./abis/DiracVaultFactory";
import { vaultAbi } from "./abis/DiracVault";
import { curatorRouterAbi } from "./abis/VaultCuratorRouter";
import { userRouterAbi } from "./abis/UserRouter";
import { getChainConfig, type ChainConfig } from "./chains";
import { useBrowsingChain } from "./ChainContext";

export { factoryAbi, vaultAbi, curatorRouterAbi, userRouterAbi };
export type { ChainConfig };

/**
 * Returns contract addresses for the current browsing chain.
 * Works whether or not a wallet is connected.
 */
export function useAddresses(): ChainConfig {
  const { browsingChainId } = useBrowsingChain();
  return getChainConfig(browsingChainId);
}

// ERC20 minimal ABI for approve + balanceOf
export const erc20Abi = [
  {
    type: "function",
    name: "approve",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "allowance",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "symbol",
    inputs: [],
    outputs: [{ type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "decimals",
    inputs: [],
    outputs: [{ type: "uint8" }],
    stateMutability: "view",
  },
] as const;
