// Reads and writes against SwarmExit. Every function here takes viem clients and returns plain data;
// the components decide how to show it.
import { parseEventLogs, parseUnits, type Address, type Hash, type PublicClient, type WalletClient } from "viem";
import { swarmExitAbi } from "../abi/swarmExit";
import { erc20Abi } from "../abi/erc20";
import {
  BPS,
  DEADLINE_SECONDS,
  DEFAULT_MAX_TOKENS_PER_SALE,
  FEE_BPS,
  IMD_ADDRESS,
  IMD_DECIMALS,
  SLIPPAGE_BPS,
  SWARM_EXIT_ADDRESS,
} from "../config";
import { short } from "./format";

/** SwarmExit.Status, in declaration order. */
export const STATUS_TEXT = [
  "Sellable",
  "Not a swarm token",
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

export type SellRoute = { venue: number; tokenOut: Address };

export type SwarmToken = {
  address: Address;
  symbol: string;
  decimals: number;
  balance: bigint;
  /** Expected IMD from the contract's preview (gross, before the fee). */
  expectedImd: bigint;
  sellable: boolean;
  status: number;
  route: SellRoute | null;
  /** Human label of the sell route, or null when the contract has none for this token. */
  routeLabel: string | null;
  heldRefund: bigint;
  /** Set after a sale transaction. */
  result?: SaleResult;
};

export type SaleResult =
  | { kind: "sold"; imdOut: bigint; txHash: Hash }
  | { kind: "unsold"; reason: string; txHash?: Hash; held?: boolean };

export type Pricing = { imdUsd: number; ethUsd: number };

export type WalletState = {
  tokens: SwarmToken[];
  pricing: Pricing | null;
  pricingError: string | null;
  paused: boolean;
  maxPerSale: number;
  minImdOut: bigint;
  registered: number;
};

export type PlanItem = { token: SwarmToken; imdOut: bigint };
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

async function loadPricing(client: PublicClient, account: Address): Promise<{ pricing: Pricing | null; error: string | null }> {
  try {
    const [{ result: bridgePerImd }, [price, decimals]] = await Promise.all([
      client.simulateContract({ ...exit, functionName: "quoteImdInBridge", args: [parseUnits("1", IMD_DECIMALS)], account }),
      client.readContract({ ...exit, functionName: "ethUsdPrice" }),
    ]);
    const ethUsd = Number(price) / 10 ** Number(decimals);
    const imdUsd = (Number(bridgePerImd) / 1e18) * ethUsd;
    return { pricing: { imdUsd, ethUsd }, error: null };
  } catch (e) {
    return { pricing: null, error: e instanceof Error ? e.message.split("\n")[0]! : String(e) };
  }
}

/** Everything the page shows for one wallet: its swarm tokens, routes, previews and prices. */
export async function loadWallet(client: PublicClient, account: Address): Promise<WalletState> {
  const [paused, maxPerSaleRaw, minImdOut, { result: previews }, priced] = await Promise.all([
    client.readContract({ ...exit, functionName: "paused" }).catch(() => false),
    client.readContract({ ...exit, functionName: "MAX_TOKENS_PER_SALE" }).catch(() => BigInt(DEFAULT_MAX_TOKENS_PER_SALE)),
    client.readContract({ ...exit, functionName: "minImdOut" }).catch(() => 0n),
    client.simulateContract({ ...exit, functionName: "previewAll", args: [account], account }),
    loadPricing(client, account),
  ]);

  const held = await Promise.all(
    previews.map((p) => client.readContract({ ...exit, functionName: "heldRefunds", args: [account, p.token] }).catch(() => 0n)),
  );
  // Only what the wallet actually holds (or has waiting as a held refund) is listed.
  const inWallet = previews.map((p, i) => ({ p, heldRefund: held[i]! })).filter(({ p, heldRefund }) => p.balance > 0n || heldRefund > 0n);

  const tokens = await Promise.all(
    inWallet.map(async ({ p, heldRefund }): Promise<SwarmToken> => {
      const erc = { address: p.token, abi: erc20Abi } as const;
      const [symbol, decimals, routeRaw] = await Promise.all([
        client.readContract({ ...erc, functionName: "symbol" }).catch(() => short(p.token)),
        client.readContract({ ...erc, functionName: "decimals" }).catch(() => 18),
        client.readContract({ ...exit, functionName: "tokenRoute", args: [p.token] }).catch(() => null),
      ]);
      const route: SellRoute | null = routeRaw && routeRaw.venue !== 0 ? { venue: routeRaw.venue, tokenOut: routeRaw.tokenOut } : null;
      return {
        address: p.token,
        symbol: String(symbol).slice(0, 32),
        decimals: Number(decimals),
        balance: p.balance,
        expectedImd: p.expectedImd,
        sellable: p.sellable,
        status: Number(p.status),
        route,
        routeLabel: describeRoute(route),
        heldRefund,
      };
    }),
  );

  return {
    tokens,
    pricing: priced.pricing,
    pricingError: priced.error,
    paused,
    maxPerSale: Number(maxPerSaleRaw),
    minImdOut,
    registered: previews.length,
  };
}

type Outcome = { token: Address; amountIn: bigint; imdOut: bigint; status: number };

const settles = (o: Outcome | undefined, floor: bigint) => !!o && o.status === STATUS_SOLD && o.imdOut > 0n && o.imdOut >= floor;

/**
 * Dry run of sellAll with zero minimums. Sales execute one after another and share the IMD pool,
 * so the simulated outputs are the real quote. A token whose sale would fail is left out; if the
 * whole call reverts, each token is simulated alone to find the culprits and the rest is rerun.
 */
export async function planSale(client: PublicClient, account: Address, chosen: SwarmToken[], minImdOut: bigint): Promise<Plan> {
  const excluded: Plan["excluded"] = [];
  let selected = chosen.slice();
  let items: PlanItem[] = [];

  for (let attempt = 0; attempt < 2 && selected.length > 0; attempt += 1) {
    let outcomes: readonly Outcome[];
    try {
      const { result } = await client.simulateContract({
        ...exit,
        functionName: "sellAll",
        args: [selected.map((t) => t.address), selected.map(() => 0n), deadline()],
        account,
      });
      outcomes = result[0];
    } catch {
      const keep: SwarmToken[] = [];
      for (const t of selected) {
        try {
          const { result } = await client.simulateContract({ ...exit, functionName: "sellAll", args: [[t.address], [0n], deadline()], account });
          if (settles(result[0][0], minImdOut)) keep.push(t);
          else excluded.push({ token: t, reason: "The sale would not settle on chain." });
        } catch (e) {
          excluded.push({ token: t, reason: `The sale reverts in simulation: ${e instanceof Error ? e.message.split("\n")[0] : e}` });
        }
      }
      selected = keep;
      continue;
    }
    items = [];
    for (const t of selected) {
      const o = outcomes.find((x) => same(x.token, t.address));
      if (settles(o, minImdOut)) items.push({ token: t, imdOut: o!.imdOut });
      else excluded.push({ token: t, reason: "The sale would fail or yield nothing on chain." });
    }
    break;
  }
  if (items.length === 0 && selected.length > 0) items = selected.map((t) => ({ token: t, imdOut: t.expectedImd }));

  const gross = items.reduce((s, i) => s + i.imdOut, 0n);
  const { fee, net } = feeSplit(gross);
  return { items, excluded, gross, fee, net };
}

export type Progress =
  | { step: "approve"; token: SwarmToken; index: number; total: number }
  | { step: "sign"; batch: number; batches: number }
  | { step: "mine"; hash: Hash; batch: number; batches: number };

/** Approves what is missing, sends sellAll in batches, and reports what happened to each token. */
export async function executeSale(
  wallet: WalletClient,
  client: PublicClient,
  account: Address,
  plan: Plan,
  maxPerSale: number,
  onProgress: (p: Progress) => void,
): Promise<Map<string, SaleResult>> {
  const results = new Map<string, SaleResult>();
  const key = (a: string) => a.toLowerCase();

  // Approvals: exact balance, so the contract can never pull more than what is being sold.
  const needing: SwarmToken[] = [];
  for (const { token } of plan.items) {
    const allowance = await client.readContract({ address: token.address, abi: erc20Abi, functionName: "allowance", args: [account, SWARM_EXIT_ADDRESS] });
    if (allowance < token.balance) needing.push(token);
  }
  for (let i = 0; i < needing.length; i += 1) {
    const token = needing[i]!;
    onProgress({ step: "approve", token, index: i + 1, total: needing.length });
    const hash = await wallet.writeContract({
      address: token.address,
      abi: erc20Abi,
      functionName: "approve",
      args: [SWARM_EXIT_ADDRESS, token.balance],
      account,
      chain: wallet.chain,
    });
    await client.waitForTransactionReceipt({ hash });
  }

  const batches: PlanItem[][] = [];
  for (let i = 0; i < plan.items.length; i += maxPerSale) batches.push(plan.items.slice(i, i + maxPerSale));

  for (let b = 0; b < batches.length; b += 1) {
    const batch = batches[b]!;
    onProgress({ step: "sign", batch: b + 1, batches: batches.length });
    let hash: Hash;
    try {
      hash = await wallet.writeContract({
        ...exit,
        functionName: "sellAll",
        args: [batch.map((i) => i.token.address), batch.map((i) => (i.imdOut * (BPS - SLIPPAGE_BPS)) / BPS), deadline()],
        account,
        chain: wallet.chain,
      });
    } catch (e) {
      for (const i of batch) results.set(key(i.token.address), { kind: "unsold", reason: `Not sent: ${e instanceof Error ? e.message.split("\n")[0] : e}` });
      throw e;
    }
    onProgress({ step: "mine", hash, batch: b + 1, batches: batches.length });
    const receipt = await client.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") {
      for (const i of batch) results.set(key(i.token.address), { kind: "unsold", reason: "The transaction reverted; nothing moved.", txHash: hash });
      continue;
    }
    const logs = parseEventLogs({ abi: swarmExitAbi, logs: receipt.logs });
    for (const i of batch) results.set(key(i.token.address), { kind: "unsold", reason: "Skipped by the contract.", txHash: hash });
    for (const log of logs) {
      if (log.eventName === "TokenSold") results.set(key(log.args.token), { kind: "sold", imdOut: log.args.imdOut, txHash: hash });
      else if (log.eventName === "TokenSkipped")
        results.set(key(log.args.token), { kind: "unsold", reason: STATUS_TEXT[Number(log.args.status)] ?? "Skipped by the contract.", txHash: hash });
      else if (log.eventName === "TokenRefunded")
        results.set(key(log.args.token), { kind: "unsold", reason: "The sale failed on chain. Your tokens were refunded in the same transaction.", txHash: hash });
      else if (log.eventName === "RefundHeld")
        results.set(key(log.args.token), { kind: "unsold", reason: "The sale failed and the token refused the refund. Claim it below.", txHash: hash, held: true });
    }
  }
  return results;
}

export async function claimRefund(wallet: WalletClient, client: PublicClient, account: Address, token: Address): Promise<Hash> {
  const hash = await wallet.writeContract({ ...exit, functionName: "claimRefund", args: [token], account, chain: wallet.chain });
  await client.waitForTransactionReceipt({ hash });
  return hash;
}
