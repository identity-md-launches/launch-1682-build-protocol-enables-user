// Reads a wallet exactly the way the site does, against the live chain, and prints what the page
// would list. From web/: `node --experimental-strip-types scripts/read-wallet.mjs [address]`.
// Default address: the launch owner 0x0acE…4782, the brief's test case.
import { pathToFileURL } from "node:url";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const { createPublicClient, http, formatUnits } = await import(pathToFileURL(path.join(here, "../node_modules/viem/_esm/index.js")).href);
const { chain, PUBLIC_RPC_URL } = await import(pathToFileURL(path.join(here, "../src/chain.ts")).href);
const { LAUNCH_SCAN_BATCH } = await import(pathToFileURL(path.join(here, "../src/constants.ts")).href);
const { loadWallet, STATUS_TEXT } = await import(pathToFileURL(path.join(here, "../src/lib/sweep.ts")).href);

const account = process.argv[2] ?? "0x0acE1DBE8AAb293cd58D5e3Ea38814f0ccb74782";
const client = createPublicClient({ chain, transport: http(PUBLIC_RPC_URL, { batch: { batchSize: LAUNCH_SCAN_BATCH, wait: 16 }, retryCount: 5 }) });
const { discoverLaunches } = await import(pathToFileURL(path.join(here, "../src/lib/launches.ts")).href);
let t0 = Date.now();
const launches = await discoverLaunches(client);
console.log(`discovery: ${launches.length} token launches (ids ${launches[0]?.id}..${launches.at(-1)?.id}) in ${Date.now() - t0} ms`);
t0 = Date.now();
const state = await loadWallet(client, account);
console.log(`wallet ${account}: ${state.launches.length} token launches known, ${state.tokens.length} held, ${state.tokens.filter((t) => t.sellable).length} sellable now; read in ${Date.now() - t0} ms`);
console.log(`contract: owner ${state.setup.owner}, registered ${state.setup.registered.length}, IMD route ${state.setup.imdRouteSet ? "set" : "missing"}, feed ${state.setup.feedSet ? "set" : "missing"}, paused ${state.paused}`);
console.log(`pricing: ${state.pricing ? `1 IMD = $${state.pricing.imdUsd.toFixed(4)} (ETH $${state.pricing.ethUsd.toFixed(2)}, ${state.pricing.source})` : state.pricingError}`);
for (const t of state.tokens) {
  const usd = state.pricing && t.quoteSource ? ` $${((Number(t.expectedImd) / 1e18) * state.pricing.imdUsd).toFixed(2)}` : "";
  console.log(
    `${t.sellable ? "SELL " : "     "}${t.symbol.padEnd(10)} launch ${String(t.launch?.id ?? "-").padEnd(5)} ${formatUnits(t.balance, t.decimals).padStart(24)}  ${t.quoteSource ? `${formatUnits(t.expectedImd, 18)} IMD (${t.quoteSource})${usd}` : "no quote"}  ${STATUS_TEXT[t.status]}`,
  );
}
