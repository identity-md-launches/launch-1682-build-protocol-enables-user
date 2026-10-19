# SwarmSweep revision review — 2026-10-19

All nine reopened findings reproduced and are addressed in `.imd-responses.json`. This revision changes the existing website’s planning, execution checks, wallet state, refund reporting, owner setup retry and unavailable-text contrast. Solidity, deployment addresses, ABIs, economics, build configuration and dependencies remain unchanged. This is a worker review and regression record, not independent certification.

## Requirements and live state

| Requirement | Result and evidence |
| --- | --- |
| Read the supplied wallet and identify swarm launches | The actual `loadWallet` code discovered 265 launches and 135 held tokens for `0x0acE1DBE8AAb293cd58D5e3Ea38814f0ccb74782`. Ethereum RPC head at the start was block 26228906; the read took about 10 seconds and was not an atomic pinned-block snapshot. Public source: `https://ethereum-rpc.publicnode.com`. |
| Sell all or selected tokens for cumulative IMD | The unchanged contract accumulates per-token proceeds and transfers one net amount per batch (`src/SwarmExit.sol:389`). Mock-venue contract tests assert the balances, while the frontend interaction tests check selection, confirmation, exact approvals and the sale arguments. Selections above 50 tokens require multiple transactions. |
| Deduct and send the 2% reward/treasury fee | The runtime fixes IMD to `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` and treasury to `0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB`. `test_sellAllHappyPathSplitsTax` and fuzz/invariant tests assert `tax = floor(gross * 200 / 10000)`, the treasury balance increase, and the seller’s cumulative remainder. |
| Refund failed sales | Predictable failures skip before pulling. Execution failures refund the amount received; a blocked refund becomes a protected, seller-owned claim. Tests cover honeypots, transfer fees, refused pulls, held refunds, claim retry, and conservation. The UI distinguishes held claims from tokens already returned. |
| Usable static site and working actions | Production export at `dist/index.html`; local assets and imports use relative URLs. Chromium tests serve it at a `/preview/` subpath, exercise the main actions, inspect errors and reflow at 320, 390 and 1440. No deployment or live transaction was attempted. |
| Product/action on the first phone screen | At 390×844, the product headline, wallet control and Sell all fit on the first screen; Sell all’s disconnected-state bottom is 442 CSS px. Screenshot inspected. |
| Metadata and design documentation | Title, description, favicon, og:title and local og:image are present. `DESIGN.md` describes the final source. `README.md` gives install, preview, typecheck and rebuild steps. |

The live SwarmExit currently has **zero registered tokens, no IMD route and no ETH/USD feed**. Its bytecode exists and exactly matches the compiled source. Discovery works independently of that registry, but selling remains unavailable until the actual owner completes configuration. The existing owner panel supplies those actions; this revision also makes interrupted setup recoverable. No owner signatures or configuration transactions were sent.

The committed ABI canonical hash matches the supplied handoff: `f259fa26782bfa734371ae5b1cad46e56f29ea84e49c0b994e5a241087fd68a2`. The compiled and live runtime both hash to `0x3ee2c3d802b7ed12f15810be0cff541b9fec580ac7aa6e0e4193864cfb509e6d`, at 24,519 bytes (57 bytes below EIP-170).

## Findings, fixes and rechecks

Exact finding ids and verdicts are in `.imd-responses.json`; prefixes below identify the same reports.

| Finding | Reproduction, correction and final evidence |
| --- | --- |
| High `f8d2701f` — first approvals excluded | The original zero-allowance fixture returned zero plan items after `NothingSold`. `web/src/lib/sweep.ts:314` now reads allowances before simulation and retains full-balance estimates for missing/partial approvals. `web/src/components/ConfirmDialog.tsx:67` labels approval-required estimates. Client and browser tests retain these items and run approvals before final simulation. |
| High `fd52f0c9` — minimum silently lowered | The original 100→10 fixture submitted a 9.7 floor; even a 100→98 quote lowered the floor to 95.06. `web/src/lib/sweep.ts:390` now derives every floor from the confirmed plan, sends 97 for a confirmed 100, and stops on a below-minimum quote/status. Client checks assert no write on 100→10. Browser checks refresh and open a new confirmation showing 10 gross / 9.8 net. |
| High `14c5d99b` — unsupported wallet chain | The original export kept selling enabled after an injected Base chain change. `web/src/App.tsx:20` and `web/src/wallet/ConnectSheet.tsx:71` use the connected account’s chain. Every write also checks the live provider chain/account in `web/src/lib/transactions.ts:5`. Chromium verifies disabled sales, switch guidance, and recovery after switching back; client tests switch during approvals and change accounts. |
| High `3073e133` — failed final simulation still signed | The original throwing simulation still caused a sale write. `web/src/lib/sweep.ts:414` now simulates the actual minimum-bearing batch, stops on errors, filters skipped outcomes and re-simulates survivors. No outcomes means no signature. The UI offers Refresh quotes, shows the decoded reason, and marks known unsold tokens. Tests assert zero sale writes on failure/all-skipped and correct arguments for mixed outcomes. |
| Medium `ec1addf6` — held refund overwritten | The original `RefundHeld`, `TokenRefunded` sequence lost the held status. `web/src/lib/sweep.ts:472` gives held events final precedence and retains the amount. Events are limited to the correct emitter, seller and submitted tokens. Both orders pass client tests; Chromium shows the held amount and Claim refund, including after a refused claim. Footer/dialog/completion copy no longer promises every token is already back in the wallet. |
| Medium `67845b6e` — reverted receipt announced as success | Original claim and setup fixtures resolved on reverted receipts. `web/src/lib/transactions.ts:24`, `web/src/lib/sweep.ts:479` and `web/src/lib/owner.ts:42` now require success. Reverted approvals also block the sale. Chromium keeps the held claim and missing route retryable and displays explorer links for failed claims/setup. A later successful claim clears the outstanding amount after a fresh read. |
| Medium `3d67540e` — route retry omitted | Original setup omitted a registered launch with no route. `web/src/lib/sweep.ts:233` reads registration routes separately and `web/src/components/OwnerSetup.tsx:29` includes missing routes. Counts require both registration and a route. Chromium registers a token, rejects its route signature, refreshes, then submits exactly the missing `setTokenRoute` without re-registering. |
| Medium `521a1373` — failed read called empty | The original RPC-error screen simultaneously claimed no tokens. `web/src/components/TokenList.tsx:80` now distinguishes idle/loading/success/error, and only success can show a zero-holdings result. Chromium covers initial failure, recovery, and failed refresh with retained stale rows and disabled selling. Obsolete wallet-context reads cannot repopulate the page. |
| Medium `4408c41c` — faint unavailable data | Original unavailable token text measured rgb(155,152,145) on white, 2.879:1. `web/src/styles.css:395` uses the existing secondary role for names/balances/active address links and removes the faint mobile-caption override. Canvas measurements cover names, balances, links at 320/390/1440 and captions at 320/390. The final pair is rgb(103,99,92) on white, 5.973:1. |

Wrapped viem errors now expose decoded contract reasons or the concise RPC detail (`web/src/lib/format.ts:24`), rather than losing them behind a generic transport message. Partial successful batches are retained if a later batch fails. A 51-token client regression verifies planning/execution stays within the contract’s 50-token limit. These support the reported failure/recovery cases without changing the contract.

## Better Interface coverage

The pinned six-domain reference was read and applied to the affected surfaces. The accepted visual system, page structure, palette, spacing and wallet connector choices were preserved.

| Domain | Coverage and result | Remaining limits |
| --- | --- | --- |
| Accessibility — checked | Native buttons/checkboxes, selection names, dialog roles, inert background, connect-sheet keyboard entry/Escape/focus return, textual status cues, receipt error links and stale/read states. Unavailable data contrast was measured and fixed. | No native screen-reader session, forced-colors session or physical assistive-device test; automated roles are not a screen-reader result. |
| Layout — checked | Production subpath export, 320/390/1440 layouts, first phone screen and connected table/card layout. Screenshots inspected for confirmation, wrong network, route retry, held refund and sale failure. Probe finds no horizontal overflow, text overlap or clipping in its entry state. | No exhaustive token-metadata extremes, localization/RTL stress run or browser-native 200% zoom. |
| Writing — checked | Approval estimates, immutable gross minimums, missing setup calls, failed reads, decoded simulation errors and held refunds say what is actually known and name a recovery action. Removed false “rest stayed in your wallet” / “tokens never rest” promises. | Live quotes are estimates; availability and live setup are not represented as completed actions. |
| Typography — checked | Existing five-size, two-weight, two-family scale retained; balances use tabular numerals. Measured text/notes and the mobile confirmation wrap without overlaps in the tested fixtures. | System font stacks vary across platforms; physical iOS rendering untested. |
| Colors — checked | Reused secondary text for readable unavailable holdings; canvas sRGB conversion measures actual rendered foreground/background pairs. Status includes words, rather than color alone. | taste@1 leaves 38 entry-screen text boxes unmeasured because of its modern-color/background parser. Its contrast pass is not full coverage of every element/overlay/hover state. |
| UI — checked | Existing flat panels and sheets, action states, loading/error/empty states, 44px main controls, reduced-motion behavior and transaction-progress copy retained. Failed final simulation offers refresh rather than another immediate signature. | No browser Animations-panel slow replay or physical wallet prompts. Coinbase passkey account creation and external phone deep-link app launches were not completed. |

The visual idea remains a quiet, single-task sweep tool: a warm page, plain data table, and a single blue primary action. Light theme only; no media, autoplay or theme variants are required.

## Commands and actual outcomes

From `web/`:

```sh
npm ci --cache /tmp/swarmsweep-npm-cache --no-audit --no-fund --loglevel=error
npm run build
npm run typecheck
node --experimental-strip-types --test scripts/revision-checks.mjs
```

- Existing lockfile install succeeded. No manifest, lockfile or dependency/configuration change is submitted.
- Production build and explicit typecheck exited 0. Main wallet bundle is about 642.31 kB / 191.46 kB gzip; Vite’s existing >500 kB warning remains.
- All 18 client regression tests pass. The first 12 assertions were run against the original implementation and failed, establishing the behavior before the fixes.

From the repository root, using the provided Playwright module/browser installation:

```sh
IMD_PLAYWRIGHT=/opt/imd-tools/playwright-mcp/node_modules/playwright/index.mjs PLAYWRIGHT_BROWSERS_PATH=/opt/imd-tools/ms-playwright node --experimental-strip-types web/scripts/interact.mjs
IMD_PLAYWRIGHT=/opt/imd-tools/playwright-mcp/node_modules/playwright/index.mjs PLAYWRIGHT_BROWSERS_PATH=/opt/imd-tools/ms-playwright node --experimental-strip-types web/scripts/interact.mjs --revision-only
IMD_PLAYWRIGHT=/opt/imd-tools/playwright-mcp/node_modules/playwright/index.mjs PLAYWRIGHT_BROWSERS_PATH=/opt/imd-tools/ms-playwright node .imd/reads/skills/design-critic/scripts/taste.mjs --out test/scratch/taste --offline
node --experimental-strip-types web/scripts/check-abi.mjs
```

Chromium runs the existing primary interaction suite and the revision cases. The primary suite covers desktop/phone layout, EIP-6963 discovery, phone wallet links, connect, keyboard/focus, wallet discovery, USD display, selection/cancel, approvals, sale minimums, receipt marks and owner setup. The revision suite covers all nine reports plus their recovery paths. No browser page/console failures were observed in those checked states. Test RPCs and wallet writes are fixtures; none are broadcast.

The probe passes **16/16**, including render, layout, targets, type scale, copy budget, motion and metadata. Its disconnected first screen has 57 prose words at 390 (limit 60). It reports one control below its comfortable 44px recommendation but meeting its minimum/spacing check. Its contrast coverage limitation is recorded above.

Generated evidence is under `test/scratch/` (intentionally excluded from delivery and regenerated by the scripts): `interaction-final.log`, `revision-interaction-final.log`, `revision-client-final.log`, `taste-final.log`, `taste/shots/390.png`, `interact/390-confirm-all.png`, `interact/revision-route-retry.png`, `interact/revision-held-refund.png`, `interact/revision-final-drop.png`, and `interact/revision-final-revert.png`. The 390 first-screen, desktop, confirmation, owner retry and held-claim screenshots were opened and inspected, not merely saved.

WebKit was attempted with `--webkit`; the provided installation has no WebKit executable, so no Safari/WebKit pass is claimed. The browser connector tool returned `Transport closed`; the successful foreground Playwright runs supplied actual Chromium rendering and interaction checks.

## Unchanged contract review

```sh
forge build --offline
forge test --offline
forge fmt --check
forge test --offline --no-match-path 'test/fork/*' --fuzz-seed 0x19 --fuzz-runs 1024
slither . --exclude-informational --exclude-optimization --exclude-low --exclude-medium
slither . --exclude-informational --exclude-optimization --exclude-low
```

Build succeeded. The default run reported 131 passing tests; three are the existing opt-in mainnet fork tests, whose bodies return without a configured fork. The explicit non-fork second-seed run executes **128 real unit/edge/fuzz/invariant tests**, all passing. Its 1,024-run fuzz cases and handler invariants cover conservation, fee accounting, held liabilities, refunds, rescue bounds and callback closure. Historical live-fork results in the README are from the accepted 2026-10-15 work and were not rerun here.

`forge fmt --check` is **not green**: the existing unmodified `test/fork/SwarmExitMainnet.t.sol` has three long signature/call wrapping differences. No cosmetic Solidity changes were made for this frontend revision.

Slither is also **not green**. High-only analysis exits 255 with six reports; including Medium exits 255 with twelve. They were reviewed without suppressions or configuration changes:

| Detector | Disposition and evidence |
| --- | --- |
| `arbitrary-send-eth` (1) | `_send` at `src/SwarmExit.sol:822` is reached only by owner-only `rescue` at line 294. The owner intentionally chooses the recipient; rescue refuses registered tokens and cannot consume held refund liabilities. No public arbitrary-send reproduction was found; rescue access/amount tests pass. |
| `reentrancy-balance` (5 paths) | `sellAll` is nonReentrant; `executeSale` requires `msg.sender == address(this)` and is called inside that guarded sale. The v4 callback requires the currently active manager. The malicious-token reentrancy test and conservation/callback invariants pass. No exploit was reproduced under the documented trusted-owner/route model. This does not prove malicious owner-configured venues safe. |
| `incorrect-equality` (2) | Empty ERC20 return data is a deliberate compatibility case; zero cumulative proceeds deliberately reverts `NothingSold`. These are sentinels, not exact external-price/balance targets. |
| `unused-return` (4) | Swaps settle from measured balance deltas rather than trusting a router return, and the quoter’s extra gas result is unused. ETH/USD validates positive answer and update age but does not use every Chainlink round field; the owner/feed trust assumption remains. |

The contract’s main limits remain: owner-controlled routes/registration/pause, spot pricing, up to 50 inputs per batch, rounded-down tax, token-specific transfer restrictions and possible transfer fees on failed swaps. Frontend preflight cannot guarantee liquidity or token behavior will remain unchanged between simulation and mining. Confirmed on-chain minimums remain enforced. A held refund can only be delivered once the token allows the transfer.

Complete for the nine-finding revision scope, subject to the stated live owner setup and validation limits. No clean Slither, full accessibility, physical-wallet or new mainnet-sale certification is claimed.
