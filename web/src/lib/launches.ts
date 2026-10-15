// Discovery of swarm-launched tokens from the IdentityMD launch factory, independent of what the
// SwarmExit owner has registered. Each token launch has one Uniswap v4 pool against IMD (or FWA);
// positionOf(launchId) returns its pool key, so the route to sell it is known from the chain.
import { encodeAbiParameters, keccak256, type Address, type Hex, type PublicClient } from "viem";
import { factoryAbi } from "../abi/factory.ts";
import {
  FWA_ADDRESS,
  IMD_ADDRESS,
  LAUNCH_FACTORY_ADDRESS,
  LAUNCH_SCAN_BATCH,
  LAUNCH_SCAN_GAP,
  LAUNCH_SCAN_MAX_ID,
  LAUNCH_SCAN_PAUSE_MS,
  NATIVE,
  SWARM_EXIT_DEPLOY_BLOCK,
  SWARM_EXIT_LAUNCH_ID,
} from "../constants.ts";

export type PoolKey = { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };

export type Launch = {
  id: number;
  /** The swarm token: the pool currency that is not a pair currency. */
  token: Address;
  /** What the token trades against: IMD, FWA or native ETH. */
  pair: Address;
  key: PoolKey;
  requester: Address;
};

const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
const isPair = (a: Address) => same(a, IMD_ADDRESS) || same(a, FWA_ADDRESS) || same(a, NATIVE);
const factory = { address: LAUNCH_FACTORY_ADDRESS, abi: factoryAbi } as const;

export function poolId(key: PoolKey): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
      [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks],
    ),
  );
}

export class FactoryMismatch extends Error {}

/** A revert or empty answer from the contract: treat as "no such thing". Anything else (a rate
 * limit, a network failure) is rethrown, so the page says it could not read rather than listing less. */
export function nullOnRevert(e: unknown): null {
  const cause = (e as { cause?: { name?: string } })?.cause;
  const name = cause?.name ?? (e as { name?: string })?.name ?? "";
  if (/ContractFunctionReverted|ContractFunctionZeroData|AbiDecodingZeroData|ContractFunctionExecution/.test(name) && !/HttpRequest|RpcRequest|TimeoutError|LimitExceeded/.test(String((cause as { cause?: { name?: string } })?.cause?.name ?? ""))) return null;
  throw e;
}

const pause = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Proves the configured factory is the one that deployed SwarmExit, using the deployment record. */
export async function verifyFactory(client: PublicClient): Promise<void> {
  const block = await client.readContract({ ...factory, functionName: "deploymentBlock", args: [SWARM_EXIT_LAUNCH_ID] });
  if (block !== SWARM_EXIT_DEPLOY_BLOCK) {
    throw new FactoryMismatch(`The launch factory does not report SwarmExit's deployment block (${block} vs ${SWARM_EXIT_DEPLOY_BLOCK}).`);
  }
}

let cache: Promise<Launch[]> | null = null;

/** Every token launch the factory knows, scanned by launch id. Cached for the page's life. */
export function discoverLaunches(client: PublicClient): Promise<Launch[]> {
  if (!cache) {
    cache = scan(client).catch((e) => {
      cache = null;
      throw e;
    });
  }
  return cache;
}

async function scan(client: PublicClient): Promise<Launch[]> {
  await verifyFactory(client);
  const launches: Launch[] = [];
  let gap = 0;
  for (let start = 1; start <= LAUNCH_SCAN_MAX_ID; start += LAUNCH_SCAN_BATCH) {
    const ids = Array.from({ length: LAUNCH_SCAN_BATCH }, (_, i) => start + i);
    const rows = await Promise.all(
      ids.map((id) => client.readContract({ ...factory, functionName: "positionOf", args: [BigInt(id)] }).catch(nullOnRevert)),
    );
    if (start > 1) await pause(LAUNCH_SCAN_PAUSE_MS);
    for (let i = 0; i < rows.length; i += 1) {
      const row = rows[i];
      if (!row || same(row[0], NATIVE) && same(row[1], NATIVE)) {
        gap += 1;
        continue;
      }
      const [currency0, currency1, fee, tickSpacing, hooks, , , requester] = row;
      if (same(currency0, NATIVE) && same(currency1, NATIVE)) {
        gap += 1;
        continue;
      }
      gap = 0;
      const token = isPair(currency0) && !isPair(currency1) ? currency1 : currency0;
      const pair = same(token, currency0) ? currency1 : currency0;
      launches.push({ id: ids[i]!, token, pair, key: { currency0, currency1, fee, tickSpacing, hooks }, requester });
    }
    if (launches.length > 0 && gap >= LAUNCH_SCAN_GAP) break;
  }
  return launches;
}
