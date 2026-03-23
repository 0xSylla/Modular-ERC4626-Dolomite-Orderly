// VaultCuratorRouter ABI — only functions needed by the API
export const routerAbi = [
  {
    type: "function",
    name: "getPosition",
    inputs: [
      { name: "vault", type: "address" },
      { name: "positionId", type: "uint256" },
    ],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "id", type: "uint256" },
          { name: "vault", type: "address" },
          { name: "collateralAsset", type: "address" },
          { name: "perpsAsset", type: "string" },
          { name: "allocation", type: "uint256" },
          { name: "rebalanceThresholdBps", type: "uint256" },
          { name: "status", type: "uint8" },
          {
            name: "legs",
            type: "tuple",
            components: [
              { name: "swapModule", type: "address" },
              { name: "lendingModule", type: "address" },
              { name: "perpsModule", type: "address" },
            ],
          },
        ],
      },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "executeOpeningRequest",
    inputs: [
      { name: "vault", type: "address" },
      { name: "positionId", type: "uint256" },
      { name: "modules", type: "address[]" },
      { name: "datas", type: "bytes[]" },
    ],
    outputs: [{ name: "results", type: "bytes[]" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "confirmOpen",
    inputs: [
      { name: "vault", type: "address" },
      { name: "positionId", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "executeClosingRequest",
    inputs: [
      { name: "vault", type: "address" },
      { name: "positionId", type: "uint256" },
      { name: "modules", type: "address[]" },
      { name: "datas", type: "bytes[]" },
    ],
    outputs: [{ name: "results", type: "bytes[]" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "executeRebalanceClose",
    inputs: [
      { name: "vault", type: "address" },
      { name: "positionId", type: "uint256" },
      { name: "modules", type: "address[]" },
      { name: "datas", type: "bytes[]" },
    ],
    outputs: [{ name: "results", type: "bytes[]" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "executeRebalanceOpen",
    inputs: [
      { name: "vault", type: "address" },
      { name: "positionId", type: "uint256" },
      { name: "modules", type: "address[]" },
      { name: "datas", type: "bytes[]" },
    ],
    outputs: [{ name: "results", type: "bytes[]" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "setupModule",
    inputs: [
      { name: "vault", type: "address" },
      { name: "module", type: "address" },
      { name: "data", type: "bytes" },
    ],
    outputs: [{ name: "", type: "bytes" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "executeModule",
    inputs: [
      { name: "vault", type: "address" },
      { name: "module", type: "address" },
      { name: "data", type: "bytes" },
    ],
    outputs: [{ name: "", type: "bytes" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "executeBatch",
    inputs: [
      { name: "vault", type: "address" },
      { name: "modules", type: "address[]" },
      { name: "datas", type: "bytes[]" },
    ],
    outputs: [{ name: "results", type: "bytes[]" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "nextPositionId",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "requestRebalance",
    inputs: [
      { name: "vault", type: "address" },
      { name: "positionId", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;
