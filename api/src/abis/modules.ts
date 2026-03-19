// KodiakModule.swap ABI
export const kodiakModuleAbi = [
  {
    type: "function",
    name: "swap",
    inputs: [
      { name: "tokenIn", type: "address" },
      { name: "wrapIn", type: "bool" },
      { name: "amountIn", type: "uint256" },
      { name: "tokenOut", type: "address" },
      { name: "unwrapOut", type: "bool" },
      { name: "minAmountOut", type: "uint256" },
      {
        name: "swapData",
        type: "tuple",
        components: [
          { name: "router", type: "address" },
          { name: "data", type: "bytes" },
        ],
      },
      {
        name: "feeData",
        type: "tuple",
        components: [
          { name: "feeQuote", type: "uint256" },
          { name: "surplusFeeBps", type: "uint16" },
          { name: "refCode", type: "uint16" },
          { name: "referrerFeeBps", type: "uint16" },
        ],
      },
    ],
    outputs: [],
    stateMutability: "payable",
  },
] as const;

// DolomiteModule ABI
export const dolomiteModuleAbi = [
  {
    type: "function",
    name: "supplyCollateral",
    inputs: [
      { name: "collateralAsset", type: "address" },
      { name: "_amount", type: "uint256" },
      { name: "_collateralMarketId", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "borrow",
    inputs: [
      { name: "_borrowAmount", type: "uint256" },
      { name: "_collateralMarketId", type: "uint256" },
      { name: "_borrowMarketId", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "repayDebt",
    inputs: [
      { name: "borrowAssetAddr", type: "address" },
      { name: "_amount", type: "uint256" },
      { name: "_collateralMarketId", type: "uint256" },
      { name: "_borrowMarketId", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "withdrawCollateral",
    inputs: [
      { name: "_amount", type: "uint256" },
      { name: "_collateralMarketId", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "repayDebtWithCollateral",
    inputs: [
      { name: "collateralAsset", type: "address" },
      { name: "borrowAssetAddr", type: "address" },
      { name: "minUSDCOut", type: "uint256" },
      { name: "expectedUSDCOut", type: "uint256" },
      { name: "pathDefinition", type: "bytes" },
      { name: "_collateralMarketId", type: "uint256" },
      { name: "_borrowMarketId", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "getPosition",
    inputs: [],
    outputs: [
      { name: "collateral", type: "uint256" },
      { name: "borrowed", type: "uint256" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "initializeModule",
    inputs: [],
    outputs: [],
    stateMutability: "payable",
  },
] as const;

// OrderlyModule ABI
export const orderlyModuleAbi = [
  {
    type: "function",
    name: "deposit",
    inputs: [
      { name: "depositAsset", type: "address" },
      {
        name: "data",
        type: "tuple",
        components: [
          { name: "accountId", type: "bytes32" },
          { name: "brokerHash", type: "bytes32" },
          { name: "tokenHash", type: "bytes32" },
          { name: "tokenAmount", type: "uint128" },
        ],
      },
      { name: "fee", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "delegateSigner",
    inputs: [
      {
        name: "data",
        type: "tuple",
        components: [
          { name: "brokerHash", type: "bytes32" },
          { name: "delegateSigner", type: "address" },
        ],
      },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "initializeModule",
    inputs: [{ name: "_orderlyVault", type: "address" }],
    outputs: [],
    stateMutability: "payable",
  },
] as const;
