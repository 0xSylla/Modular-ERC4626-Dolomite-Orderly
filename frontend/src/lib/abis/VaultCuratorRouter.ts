export const curatorRouterAbi = [
  // === Lifecycle ===
  {
    type: "function",
    name: "closeCycle",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
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
    name: "definePosition",
    inputs: [
      { name: "vault", type: "address" },
      { name: "collateralAsset", type: "address" },
      { name: "perpsAsset", type: "string" },
      { name: "allocation", type: "uint256" },
    ],
    outputs: [{ name: "positionId", type: "uint256" }],
    stateMutability: "nonpayable",
  },

  // === Execution ===
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

  // === View functions ===
  {
    type: "function",
    name: "factory",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
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
    name: "getPositionsCount",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
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
    name: "positionCount",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "positions",
    inputs: [
      { name: "vault", type: "address" },
      { name: "positionId", type: "uint256" },
    ],
    outputs: [
      { name: "id", type: "uint256" },
      { name: "vault", type: "address" },
      { name: "collateralAsset", type: "address" },
      { name: "perpsAsset", type: "string" },
      { name: "allocation", type: "uint256" },
      { name: "rebalanceThresholdBps", type: "uint256" },
      { name: "status", type: "uint8" },
    ],
    stateMutability: "view",
  },

  // === Deposit/withdrawal control ===
  {
    type: "function",
    name: "openDeposits",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "openWithdrawals",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },

  // === Position management ===
  {
    type: "function",
    name: "removePosition",
    inputs: [
      { name: "vault", type: "address" },
      { name: "positionId", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "requestClosingPosition",
    inputs: [
      { name: "vault", type: "address" },
      { name: "positionId", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
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
    name: "requestOpeningPosition",
    inputs: [
      { name: "vault", type: "address" },
      { name: "positionId", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "updatePosition",
    inputs: [
      { name: "vault", type: "address" },
      { name: "positionId", type: "uint256" },
      { name: "allocation", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },

  // === Vault legs ===
  {
    type: "function",
    name: "setVaultLegs",
    inputs: [
      { name: "vault", type: "address" },
      {
        name: "legs",
        type: "tuple",
        components: [
          { name: "swapModuleType", type: "bytes32" },
          { name: "lendingModuleType", type: "bytes32" },
          { name: "perpsModuleType", type: "bytes32" },
        ],
      },
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

  // === Trading ===
  {
    type: "function",
    name: "startTrading",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },

  // === Whitelist ===
  {
    type: "function",
    name: "whitelistTargetAsset",
    inputs: [
      { name: "vault", type: "address" },
      { name: "asset", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },

  // === Events ===
  {
    type: "event",
    name: "RebalanceRequested",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "positionId", type: "uint256", indexed: true },
    ],
  },
  {
    type: "event",
    name: "PositionRebalancing",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "positionId", type: "uint256", indexed: true },
    ],
  },
  {
    type: "event",
    name: "PositionRebalanced",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "positionId", type: "uint256", indexed: true },
    ],
  },
  {
    type: "event",
    name: "CloseRequested",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "positionId", type: "uint256", indexed: true },
    ],
  },
  {
    type: "event",
    name: "OpenRequested",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "positionId", type: "uint256", indexed: true },
    ],
  },
  {
    type: "event",
    name: "PositionClosed",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "positionId", type: "uint256", indexed: true },
    ],
  },
  {
    type: "event",
    name: "PositionDefined",
    inputs: [
      { name: "positionId", type: "uint256", indexed: true },
      { name: "collateralAsset", type: "address", indexed: true },
      { name: "perpsAsset", type: "string", indexed: false },
      { name: "allocation", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "PositionOpenConfirmed",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "positionId", type: "uint256", indexed: true },
    ],
  },
  {
    type: "event",
    name: "PositionOpening",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "positionId", type: "uint256", indexed: true },
    ],
  },
  {
    type: "event",
    name: "PositionRemoved",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "positionId", type: "uint256", indexed: true },
    ],
  },
  {
    type: "event",
    name: "PositionUpdated",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "positionId", type: "uint256", indexed: true },
      { name: "allocation", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "VaultLegsSet",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "swapModuleType", type: "bytes32", indexed: false },
      { name: "lendingModuleType", type: "bytes32", indexed: false },
      { name: "perpsModuleType", type: "bytes32", indexed: false },
    ],
  },
] as const;
