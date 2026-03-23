export const factoryAbi = [
  // === Role constants ===
  {
    type: "function",
    name: "DEFAULT_ADMIN_ROLE",
    inputs: [],
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "DIRAC_ADMIN_ROLE",
    inputs: [],
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "view",
  },

  // === Vault creation ===
  {
    type: "function",
    name: "allVaults",
    inputs: [{ name: "index", type: "uint256" }],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "createVault",
    inputs: [
      { name: "name", type: "string" },
      { name: "symbol", type: "string" },
      { name: "depositToken", type: "address" },
      { name: "maxDeposit", type: "uint256" },
      { name: "templateId", type: "bytes32" },
      {
        name: "curatorFee",
        type: "tuple",
        components: [
          { name: "curatorFeeBps", type: "uint256" },
          { name: "curatorFeeRecipient", type: "address" },
        ],
      },
    ],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "nonpayable",
  },

  // === Emergency functions ===
  {
    type: "function",
    name: "emergencyEndCycle",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "emergencyExecute",
    inputs: [
      { name: "vault", type: "address" },
      { name: "module", type: "address" },
      { name: "data", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "emergencyPause",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "emergencyUnpause",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },

  // === Module management ===
  {
    type: "function",
    name: "getModule",
    inputs: [{ name: "moduleType", type: "bytes32" }],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "registerModule",
    inputs: [
      { name: "moduleType", type: "bytes32" },
      { name: "module", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "registeredModules",
    inputs: [{ name: "moduleType", type: "bytes32" }],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "removeModule",
    inputs: [{ name: "moduleType", type: "bytes32" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "moduleTypes",
    inputs: [{ name: "index", type: "uint256" }],
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "view",
  },

  // === Role management ===
  {
    type: "function",
    name: "getRoleAdmin",
    inputs: [{ name: "role", type: "bytes32" }],
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "grantRole",
    inputs: [
      { name: "role", type: "bytes32" },
      { name: "account", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "hasRole",
    inputs: [
      { name: "role", type: "bytes32" },
      { name: "account", type: "address" },
    ],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "renounceRole",
    inputs: [
      { name: "role", type: "bytes32" },
      { name: "callerConfirmation", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "revokeRole",
    inputs: [
      { name: "role", type: "bytes32" },
      { name: "account", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },

  // === Vault role grants/revokes ===
  {
    type: "function",
    name: "grantVaultCurator",
    inputs: [
      { name: "vault", type: "address" },
      { name: "curator", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "grantVaultOperator",
    inputs: [
      { name: "vault", type: "address" },
      { name: "operator", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "revokeVaultCurator",
    inputs: [
      { name: "vault", type: "address" },
      { name: "curator", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "revokeVaultOperator",
    inputs: [
      { name: "vault", type: "address" },
      { name: "operator", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },

  // === Asset whitelist queries ===
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
  {
    type: "function",
    name: "isVault",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },

  // === Curator router & operator ===
  {
    type: "function",
    name: "curatorRouter",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "setCuratorRouter",
    inputs: [{ name: "router", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "operator",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "setOperator",
    inputs: [{ name: "newOperator", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "updateOperator",
    inputs: [
      { name: "newOperator", type: "address" },
      { name: "protocolFeeBps", type: "uint256" },
      { name: "daoFeeBps", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },

  // === Protocol fees ===
  {
    type: "function",
    name: "protocolFees",
    inputs: [],
    outputs: [
      { name: "protocolFeeBps", type: "uint256" },
      { name: "daoFeeBps", type: "uint256" },
      { name: "protocolFeeRecipient", type: "address" },
      { name: "daoFeeRecipient", type: "address" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "setProtocolFee",
    inputs: [
      { name: "feeBps", type: "uint256" },
      { name: "recipient", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "setDaoFee",
    inputs: [
      { name: "feeBps", type: "uint256" },
      { name: "recipient", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },

  // === Template management ===
  {
    type: "function",
    name: "registerTemplate",
    inputs: [{ name: "templateId", type: "bytes32" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "registeredTemplates",
    inputs: [{ name: "templateId", type: "bytes32" }],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "removeTemplate",
    inputs: [{ name: "templateId", type: "bytes32" }],
    outputs: [],
    stateMutability: "nonpayable",
  },

  // === Deposit token management ===
  {
    type: "function",
    name: "whitelistDepositToken",
    inputs: [{ name: "token", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "removeDepositToken",
    inputs: [{ name: "token", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "whitelistedDepositTokens",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },

  // === Strategy asset management ===
  {
    type: "function",
    name: "whitelistStrategyAsset",
    inputs: [
      {
        name: "assetInfo",
        type: "tuple",
        components: [
          { name: "token", type: "address" },
          { name: "allowedPerpsAssets", type: "string[]" },
        ],
      },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "removeStrategyAsset",
    inputs: [{ name: "token", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "strategyAssetList",
    inputs: [{ name: "index", type: "uint256" }],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "whitelistedStrategyAssets",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ name: "token", type: "address" }],
    stateMutability: "view",
  },

  // === Vault info ===
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
  {
    type: "function",
    name: "vaultsByCurator",
    inputs: [
      { name: "curator", type: "address" },
      { name: "index", type: "uint256" },
    ],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },

  // === Perps module symbol ===
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

  // === Module lending config ===
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
  {
    type: "function",
    name: "setModuleLendingConfig",
    inputs: [
      { name: "moduleTypeHash", type: "bytes32" },
      { name: "token", type: "address" },
      { name: "config", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },

  // === Misc ===
  {
    type: "function",
    name: "supportsInterface",
    inputs: [{ name: "interfaceId", type: "bytes4" }],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },

  // === Events ===
  {
    type: "event",
    name: "DaoFeeUpdated",
    inputs: [
      { name: "feeBps", type: "uint256", indexed: false },
      { name: "recipient", type: "address", indexed: false },
    ],
  },
  {
    type: "event",
    name: "DepositTokenRemoved",
    inputs: [
      { name: "token", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "DepositTokenWhitelisted",
    inputs: [
      { name: "token", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "EmergencyAction",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "action", type: "string", indexed: false },
    ],
  },
  {
    type: "event",
    name: "ModuleRegistered",
    inputs: [
      { name: "moduleType", type: "bytes32", indexed: true },
      { name: "module", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "ModuleRemoved",
    inputs: [
      { name: "moduleType", type: "bytes32", indexed: true },
    ],
  },
  {
    type: "event",
    name: "ProtocolFeeUpdated",
    inputs: [
      { name: "feeBps", type: "uint256", indexed: false },
      { name: "recipient", type: "address", indexed: false },
    ],
  },
  {
    type: "event",
    name: "RoleAdminChanged",
    inputs: [
      { name: "role", type: "bytes32", indexed: true },
      { name: "previousAdminRole", type: "bytes32", indexed: true },
      { name: "newAdminRole", type: "bytes32", indexed: true },
    ],
  },
  {
    type: "event",
    name: "RoleGranted",
    inputs: [
      { name: "role", type: "bytes32", indexed: true },
      { name: "account", type: "address", indexed: true },
      { name: "sender", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "RoleRevoked",
    inputs: [
      { name: "role", type: "bytes32", indexed: true },
      { name: "account", type: "address", indexed: true },
      { name: "sender", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "StrategyAssetRemoved",
    inputs: [
      { name: "token", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "StrategyAssetWhitelisted",
    inputs: [
      { name: "token", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "ModuleLendingConfigSet",
    inputs: [
      { name: "moduleTypeHash", type: "bytes32", indexed: true },
      { name: "token", type: "address", indexed: true },
      { name: "config", type: "bytes", indexed: false },
    ],
  },
  {
    type: "event",
    name: "PerpsModuleSymbolSet",
    inputs: [
      { name: "token", type: "address", indexed: true },
      { name: "moduleTypeHash", type: "bytes32", indexed: true },
      { name: "symbol", type: "bytes", indexed: false },
    ],
  },
  {
    type: "event",
    name: "TemplateRegistered",
    inputs: [
      { name: "templateId", type: "bytes32", indexed: true },
    ],
  },
  {
    type: "event",
    name: "TemplateRemoved",
    inputs: [
      { name: "templateId", type: "bytes32", indexed: true },
    ],
  },
  {
    type: "event",
    name: "VaultCreated",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "curator", type: "address", indexed: true },
      { name: "depositToken", type: "address", indexed: true },
    ],
  },
] as const;
