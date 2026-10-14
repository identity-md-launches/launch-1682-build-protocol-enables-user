# Swarm Exit

One-click sale of every swarm-launched token in a wallet for $IMD on Ethereum mainnet.

- `src/SwarmExit.sol`: the only launched contract (Solidity name `SwarmExit`, one constructor argument: the owner).
- `web/`: static website (connect wallet, list swarm tokens with balances and USD values, highlight unsellable ones, sell all in one transaction). Serve the folder with any static file server; `ethers` is vendored in `web/vendor/`.
- `test/`: Foundry tests with mock Uniswap V2 / V3 venues, honeypot, fee-on-transfer, no-liquidity and reentrant tokens.
- `script/Deploy.s.sol`: reviewable deployment function used by the tests. The IMD launch deploys from bytecode through its factory; nobody runs this script against mainnet for the launch.

## How it works

1. The owner registers each token the swarm launched (`setSwarmToken`) and the route that sells it (`setTokenRoute`): a Uniswap V2 style path (`abi.encode(address[])`) or a Uniswap V3 packed path (`token | fee | token …`). A route ends either directly in IMD or in the bridge token (WETH).
2. The owner sets one global route from the bridge token into IMD (`setImdRoute`). IMD trades today in the Uniswap V3 1% WETH/IMD pool, so the expected value is a V3 route `WETH | 10000 | IMD` through SwapRouter02 and QuoterV2.
3. The website calls `previewAll(user)` with `eth_call`. For every registered token it returns the balance, the expected IMD and a status. A token is sellable only when it is registered, has a route, has a balance, quotes successfully through every leg (so liquidity exists), the bridge route is configured, and the quote clears the dust threshold `minImdOut`.
4. USD values: `quoteImdInBridge(1e18)` (IMD priced in WETH along the reversed IMD route) multiplied by the Chainlink ETH/USD price from `ethUsdPrice()` (staleness bound `MAX_PRICE_AGE`, 3 hours). These are display figures; no on-chain decision depends on them.
5. The user approves each sellable token for its exact balance, the website dry-runs `sellAll` with `eth_call` and zero minimums, excludes any token whose sale would fail, takes the simulated per-token outputs as the real quote (sales run one after another and share the WETH/IMD pool, so isolated quotes overstate later tokens), then sends `sellAll(tokens, minImdOuts, deadline)` with minimums `slippageBps` under those outputs.
6. `sellAll` pulls each token's full balance (measured by balance delta, so fee-on-transfer tokens are handled), sells it through its route in an atomic self-call, and pools the IMD. If a token's sale reverts (honeypot, no liquidity, slippage below the caller's minimum for that token, missing bridge route) the pulled tokens are refunded to the user inside the same transaction and the loop continues. If nothing sold, the whole call reverts with `NothingSold` so nothing moves.
7. Of the pooled IMD, 2% (`SELL_TAX_BPS = 200`) goes to the treasury `0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB`; the rest goes to the user.

The contract never keeps user tokens or IMD between transactions; every router allowance is reset to zero after each swap.

## Fixed values (from the brief)

| Value | Where |
|---|---|
| IMD token `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | constant `IMD` |
| Treasury `0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB` | constant `TREASURY` |
| Sell tax 2% | constant `SELL_TAX_BPS = 200` |
| Owner `0x0acE1DBE8AAb293cd58D5e3Ea38814f0ccb74782` | constructor argument, `$owner` in the manifest |

## Values chosen here (named constants)

| Constant | Value | Meaning |
|---|---|---|
| `DEFAULT_MIN_IMD_OUT` | `1e15` (0.001 IMD) | Initial dust threshold; owner can change it with `setMinImdOut` |
| `MAX_PRICE_AGE` | 3 hours | Oldest Chainlink answer accepted (feed heartbeat is 1 hour) |
| `MAX_TOKENS_PER_SALE` | 50 | Tokens per `sellAll` call |
| `web/config.js` `slippageBps` | 300 (3%) | Per-token minimum IMD = simulated output minus slippage |
| `web/config.js` `deadlineSeconds` | 600 | Transaction deadline |

## After launch (owner responsibilities)

Every function below is owner-only and emits an event. Until they are set, `sellAll` refunds (bridge route missing) or skips (no token route), `previewAll` reports the reason, and `ethUsdPrice` / `quoteImdInBridge` revert with `NotConfigured`.

| Setter | Set it to | Where the owner gets it |
|---|---|---|
| `setImdRoute(venue, router, quoter, data)` | Uniswap V3: `venue = 2`, router = SwapRouter02, quoter = QuoterV2, `data = abi.encodePacked(WETH, uint24(10000), IMD)` | Uniswap's published mainnet deployments (SwapRouter02 `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45`, QuoterV2 `0x61fFE014bA17989E743c5F6cB21bF9697530B21e`, WETH `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`). Checked on 2026-10-13 with `cast code` and reads (`WETH9()`, `factory()`, `symbol()`); no chain table was supplied to this task, so re-check before setting. |
| `setSwarmToken(token, true)` | Each token launched by the swarm | The swarm's launch records |
| `setTokenRoute(token, venue, router, quoter, data)` | `venue = 1` with `abi.encode([token, WETH])` for a V2 pool (Router02 `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`, quoter unused) or `venue = 2` with the packed V3 path to WETH or IMD | The pool each swarm token was launched with |
| `setEthUsdFeed(feed)` | Chainlink ETH/USD aggregator (`0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`) | Chainlink's published feed list |
| `setMinImdOut(value)` | Optional; dust threshold in IMD wei | Owner's choice |
| `pause()` / `unpause()` | Emergency stop for selling | Owner |
| `rescue(token, to, amount)` | Return tokens sent here by mistake; refuses registered swarm tokens | Owner |
| `transferOwnership` / `acceptOwnership` | Two-step handover | Owner |

Website: put the deployed SwarmExit address from the launch handoff into `web/config.js` (`swarmExit`). The page also accepts it in its address field.

## Trust assumptions and limits

- The owner decides which tokens count as swarm-launched and which pools sell them. A wrong route cannot steal funds (a failed sale refunds) but can make a token unsellable. The owner can pause selling.
- `rescue` cannot touch registered swarm tokens, and IMD never rests in the contract, so the owner cannot claim a user's tokens in flight. Unregistered tokens sent to the contract by mistake can be returned by the owner.
- Routes use Uniswap V2 style routers (`swapExactTokensForTokensSupportingFeeOnTransferTokens`) and Uniswap V3 SwapRouter02 (`exactInput`). Uniswap V4 pools are not supported by this version; a token launched into V4 needs a route through a V2/V3 pool or a later adapter.
- Quotes are DEX spot quotes used only for sellability and display. The on-chain protection against sandwiching is the per-token `minImdOuts` the user passes (3% default in the website). Users should prefer a private RPC such as Flashbots Protect.
- Fee-on-transfer tokens sell through V2 routes (measured amounts). Uniswap V3 cannot swap fee-on-transfer tokens; route those through V2.
- Honeypots that pass quotes are caught by the website's dry run and, failing that, refunded on chain. A token that blocks transfers out of the user's wallet reverts the whole transaction (nothing moves).
- Tests are not an audit. An independent adversarial review is required before this holds other people's funds.

## Build and test

```
forge build
FOUNDRY_FUZZ_SEED=0x13977e752756c31de407b32f33bcdf3453d8906272d732125dad455e54ecda96 forge test
forge fmt --check
```

The suite covers: owner and two-step ownership, registry add/remove, route validation (both venues), every preview status, the happy path with exact 2% / 98% split and zero residue, events, fee-on-transfer, zero-balance skip, honeypot refund with other tokens still sold, no-liquidity refund, slippage refund that rolls back the first leg, missing bridge route refund, nothing-sold revert, input validation (unregistered, duplicate, expired, length mismatch, empty, too many), missing approval, pause, self-call guard, reentrancy from a malicious token, Chainlink staleness and sanity checks, reversed V2 / V3 / multi-hop quoting, rescue limits, the deploy function, runtime size and forbidden opcodes, and two fuzz tests (tax conservation, slippage guard).

Tooling run: forge build, forge test (with the verifier's fuzz seed), forge fmt. Slither and Mythril were not available on this machine.
