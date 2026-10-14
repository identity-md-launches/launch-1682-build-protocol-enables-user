// Frontend configuration. The SwarmExit address comes from the launch handoff after deployment:
// paste it here (or in the page's address field). Never invent one.
window.SWARM_EXIT_CONFIG = {
  chainId: 1,
  chainName: "Ethereum",
  swarmExit: "",
  imd: "0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7",
  treasury: "0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB",
  // Slippage applied to every per-token minimum IMD, in basis points (300 = 3%).
  slippageBps: 300,
  // Seconds the sell transaction stays valid.
  deadlineSeconds: 600,
};
