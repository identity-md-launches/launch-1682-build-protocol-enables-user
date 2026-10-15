// The IdentityMD launch factory: the contract that deployed SwarmExit (deployment record txHash
// 0x325cd2…54a1c, launch 1682) and every swarm token. Only the views the site reads are listed;
// signatures were resolved from the deployed bytecode's selectors (openchain signature database).
export const factoryAbi = [
  {
    type: "function",
    name: "positionOf",
    stateMutability: "view",
    inputs: [{ name: "launchId", type: "uint64" }],
    outputs: [
      { name: "currency0", type: "address" },
      { name: "currency1", type: "address" },
      { name: "fee", type: "uint24" },
      { name: "tickSpacing", type: "int24" },
      { name: "hooks", type: "address" },
      { name: "tickLower", type: "int24" },
      { name: "tickUpper", type: "int24" },
      { name: "requester", type: "address" },
    ],
  },
  {
    type: "function",
    name: "deploymentBlock",
    stateMutability: "view",
    inputs: [{ name: "launchId", type: "uint64" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  { type: "function", name: "poolManager", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
] as const;
