export const vaultAbi = [
  {
    "type": "function",
    "name": "executeModule",
    "inputs": [
      { "name": "module", "type": "address", "internalType": "address" },
      { "name": "data", "type": "bytes", "internalType": "bytes" }
    ],
    "outputs": [{ "name": "", "type": "bytes", "internalType": "bytes" }],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "executeBatch",
    "inputs": [
      { "name": "modules", "type": "address[]", "internalType": "address[]" },
      { "name": "datas", "type": "bytes[]", "internalType": "bytes[]" }
    ],
    "outputs": [{ "name": "results", "type": "bytes[]", "internalType": "bytes[]" }],
    "stateMutability": "payable"
  }
] as const;
