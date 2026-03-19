// Factory ABI — only functions needed by the API
// Most factory state is public (auto-getters: registeredModules, vaultInfo, etc.)
export const factoryAbi = [
  {
    type: "function",
    name: "getModule",
    inputs: [{ name: "moduleType", type: "bytes32" }],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isVault",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isPerpsAssetAllowed",
    inputs: [
      { name: "collateralAsset", type: "address" },
      { name: "perpsAsset", type: "string" },
    ],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isStrategyAssetWhitelisted",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  // Auto-getter for public mapping: vaultInfo(address)
  // Returns flattened tuple (no struct wrapper)
  {
    type: "function",
    name: "vaultInfo",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [
      { name: "vault", type: "address" },
      { name: "creator", type: "address" },
      { name: "templateId", type: "bytes32" },
      { name: "deployedAt", type: "uint256" },
    ],
    stateMutability: "view",
  },
  // Auto-getter for public mapping: whitelistedStrategyAssets(address)
  // Note: auto-getter omits dynamic array (allowedPerpsAssets), returns only fixed fields
  {
    type: "function",
    name: "whitelistedStrategyAssets",
    inputs: [{ name: "token", type: "address" }],
    outputs: [
      { name: "token", type: "address" },
    ],
    stateMutability: "view",
  },
  // moduleLendingConfig(moduleTypeHash, token) => bytes (e.g. abi.encode(uint256 marketId))
  {
    type: "function",
    name: "moduleLendingConfig",
    inputs: [
      { name: "moduleTypeHash", type: "bytes32" },
      { name: "token", type: "address" },
    ],
    outputs: [{ name: "", type: "bytes" }],
    stateMutability: "view",
  },
  // perpsModuleSymbol(token, moduleTypeHash) => bytes
  {
    type: "function",
    name: "perpsModuleSymbol",
    inputs: [
      { name: "token", type: "address" },
      { name: "moduleTypeHash", type: "bytes32" },
    ],
    outputs: [{ name: "", type: "bytes" }],
    stateMutability: "view",
  },
  // setPerpsModuleSymbol — admin only
  {
    type: "function",
    name: "setPerpsModuleSymbol",
    inputs: [
      { name: "token", type: "address" },
      { name: "moduleTypeHash", type: "bytes32" },
      { name: "symbol", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  // Auto-getter for public mapping: registeredTemplates(bytes32)
  {
    type: "function",
    name: "registeredTemplates",
    inputs: [{ name: "templateId", type: "bytes32" }],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
] as const;
