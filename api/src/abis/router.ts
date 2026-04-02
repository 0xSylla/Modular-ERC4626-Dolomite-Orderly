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
          { name: "status", type: "uint8" },
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
      { name: "moduleTypes", type: "bytes32[]" },
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
      { name: "moduleTypes", type: "bytes32[]" },
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
      { name: "moduleTypes", type: "bytes32[]" },
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
      { name: "moduleTypes", type: "bytes32[]" },
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
      { name: "moduleType", type: "bytes32" },
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
      { name: "moduleType", type: "bytes32" },
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
      { name: "moduleTypes", type: "bytes32[]" },
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
  {
    type: "function",
    name: "vaultLegs",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [
      { name: "swapModuleType", type: "bytes32" },
      { name: "lendingModuleType", type: "bytes32" },
      { name: "perpsModuleType", type: "bytes32" },
    ],
    stateMutability: "view",
  },
] as const;
