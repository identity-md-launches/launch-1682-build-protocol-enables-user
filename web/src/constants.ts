// Addresses and limits the site uses (no wagmi here, so node scripts can import it).
// Addresses come from the launch's verified deployment record and the chain table;
// nothing here is invented and nothing needs an account.
export const SITE_NAME = "SwarmSweep";
export const SITE_DESCRIPTION =
  "Sell every swarm-launched token in your wallet for $IMD in one transaction on Ethereum. 2% of the proceeds go to the treasury.";
export const SITE_URL = "./";
export const SITE_ICON_URL = "./favicon.svg";

/** SwarmExit on Ethereum mainnet (deployment record, launch 1682, source commit 5868d48). */
export const SWARM_EXIT_ADDRESS = "0x5c3c2a6d7d340db9f8b3e0cbbc8dbbb7ec73bc61" as const;
/** keccak256 of the key-sorted ABI JSON lives in abi/hash.ts and is checked by web/scripts/check-abi.mjs. */
export { SWARM_EXIT_ABI_HASH } from "./abi/hash.ts";
/** Launch id and deployment block of SwarmExit (deployment record). */
export const SWARM_EXIT_LAUNCH_ID = 1682n;
export const SWARM_EXIT_DEPLOY_BLOCK = 26188854n;

/**
 * The IdentityMD launch factory: the `to` of the deployment record's txHash
 * (0x325cd29e2c19070573abaf7b9f88ece5b59813ba47f31c73dfda61f6d3054a1c), which deployed SwarmExit and
 * every swarm token. Before it is trusted the site checks on chain that
 * factory.deploymentBlock(SWARM_EXIT_LAUNCH_ID) equals SWARM_EXIT_DEPLOY_BLOCK from the record.
 */
export const LAUNCH_FACTORY_ADDRESS = "0xff03410d0fe5fa8f7f59f743de35e333d9857120" as const;
/** Launch ids are scanned from 1 in batches of this many eth_calls (one JSON-RPC batch each; the public RPC answered 500 in one batch). */
export const LAUNCH_SCAN_BATCH = 100;
/** The scan stops once launches were seen and this many consecutive ids hold no token launch. */
export const LAUNCH_SCAN_GAP = 400;
/** Pause between scan batches, to stay under the public RPC's rate limit. */
export const LAUNCH_SCAN_PAUSE_MS = 250;
/** Hard cap on scanned ids. */
export const LAUNCH_SCAN_MAX_ID = 50_000;

/** $IMD, the settlement token (chain table pairToken; also a constant of the contract). */
export const IMD_ADDRESS = "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7" as const;
export const IMD_SYMBOL = "IMD";
export const IMD_DECIMALS = 18;
/** Other pair currencies the swarm launches against (chain table otherPairTokens). */
export const FWA_ADDRESS = "0xa0df17b5ac76ababa36e1450e2cbcd18a620c845" as const;
/** Native ETH as a Uniswap v4 currency. */
export const NATIVE = "0x0000000000000000000000000000000000000000" as const;

/** Uniswap v4 on Ethereum mainnet (chain table uniswapV4). */
export const POOL_MANAGER_ADDRESS = "0x000000000004444c5dc75cb358380d2e3de08a90" as const;
export const V4_QUOTER_ADDRESS = "0x52f0e24d1c21c8a0cb1e5a5dd6198556bd9e1203" as const;
export const STATE_VIEW_ADDRESS = "0x7ffe42c4a5deea5b0fec41c94c136cf115597227" as const;
/** Hookless fee tiers probed for the ETH/IMD pool; the one with the most liquidity prices IMD. */
export const ETH_IMD_FEE_TIERS: ReadonlyArray<{ fee: number; tickSpacing: number }> = [
  { fee: 500, tickSpacing: 10 },
  { fee: 3000, tickSpacing: 60 },
  { fee: 10000, tickSpacing: 200 },
];

/**
 * Chainlink ETH/USD aggregator on Ethereum mainnet. Used only for display (and offered to the owner
 * as the feed to set); the site reads its description() and refuses it unless it answers "ETH / USD".
 */
export const CHAINLINK_ETH_USD_ADDRESS = "0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419" as const;
export const CHAINLINK_ETH_USD_DESCRIPTION = "ETH / USD";
/** Oldest Chainlink answer accepted for display, matching the contract's MAX_PRICE_AGE. */
export const MAX_PRICE_AGE_SECONDS = 3 * 3600;

/** Treasury receiving the 2% fee (the contract's TREASURY constant). */
export const TREASURY_ADDRESS = "0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB" as const;
/** Fee in basis points, enforced by the contract (SELL_TAX_BPS). */
export const FEE_BPS = 200n;
export const BPS = 10_000n;

/** Per-token minimum IMD = simulated output minus this slippage, in basis points. */
export const SLIPPAGE_BPS = 300n;
/** Seconds a sell transaction stays valid. */
export const DEADLINE_SECONDS = 600;
/** Fallback when MAX_TOKENS_PER_SALE cannot be read. */
export const DEFAULT_MAX_TOKENS_PER_SALE = 50;
/** Tokens per preview eth_call (each quotes through the pool, so the call stays well under RPC gas caps). */
export const PREVIEW_CHUNK = 12;

export const EXPLORER_URL = "https://etherscan.io";

