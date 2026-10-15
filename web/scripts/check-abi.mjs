// Checks that the committed ABI (web/src/abi/swarmExit.ts) is the one the launch deployed:
// keccak256 of the key-sorted, whitespace-free JSON must equal the abiHash in the deployment record.
import { keccak256, toBytes } from "viem";
import { swarmExitAbi } from "../src/abi/swarmExit.ts";
import { SWARM_EXIT_ABI_HASH } from "../src/abi/hash.ts";

const sortKeys = (v) =>
  Array.isArray(v) ? v.map(sortKeys) : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])])) : v;
const hash = keccak256(toBytes(JSON.stringify(sortKeys(swarmExitAbi)))).slice(2);
if (hash !== SWARM_EXIT_ABI_HASH) {
  console.error(`ABI hash mismatch: computed ${hash}, expected ${SWARM_EXIT_ABI_HASH}`);
  process.exit(1);
}
console.log(`ABI hash matches the deployment record: ${hash}`);
