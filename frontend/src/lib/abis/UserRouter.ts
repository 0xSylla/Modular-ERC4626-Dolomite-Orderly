export const userRouterAbi = [
  {
    type: "function",
    name: "batchDeposit",
    inputs: [
      { name: "vaults", type: "address[]" },
      { name: "amounts", type: "uint256[]" },
      { name: "receivers", type: "address[]" },
    ],
    outputs: [{ name: "sharesArray", type: "uint256[]" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "depositIntoVault",
    inputs: [
      { name: "vault", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "receiver", type: "address" },
    ],
    outputs: [{ name: "shares", type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "factory",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getVaultInfo",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [
      { name: "totalAssets", type: "uint256" },
      { name: "cycleStatus", type: "uint8" },
      { name: "sharePrice", type: "uint256" },
      { name: "maxDeposit", type: "uint256" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "previewDeposit",
    inputs: [
      { name: "vault", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "previewWithdraw",
    inputs: [
      { name: "vault", type: "address" },
      { name: "assets", type: "uint256" },
    ],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "redeemFromVault",
    inputs: [
      { name: "vault", type: "address" },
      { name: "shares", type: "uint256" },
      { name: "receiver", type: "address" },
    ],
    outputs: [{ name: "assets", type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "withdrawFromVault",
    inputs: [
      { name: "vault", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "receiver", type: "address" },
    ],
    outputs: [{ name: "shares", type: "uint256" }],
    stateMutability: "nonpayable",
  },
] as const;
