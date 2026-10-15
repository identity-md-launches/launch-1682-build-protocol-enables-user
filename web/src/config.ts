// The site's wagmi configuration: chain, RPC transport and wallet connectors. Addresses live in
// constants.ts and are re-exported here.
import { createConfig, http } from "wagmi";
import { coinbaseWallet, injected } from "wagmi/connectors";
import { chain, PUBLIC_RPC_URL } from "./chain";
import { LAUNCH_SCAN_BATCH, SITE_NAME } from "./constants";

export * from "./constants";

export const config = createConfig({
  chains: [chain],
  // EIP-6963 discovery lists every installed extension under its own name
  multiInjectedProviderDiscovery: true,
  connectors: [injected(), coinbaseWallet({ appName: SITE_NAME })],
  // Reads issued in the same tick travel as one JSON-RPC batch (the public RPC answers 100 per batch).
  transports: { [chain.id]: http(PUBLIC_RPC_URL, { batch: { batchSize: LAUNCH_SCAN_BATCH, wait: 16 }, retryCount: 5 }) },
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
