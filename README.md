# Swarm Exit and SwarmSweep

One-click sale of every swarm-launched token in a wallet for $IMD on Ethereum mainnet: the `SwarmExit` contract (live at `0x5c3c2a6d7d340db9f8b3e0cbbc8dbbb7ec73bc61`) and the SwarmSweep website that drives it.

- `src/SwarmExit.sol`: the only launched contract (Solidity name `SwarmExit`, one constructor argument: the owner).
- `web/`: the SwarmSweep website source (Vite, React, TypeScript, wagmi, viem). `dist/`: its committed static export, the thing that gets published. See [Website](#website-swarmsweep) below, `DESIGN.md` for the design system and [REVIEW.md](REVIEW.md) for the current validation record.
- `test/`: Foundry tests with mock Uniswap V2 / V3 venues, a mock Uniswap v4 PoolManager (flash accounting, native ETH), WETH, honeypot, fee-on-transfer, refund-blocking, no-liquidity and reentrant tokens.
- `script/Deploy.s.sol`: reviewable deployment function used by the tests. The IMD launch deploys from bytecode through its factory; nobody runs this script against mainnet for the launch.

## How it works

1. The owner registers each token the swarm launched (`setSwarmToken`, the address must have code) and the route that sells it (`setTokenRoute`). Three venues: a Uniswap V2 style path (`venue = 1`, `abi.encode(address[])`), a Uniswap V3 packed path (`venue = 2`, `token | fee | token …`), or a Uniswap v4 hop list (`venue = 3`, `abi.encode(address currencyIn, V4Hop[] hops)` where each hop is `(currencyOut, fee, tickSpacing, hooks)` and `address(0)` is native ETH). A route ends either directly in IMD or in the bridge currency (WETH or native ETH).
2. The owner sets one global route from the bridge currency into IMD (`setImdRoute`). IMD's liquidity sits in the Uniswap v4 PoolManager, so the expected value is a v4 route from native ETH (or WETH) into IMD. WETH and ETH bridge 1:1 between legs: a V2/V3 leg ending in WETH is unwrapped before a v4 ETH leg, and a v4 leg ending in ETH is wrapped before a V2/V3 WETH leg.
3. The website discovers factory launches, unions them with registered tokens, reads wallet balances, and calls chunked `preview(user, tokens)` with `eth_call`. For every registered token the preview returns the balance, the expected IMD and a status. A token is sellable only when it is registered, has a route, has a balance, quotes successfully through every leg (so a pool exists and the swap is possible), the bridge route is configured, the quote clears the dust threshold `minImdOut`, and the holding's price impact (full quote against a 1/1000 probe scaled up) is within `maxImpactBps`. v4 routes are quoted the way Uniswap's own quoter works: the swaps run inside `unlock` and revert with the result, so nothing settles.
4. USD values: `quoteImdInBridge(1e18)` (IMD priced in ETH/WETH along the reversed IMD route) multiplied by the Chainlink ETH/USD price from `ethUsdPrice()` (staleness bound `MAX_PRICE_AGE`, 3 hours). These are display figures; no on-chain decision depends on them.
5. The website checks allowances before planning. Already approved tokens are dry-run together with `sellAll`; tokens needing an approval retain the full-balance preview quote and are labelled **Approval required / Estimated proceeds**. The confirmation shows the amounts, gross IMD, 2% treasury fee and estimated net. After confirmation, missing approvals request exactly the displayed token balances and must mine successfully. Each sale batch is then simulated with the **same per-token minimums the visitor confirmed**: 97% of each displayed gross amount. A lower quote or a failed simulation stops for refresh and a new confirmation. Other skipped outcomes are removed and the remaining exact batch is simulated again before requesting its sale signature. There are at most 50 tokens per transaction; larger selections use multiple batches.
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
| `web/src/config.ts` `SLIPPAGE_BPS` | 300 (3%) | Per-token minimum IMD = the confirmed output minus slippage |
| `web/src/config.ts` `DEADLINE_SECONDS` | 600 | Transaction deadline |

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

Website: the deployed SwarmExit address is fixed in `web/src/constants.ts` (`SWARM_EXIT_ADDRESS`), taken from the launch's deployment record. The site lists every swarm token a wallet holds whether or not the owner has registered it (see "Swarm token discovery"), but the contract can only sell registered tokens: the owner wallet sees an "Owner setup" panel on the site that sends the setters above with values read from the chain (the launch pool of each token as its v4 route, the ETH/IMD v4 pool with liquidity as the IMD route, the Chainlink ETH/USD feed).

## Swarm token discovery (the 2026-10-15 review)

The review request said the site could not read a wallet and identify swarm-launched tokens. Cause: the site only listed tokens registered in SwarmExit (`previewAll`), and on 2026-10-15 the live contract had zero registered tokens, no IMD route and no price feed (`swarmTokenCount() == 0`, `imdRoute().venue == 0`, `ethUsdFeed() == 0`). Nothing was ever registered after deployment, so every wallet read as empty.

Fix: the site now identifies swarm tokens from the chain itself. Every swarm launch goes through the IdentityMD launch factory `0xff03410d0fe5fa8f7f59f743de35e333d9857120`, the contract that deployed SwarmExit (the `to` of the deployment record's `txHash`; `web/src/constants.ts` `LAUNCH_FACTORY_ADDRESS`). Before trusting it the site checks `factory.deploymentBlock(1682) == 26188854`, the launch id and block from the deployment record. `factory.positionOf(launchId)` returns the Uniswap v4 pool key of each token launch (currency0, currency1, fee 12500, tick spacing 60, the launch hook `0x784F…6000`) and the requester; the swarm token is the pool currency that is not a pair currency (IMD, FWA or ETH). The site scans launch ids from 1 in JSON-RPC batches of 100 `eth_call`s (`web/src/lib/launches.ts`), stops after 400 consecutive empty ids, and unions the result with `swarmTokens()` from the contract. For every token the wallet holds it then calls `preview(user, tokens)` on SwarmExit (sellability as the contract sees it) and, for tokens not registered yet, quotes the whole balance through the launch pool with the Uniswap v4 Quoter `0x52f0…1203` (chain table), so the holder sees what the token is worth and whether anyone is buying. USD values use the contract's `quoteImdInBridge` and `ethUsdPrice` when configured, otherwise the ETH/IMD v4 pool with the most liquidity (probed through StateView `0x7ffe…7227` over the 0.05%, 0.3% and 1% hookless tiers) and the Chainlink ETH/USD feed `0x5f4e…8419`, which the site accepts only if its `description()` is "ETH / USD".

Test case, the launch owner `0x0acE1DBE8AAb293cd58D5e3Ea38814f0ccb74782`, read through the site's own code (`node --experimental-strip-types web/scripts/read-wallet.mjs`, 2026-10-15): 187 token launches known (ids 737 to 1888), 142 held by the wallet, 1 with a buyer in its pool (PLEA, launch 1609: 76,775 PLEA quoted at 0.1912 IMD, about $1.29), 0 sellable through the contract until the owner registers them. Every other held token sits in a launch pool nobody has bought from, so the pool holds no IMD to pay for a sale: the v4 Quoter reverts and `preview` reports `QuoteFailed`. Those rows are greyed out as "No sell route found" with the reason. Tokens paired with FWA have no route to IMD and are listed the same way.

Checks 2 to 4 of the review ran on a mainnet fork of the live contract (`test/fork/SwarmExitMainnet.t.sol`, see Validation): the owner registers PLEA, NECTAR and COMB with their launch pools and sets the IMD route and feed, then one `sellAll` returns one cumulative gross of 0.191169797402410816 IMD, a tax of exactly 2% (0.003823395948048216 IMD) credited to the treasury, the rest (0.187346401454362600 IMD) credited to the seller, nothing left in the contract, and the two unsellable tokens skipped before any pull with their balances unchanged. The refund path (a sale that reverts after the pull) cannot be forced on real pools; it is covered by the unit tests with honeypot, refund-blocking and no-liquidity mocks (`test/SwarmExitEdges.t.sol`), and a sale below the caller's minimum was shown on the fork to revert with `NothingSold` and move nothing.

## Trust assumptions and limits

- Routes are fully trusted owner configuration. The owner decides which tokens count as swarm-launched and which pools sell them, and a route is arbitrary code that receives the user's full balance with no minimum of its own. The on-chain bounds are: a sale that yields nothing, or less than `max(minImdOuts[i], minImdOut)`, is refunded; above that, a wrong or malicious route can keep up to the caller's slippage tolerance (3% by default on the site) of every sale. Route changes take effect immediately and `sellAll` does not bind the caller to the routes it simulated. The owner can pause selling.
- `rescue` cannot touch registered swarm tokens or amounts owed as held refunds. A failed sale normally returns the tokens immediately. If the token blocks that transfer, it remains accounted to the seller in `heldRefunds` until a successful `claimRefund`. Unregistering a token clears its route; held refund amounts remain protected from rescue.
- Sellability in `preview` is decided from quotes, the dust floor and the price-impact bound. A honeypot or approve-blocking token that quotes fine is reported sellable; the website's dry run of `sellAll` after approval excludes it, and an execution-time failure is refunded (or its refund held). Integrators using `preview` directly should dry-run `sellAll` the same way.
- Fee-on-transfer tokens sell through V2 or v4 routes (measured amounts); Uniswap V3 cannot swap them. On v4 the callback pays the input first (sync, transfer, settle) and swaps only the amount the PoolManager credited, so a token that charges a fee on the transfer into the manager sells the post-fee amount instead of leaving an unsettled delta. `preview` quotes the pre-fee wallet balance, so `expectedImd` overstates their proceeds (on v4 by two fees: the pull and the transfer into the manager); the site can use an approved simulation to quote the actual output. If an initial unapproved estimate overstates proceeds beyond the confirmed 3% tolerance, execution stops; refresh and open a new confirmation rather than lowering that minimum silently. A predictable failure (bad quote, below minimum) is skipped before the pull so no fee is paid; a sale that fails only at execution (liquidity moved after the simulation) costs one transfer fee on the pull and one on the refund.
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

Current build, test, formatting and Slither results, including the existing non-green checks and their review, are recorded in [REVIEW.md](REVIEW.md). The only `transferFrom` is made from `sellAll`'s loop with `msg.sender` as the source.

## Website (SwarmSweep)

A single page at `dist/index.html`. The visitor connects through an EIP-6963 browser wallet, a phone wallet’s browser, or Coinbase Smart Wallet. SwarmSweep discovers factory launches independently of SwarmExit registration, reads the held balances, routes, IMD quotes and USD values, and explains unavailable tokens. Sell all and Sell selected open the approval-aware confirmation described above. Ethereum is required for all writes; changing the wallet’s chain or account blocks signing until the correct context is restored.

Receipt events mark each token Sold or Unsold. A held refund takes precedence over a generic refund event and shows its amount and Claim refund action. Claims and owner setup steps are successful only after a successful receipt; failures retain the pending state and provide a transaction link. Wallet-read failures show retry guidance, and previous results remain visibly stale and cannot be sold. The owner panel separates registration from route completion, so interrupted setup can resume with just the missing route call.
### Install, preview, rebuild

```
cd web
npm ci                      # Node 22.23.3 used for this revision; uses the existing lockfile
npm run dev                 # local dev server
npm run typecheck           # tsc --noEmit
npm run build               # typecheck, then vite build into ../dist
npm run preview             # serves the built dist/
node --experimental-strip-types scripts/read-wallet.mjs [address]   # reads a wallet through the site's code against mainnet
```

`dist/` is committed and must be rebuilt and committed after any change under `web/`. The export uses relative asset URLs (`base: "./"`) so it works at an IPFS gateway subpath or an ENS name; there is no server-side routing.

Regenerating the ABI after a change to `src/SwarmExit.sol`: `forge build` at the repository root, then `node web/scripts/gen-abi.mjs`. The committed ABI is checked against the deployment record's `abiHash` with `node --experimental-strip-types web/scripts/check-abi.mjs` (key-sorted JSON, keccak256).

The share image `web/public/og.png` is rendered from `web/scripts/og.html` with `node web/scripts/make-og.mjs` (needs Playwright; see the script header).

### Validation

The 2026-10-19 revision reproduces and fixes all nine reopened findings; `.imd-responses.json` answers each exact finding id for the revision worker. See [REVIEW.md](REVIEW.md) for evidence, all six Better Interface domains, commands, contract review and limitations.

- Production build and explicit TypeScript typecheck pass. The wallet bundle retains Vite’s >500 kB warning.
- 18 client regression tests pass: first-time/mixed approvals, immutable minimums, failed and mixed final simulations, held refunds, reverted receipts, setup retry, account/chain changes and multiple batches.
- Chromium interaction checks cover selection, confirmation, approvals, settlement marks, held claims, setup interruption/retry, read errors, stale results, and wrong-network switching. The export is served under `/preview/` to check relative assets.
- The design probe passes all 16 checks at 320, 390 and 1440 wide. Manual canvas-based checks cover the modern-color holdings text the probe does not resolve; unavailable names, balances, address links and mobile captions meet 4.5:1.
- The supplied wallet read finds 265 launches and 135 held tokens (head at read start: Ethereum block 26228906). The live contract still has zero registrations, no IMD route and no feed. The owner must complete setup before any token can sell here. These are live reads, not a permanent count or a pinned-block snapshot.
- The ABI hash matches the handoff and the compiled 24,519-byte runtime exactly matches the live contract. All 128 non-fork Foundry tests pass at a second fuzz seed with 1,024 fuzz runs. Existing Slither reports and three existing formatting differences in the historical fork test remain documented; this is not a clean static-analysis claim.
- No real transaction was broadcast. WebKit is unavailable in the supplied browser installation. Native screen-reader, physical-wallet/mobile and browser-native 200% zoom checks were not performed. The 2026-10-15 fork results above are historical and were not rerun in this revision.

From `web/`, rerun the client tests with:

```sh
node --experimental-strip-types --test scripts/revision-checks.mjs
```

With an installed Playwright module supplied through `IMD_PLAYWRIGHT` (and its browser path through `PLAYWRIGHT_BROWSERS_PATH`), run from the repository root:

```sh
node --experimental-strip-types web/scripts/interact.mjs
node --experimental-strip-types web/scripts/interact.mjs --revision-only
node .imd/reads/skills/design-critic/scripts/taste.mjs --out test/scratch/taste --offline
```

The taste script is a pinned job input and is available during this assignment. The committed interaction scripts remain runnable with Playwright after handoff. Generated test logs and screenshots go under `test/scratch/` and are not part of the export.
