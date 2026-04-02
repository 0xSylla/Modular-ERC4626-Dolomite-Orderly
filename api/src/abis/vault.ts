export const vaultAbi = [
  {
    "type": "function",
    "name": "executeModule",
    "inputs": [
      { "name": "moduleType", "type": "bytes32", "internalType": "bytes32" },
      { "name": "data", "type": "bytes", "internalType": "bytes" }
    ],
    "outputs": [{ "name": "", "type": "bytes", "internalType": "bytes" }],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "executeBatch",
    "inputs": [
      { "name": "moduleTypes", "type": "bytes32[]", "internalType": "bytes32[]" },
      { "name": "datas", "type": "bytes[]", "internalType": "bytes[]" }
    ],
    "outputs": [{ "name": "results", "type": "bytes[]", "internalType": "bytes[]" }],
    "stateMutability": "payable"
  }
] as const;
