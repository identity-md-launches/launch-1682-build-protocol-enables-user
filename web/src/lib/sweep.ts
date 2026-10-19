// Reads and writes against SwarmExit. Every function here takes viem clients and returns plain data;
// the components decide how to show it.
import { parseEventLogs, parseUnits, type Address, type Hash, type PublicClient, type WalletClient } from "viem";
import { swarmExitAbi } from "../abi/swarmExit.ts";
import { erc20Abi } from "../abi/erc20.ts";
import { aggregatorAbi, stateViewAbi, v4QuoterAbi } from "../abi/v4.ts";
import {
  BPS,
  CHAINLINK_ETH_USD_ADDRESS,
  CHAINLINK_ETH_USD_DESCRIPTION,
  DEADLINE_SECONDS,
  DEFAULT_MAX_TOKENS_PER_SALE,
  ETH_IMD_FEE_TIERS,
  FEE_BPS,
  IMD_ADDRESS,
  IMD_DECIMALS,
  MAX_PRICE_AGE_SECONDS,
  NATIVE,
  PREVIEW_CHUNK,
  SLIPPAGE_BPS,
  STATE_VIEW_ADDRESS,
  SWARM_EXIT_ADDRESS,
  V4_QUOTER_ADDRESS,
} from "../constants.ts";
import { discoverLaunches, nullOnRevert, poolId, type Launch, type PoolKey } from "./launches.ts";
import { errorText, fmtAmount, short } from "./format.ts";
import { assertWalletContext, confirmedReceipt, transactionHash } from "./transactions.ts";

/** SwarmExit.Status, in declaration order. */
export const STATUS_TEXT = [
  "Sellable",
  "Not registered in SwarmExit yet",
  "No balance",
  "No sale route configured",
  "IMD route not configured",
  "No liquidity (quote failed)",
  "Below the minimum proceeds",
  "Sale would fail on chain",
  "Price impact too high",
  "Not approved",
] as const;
export const STATUS_SOLD = 0;
export const STATUS_NOT_REGISTERED = 1;
export const STATUS_NO_ROUTE = 3;

export type SellRoute = { venue: number; tokenOut: Address };

export type SwarmToken = {
  address: Address;
  symbol: string;
  decimals: number;
  balance: bigint;
  /** Expected IMD, gross before the fee: the contract's quote when registered, else the pool's. */
  expectedImd: bigint;
  /** Where expectedImd came from; null when nothing could quote it. */
  quoteSource: "contract" | "pool" | null;
  sellable: boolean;
  status: number;
  route: SellRoute | null;
  /** Human label of the sell route, or null when the contract has none for this token. */
  routeLabel: string | null;
  /** The launch the factory recorded for this token, if any. */
  launch: Launch | null;
  heldRefund: bigint;
  /** Set after a sale transaction. */
  result?: SaleResult;
};

export type SaleResult =
  | { kind: "sold"; imdOut: bigint; txHash: Hash }
  | { kind: "unsold"; reason: string; txHash?: Hash; held?: boolean; heldAmount?: bigint };

export type Pricing = { imdUsd: number; ethUsd: number; source: "contract" | "pool" };

export type ContractSetup = {
  owner: Address;
  imdRouteSet: boolean;
  feedSet: boolean;
  registered: Address[];
  /** Configured routes for registered tokens; null means no route. */
  routes: Record<string, SellRoute | null>;
  /** The ETH/IMD pool with the most liquidity among the hookless fee tiers, or null. */
  imdPool: PoolKey | null;
};

export type WalletState = {
  tokens: SwarmToken[];
  pricing: Pricing | null;
  pricingError: string | null;
  paused: boolean;
  maxPerSale: number;
  minImdOut: bigint;
  /** Every token launch the factory knows. */
  launches: Launch[];
  setup: ContractSetup;
};

export type PlanItem = { token: SwarmToken; imdOut: bigint; approvalRequired?: boolean; estimated?: boolean };
export type Plan = {
  items: PlanItem[];
  excluded: { token: SwarmToken; reason: string }[];
  gross: bigint;
  fee: bigint;
  net: bigint;
};

const exit = { address: SWARM_EXIT_ADDRESS, abi: swarmExitAbi } as const;
const deadline = () => BigInt(Math.floor(Date.now() / 1000) + DEADLINE_SECONDS);
const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

export function describeRoute(route: SellRoute | null): string | null {
  if (!route || route.venue === 0) return null;
  const venue = route.venue === 1 ? "Uniswap V2" : route.venue === 2 ? "Uniswap V3" : "Uniswap v4";
  const end = same(route.tokenOut, IMD_ADDRESS) ? "IMD" : "ETH, then IMD";
  return `${venue} to ${end}`;
}

export function usdValue(imd: bigint, pricing: Pricing | null): number | null {
  if (!pricing) return null;
  return (Number(imd) / 10 ** IMD_DECIMALS) * pricing.imdUsd;
}

export function feeSplit(gross: bigint) {
  const fee = (gross * FEE_BPS) / BPS;
  return { fee, net: gross - fee };
}

/** The ETH/IMD v4 pool with the most liquidity among the standard hookless tiers. */
export async function findImdPool(client: PublicClient): Promise<PoolKey | null> {
  const keys: PoolKey[] = ETH_IMD_FEE_TIERS.map((t) => ({ currency0: NATIVE, currency1: IMD_ADDRESS, fee: t.fee, tickSpacing: t.tickSpacing, hooks: NATIVE }));
  const liquidity = await Promise.all(
    keys.map((k) => client.readContract({ address: STATE_VIEW_ADDRESS, abi: stateViewAbi, functionName: "getLiquidity", args: [poolId(k)] }).catch(() => 0n)),
  );
  let best = -1;
  for (let i = 0; i < keys.length; i += 1) if (liquidity[i]! > 0n && (best < 0 || liquidity[i]! > liquidity[best]!)) best = i;
  return best < 0 ? null : keys[best]!;
}

/** Sell quote of `amountIn` of the launch's token through its own pool, in the pair currency. */
export async function quoteThroughPool(client: PublicClient, key: PoolKey, tokenIn: Address, amountIn: bigint): Promise<bigint | null> {
  if (amountIn <= 0n || amountIn > 2n ** 128n - 1n) return null;
  try {
    const { result } = await client.simulateContract({
      address: V4_QUOTER_ADDRESS,
      abi: v4QuoterAbi,
      functionName: "quoteExactInputSingle",
      args: [{ poolKey: key, zeroForOne: same(tokenIn, key.currency0), exactAmount: amountIn, hookData: "0x" }],
    });
    return result[0];
  } catch {
    return null;
  }
}

async function loadPricing(client: PublicClient, account: Address, imdPool: PoolKey | null): Promise<{ pricing: Pricing | null; error: string | null }> {
  const oneImd = parseUnits("1", IMD_DECIMALS);
  // The contract's own pricing, once the owner has set the IMD route and the feed.
  try {
    const [{ result: bridgePerImd }, [price, decimals]] = await Promise.all([
      client.simulateContract({ ...exit, functionName: "quoteImdInBridge", args: [oneImd], account }),
      client.readContract({ ...exit, functionName: "ethUsdPrice" }),
    ]);
    const ethUsd = Number(price) / 10 ** Number(decimals);
    return { pricing: { imdUsd: (Number(bridgePerImd) / 1e18) * ethUsd, ethUsd, source: "contract" }, error: null };
  } catch {
    /* not configured yet: price from the pool and the feed directly */
  }
  try {
    if (!imdPool) throw new Error("No ETH/IMD pool with liquidity was found.");
    const feed = { address: CHAINLINK_ETH_USD_ADDRESS, abi: aggregatorAbi } as const;
    const [ethPerImd, description, decimals, round] = await Promise.all([
      quoteThroughPool(client, imdPool, IMD_ADDRESS, oneImd),
      client.readContract({ ...feed, functionName: "description" }),
      client.readContract({ ...feed, functionName: "decimals" }),
      client.readContract({ ...feed, functionName: "latestRoundData" }),
    ]);
    if (description !== CHAINLINK_ETH_USD_DESCRIPTION) throw new Error(`The price feed describes itself as "${description}", not "${CHAINLINK_ETH_USD_DESCRIPTION}".`);
    const [, answer, , updatedAt] = round;
    if (answer <= 0n) throw new Error("The price feed returned no price.");
    if (Math.floor(Date.now() / 1000) - Number(updatedAt) > MAX_PRICE_AGE_SECONDS) throw new Error("The ETH/USD price is stale.");
    if (ethPerImd === null) throw new Error("IMD could not be priced in ETH.");
    const ethUsd = Number(answer) / 10 ** Number(decimals);
    return { pricing: { imdUsd: (Number(ethPerImd) / 1e18) * ethUsd, ethUsd, source: "pool" }, error: null };
  } catch (e) {
    return { pricing: null, error: e instanceof Error ? e.message.split("\n")[0]! : String(e) };
  }
}

type PreviewRow = { token: Address; balance: bigint; expectedImd: bigint; sellable: boolean; status: number };

async function previewChunked(client: PublicClient, account: Address, tokens: Address[]): Promise<Map<string, PreviewRow>> {
  const out = new Map<string, PreviewRow>();
  for (let i = 0; i < tokens.length; i += PREVIEW_CHUNK) {
    const chunk = tokens.slice(i, i + PREVIEW_CHUNK);
    try {
      const { result } = await client.simulateContract({ ...exit, functionName: "preview", args: [account, chunk], account });
      for (const p of result) out.set(p.token.toLowerCase(), { ...p, status: Number(p.status) });
    } catch {
      // one token at a time, so a single reverting token cannot hide the others
      for (const t of chunk) {
        try {
          const { result } = await client.simulateContract({ ...exit, functionName: "preview", args: [account, [t]], account });
          for (const p of result) out.set(p.token.toLowerCase(), { ...p, status: Number(p.status) });
        } catch {
          out.set(t.toLowerCase(), { token: t, balance: 0n, expectedImd: 0n, sellable: false, status: 5 });
        }
      }
    }
  }
  return out;
}

/** Everything the page shows for one wallet: its swarm tokens, routes, previews and prices. */
export async function loadWallet(client: PublicClient, account: Address): Promise<WalletState> {
  const [launches, registered, owner, paused, maxPerSaleRaw, minImdOut, imdRoute, feed, imdPool] = await Promise.all([
    discoverLaunches(client),
    client.readContract({ ...exit, functionName: "swarmTokens" }),
    client.readContract({ ...exit, functionName: "owner" }),
    client.readContract({ ...exit, functionName: "paused" }).catch(() => false),
    client.readContract({ ...exit, functionName: "MAX_TOKENS_PER_SALE" }).catch(() => BigInt(DEFAULT_MAX_TOKENS_PER_SALE)),
    client.readContract({ ...exit, functionName: "minImdOut" }).catch(() => 0n),
    client.readContract({ ...exit, functionName: "imdRoute" }).catch(() => null),
    client.readContract({ ...exit, functionName: "ethUsdFeed" }).catch(() => NATIVE),
    findImdPool(client),
  ]);

  // The universe: every factory launch plus anything the owner registered by hand.
  const byToken = new Map<string, Launch | null>();
  for (const l of launches) byToken.set(l.token.toLowerCase(), l);
  for (const t of registered) if (!byToken.has(t.toLowerCase())) byToken.set(t.toLowerCase(), null);
  const universe = [...byToken.keys()] as Address[];

  const routeEntries = await Promise.all(registered.map(async (t) => {
    const r = await client.readContract({ ...exit, functionName: "tokenRoute", args: [t] });
    return [t.toLowerCase(), r.venue === 0 ? null : { venue: r.venue, tokenOut: r.tokenOut }] as const;
  }));
  const routes: ContractSetup["routes"] = Object.fromEntries(routeEntries);

  const [balances, held] = await Promise.all([
    Promise.all(universe.map((t) => client.readContract({ address: t, abi: erc20Abi, functionName: "balanceOf", args: [account] }).catch((e) => nullOnRevert(e) ?? 0n))),
    Promise.all(universe.map((t) => client.readContract({ ...exit, functionName: "heldRefunds", args: [account, t] }).catch((e) => nullOnRevert(e) ?? 0n))),
  ]);
  // Only what the wallet actually holds (or has waiting as a held refund) is listed.
  const inWallet = universe.map((t, i) => ({ t, balance: balances[i]!, heldRefund: held[i]! })).filter((x) => x.balance > 0n || x.heldRefund > 0n);

  const [previews, priced] = await Promise.all([
    previewChunked(client, account, inWallet.map((x) => x.t)),
    loadPricing(client, account, imdPool),
  ]);

  const tokens = await Promise.all(
    inWallet.map(async ({ t, balance, heldRefund }): Promise<SwarmToken> => {
      const erc = { address: t, abi: erc20Abi } as const;
      const launch = byToken.get(t.toLowerCase()) ?? null;
      const p = previews.get(t.toLowerCase());
      const isRegistered = registered.some((r) => same(r, t));
      const [symbol, decimals] = await Promise.all([
        client.readContract({ ...erc, functionName: "symbol" }).catch(() => short(t)),
        client.readContract({ ...erc, functionName: "decimals" }).catch(() => 18),
      ]);
      const route = routes[t.toLowerCase()] ?? null;
      let expectedImd = p?.expectedImd ?? 0n;
      let quoteSource: SwarmToken["quoteSource"] = p && p.status === STATUS_SOLD ? "contract" : null;
      // Not registered yet: quote through the launch pool so the holder still sees what it is worth.
      if (!isRegistered && launch && same(launch.pair, IMD_ADDRESS) && balance > 0n) {
        const q = await quoteThroughPool(client, launch.key, t, balance);
        if (q !== null && q > 0n) {
          expectedImd = q;
          quoteSource = "pool";
        }
      }
      return {
        address: t,
        symbol: String(symbol).slice(0, 32),
        decimals: Number(decimals),
        balance,
        expectedImd,
        quoteSource,
        sellable: p?.sellable ?? false,
        status: p?.status ?? STATUS_NOT_REGISTERED,
        route,
        routeLabel: describeRoute(route),
        launch,
        heldRefund,
      };
    }),
  );
  tokens.sort((a, b) => Number(b.sellable) - Number(a.sellable) || Number(b.expectedImd > a.expectedImd) - Number(a.expectedImd > b.expectedImd));

  return {
    tokens,
    pricing: priced.pricing,
    pricingError: priced.error,
    paused,
    maxPerSale: Number(maxPerSaleRaw),
    minImdOut,
    launches,
    setup: {
      owner,
      imdRouteSet: !!imdRoute && imdRoute.venue !== 0,
      feedSet: !same(feed, NATIVE),
      registered: [...registered],
      routes,
      imdPool,
    },
  };
}

type Outcome = { token: Address; amountIn: bigint; imdOut: bigint; status: number };

const settles = (o: Outcome | undefined, floor: bigint) => !!o && o.status === STATUS_SOLD && o.imdOut > 0n && o.imdOut >= floor;

/** Missing full-balance allowances need approval before a meaningful sellAll dry run. */
export async function planSale(
  client: PublicClient, account: Address, chosen: SwarmToken[], minImdOut: bigint,
  maxPerSale = DEFAULT_MAX_TOKENS_PER_SALE,
): Promise<Plan> {
  const excluded: Plan["excluded"] = [];
  const byToken = new Map<string, PlanItem>();
  const approved: SwarmToken[] = [];
  const allowances = await Promise.all(chosen.map(t => client.readContract({ address: t.address, abi: erc20Abi, functionName: "allowance", args: [account, SWARM_EXIT_ADDRESS] })));
  for (const [index, t] of chosen.entries()) {
    if (!t.sellable || t.expectedImd <= 0n || t.expectedImd < minImdOut) {
      excluded.push({ token: t, reason: STATUS_TEXT[t.status] ?? "No usable sale quote. Refresh to try again." });
      continue;
    }
    if (allowances[index]! < t.balance) byToken.set(t.address.toLowerCase(), { token: t, imdOut: t.expectedImd, approvalRequired: true, estimated: true });
    else approved.push(t);
  }

  const simulate = async (tokens: SwarmToken[]) => {
    const { result } = await client.simulateContract({ ...exit, functionName: "sellAll", args: [tokens.map(t => t.address), tokens.map(() => 0n), deadline()], account });
    return result[0];
  };
  const record = (tokens: SwarmToken[], outcomes: readonly Outcome[]) => {
    for (const t of tokens) {
      const o = outcomes.find(x => same(x.token, t.address));
      if (settles(o, minImdOut)) byToken.set(t.address.toLowerCase(), { token: t, imdOut: o!.imdOut });
      else excluded.push({ token: t, reason: o ? (STATUS_TEXT[o.status] ?? "The sale would fail on chain.") : "The sale would not settle on chain." });
    }
  };
  const size = Math.max(1, Math.min(maxPerSale, DEFAULT_MAX_TOKENS_PER_SALE));
  for (let start = 0; start < approved.length; start += size) {
    const batch = approved.slice(start, start + size);
    try {
      record(batch, await simulate(batch));
    } catch {
      // Isolate an actually reverting token, then re-quote the surviving batch together.
      const keep: SwarmToken[] = [];
      for (const t of batch) {
        try {
          const outcomes = await simulate([t]);
          if (settles(outcomes[0], minImdOut)) keep.push(t);
          else record([t], outcomes);
        } catch (e) {
          excluded.push({ token: t, reason: `The sale reverts in simulation: ${errorText(e)}` });
        }
      }
      if (keep.length > 0) {
        try { record(keep, await simulate(keep)); }
        catch (e) { for (const t of keep) excluded.push({ token: t, reason: `The batch simulation failed: ${errorText(e)}` }); }
      }
    }
  }
  const items = chosen.flatMap(t => { const item = byToken.get(t.address.toLowerCase()); return item ? [item] : []; });
  const gross = items.reduce((sum, i) => sum + i.imdOut, 0n);
  return { items, excluded, gross, ...feeSplit(gross) };
}

export type Progress =
  | { step: "check"; batch: number; batches: number }
  | { step: "approve"; token: SwarmToken; index: number; total: number }
  | { step: "sign"; batch: number; batches: number }
  | { step: "mine"; hash: Hash; batch: number; batches: number };

/** Keeps outcomes from earlier batches visible if a later check or wallet request fails. */
export class SaleExecutionError extends Error {
  readonly results: Map<string, SaleResult>;
  readonly hash: Hash | null;
  constructor(error: unknown, results: Map<string, SaleResult>) {
    super(errorText(error));
    this.results = new Map(results);
    this.hash = transactionHash(error);
  }
}

const minimum = (i: PlanItem) => (i.imdOut * (BPS - SLIPPAGE_BPS)) / BPS;

/** Approves missing balances, validates the exact batch, then requests its sale signature. */
export async function executeSale(
  wallet: WalletClient, client: PublicClient, account: Address, plan: Plan, maxPerSale: number,
  onProgress: (p: Progress) => void,
): Promise<Map<string, SaleResult>> {
  const results = new Map<string, SaleResult>();
  const key = (a: string) => a.toLowerCase();
  try {
    const needing: SwarmToken[] = [];
    for (const { token } of plan.items) {
      const allowance = await client.readContract({ address: token.address, abi: erc20Abi, functionName: "allowance", args: [account, SWARM_EXIT_ADDRESS] });
      if (allowance < token.balance) needing.push(token);
    }
    for (let i = 0; i < needing.length; i += 1) {
      const token = needing[i]!;
      await assertWalletContext(wallet, account);
      onProgress({ step: "approve", token, index: i + 1, total: needing.length });
      const hash = await wallet.writeContract({ address: token.address, abi: erc20Abi, functionName: "approve", args: [SWARM_EXIT_ADDRESS, token.balance], account, chain: wallet.chain });
      await confirmedReceipt(client, hash, `Approval of ${token.symbol}`);
    }

    const size = Math.max(1, Math.min(maxPerSale, DEFAULT_MAX_TOKENS_PER_SALE));
    const batches: PlanItem[][] = [];
    for (let i = 0; i < plan.items.length; i += size) batches.push(plan.items.slice(i, i + size));
    for (let b = 0; b < batches.length; b += 1) {
      let batch = batches[b]!;
      onProgress({ step: "check", batch: b + 1, batches: batches.length });
      const expires = deadline();
      // Removing a skipped token changes the shared pool's execution order. Re-simulate until
      // the exact remaining batch settles, using the immutable amounts the user confirmed.
      while (batch.length > 0) {
        let outcomes: readonly Outcome[];
        try {
          const { result } = await client.simulateContract({ ...exit, functionName: "sellAll", args: [batch.map(i => i.token.address), batch.map(minimum), expires], account });
          outcomes = result[0];
        } catch (e) {
          const reason = `Final sale simulation failed: ${errorText(e)}. Refresh quotes to review a new sale.`;
          for (const i of batch) results.set(key(i.token.address), { kind: "unsold", reason });
          throw new Error(reason);
        }
        const keep: PlanItem[] = [];
        for (const i of batch) {
          const o = outcomes.find(x => same(x.token, i.token.address));
          if (o?.status === 6) {
            const reason = `${i.token.symbol} no longer meets the ${fmtAmount(minimum(i))} IMD minimum you confirmed. Refresh quotes to review a new sale.`;
            results.set(key(i.token.address), { kind: "unsold", reason });
            throw new Error(reason);
          }
          if (o?.status === STATUS_SOLD && o.imdOut > 0n && o.imdOut < minimum(i)) {
            const reason = `${i.token.symbol} now quotes ${fmtAmount(o.imdOut)} IMD, below the ${fmtAmount(minimum(i))} IMD minimum you confirmed. Refresh quotes to review a new sale.`;
            results.set(key(i.token.address), { kind: "unsold", reason });
            throw new Error(reason);
          }
          if (settles(o, minimum(i))) keep.push(i);
          else results.set(key(i.token.address), { kind: "unsold", reason: `${o ? (STATUS_TEXT[o.status] ?? "The sale would fail on chain") : "No selling outcome returned"}. No sale transaction was requested for this token. Refresh quotes to try again.` });
        }
        if (keep.length === batch.length) break;
        batch = keep;
      }
      if (batch.length === 0) continue;
      await assertWalletContext(wallet, account);
      onProgress({ step: "sign", batch: b + 1, batches: batches.length });
      const hash = await wallet.writeContract({ ...exit, functionName: "sellAll", args: [batch.map(i => i.token.address), batch.map(minimum), expires], account, chain: wallet.chain });
      onProgress({ step: "mine", hash, batch: b + 1, batches: batches.length });
      let receipt;
      try { receipt = await confirmedReceipt(client, hash, "Sale"); }
      catch (e) {
        for (const i of batch) results.set(key(i.token.address), { kind: "unsold", reason: "The sale transaction reverted; this batch moved no tokens.", txHash: hash });
        throw e;
      }
      const logs = parseEventLogs({ abi: swarmExitAbi, logs: receipt.logs.filter(log => same(log.address, SWARM_EXIT_ADDRESS)) });
      const relevant = logs.filter(log => {
        const args = log.args;
        return "user" in args && same(args.user as string, account) && "token" in args && batch.some(i => same(i.token.address, args.token as string));
      });
      for (const i of batch) results.set(key(i.token.address), { kind: "unsold", reason: "Skipped by the contract.", txHash: hash });
      for (const log of relevant) {
        if (log.eventName === "TokenSold") results.set(key(log.args.token), { kind: "sold", imdOut: log.args.imdOut, txHash: hash });
        else if (log.eventName === "TokenSkipped") results.set(key(log.args.token), { kind: "unsold", reason: STATUS_TEXT[Number(log.args.status)] ?? "Skipped by the contract.", txHash: hash });
        else if (log.eventName === "TokenRefunded") results.set(key(log.args.token), { kind: "unsold", reason: "The sale failed on chain. Your tokens were refunded in the same transaction.", txHash: hash });
      }
      // Held refunds have priority regardless of the order in which the token's events appeared.
      for (const log of relevant) if (log.eventName === "RefundHeld") results.set(key(log.args.token), { kind: "unsold", reason: "The token blocked its refund. It stays claimable here; use Claim refund below.", txHash: hash, held: true, heldAmount: log.args.amount });
    }
    return results;
  } catch (e) {
    throw new SaleExecutionError(e, results);
  }
}

export async function claimRefund(wallet: WalletClient, client: PublicClient, account: Address, token: Address): Promise<Hash> {
  await assertWalletContext(wallet, account);
  const hash = await wallet.writeContract({ ...exit, functionName: "claimRefund", args: [token], account, chain: wallet.chain });
  await confirmedReceipt(client, hash, "Refund claim");
  return hash;
}
