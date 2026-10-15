// Owner configuration of the live SwarmExit, built from chain facts: the IMD route from the ETH/IMD
// pool with liquidity, the Chainlink ETH/USD feed, and one registration plus one v4 route per swarm
// token (its launch pool from the factory). Each call is one transaction signed by the owner wallet.
import { encodeAbiParameters, type Address, type Hash, type PublicClient, type WalletClient } from "viem";
import { swarmExitAbi } from "../abi/swarmExit.ts";
import { CHAINLINK_ETH_USD_ADDRESS, IMD_ADDRESS, NATIVE, POOL_MANAGER_ADDRESS, SWARM_EXIT_ADDRESS } from "../constants.ts";
import type { Launch, PoolKey } from "./launches.ts";

const exit = { address: SWARM_EXIT_ADDRESS, abi: swarmExitAbi } as const;
const VENUE_V4 = 3;
const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

const hopParams = [
  { type: "address" },
  {
    type: "tuple[]",
    components: [
      { name: "currencyOut", type: "address" },
      { name: "fee", type: "uint24" },
      { name: "tickSpacing", type: "int24" },
      { name: "hooks", type: "address" },
    ],
  },
] as const;

/** abi.encode(address currencyIn, V4Hop[] hops) for a one-hop v4 route. */
export function v4RouteData(currencyIn: Address, key: PoolKey): `0x${string}` {
  const currencyOut = same(key.currency0, currencyIn) ? key.currency1 : key.currency0;
  return encodeAbiParameters(hopParams, [currencyIn, [{ currencyOut, fee: key.fee, tickSpacing: key.tickSpacing, hooks: key.hooks }]]);
}

/** A launch the contract can sell: paired with IMD on its v4 pool. */
export const routable = (l: Launch) => same(l.pair, IMD_ADDRESS);

export type OwnerStep = { label: string; run: () => Promise<Hash> };

export function setupSteps(
  wallet: WalletClient,
  client: PublicClient,
  account: Address,
  opts: { imdPool: PoolKey | null; imdRouteSet: boolean; feedSet: boolean; register: Launch[] },
): OwnerStep[] {
  const write = (functionName: "setImdRoute" | "setEthUsdFeed" | "setSwarmToken" | "setTokenRoute", args: readonly unknown[]) => async () => {
    const hash = await wallet.writeContract({ ...exit, functionName, args: args as never, account, chain: wallet.chain } as never);
    await client.waitForTransactionReceipt({ hash });
    return hash;
  };
  const steps: OwnerStep[] = [];
  if (!opts.imdRouteSet && opts.imdPool) {
    steps.push({ label: "Set the ETH to IMD route", run: write("setImdRoute", [VENUE_V4, POOL_MANAGER_ADDRESS, NATIVE, v4RouteData(NATIVE, opts.imdPool)]) });
  }
  if (!opts.feedSet) steps.push({ label: "Set the ETH/USD price feed", run: write("setEthUsdFeed", [CHAINLINK_ETH_USD_ADDRESS]) });
  for (const l of opts.register) {
    steps.push({ label: `Register launch ${l.id}`, run: write("setSwarmToken", [l.token, true]) });
    steps.push({ label: `Set the route of launch ${l.id}`, run: write("setTokenRoute", [l.token, VENUE_V4, POOL_MANAGER_ADDRESS, NATIVE, v4RouteData(l.token, l.key)]) });
  }
  return steps;
}
