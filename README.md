# Swarm Exit

One-click sale of every swarm-launched token in a wallet for $IMD on Ethereum mainnet.

- `src/SwarmExit.sol`: the only launched contract (Solidity name `SwarmExit`, one constructor argument: the owner).
- `web/`: static website (connect wallet, list swarm tokens with balances and USD values, highlight unsellable ones, sell all in one transaction, claim a held refund). Serve the folder with any static file server; `ethers` is vendored in `web/vendor/`.
- `test/`: Foundry tests with mock Uniswap V2 / V3 venues, a mock Uniswap v4 PoolManager (flash accounting, native ETH), WETH, honeypot, fee-on-transfer, refund-blocking, no-liquidity and reentrant tokens.
- `script/Deploy.s.sol`: reviewable deployment function used by the tests. The IMD launch deploys from bytecode through its factory; nobody runs this script against mainnet for the launch.

## How it works

1. The owner registers each token the swarm launched (`setSwarmToken`, the address must have code) and the route that sells it (`setTokenRoute`). Three venues: a Uniswap V2 style path (`venue = 1`, `abi.encode(address[])`), a Uniswap V3 packed path (`venue = 2`, `token | fee | token …`), or a Uniswap v4 hop list (`venue = 3`, `abi.encode(address currencyIn, V4Hop[] hops)` where each hop is `(currencyOut, fee, tickSpacing, hooks)` and `address(0)` is native ETH). A route ends either directly in IMD or in the bridge currency (WETH or native ETH).
2. The owner sets one global route from the bridge currency into IMD (`setImdRoute`). IMD's liquidity sits in the Uniswap v4 PoolManager, so the expected value is a v4 route from native ETH (or WETH) into IMD. WETH and ETH bridge 1:1 between legs: a V2/V3 leg ending in WETH is unwrapped before a v4 ETH leg, and a v4 leg ending in ETH is wrapped before a V2/V3 WETH leg.
3. The website calls `previewAll(user)` with `eth_call`. For every registered token it returns the balance, the expected IMD and a status. A token is sellable only when it is registered, has a route, has a balance, quotes successfully through every leg (so a pool exists and the swap is possible), the bridge route is configured, the quote clears the dust threshold `minImdOut`, and the holding's price impact (full quote against a 1/1000 probe scaled up) is within `maxImpactBps`. v4 routes are quoted the way Uniswap's own quoter works: the swaps run inside `unlock` and revert with the result, so nothing settles.
4. USD values: `quoteImdInBridge(1e18)` (IMD priced in ETH/WETH along the reversed IMD route) multiplied by the Chainlink ETH/USD price from `ethUsdPrice()` (staleness bound `MAX_PRICE_AGE`, 3 hours). These are display figures; no on-chain decision depends on them.
5. The user approves each sellable token for its balance, the website dry-runs `sellAll` with `eth_call` and zero minimums, excludes any token whose simulated outcome is not `Sold` with proceeds at or above `minImdOut` (bisecting token by token if the whole call reverts), takes the simulated per-token outputs as the real quote (sales run one after another and share the IMD pool, so isolated quotes overstate later tokens), then sends `sellAll(tokens, minImdOuts, deadline)` with minimums `slippageBps` under those outputs, in batches of at most `MAX_TOKENS_PER_SALE`.
6. `sellAll`, per token: (a) skip without touching the wallet when there is no route, no balance, no allowance, the quote fails, the bridge route is missing, or the quote is below the larger of the caller's minimum and `minImdOut` (status recorded in the outcome, `TokenSkipped` event); (b) pull `min(balance, allowance)` with a non-reverting call (a token that refuses the pull is a `SaleFailed` outcome, not a revert); (c) sell through its route in an atomic self-call (`executeSale`) that reverts when a leg yields nothing or the IMD is below the floor; (d) on failure refund what was pulled with a non-reverting transfer and, if the token refuses even that, hold it in `heldRefunds` for `claimRefund`. Then pool the IMD. If nothing sold, the whole call reverts with `NothingSold` so nothing moves.
7. Of the pooled IMD, 2% (`SELL_TAX_BPS = 200`, rounded down) goes to the treasury `0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB`; the rest goes to the user.

The contract never keeps user tokens, ETH or IMD between transactions except held refunds, which only their owner can claim; every router allowance is reset to zero after each swap, and the v4 callback only accepts the PoolManager the contract is inside an `unlock` of.

## Fixed values (from the brief and the chain)

| Value | Where |
|---|---|
| IMD token `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | constant `IMD` |
| Treasury `0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB` | constant `TREASURY` |
| Sell tax 2% | constant `SELL_TAX_BPS = 200` |
| WETH9 `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | constant `WETH` (mainnet, used only to wrap/unwrap between legs) |
| Owner `0x0acE1DBE8AAb293cd58D5e3Ea38814f0ccb74782` | constructor argument, `$owner` in the manifest |

## Values chosen here (named constants)

| Constant | Value | Meaning |
|---|---|---|
| `DEFAULT_MIN_IMD_OUT` | `1e15` (0.001 IMD) | Dust threshold, enforced in preview and on chain; owner can change it with `setMinImdOut` |
| `DEFAULT_MAX_IMPACT_BPS` | 3000 (30%) | Price-impact bound applied by `preview`; `setMaxImpactBps(10000)` disables it |
| `IMPACT_PROBE_DIVISOR` | 1000 | The impact probe quotes 1/1000 of the holding |
| `MAX_PRICE_AGE` | 3 hours | Oldest Chainlink answer accepted (feed heartbeat is 1 hour) |
| `MAX_TOKENS_PER_SALE` | 50 | Tokens per `sellAll` call (the site batches above it) |
| `web/config.js` `slippageBps` | 300 (3%) | Per-token minimum IMD = simulated output minus slippage |
| `web/config.js` `deadlineSeconds` | 600 | Transaction deadline |

## After launch (owner responsibilities)

Every function below is owner-only and emits an event. Until they are set, `sellAll` skips (no token route, bridge route missing), `previewAll` reports the reason, and `ethUsdPrice` / `quoteImdInBridge` revert with `NotConfigured`.

| Setter | Set it to | Where the owner gets it |
|---|---|---|
| `setImdRoute(venue, router, quoter, data)` | Uniswap v4: `venue = 3`, router = PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90`, quoter = `0`, `data = abi.encode(address(0), [V4Hop(IMD, fee, tickSpacing, hooks)])` with the fee, tick spacing and hooks of the ETH/IMD pool (use WETH as `currencyIn` instead if the pool is WETH/IMD) | The pool key from the IMD launch records or the PoolManager's `Initialize` event for the IMD pool. On 2026-10-14 the only V2/V3 WETH/IMD pool (V3 1%, `0xD6A822D028bbf7b6EDfA1533e110Ee40c08551d9`) had zero liquidity, so a V2/V3 IMD route would make every bridged token unsellable; check `quoteImdInBridge(1e18)` returns a sensible amount after setting it |
| `setSwarmToken(token, true)` | Each token launched by the swarm | The swarm's launch records |
| `setTokenRoute(token, venue, router, quoter, data)` | `venue = 3` with the token's v4 pool hop(s) to ETH or IMD (PoolManager as router); `venue = 1` with `abi.encode([token, WETH])` for a V2 pool (Router02 `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`); `venue = 2` with the packed V3 path (SwapRouter02 `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45`, QuoterV2 `0x61fFE014bA17989E743c5F6cB21bF9697530B21e`) | The pool each swarm token was launched with |
| `setEthUsdFeed(feed)` | Chainlink ETH/USD aggregator (`0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`) | Chainlink's published feed list |
| `setMinImdOut(value)` | Optional; dust threshold in IMD wei | Owner's choice |
| `setMaxImpactBps(value)` | Optional; price-impact bound for sellability | Owner's choice |
| `pause()` / `unpause()` | Emergency stop for selling (previews and refund claims keep working) | Owner |
| `rescue(token, to, amount)` | Return tokens or ETH (`token = 0`) sent here by mistake; refuses registered swarm tokens and any amount belonging to held refunds | Owner |
| `transferOwnership` / `acceptOwnership` | Two-step handover | Owner |

The Uniswap and Chainlink addresses above are mainnet deployments checked on 2026-10-13 with `cast code` and reads (`WETH9()`, `factory()`, `symbol()`); no chain table was supplied to this task, so re-check before setting them. The v4 PoolManager address is the published Uniswap v4 mainnet deployment and was not re-checked from this machine.

Website: put the deployed SwarmExit address from the launch handoff into `web/config.js` (`swarmExit`). The page also accepts it in its address field.

## Trust assumptions and limits

- Routes are fully trusted owner configuration. The owner decides which tokens count as swarm-launched and which pools sell them, and a route is arbitrary code that receives the user's full balance with no minimum of its own. The on-chain bounds are: a sale that yields nothing, or less than `max(minImdOuts[i], minImdOut)`, is refunded; above that, a wrong or malicious route can keep up to the caller's slippage tolerance (3% by default on the site) of every sale. Route changes take effect immediately and `sellAll` does not bind the caller to the routes it simulated. The owner can pause selling.
- `rescue` cannot touch registered swarm tokens or held refunds; swarm tokens, bridge currency and IMD never rest in the contract because every sale settles or refunds within one transaction. Unregistering a token clears its route (and the token could then be rescued), which is why the contract never holds swarm tokens between transactions.
- Sellability in `preview` is decided from quotes, the dust floor and the price-impact bound. A honeypot or approve-blocking token that quotes fine is reported sellable; the website's dry run of `sellAll` excludes it, and on chain it is refunded (or its refund held). Integrators using `preview` directly should dry-run `sellAll` the same way.
- Fee-on-transfer tokens sell through V2 or v4 routes (measured amounts); Uniswap V3 cannot swap them. On v4 the callback pays the input first (sync, transfer, settle) and swaps only the amount the PoolManager credited, so a token that charges a fee on the transfer into the manager sells the post-fee amount instead of leaving an unsettled delta. `preview` quotes the pre-fee wallet balance, so `expectedImd` overstates their proceeds (on v4 by two fees: the pull and the transfer into the manager); the site takes the simulated output instead. A predictable failure (bad quote, below minimum) is skipped before the pull so no fee is paid; a sale that fails only at execution (liquidity moved after the simulation) costs one transfer fee on the pull and one on the refund.
- Quotes are DEX spot quotes used only for sellability and display. The on-chain protection against sandwiching is the per-token `minImdOuts` the user passes. Users should prefer a private RPC such as Flashbots Protect.
- The sell tax rounds down (at most 1 wei per call less than 2%).
- v4 pools with hooks are swapped with empty hook data; a hook that requires data or blocks the swap makes the sale fail and refund.
- The real IMD token is a custom contract; the suite exercises settlement against a plain ERC20 etched at its address. Before release, rehearse the happy path on a mainnet fork against the real IMD and the configured v4 pool, and assert the user and treasury balances.
- Tests are not an audit. An independent adversarial review is required before this holds other people's funds.

## Build and test

```
forge build
FOUNDRY_FUZZ_SEED=0x13977e752756c31de407b32f33bcdf3453d8906272d732125dad455e54ecda96 forge test
forge fmt --check
```

The suite covers: owner and two-step ownership, registry add/remove (code check, route cleared on unregister), route validation (three venues), every preview status including price impact and a reverting `balanceOf`, the happy path with exact 2% / 98% split and zero residue, events, fee-on-transfer (V2 sale, v4 sale with the measured amount, pre-pull skip, execution-time refund), zero-balance and no-allowance skips, allowance-capped pull, honeypot refund with other tokens still sold, a pull the token refuses, a refund the token refuses (held, claimable, not rescuable), a route that pays nothing, the on-chain floor, no-liquidity and missing-bridge skips, nothing-sold revert, input validation, pause, self-call and callback guards, reentrancy from a malicious token, Chainlink checks, reversed V2 / V3 / v4 / multi-hop quoting, v4 direct and bridged sales in both wrap directions, v4 partial fills, rescue limits (tokens and ETH), the deploy function, runtime size and forbidden opcodes, and three fuzz tests (tax conservation on V2/V3 and v4, slippage guard).

Tooling run: forge build, forge test (with the verifier's fuzz seed), forge fmt. Slither and Mythril were not available on this machine; the only `transferFrom` is made from `sellAll`'s loop with `msg.sender` as the source.
