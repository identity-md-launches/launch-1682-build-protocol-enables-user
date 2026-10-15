// Ethereum mainnet, built from the network table supplied with the launch (.imd/reads/network.json).
import { defineChain } from "viem";

export const RPC_URLS = ["https://ethereum-rpc.publicnode.com", "https://eth.drpc.org"] as const;
export const PUBLIC_RPC_URL = RPC_URLS[0];

export const chain = defineChain({
  id: 1,
  name: "Ethereum",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [...RPC_URLS] } },
  blockExplorers: { default: { name: "Etherscan", url: "https://etherscan.io" } },
});

/** Parameters for wallet_addEthereumChain, from the same table. */
export const WALLET_ADD_CHAIN = {
  chainId: "0x1",
  chainName: "Ethereum",
  rpcUrls: [...RPC_URLS],
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  blockExplorerUrls: ["https://etherscan.io"],
};
